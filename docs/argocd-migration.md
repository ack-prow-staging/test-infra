# Argo CD Migration

Replacing self-managed Flux with the AWS-managed EKS Argo CD capability. Validated on
**staging only** (`086987147623`, us-west-2). Nothing applied to prod.

Detailed rationale lives next to the code: each cut-over path's HelmRelease explains its
own suspension, `bootstrap/argocd-applications.tf` explains the Application shape, and
`flux/argocd/namespaced-rbac.yaml` explains the RBAC grant. This file is the map.

## State

| | |
|---|---|
| Kustomizations / HelmReleases Ready | 27/27, 17/17 |
| Argo CD Applications | 12 live, all Synced/Healthy. A 13th (`prow-build-cluster-resources`) is declared in Terraform but **not applied** — see below |
| Cut over | **12 of 13** chart paths, all `automated`, prune off everywhere |
| ACK CRs | 64, all Argo CD-tracked, 0 deleting |
| Still on Flux | `prow-build-cluster-resources` (raw manifests, awaiting cutover) and the three `${TOKEN}` paths |
| Clusters registered | 2 — hub, plus the build cluster as a spoke |

`Synced` was never progress on its own. An Application whose objects are all Helm hooks has
nothing to compare, so it reports Synced while doing nothing — which is what `prow-mirror` did
from creation until it was given a tracked object. The signal is `suspend: true` on the
HelmRelease plus `automated` on the Application: together they mean exactly one reconciler
owns the path.

## The constraint that shapes everything

