################################################################################
# Argo CD Applications for the converted chart paths.
#
# Terraform emits these rather than Git, because Terraform already owns the values.
# The 29 chart parameters below are the same locals that populate the
# self-managed-vars ConfigMap, so this is one hop shorter than Flux's route
# (Terraform -> ConfigMap -> HelmRelease.valuesFrom -> chart) and needs nothing read
# from the cluster at render time, which Argo CD cannot do: it renders off-cluster,
# valuesFrom against a ConfigMap does not exist (argo-cd#12060), Helm's lookup
# returns empty, and there is no repo-server here to attach a plugin to.
# self-managed-vars is deleted in Phase 5, not replaced.
#
# THREE DELIBERATE SAFETY CHOICES, each mirroring something that already went wrong
# once during this migration:
#
#   prune is NOT enabled. If Argo CD's rendered set does not exactly match what is
#   live, prune deletes the difference. This is the same discipline that made
#   prune: false a prerequisite on the Flux side, and it is why the earlier incident
#   was survivable. Enable per Application only after its diff is confirmed empty.
#
#   automated sync is NOT enabled. Applications are created in manual sync so Argo CD
#   computes the diff and applies nothing. Every object here already exists and was
#   verified byte-identical, so the expected initial state is OutOfSync purely from
#   reconciler ownership labels - Flux's kustomize.toolkit.fluxcd.io/* are present on
#   live objects and absent from Argo CD's desired state. An OutOfSync Application
#   here means labels, not content, and that must be confirmed before syncing.
#
#   ServerSideApply=true. Live objects carry field managers from kustomize-controller
#   and from Helm. SSA transfers ownership field by field instead of fighting them.
#
# The three generated prow paths (prow-plugins, prow-jobs, prow-agent-workflows) are
# deliberately absent. They still contain ${TOKEN} placeholders and Argo CD has no
# substitution, so an Application would write image: ${PROW_IMAGES_REPO_URI}:... into
# a Deployment and GITHUB_ORG: ${TEST_INFRA_ORG} into the agent workflow config. They
# stay on Flux until their generator emits Helm placeholders instead.
#
# prow-build-cluster-resources is absent for a different and permanent reason: its
# destination is the BUILD CLUSTER, and D13 puts anything keyed to that cluster out of
# Terraform's reach entirely. Terraform declaring it would hold a reference to a cluster
# ACK owns - created before the cluster exists on a fresh bootstrap, removed while its
# objects still depend on it on destroy. It is created at runtime by the
# prow-build-cluster-connection Job, which already reads the cluster ARN from the CR
# status, writes the spoke registration Secret and appends the AppProject destination.
#
# Terraform's part is unchanged in kind from what it already does for that Job: it supplies
# VALUES (repo coordinates, stackName, the test_config content), never the object. See the
# prow-build-cluster-connection entry below.
#
# prow-build-cluster-kubeconfig is absent for a different reason: it does not outlive
# Flux, so there is nothing to migrate. The build-cluster-flux-kubeconfig ConfigMap
# exists only so kustomize-controller can remote-apply into the build cluster, its one
# consumer is that Kustomization's kubeConfig.configMapRef, and Phase 5 deletes
# flux/prow/build-cluster-kubeconfig/ outright - the Access Entry replaces it. Moving
# it to Argo CD first would mean adopting an object in order to delete it.
#
# Note the contrast with flux/prow/build-cluster-connection/, which looks similar and
# is NOT deleted: it writes the build-cluster-kubeconfig that Prow's own components
# mount, so it survives the migration and does have an Application (D16).
#
# ack-flux is in the same category and is already cut over, done before this was
# noticed. Its PullThroughCacheRule caches ghcr.io/fluxcd images for Flux and Phase 5
# removes it with the rest. Left as-is rather than reverted - it is working and
# un-migrating it would be churn - but it does not need to reach automated sync.
################################################################################

