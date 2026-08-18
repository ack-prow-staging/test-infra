################################################################################
# Argo CD authorization and cluster registration
#
# Everything here is pure Terraform. No local-exec, no kubectl.
#
# What EKS already did for us when the capability was created (verified live):
#   AmazonEKSArgoCDClusterPolicy  scope=cluster
#   AmazonEKSArgoCDPolicy         scope=namespace, namespaces=[argocd]
#
# Those cover Argo CD's OWN operation - reading its CRs, reading cluster
# registration Secrets, API discovery, namespace creation, CRD create. They do NOT
# grant permission to deploy workloads or to read arbitrary resources for health
# assessment. That is what this file adds.
#
# Authorization is granted via EKS access policies rather than in-cluster RBAC,
# because Argo CD cannot apply the object that authorizes Argo CD. The repo already
# documents this pattern for Flux in flux/ack/build-cluster/access-entries.yaml.
################################################################################

################################################################################
# SCOPE: hub cluster only.
#
# Nothing here touches the build cluster, deliberately. The build cluster is not
# registered as an Argo CD spoke until Phase 4, and when it is, its AccessEntry
# belongs in flux/ack/build-cluster/access-entries.yaml as an ACK CR alongside the
# eight already there - not in Terraform. See the migration plan, D13.
################################################################################

locals {
  argocd_capability_role_arn = aws_iam_role.argocd_capability.arn

  # Namespaces Argo CD may write to on the hub.
  #
  # Granting authorization is not the same as Argo CD acting: while Flux still owns
  # these objects there are no Applications targeting them, so this is inert until
  # Phase 4 cutover. flux-system is transitional and should be dropped in Phase 5.
  argocd_hub_namespaces = [
    "ack-system",
    "prow",
    "test-pods",
    "prometheus",
    "flux-system",
  ]
}

################################################################################
# Hub cluster (control plane) authorization
################################################################################

# Cluster-wide read for resource discovery and health assessment. Argo CD needs to
# read all resource types cluster-wide even when it writes to only a few namespaces.
resource "aws_eks_access_policy_association" "argocd_hub_read" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = local.argocd_capability_role_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSAdminViewPolicy"

  access_scope {
    type = "cluster"
  }
}

# Write access, namespace-scoped.
#
# ONE association carrying the full namespace list - NOT for_each over namespaces.
# aws_eks_access_policy_association is keyed by (cluster, principal, policy), so its
# Terraform ID contains no namespace component:
#   <cluster>#<principal-arn>#<policy-arn>
# A for_each over namespaces therefore produces N resources all contending for the
# same AWS resource. They thrash on every apply and only the last writer survives,
# silently leaving the other namespaces ungranted. namespaces is a list property of
# a single association, not a key.
resource "aws_eks_access_policy_association" "argocd_hub_write" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = local.argocd_capability_role_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"

  access_scope {
    type       = "namespace"
    namespaces = local.argocd_hub_namespaces
  }
}

################################################################################
# Cluster registration
#
# Registration is a labelled Secret in the capability's namespace. The server field
# must be the EKS cluster ARN - API server URLs and kubernetes.default.svc are not
# supported. No connection credentials are needed; the capability derives them from
# the capability role and the access entries above.
#
# The hub registration must be Terraform-owned: Argo CD cannot deploy anything until
# at least one cluster is registered, so this is the chicken-and-egg seam.
################################################################################

resource "kubernetes_secret_v1" "argocd_cluster_hub" {
  metadata {
    name      = "in-cluster"
    namespace = "argocd"

    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
    }
  }

  data = {
    name    = "in-cluster"
    server  = aws_eks_cluster.this.arn
    project = kubernetes_manifest.argocd_project.manifest.metadata.name
  }

  depends_on = [awscc_eks_capability.argocd]
}

################################################################################
# AppProject
#
# spec.sourceNamespaces is REQUIRED by the managed capability and must contain the
# capability's configured namespace. Omitting it does not error clearly - Applications
# in that namespace simply cannot reference the project, surfacing as deployment
# failures. The built-in "default" project is not relied upon for this reason.
#
# kubernetes_manifest validates against the live API at PLAN time, so the Argo CD
# CRDs must already exist. That holds here because the capability created them. On a
# fresh bootstrap the capability and this resource would be in the same apply, so the
# capability must be applied first - see the note in the migration plan.
################################################################################

resource "kubernetes_manifest" "argocd_project" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "AppProject"

    metadata = {
      name      = "test-infra"
      namespace = "argocd"
    }

    spec = {
      description = "ACK test-infra platform applications"

      sourceNamespaces = ["argocd"]

      sourceRepos = [
        "https://github.com/${var.test_infra_org}/${var.test_infra_repo}",
      ]

      # Hub only. The build cluster is added as a destination in Phase 4, when it is
      # registered as a spoke - not before. A destination for an unregistered cluster
      # would be misleading.
      destinations = [
        {
          server    = aws_eks_cluster.this.arn
          namespace = "*"
        },
      ]

      clusterResourceWhitelist = [
        {
          group = "*"
          kind  = "*"
        },
      ]
    }
  }

  depends_on = [awscc_eks_capability.argocd]
}

################################################################################
# CRD write exception
#
# AmazonEKSArgoCDClusterPolicy grants customresourcedefinitions `create`, but
# get/update/patch/delete only on Argo CD's OWN CRDs. Any Application that manages a
# third-party CRD therefore installs it successfully on first sync and then fails
# forever on the next one. Confirmed live in staging:
#
#   customresourcedefinitions.apiextensions.k8s.io "..." is forbidden: User
#   ".../ack-test-infra-staging-argocd-capability-role/..." cannot patch resource
#   "customresourcedefinitions" in API group "apiextensions.k8s.io" at the cluster scope
#
# It does not fail fast either - the Application retries indefinitely and sits in
# Running, so the symptom is a stuck sync rather than a clear permission error.
#
# This matters for prow-crds, which installs the ProwJob CRD and must be able to
# refresh it when scripts/upgrade-prow.sh pulls a new version from upstream.
#
# Granted as narrow in-cluster RBAC on exactly one resource type rather than by
# attaching AmazonEKSClusterAdminPolicy, which would hand over the whole cluster.
#
# Terraform must own this: it is the object that authorizes Argo CD, so Argo CD
# cannot apply it (3.4).
################################################################################

# Custom in-cluster RBAC CANNOT be used here, which is worth recording because the
# AWS docs suggest otherwise. The capability's auto-created access entry has:
#
#   kubernetesGroups: []
#   username: arn:aws:sts::<acct>:assumed-role/<role>/{{SessionName}}
#
# There is no group to bind to, and the username is session-templated - at runtime it
# resolves to a fresh value like aws-go-sdk-1787004054908077004. A ClusterRoleBinding
# to "eks-access-entry:<principal-arn>", which the Register-target-clusters docs
# recommend, binds to a group that does not exist and silently grants nothing.
# Verified by attempting exactly that: the CRD patch stayed forbidden.
#
# A separate IAM role does not help either - every capability role gets an identical,
# equally unbindable access entry. The only lever is which access POLICIES are
# associated.
#
# AmazonEKSKROPolicy grants apiextensions.k8s.io/customresourcedefinitions: * . It is
# AWS-managed and far narrower than AmazonEKSClusterAdminPolicy. Its incidental
# grants (kro.run/*, leases, events) are inert here - no kro CRDs are installed.
resource "aws_eks_access_policy_association" "argocd_hub_crd" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = local.argocd_capability_role_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSKROPolicy"

  access_scope {
    type = "cluster"
  }
}