The Argo CD control plane is AWS-hosted **off-cluster** — the `argocd` namespace is empty.
Nothing can be read from the cluster at render time: no repo-server to attach a plugin to,
`helm lookup` returns empty, `valuesFrom` does not exist ([argo-cd#12060]). The capability's
whole config surface is `namespace`, `aws_idc`, `rbac_role_mappings`.

That is why every token-bearing path had to become a Helm chart, and why Terraform emits
Application `helm.parameters` directly. `self-managed-vars` is deleted, not replaced.

[argo-cd#12060]: https://github.com/argoproj/argo-cd/issues/12060

## Ownership

Terraform owns what Argo CD cannot bootstrap for itself: the capability, the hub
registration Secret (by cluster **ARN**, not URL), access policy associations, the
AppProject, and the Applications (`bootstrap/argocd*.tf`). `bootstrap/identity/` is separate
state so a routine destroy/apply cannot take out the IdC instance. The hub cluster is
`aws_eks_cluster.this`, not an ACK CR.

Argo CD gets cluster-scoped objects without cluster-admin via a Kubernetes group on the
capability's access entry, bound to narrow rules in `flux/argocd/`. Both RBAC files stay
Flux-owned — Argo CD cannot apply the object that authorises Argo CD. Phase 5 decides who
inherits them.

**Anything keyed to the build cluster is runtime-owned, never Terraform** (D13). The build
cluster is an ACK `Cluster` CR, so Terraform holding a reference to it would be created
before the cluster exists on a fresh bootstrap and removed while Applications still
referenced it on destroy. The `prow-build-cluster-connection` Job therefore does three
things beyond Prow's kubeconfig: reads the cluster ARN from the CR status, writes the Argo CD
spoke registration Secret in `argocd`, and appends the spoke to the AppProject's
`destinations`. Registration alone is not enough — an Application whose `destination.server`
is not listed in its project is *rejected*, not failed at sync.

That last one is why `kubernetes_manifest.argocd_project` carries
`ignore_changes = [manifest.spec.destinations]`. Without it, every `terraform apply` reverts
the list to hub-only; nothing errors, because the Job re-adds it, but in between
build-cluster Applications are rejected — a symptom appearing far from its cause.

**D13 has exactly one carve-out: the `prow-build-cluster-resources` Application.** Its
`destination.server` names the build cluster, and Terraform declares it
(`local.argocd_build_cluster_arn`). D13's two failure modes do not bite for an Application:
created before the cluster exists it is *rejected* — a condition, applying nothing, valid
the moment the Job registers the spoke — and deleted it *orphans* its objects, because
cascade requires the `resources-finalizer.argocd.argoproj.io` finalizer and Terraform does
not set it. Compare the registration Secret, which would advertise a cluster Argo CD cannot
reach, and the AppProject destination, which an apply would revert.

The ARN is **constructed** from `partition`/`region`/`account_id`/`stack_name`, never read,
so there is no plan-time dependency on the CR. The Job still reads it from the CR status
for the Secret and the destination, where the read doubles as proof the cluster exists.
Having the Job create this Application instead was rejected: `repoURL`, `targetRevision`
and the chart values are Terraform's, so the Job would need them threaded through its own
chart, and one path would end up with two owners.

The hub's Argo CD holds **cluster-admin on the build cluster**
(`argocd-build-cluster-access` in the `ack-build-infra` chart). It is a lateral move, not an
expansion: `flux-build-cluster-role` holds exactly that grant today and loses it in Phase 5,
so cluster-admin principals there stay at one. Narrowing it is not available — a narrow
ClusterRole on a remote cluster has no applier once Flux is gone. A build-cluster-local Argo
CD capability was considered and rejected: all 650 Prow jobs target `cluster: build`,
including presubmits, so it would put a control plane with repo access on the cluster that
runs untrusted PR code, and it would still need Terraform to reach an ACK-created cluster to
seed its Applications.

## Applying Terraform during the migration

`test_infra_branch` must be overridden until this merges. SSM and the generated
`environment/staging.tfvars` both say `main`, but the live GitRepository and all Applications
track the migration branch:

```
terraform apply -var-file=environment/staging.tfvars \
                -var test_infra_branch=feat/argocd-migration-clean
```

A bare apply repoints everything to `main`, which has no charts and `prune: true` on the ACK
Kustomizations — the reverse transition, and the destructive direction.

`null_resource.bootstrap_prow_images_job` is tainted; a non-targeted apply rebuilds all 15
Prow images and blocks up to an hour. `terraform untaint` it if unwanted.

## Cutting over a path

1. Snapshot every object's `uid`, `creationTimestamp`, `generation`, **and** its AWS
   identifier — `RoleId`, `associationId`, ECR `createdAt`. For EC2 resources snapshot
   *counts* too: `CreateVpc`/`CreateSubnet`/`CreateNatGateway`/`AllocateAddress` duplicate
   rather than erroring, so a recreated CR adds a second one instead of failing.
2. Set `suspend: true` on the path's **HelmRelease, in git**. `prow-build-cluster-resources`
   is the exception — it has no HelmRelease and cannot have one, so its equivalent step is
   deleting the raw manifests. See its section below.
3. Trigger one sync by patching the Application's `operation`. Do not enable `automated`.
4. Confirm each `uid` held and each object now carries `argocd.argoproj.io/tracking-id`.
5. Set `automated = true` on the path in `bootstrap/argocd-applications.tf`. Until you do,
   the path has **no** reconciler: helm-controller ignores a suspended HelmRelease and a
   manual Application applies nothing, so chart changes sit in git doing nothing. Manual
   sync is only correct for the window between creating an Application and cutting over.
   `prune` stays false everywhere; `selfHeal` too, so Argo CD does not fight manual
   intervention mid-diagnosis.

Suspend must be **in git**: the root `test-infra` Kustomization re-applies every spec, so a
`kubectl patch` suspend is silently reverted and both reconcilers resume owning the objects.
And suspend the **HelmRelease, not the Kustomization** — the HelmRelease is applied *by* its
Kustomization, so a suspended Kustomization can never deliver a suspend to its own
HelmRelease. Keep both declared; cutover then reverses by flipping one field.

**Argo CD runs Helm hooks on syncs that have work, and skips them on no-ops.** That covers
bootstrap, which is what matters for the two hook-driven paths — `prow-charts` dependsOn both,
so they run before Prow exists and a Prow-owned schedule is circular. But a hook is excluded
from the comparison, so a chart containing *only* a hook can never drift and never syncs. Such
a path needs a **tracked object carrying whatever should trigger it**: `prow-mirror` has a
ConfigMap holding the versions it mirrors, so a patch bump is drift. Where live drift is the
right trigger instead, use `selfHeal` — but only where the chart owns no AWS resource, which is
why `prow-build-cluster-connection` has it and the ACK paths do not. A sync requested by
patching `operation` defaults to `syncStrategy.apply`, which skips hooks and cannot be cleared
that way; use `automated`.

**Ignore rendered-vs-live spec diffs.** ACK late-initialises fields the charts never set
(`addonVersion`, `registryID`, `maxSessionDuration`, `disableSessionTags`, …). `ack-prow`
shows 32 such diffs and none is drift: under `ServerSideApply` Argo CD compares only fields
it manages. Do not add `ignoreDifferences` for them — exceptions were tried and removed.
Serialized-JSON fields (`inlinePolicies`, policy documents) cannot be compared as strings at
all; parse them. They also rewrite `generation` harmlessly on sync.

## What is left

| item | blocker |
|---|---|
| `prow-jobs`, `prow-plugins`, `prow-agent-workflows` | still `${TOKEN}`-bearing, so they block Flux removal. Generated by `prow/jobs/generator.go`; the fix belongs in the `.tpl` files and generator, which must emit Helm placeholders rather than baked values so config stays per-environment. Small: 2–3 tokens each, plus 9 in one Job's env for `prow-jobs` |
| `prow-build-cluster-resources` | chart written and Application declared; **needs push, apply and cutover**, none of which has happened. See below |

### Next task in detail: `prow-build-cluster-resources`

The chart exists (`flux/prow/charts/prow-build-cluster-resources`, 13 objects) and the
Application is declared in `bootstrap/argocd-applications.tf`. **Nothing is live.** Argo CD
reads git, so the chart has to be pushed before the Application can render, and the
Application has to be applied before it can sync.

What the conversion settled, so it is not re-derived:

- The out-of-path `configMapGenerator` is gone. Terraform reads
  `prow/jobs/test_config.yaml` with `file()` and passes the **content**; the chart renders
  the ConfigMap. One source file, both clusters, no duplication. Verified byte-identical end
  to end — `yamlencode` round-trips the file, and the rendered `test_config.yaml` key equals
  both the source file and the live ConfigMap on the build cluster.
- `helm.values`, **not** `helm.valuesObject` as previously planned. The reason for rejecting
  `parameters` still holds (they are `--set`, which reads the file's `.` and `,` as path and
  list separators), but `valuesObject` is `x-kubernetes-preserve-unknown-fields`, so
  `kubernetes_manifest` types it dynamically. `values` is a plain string the provider
  handles predictably, and Argo CD writes it to a values file, so multi-line content passes
  through untouched.
- **This path cannot have a HelmRelease, so there is nothing to suspend.** The
  build-cluster `PodIdentityAssociation` binds `serviceAccount: kustomize-controller`
  (`ack-build-infra/templates/flux-pod-identity.yaml`), so helm-controller has no identity
  on the spoke and could never render a release there — checked, and its image carries
  neither `aws` nor `aws-iam-authenticator`. Giving it one means a second association and a
  wider Flux credential footprint, three commits before Flux is deleted. So the raw
  manifests stay, kustomize-controller keeps applying them, and **cutover here means
  deleting them rather than flipping `suspend`**. `prune: false` is already live on that
  Kustomization, which is what makes their removal non-destructive (D19-P1).
- The chart owns the `test-pods` Namespace — the one exception to "no chart owns a
  Namespace", because nothing else reaches inside the build cluster and after Phase 5 this
  path is the only writer left. Guarded at the object level instead: Flux `prune: disabled`,
  `helm.sh/resource-policy: keep`, and `argocd.argoproj.io/sync-options: Prune=false,Delete=false`.
- Argo CD needs no `namespaced-rbac` equivalent on the spoke. Escalation prevention only
  sees in-cluster RBAC, and there the capability holds cluster-admin
  (`argocd-build-cluster-access`), so it can apply the four Roles and RoleBindings directly.

Remaining steps, in order:

1. Push the branch. Until then the Application would render nothing and report a
   ComparisonError, which is why it is deliberately left unapplied.
2. `terraform apply` with the branch override from *Applying Terraform during the
   migration*. Expect **1 to add** — the Application — plus three in-place
   `prune: null -> false` / `selfHeal: null -> false` normalisations on `ack-build-infra`,
   `prow-build-cluster-connection` and `prow-mirror`, which are pre-existing and unrelated.
   Verified by a targeted plan.
3. Cut over per *Cutting over a path*, with step 2 replaced by "delete the raw manifests
   from `flux/prow/build-cluster-resources/` in git". The snapshot to check against is the
   13 uids; content was already confirmed identical, so the only expected change on the
   first sync is annotations — the tracking-id Argo CD adds, plus the guards above.
4. Then `automated = true`, `prune` and `selfHeal` off as everywhere else.

Nothing Phase 5 deletes needs migrating: `prow-build-cluster-kubeconfig` was dropped for
that reason, and `ack-flux` qualifies too (already cut over, harmless).

Flux removal must be the **last** change merged, after every stage cuts over; all three share
one tree.

## Traps

- `AmazonEKSAdminPolicy` at cluster scope **replaces** a namespace-scoped association of the
  same policy, silently widening it. Verify with `list-associated-access-policies`.
- `AmazonEKSBlockStorageClusterPolicy` / `ComputeClusterPolicy` cannot be associated at all —
  service-linked roles only. Declaring either makes every apply fail.
- Argo CD cannot apply Role/RoleBinding objects unaided: escalation prevention only sees
  in-cluster RBAC, so access-policy authorisation counts for nothing. See
  `flux/argocd/namespaced-rbac.yaml`.
- `upgrade.force` does not fix Job immutability; Helm's force is a replace, still rejected on
  a changed Job `spec.template`. `force` is false everywhere.
- `reconcileStrategy: ChartVersion` ignores template edits until `Chart.yaml` `version` bumps
  (`prow/config`, `prow/data-plane`).
- Argo CD reads git, not your working tree.
- AWS names do not always follow the stack prefix — read `spec.name` from the CR. The logs
  bucket is account-suffixed; `supernova-role` is `Nova-DO-NOT-DELETE`, adopted.
- `terraform import` without `-var-file` hangs on stdin holding the state lock.
- Reconcile latency is `dependsOn` polling: ~4 minutes for a full tree walk. Not a fault.
- kubectl context must be `ack-prow-staging`; it has drifted before.

Teardown is scripted (`bootstrap/scripts/cleanup-argocd-resources.sh`): drain first — strip
`automated`, delete Applications with `--cascade=orphan` so Terraform tears down AWS, not
Argo CD pruning.

## Rules cited in code comments

- **D3** — one-shot Jobs leave the sync path.
- **D7** — controllers run off-cluster and cannot be scraped; capability log delivery
  (`bootstrap/argocd-logs.tf`) is the compensating control, and the only way to see why a
  sync behaved as it did.
- **D13** — build cluster AWS resources are only ever ACK CRs on the hub, never Terraform.
  One carve-out, the `prow-build-cluster-resources` Application's `destination.server`; the
  reasoning is under *Ownership* and in the code beside it.
- **D14** — CRD write needs `AmazonEKSKROPolicy`. Its claim that in-cluster RBAC is
  impossible was **wrong**: a group can be added to the access entry and is bindable.
- **D16** — registering the cluster by ARN replaces Flux's own kubeconfig but not Prow's, so
  `prow-build-cluster-connection` survives the migration while
  `prow-build-cluster-kubeconfig` does not.
- **D19-P1** — `prune: false` must be live *before* any content change.