locals {
  # Parameters every chart may draw from, keyed by the chart value name. Sourced from
  # the same locals as self-managed-vars so the two cannot drift while both exist.
  argocd_chart_values = {
    stackName         = local.stack_name
    accountId         = local.account_id
    region            = var.region
    publishAccountId  = var.publish_account_id
    prowDomain        = var.prow_domain
    ghcrPtcSecretArn  = data.aws_secretsmanager_secret.ghcr_ptc.arn
    prowImagesRepoUri = local.prow_images_repo_uri

    # Repo coordinates, needed by prow-build-cluster-connection because the Application it
    # creates at runtime has to name its own source. Terraform uses these for every
    # Application's source already (see repoURL / targetRevision below) and for the
    # AppProject's sourceRepos; passing them as chart values is the same data by the route
    # a runtime owner can reach. They say nothing about the build cluster.
    testInfraOrg    = var.test_infra_org
    testInfraRepo   = var.test_infra_repo
    testInfraBranch = var.test_infra_branch

    # For prow-jobs. The only token on the three generated paths that had no counterpart here
    # and had to be added; same expression as CONTROLLER_ECR_REGISTRY in self-managed-vars, so
    # the two cannot drift while both exist.
    #
    # It is threaded into the substitutor Job's env and passed to envsubst over jobs.yaml, but
    # currently has zero occurrences in that file. Kept because dropping it would change the
    # Job's behaviour on a path being migrated; worth removing from both once confirmed dead.
    controllerEcrRegistry = "public.ecr.aws/${local.controller_ecr_alias}"
  }

  # One entry per converted chart path. `values` lists which parameters that chart
  # requires; each is declared `required` in the chart, so a missing entry fails at
  # render time rather than producing a truncated name or ARN.
  argocd_applications = {
    ack-capability-role = {
      path             = "flux/ack/charts/ack-capability-role"
      target_namespace = "ack-system"
      values           = ["accountId", "region", "stackName"]
      automated        = true
    }
    ack-capability = {
      path             = "flux/ack/charts/ack-capability"
      target_namespace = "ack-system"
      values           = ["accountId", "stackName"]
      automated        = true
    }
    ack-cluster = {
      path             = "flux/ack/charts/ack-cluster"
      target_namespace = "ack-system"
      values           = ["accountId", "stackName"]
      automated        = true
    }
    ack-addons-roles = {
      path             = "flux/ack/charts/ack-addons-roles"
      target_namespace = "ack-system"
      values           = ["stackName"]
      automated        = true
    }
    ack-addons = {
      path             = "flux/ack/charts/ack-addons"
      target_namespace = "ack-system"
      values           = ["accountId", "stackName"]
      automated        = true
    }
    ack-pod-identity-roles = {
      path             = "flux/ack/charts/ack-pod-identity-roles"
      target_namespace = "ack-system"
      values           = ["accountId", "publishAccountId", "region", "stackName"]
      automated        = true
    }
    ack-pod-identities = {
      path             = "flux/ack/charts/ack-pod-identities"
      target_namespace = "ack-system"
      values           = ["accountId", "stackName"]
      automated        = true
    }
    ack-prow = {
      path             = "flux/ack/charts/ack-prow"
      target_namespace = "ack-system"
      values           = ["accountId", "prowDomain", "stackName"]
      automated        = true
    }
    ack-flux = {
      path             = "flux/ack/charts/ack-flux"
      target_namespace = "ack-system"
      values           = ["ghcrPtcSecretArn"]
      automated        = true
    }
    ack-build-infra = {
      path             = "flux/ack/charts/ack-build-infra"
      target_namespace = "ack-system"
      values           = ["accountId", "region", "stackName"]
      automated        = true
    }
    prow-build-cluster-connection = {
      # flux-system, not ack-system: the Job writes build-cluster-kubeconfig there and
      # Prow's crier, deck, sinker and prow-controller-manager mount it from there.
      # Unlike prow-build-cluster-kubeconfig this path survives Flux (D16), which is
      # why it has an Application and that one does not.
      path             = "flux/prow/charts/prow-build-cluster-connection"
      target_namespace = "flux-system"
      automated        = true

      # The last three exist so the Job can compose the prow-build-cluster-resources
      # Application, whose destination is the build cluster and which Terraform therefore
      # must not declare (D13). The Job supplies the one field Terraform cannot know - the
      # cluster ARN, read from the CR status - and the chart supplies the rest.
      values = ["prowImagesRepoUri", "stackName", "testInfraOrg", "testInfraRepo", "testInfraBranch"]

      # The content of prow/jobs/test_config.yaml, which the composed Application passes on
      # to the prow-build-cluster-resources chart so the build cluster's test-config
      # ConfigMap comes from the same file the hub's does.
      #
      # It has to travel as a value because that chart cannot read it: the directory it
      # replaces used a `../../../` configMapGenerator reference, which only
      # kustomize-controller permits (it builds with load restrictions disabled). The
      # managed capability exposes no equivalent, kustomize refuses to read above the
      # kustomization root, and Helm's .Files.Get is chart-rooted. Relocating the file is
      # not an option either - prow/jobs/ and that chart share only the repo root, so
      # "relocating" means duplicating, which is the drift the shared reference prevents.
      #
      # values_yaml, NOT a parameter. Parameters are passed as --set, which reads `.` and
      # `,` as path and list separators and this file contains both. Not valuesObject
      # either: that field is x-kubernetes-preserve-unknown-fields, so kubernetes_manifest
      # types it dynamically, while values is a plain string the provider handles
      # predictably.
      #
      # file() at 226 bytes, precedent at images.tf:63. Verified byte-identical to the live
      # ConfigMap on the build cluster, same single test_config.yaml key.
      values_yaml = yamlencode({
        testConfig = file("${path.module}/../prow/jobs/test_config.yaml")
      })

      # The only path with selfHeal on, and the difference is deliberate. Its Job is a
      # Helm post-install/post-upgrade hook, which Argo CD maps to PostSync and runs
      # whenever a sync has work to do - so making live drift a sync trigger is also what
      # gives the Job a re-run trigger. Verified: deleting one Role and the Job caused
      # Argo CD to restore the Role and re-run the hook, and the Job rebuilt
      # build-cluster-kubeconfig byte-identically.
      #
      # Safe here in a way it is not on the ACK paths: this chart owns only in-cluster
      # RBAC and a Job. There is no AWS resource behind any of it, so Argo CD reasserting
      # desired state cannot fight ACK or overwrite someone mid-diagnosis of AWS state.
      self_heal = true
    }
    # The two token-free paths. NOTHING IS CONVERTED FOR THESE.
    #
    # Both are plain kustomize directories with no ${TOKEN} anywhere, so there was nothing for
    # postBuild to do and nothing for a chart to solve. Argo CD reads the same directory Flux
    # reads and runs kustomize itself; no `values`, and therefore no `helm` block, which is
    # what lets tool detection fall through to kustomization.yaml.
    #
    # Their cutover is also different: because the path is unchanged, the objects never go
    # stale, so cutover is suspending the Flux Kustomization in git rather than removing
    # content. `prune: false` still had to go in first - deleting or suspending a Kustomization
    # with prune enabled garbage-collects what it applied, and for prow-crds that means the
    # ProwJob CRD and every ProwJob with it.
    prow-crds = {
      # One CustomResourceDefinition, cluster-scoped, so target_namespace is only a default.
      #
      # Argo CD can manage it because AmazonEKSArgoCDClusterPolicy grants CRD create, and
      # bootstrap/argocd-access.tf adds the narrow in-cluster rule for get/update/patch that
      # the policy withholds for CRDs Argo CD does not own. That exception was added for this
      # path specifically - scripts/upgrade-prow.sh needs to refresh this CRD.
      #
      # ONE FIELD TO WATCH ON FIRST SYNC, and only one: the manifest sets
      # spec.preserveUnknownFields: false, which the API server accepts and then drops, because
      # it is deprecated and already the default for apiextensions.k8s.io/v1. Everything else in
      # the render matches live exactly. If Argo CD reports this path OutOfSync with that field
      # as the only difference, that is why - and an ignoreDifferences entry for it is the fix.
      # Not added pre-emptively, per the rule in the migration doc: add an exception only for a
      # field Argo CD itself calls OutOfSync. Editing the CRD instead would fork it from
      # upstream, and upgrade-prow.sh would overwrite the edit.
      path             = "flux/prow/crds"
      target_namespace = "prow"
    }
    prometheus-dashboards = {
      # Four Grafana dashboard JSONs in one generated ConfigMap. The generator sets
      # disableNameSuffixHash and the grafana_dashboard: "1" label that Grafana's sidecar
      # watches for, and kustomize under Argo CD honours both - they are plain
      # generatorOptions, not a Flux feature.
      #
      # The ConfigMap carries no namespace of its own; the Flux Kustomization supplies it via
      # targetNamespace, and here destination.namespace does the same job.
      path             = "prow/prometheus-dashboards"
      target_namespace = "prometheus"
    }
    prow-jobs = {
      # Last of the generated paths. Same shape as the other two - chart in the generated
      # files' own directory, read with .Files.Get, generator untouched - but three things are
      # specific to it.
      #
      # Its templates/ holds 25 generator templates across four subdirectories, all named in
      # .helmignore. jobs.yaml is ignored too: at 1.9 MB it is the largest file in the repo and
      # the chart does not need it, because it never enters the render. It exceeds the 1 MB
      # ConfigMap limit, so the substitutor Job clones the repo at runtime, resolves it with
      # envsubst and gzips the result into job-config. That mechanism is reconciler-independent
      # and survives the migration untouched, which is why the 11,511 tokens in that file are
      # not migration work.
      #
      # The Job's spec.template is immutable, which is what `force: true` on the Flux
      # Kustomization handles. The chart annotates that Job alone with
      # `Force=true,Replace=true`, which is the case the Argo CD docs name for jobs that should
      # re-run on sync. Scoped to the Job by annotation rather than set here: as an
      # Application-level syncOption it would delete and recreate the ConfigMaps and RBAC too,
      # giving them new uids, which is exactly what the cutover procedure checks against.
      #
      # And it reproduces Flux's `$$` unescaping in the chart. Two sequences in
      # job-config-job.yaml are escaped so postBuild leaves them for the container -
      # `envsubst '$$TEST_INFRA_ORG ...'` and `config.yaml: "$${GZIPPED_B64}"`. Helm has no
      # unescaping step, and getting it wrong is silent: jobs.yaml would go unsubstituted, or
      # bash would expand `$$` to its PID and write a corrupt job-config. Asserted in the
      # chart and in verification against what the container needs.
      path             = "prow/jobs"
      target_namespace = "prow"

      # prowVersion, toolsVersion and prowPatchRevision are deliberately absent, as on
      # prow-mirror: static git-authored strings, so they are chart defaults rather than
      # per-environment parameters. Phase 5 deletes flux/prow/version/ and leaves those
      # defaults as the only copy - until then all three copies must agree.
      values = ["prowImagesRepoUri", "testInfraOrg", "testInfraRepo", "testInfraBranch", "accountId", "region", "controllerEcrRegistry"]

      # selfHeal, and here it is load-bearing rather than a nicety. ttlSecondsAfterFinished
      # deletes the Job 300s after it finishes, which Argo CD sees as drift; selfHeal recreates
      # it, which re-runs it and refreshes job-config. That reproduces today's behaviour, where
      # the same ttl against a 5m Kustomization interval means Flux recreates it on most
      # reconciles. Without it the Job would run once and job-config would go stale the next
      # time jobs.yaml changed - jobs.yaml is not a tracked object here, so its content cannot
      # be the trigger.
      #
      # Safe for the same reason it is on prow-build-cluster-connection: this chart owns RBAC,
      # ConfigMaps and a Job, with no AWS resource behind any of it.
      #
      # Inert until cutover: selfHeal sits inside the automated block, so declaring it here
      # does nothing while sync is manual. That is the correct order - kustomize-controller is
      # still recreating the Job on its own interval until this path is cut over, so nothing
      # stops refreshing job-config in between.
      self_heal = true

      # NOT cut over. Manual sync until the first sync confirms the six live objects kept their
      # uid; the Job is absent most of the time and is expected to be created, not adopted.
      # prow-jobs' Kustomization has had prune: false all along.
    }
    prow-plugins = {
      # Second of the generated paths. Same shape as prow-agent-workflows - chart in the
      # generated files' own directory, read with .Files.Get, generator untouched, Terraform
      # supplying only the scalars - so see that entry for the reasoning.
      #
      # What is different: this path's rbac.yaml carries a ClusterRole and ClusterRoleBinding,
      # and Argo CD could neither create those nor hold cluster-wide what they grant, so
      # escalation prevention would have refused them. That was a decision rather than a
      # detail, and it was taken deliberately: flux/argocd/cluster-scoped-rbac.yaml now grants
      # both, which is the one privilege EXPANSION in this migration rather than a restatement
      # of access Argo CD already had. The alternative - narrowing the plugin's own ClusterRole
      # to namespaced Roles - is better and still open, but it changes generated RBAC and the
      # plugin's effective permissions, so it belongs to whoever owns agent-plugin. Read the
      # block in that file before touching this.
      #
      # ORDERING: those grantor rules must be live before this Application first syncs. They
      # are on the flux/argocd path, so Flux applies them; a sync attempted first fails on
      # escalation with a message naming the ClusterRole rather than the missing rule.
      path             = "prow/plugins/deployments"
      target_namespace = "prow"
      values           = ["prowImagesRepoUri", "stackName", "accountId"]

      # NOT cut over. Manual sync until the first sync confirms all five objects kept their
      # uid - the Deployment matters most, since its spec.selector is immutable and a
      # recreate would drop the webhook server. prow-plugins' Kustomization has prune: false
      # as of the earlier commit (D19-P1).
    }
    prow-agent-workflows = {
      # First of the three generated paths to convert, and the smallest: one ConfigMap, two
      # tokens, no workload objects.
      #
      # The chart is IN prow/agent-workflows/, not under flux/prow/charts/ with the others,
      # because .Files.Get is chart-rooted and that is the only layout where the chart can
      # read the generated agent-workflows.yaml from git. The alternative - Terraform
      # reading it with file() and passing the content, as the build-cluster test_config
      # does - would mean `make prow-gen` had no effect until someone also ran terraform
      # apply. Workflow definitions belong to git, so git is what Argo CD reads and
      # Terraform supplies only the two scalars below.
      #
      # The generated file keeps its ${TOKEN} placeholders and the generator is untouched.
      # Those placeholders are how every stage gets per-environment values, and the stages
      # still on Flux resolve them via postBuild; emitting Helm actions instead would break
      # them on merge and would rewrite all seven generated files, since the generator
      # restamps a timestamp on every run. The chart resolves the two tokens with `replace`
      # and fails the render if an unrecognised one appears.
      #
      # kustomization.yaml stays in place for those stages. It and this chart read the same
      # file and produce the same object, verified byte-identical against the live
      # ConfigMap, so the two reconcilers cannot disagree about content.
      path             = "prow/agent-workflows"
      target_namespace = "prow"
      values           = ["prowImagesRepoUri", "testInfraOrg"]

      # NOT cut over. Manual sync until the first sync confirms the ConfigMap kept its uid;
      # kustomize-controller still owns it via the prow-agent-workflows Kustomization, whose
      # prune is now false (D19-P1) so removing that path later will not delete the object.
    }
    prow-mirror = {
      path             = "flux/prow/charts/prow-mirror"
      target_namespace = "test-pods"
      automated        = true
      # prowVersion, toolsVersion and prowPatchRevision are deliberately absent:
      # they are static git-authored strings and now live as defaults in the chart's
      # values.yaml, not as per-environment parameters Terraform supplies.
      values = ["accountId", "region"]
    }
  }
}

resource "kubernetes_manifest" "argocd_application" {
  for_each = local.argocd_applications

  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = each.key
      namespace = "argocd"
    }
    spec = {
      project = kubernetes_manifest.argocd_project.manifest.metadata.name

      source = merge(
        {
          repoURL        = "https://github.com/${var.test_infra_org}/${var.test_infra_repo}"
          targetRevision = var.test_infra_branch
          path           = each.value.path
        },
        # helm is OMITTED ENTIRELY for paths that are not charts, which is why this is a merge
        # rather than a literal object.
        #
        # A `helm` block is explicit tool configuration and wins Argo CD's tool detection
        # outright. Emitting `helm = { parameters = [] }` for a kustomize directory would make
        # Argo CD run Helm against a directory with no Chart.yaml and fail, instead of falling
        # through to the implicit rule that finds kustomization.yaml.
        #
        # Those paths exist because substitution was the only thing that forced the chart
        # conversions: a path with no ${TOKEN} needs no values, so Argo CD can read the same
        # kustomize directory Flux reads, unchanged. Nothing is converted for them at all.
        lookup(each.value, "values", []) == [] && lookup(each.value, "values_yaml", null) == null ? {} : {
          helm = merge(
            {
              # Parameters, not a values file: these are per-environment and Terraform is
              # the only thing that knows them.
              parameters = [
                for k in lookup(each.value, "values", []) : {
                  name  = k
                  value = local.argocd_chart_values[k]
                }
              ]
            },
            # values carries anything --set cannot express - currently only the test_config
            # content for prow-build-cluster-connection, whose `.` and `,` characters --set
            # would read as path and list separators. Argo CD applies values first and
            # parameters second, and the two never carry the same key, so they do not
            # interact.
            lookup(each.value, "values_yaml", null) != null ? {
              values = each.value.values_yaml
            } : {}
          )
        }
      )

      destination = {
        # The capability registers the cluster by ARN, not by URL. A URL here would
        # not match the AppProject destination and the Application would be rejected.
        #
        # Always the hub, with no override. Every Application Terraform declares targets the
        # cluster Terraform owns; the one Application whose destination is the build cluster
        # is composed at runtime by the prow-build-cluster-connection Job, because Terraform
        # must hold nothing keyed to a cluster ACK owns (D13).
        server    = aws_eks_cluster.this.arn
        namespace = each.value.target_namespace
      }

      syncPolicy = merge({
        syncOptions = [
          "ServerSideApply=true",
          # Namespaces are owned by prow-namespaces.yaml and by Terraform, never by a
          # chart, so Argo CD must not create them either.
          "CreateNamespace=false",
        ]
        },
        # automated is set only on paths that are cut over, and it is what makes the
        # cutover complete rather than merely started. Once a path's HelmRelease is
        # suspended, helm-controller ignores it; with sync still manual, Argo CD applies
        # nothing either, so a change to that chart would be reconciled by NEITHER
        # reconciler and would sit in git doing nothing. Manual sync is correct only for
        # the window between creating an Application and cutting its path over.
        #
        # prune stays false everywhere. Argo CD deleting whatever its rendered set does
        # not contain is the failure this whole migration was shaped to avoid, and it is
        # not needed for reconciliation - only for garbage collection, which nothing
        # requires yet.
        #
        # selfHeal is false as well, deliberately. It reverts live changes Argo CD did not
        # make, which during a migration means fighting a human mid-diagnosis. Without it
        # Argo CD syncs on git changes and leaves manual intervention alone.
        lookup(each.value, "automated", false) ? {
          automated = {
            prune    = false
            selfHeal = lookup(each.value, "self_heal", false)
          }
        } : {}
      )

      # NO ignoreDifferences, deliberately. ACK late-initialises fields the charts never
      # set - addonVersion and encryptionConfiguration and registryID, maxSessionDuration
      # and path on every Role, disableSessionTags on every association - and a plain
      # spec comparison flags all of them. They are NOT drift to Argo CD.
      #
      # ServerSideApply is why: Argo CD diffs only the fields it manages, so fields owned
      # by another field manager (`eks`, the ACK controller) are not part of the
      # comparison. Confirmed by experiment rather than by reading: exceptions for
      # addonVersion and disableSessionTags were added, then removed from the live
      # Applications and the paths hard-refreshed - both stayed Synced with
      # ignoreDifferences: []. ack-addons-roles and ack-pod-identity-roles have always
      # been Synced with no exception despite their Roles carrying late-initialised
      # maxSessionDuration and path.
      #
      # So do not add an exception because `helm template` differs from live. Cut the path
      # over and let Argo CD report; add one only for a field Argo CD itself calls
      # OutOfSync. RespectIgnoreDifferences=true was removed with the exceptions since it
      # does nothing without them.
    }
  }

  # The Applications describe paths that Flux is still reconciling. Creating them is
  # inert while sync is manual, but they must not be created before the AppProject
  # that authorises the repo and destination.
  depends_on = [kubernetes_manifest.argocd_project]
}
