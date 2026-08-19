# Argo CD Migration

Replacing self-managed Flux with the AWS-managed EKS Argo CD capability. Validated on
**staging only** (`086987147623`, us-west-2). Nothing applied to prod.

Detailed rationale lives next to the code: each cut-over path's HelmRelease explains its
own suspension, `bootstrap/argocd-applications.tf` explains the Application shape, and
`flux/argocd/namespaced-rbac.yaml` explains the RBAC grant. This file is the map.

## State

| | |
|---|---|
| Kustomizations / HelmReleases Ready | 26/26, 17/17 |
| Argo CD Applications | **12 live**, all Synced/Healthy. **16 declared**: 15 by Terraform, all hub-targeted, plus `prow-build-cluster-resources` which is build-cluster-targeted and therefore composed by the connection chart and applied by its Job, never by Terraform (D13). Verified: all 15 render with the exact values Terraform supplies |
| Cut over | **12** paths, all `automated`, prune off everywhere |
| Wired, not live | **8** — `prow-config`, `prow-data-plane`, `prow-jobs`, `prow-plugins`, `prow-agent-workflows`, `prow-build-cluster-resources`, `prow-crds`, `secrets`. All verified against live objects; awaiting push, apply and cutover |
| Deleted, not migrated | **1** — `prometheus-dashboards` and its recording rules. Unmaintained since 2021 |
| ACK CRs | 64, all Argo CD-tracked, 0 deleting |
| Still on Flux, not started | **1** — `prometheus`. Blocked on a privilege decision, not on code: its chart's five ClusterRoles would need 112 further cluster-wide triples, which is cluster-admin by another name. See *What is left* |
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
referenced it on destroy. This covers Kubernetes objects, not just AWS ones. The
`prow-build-cluster-connection` Job therefore does four things beyond Prow's kubeconfig:
reads the cluster ARN from the CR status, writes the Argo CD spoke registration Secret in
`argocd`, appends the spoke to the AppProject's `destinations`, and applies the
`prow-build-cluster-resources` Application. Registration alone is not enough — an Application whose `destination.server`
is not listed in its project is *rejected*, not failed at sync.

That last one is why `kubernetes_manifest.argocd_project` carries
`ignore_changes = [manifest.spec.destinations]`. Without it, every `terraform apply` reverts
the list to hub-only; nothing errors, because the Job re-adds it, but in between
build-cluster Applications are rejected — a symptom appearing far from its cause.

**D13 has no exceptions, and the temptation to make one is worth recording.** The
`prow-build-cluster-resources` Application names the build cluster in
`destination.server`, so Terraform must not declare it either — it is the *fourth* thing
the Job owns, alongside Prow's kubeconfig, the registration Secret and the AppProject
destination. An earlier attempt reasoned that an Application was different because it is
merely *rejected* when its destination is unregistered, and *orphans* its objects when
deleted, and so is harmless in both directions D13 worries about. That is true and still
beside the point: the rule is about what Terraform may hold a reference to, not how bad the
failure looks. A constructed ARN is a reference to a cluster ACK owns.

The distinction that does hold is **values versus objects**. Terraform already supplies
`stackName` and `prowImagesRepoUri` to that Job, and the Job builds
`${stackName}-build-cluster` from them; supplying `testInfraOrg`, `testInfraRepo`,
`testInfraBranch` and the `test_config.yaml` content is the same arrangement. Terraform
supplies values; the Job holds the objects and reads the ARN from the CR status, where the
read doubles as proof the cluster exists.

The Application manifest is composed by the chart into the
`build-cluster-resources-application` ConfigMap and applied by the Job, rather than built
in the Job's shell. That keeps Helm responsible for three levels of nested indentation
(Application → `helm.values` → `test_config.yaml`), and it gives this hook-driven chart a
**tracked** object carrying the Application's desired state — so editing the Application is
drift, which syncs, which re-runs the hook that applies it. Without that, a chart of
nothing but hooks can never drift and never syncs.

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

This table was previously scoped to the paths being converted, which made it read as though
Flux removal were one step away. It is not. Measured against the live cluster — 26
Kustomizations and 17 HelmReleases — twelve paths are cut over, six are converted or wired and
waiting, and **three have not been started**.

A correction worth keeping, because it was mine: an earlier version of this table said the
token-free paths were "blocked on nothing but an Application each". That held for two of the
four. `secrets` and `prometheus` each carry a distinct problem that has nothing to do with
substitution — a cluster-wide RBAC grant and an upstream chart source respectively. Zero tokens
means Argo CD can *render* a path; it does not mean Argo CD is allowed to apply it, or that the
path is even a git directory.

### `prow-charts` splits unevenly, and `prow-config` is not a value-mapping job

`prow-charts` looked like one item. It is two HelmReleases with nothing in common.

**`prow-data-plane` is done and cost nothing.** Zero tokens; its values block was
`region: us-west-2` plus the same ServiceAccount name eight times. Those moved into
`prow/data-plane/values.yaml` as chart defaults — the `prow-mirror` rule that static
git-authored values belong with the structure rather than in Terraform. Verified: rendering from
chart defaults alone is **byte-identical** to rendering with the HelmRelease's explicit values,
and all ten objects (five Roles, five RoleBindings in `test-pods`) match live content. So the
change is inert for stages still on Flux, which keep passing the same values explicitly. The
Application needs no `values`, and therefore no `helm` block.

**`prow-config`: the chart half is done, the value-mapping half is not.** Its 25 token
occurrences were never 25 independent values:

| token | count | what it is |
|---|---|---|
| `ACCOUNT_ID`, `REGION`, `PROW_VERSION`, `PROW_PATCH_REVISION` | 13 each (15 for `ACCOUNT_ID`) | the **same composed image reference**, 13 times: `${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/prow/<component>:${PROW_VERSION}-ack.${PROW_PATCH_REVISION}` |
| `STACK_NAME` ×3, `PROW_DOMAIN` ×2, `PUBLISH_ACCOUNT_ID` ×2 | 7 | bucket names, ingress hostname, ECR reader role |
| `CONTROLLER_ECR_REGISTRY`, `KUBERNETES_ORG`, `REDHAT_ORG`, `STAGE`, `TEST_INFRA_ORG` | 1 each | plain scalars |

Terraform cannot pass those 13 as parameters, because it cannot compose them: `PROW_VERSION` and
`PROW_PATCH_REVISION` are git-authored, live in `flux/prow/version/prow-version-configmap.yaml`,
and are deliberately **not** Terraform's to know — the `prow-mirror` precedent, now applied four
times. Nothing outside the chart holds all four inputs, so nothing outside the chart can build
the string.

**So the composition moved into the chart, and that part is done.** `prow/config` gained an
`imageMirror` block (`accountId`, `region` per-environment; `prowVersion`,
`prowPatchRevision` as git-authored defaults) and a `prow-config.image` helper. Each of the 13
sites now resolves an explicit override *or* composes. Proven behaviour-preserving three ways:
rendering with the HelmRelease's values is byte-identical to the previous chart, rendering with
`imageMirror` and no explicit images produces the same manifests, and all nine composed component
references match the live Deployment images exactly.

Two things that bit while doing it, both worth keeping:

- **`default` does not short-circuit.** `.Values.x.image | default (include "…")` evaluates the
  `include` eagerly, so the composition ran even when an override was set and its `required`
  calls failed on `imageMirror` values a Flux render has no reason to supply. The override is
  resolved *inside* the helper instead.
- **`toString` on every input.** A 12-digit AWS account id written unquoted in a values file is
  read as a float, and `printf %s` then yields `%!s(float64=8.6987147623e+10)` — a syntactically
  valid image reference that fails at pull time rather than at render time. Argo CD parameters
  and `--set` both keep it a string; a hand-written values file is what this guards.

**The value mapping is done too, and it needed no `helm.values` block** — 12 parameters and
nothing else, which took two changes to earn:

- The 13 image references are composed by the chart, as above.
- The ALB annotations moved into the chart as defaults. Two of them are JSON containing commas
  (`alb.ingress.kubernetes.io/actions.ssl-redirect`, `listen-ports`), which `--set` reads as list
  separators, so leaving them in the Application would have forced a `values` block. The one
  per-environment annotation, the external-dns hostname, is now composed in the Ingress template
  from `prow.domain` — which that template already used as the host.

Everything else static followed the same rule applied five times now: the `github.bot` identity,
`buildCluster.enabled`/`name`, the `scrapeMetrics` flags and the eight serviceAccount names are
chart defaults. The HelmRelease still passes them identically while stages remain on Flux.

`buildCluster.clusterName` is deliberately **not** passed. Its only consumer,
`build-cluster-kubeconfig-ConfigMap.yaml`, is gated on `buildCluster.server`, which nothing sets
any more — the connection Job writes that ConfigMap instead (D16). So the value is unused, and
Terraform never has to compose a string naming the build cluster, which is why D13 does not arise
on the largest path.

Two parameter names could not match their keys (`github.organisation`, `imageMirror.accountId`,
and the rest), so `bootstrap/argocd-applications.tf` gained a `value_paths` map alongside `values`:
the parameter name is the chart path and `--set` reads the dots as a path, which is what is wanted.

Verified three ways. Rendering the chart with the HelmRelease's values is identical before and
after (37 objects), so Flux stages are untouched. Rendering with only the 12 parameters is
identical to rendering with the HelmRelease's full values. And all 12 parameter values match what
`self-managed-vars` substitutes today, checked against the live ConfigMap rather than assumed —
worth doing, since two of them (`kubernetesOrg`, `redhatOrg`) are `ack-prow-staging` in this
environment rather than the upstream names a reader would guess.

Still note `reconcileStrategy: ChartVersion` on this HelmRelease: template edits are ignored until
`Chart.yaml` `version` bumps (see Traps), which bites while iterating on the Flux side.

### `prometheus`: migrating it as-is costs cluster-admin

This was carried in the backlog as "an upstream chart source plus a values file, and probably a
wider CRD exception". Both halves of that were wrong.

**The CRDs are already covered.** `AmazonEKSKROPolicy` grants
`apiextensions.k8s.io/customresourcedefinitions: *`, so all ten `monitoring.coreos.com` CRDs are
fine, and escalation prevention does not apply to CRDs — they are not RBAC objects. Note that
`kubectl auth can-i --as-group=argocd-cluster-scoped` reports `no` for CRDs anyway: access
policies are enforced by the EKS authorizer and are invisible to a SubjectAccessReview. That is a
limitation of the probe, not a gap, and it is worth remembering before reading any `can-i` result
here as evidence.

**The blocker is the chart's own RBAC.** Rendered with the live values, `kube-prometheus-stack`
84.5.0 produces 125 objects including **five ClusterRoles**. Escalation prevention requires the
applier to hold every rule in a ClusterRole it creates, and measured against what the RBAC
authorizer can actually see — `flux/argocd/cluster-scoped-rbac.yaml`, not the access policies:

| | |
|---|---|
| Argo CD holds today | 53 triples |
| The five ClusterRoles need | 121 triples |
| **Missing** | **112**, over **13 API groups** |
| Of those, non-read | 47 triples over 35 resources |

The missing set includes the `*` verb, and write on
`mutatingwebhookconfigurations`/`validatingwebhookconfigurations` — which is its own escalation
path, since whoever can write admission webhooks can intercept or mutate every API request in the
cluster. `prometheus-kube-prometheus-operator` alone accounts for 57, `kube-state-metrics` for 50.

Granting all 112 is not a bigger version of the `prow-plugins` or `secrets` decisions. It is
`AmazonEKSClusterAdminPolicy` by another route — the exact thing the header of
`cluster-scoped-rbac.yaml` records as refused. And it would be spent on the **least** critical path
in the repo: monitoring, not Prow.

Options, none of them free:

1. **Disable RBAC creation in the chart and let Terraform own those five ClusterRoles.**
   `rbac.create: false` on the subcharts, and Terraform — which is cluster-admin and hub-owned —
   applies them. Argo CD then never applies an RBAC object for this path and needs no new grant.
   Cost: 121 upstream rules copied into Terraform, to be re-synced on every chart upgrade, with
   drift being silent.
2. **Keep `prometheus` on Flux** and scope Flux removal to everything else. Honest, and cheap
   today, but it means Flux never fully goes away, which was the point.
3. **Replace the chart** with AWS-managed monitoring (AMP plus managed Grafana, or the EKS
   observability add-on). Removes the problem, the 112 triples and the vendoring question at once,
   and is the largest change.
4. **Grant the 112.** Recorded for completeness. It makes the Argo CD capability role
   cluster-admin in all but name, including admission-webhook write.

Whichever is chosen, the mechanism questions that looked like the work here are secondary. For the
record, since they were measured: the chart is 7.2 MB unpacked across 297 files and five subcharts,
so vendoring it into `charts/` — the house pattern, per `charts/flux2-2.18.4` and
`scripts/pull-flux-chart.sh` — is 12× the flux2 chart. The alternative, a multi-source Application
with a `$values` ref, avoids vendoring but adds the repo's first multi-source Application, needs
the Helm repo in the AppProject's `sourceRepos`, and assumes the managed capability's repo-server
has egress to a third-party Helm repo, which is unverified. Vendoring depends on nothing but git.

### `secrets`: two gaps, and the second is not "read"

Measured with `kubectl auth can-i --as-group=argocd-cluster-scoped`, which is the view the RBAC
authorizer has. Both gaps returned `no` on every probe.

**Gap 1, done.** The path declares a `SecretProviderClass` in `prow` and another in `test-pods`,
and Argo CD could not write either. This is *not* escalation prevention — an SPC is not an RBAC
object — it is a plain permission `AmazonEKSAdminPolicy` withholds, because it mirrors the
built-in `admin` ClusterRole and that excludes **CRD instances**. ACK's CRs escape this via
`AmazonEKSACKPolicy`; there is no equivalent for `secrets-store.csi.x-k8s.io`. Granted narrowly:
`get,create,update,patch` on `secretproviderclasses` in exactly those two namespaces, no
`delete`. Required whichever way gap 2 is settled, so it landed ahead of the decision.

**Gap 2, granted — and it is the widest grant in this migration.** `secrets-store-rbac.yaml` is a
ClusterRole giving the CSI driver `secrets` **create, delete, get, list, patch, update, watch**
cluster-wide. Escalation prevention requires the applier to hold *every* rule in a ClusterRole it
creates, so Argo CD now holds all seven verbs on every Secret in the cluster. **That is not read
access for health assessment** — it is read, write and delete on every credential in the cluster,
including ones this repo does not own, reachable by anything that can act as the capability role.

There is no narrower version that still applies the object: a subset fails the escalation check,
and the only other mechanism is the `escalate` verb, rejected here and in `namespaced-rbac.yaml`
for being broader still. It was authorised explicitly after being priced, which is the only reason
it is here rather than deferred — three earlier grants in this file could honestly be described as
restatements of access Argo CD already had, and this one cannot.

**Take the exit condition.** Narrow the CSI driver's own ClusterRole to namespaced Roles and this
rule can be deleted outright, because Argo CD would then need only *namespaced* secrets write,
which `AmazonEKSAdminPolicy` already grants it in both namespaces. The measurements say that is
viable: the ClusterRoleBinding's only subject is the single `secrets-store-csi-driver`
ServiceAccount in `aws-secrets-manager`, and the only SecretProviderClasses in the entire cluster
are `prow/prow-secrets` and `test-pods/prow-secrets`. The driver writes Secrets in two namespaces,
not all of them. That change belongs to whoever owns the CSI driver deployment, and it is a
two-object edit.

Verified for the path itself: all four objects render identical to live, the grantor ClusterRole
covers all seven of the driver ClusterRole's triples exactly, and no token needs substituting.

### The token-free paths need no conversion at all

`prow-crds` and `secrets` are wired this way, and they were the first paths that required **no
chart and no generator change**. Both are plain kustomize directories with no `${TOKEN}`, so Argo
CD reads the same directory Flux reads and runs kustomize itself. That is worth stating plainly:
the chart conversions were never about Helm being better, only about `postBuild` substitution
having no Argo CD equivalent. With no tokens, there is nothing to solve.

`prometheus-dashboards` was wired the same way and then **deleted instead of migrated** — see
*Deleted rather than migrated* below. These notes describe the shape; that path is gone.

Consequences specific to this shape:

- The Application carries **no `helm` block at all**. `helm` is explicit tool configuration and
  wins detection, so an empty `helm: {parameters: []}` would make Argo CD run Helm against a
  directory with no `Chart.yaml` and fail instead of falling through to `kustomization.yaml`.
  `bootstrap/argocd-applications.tf` omits the block when a path declares no values.
- **Cutover is suspending the Flux Kustomization, not removing content.** The path is shared and
  unchanged, so the objects never go stale.
- `prune: false` still had to land first, and for a different reason than usual: deleting or
  suspending a Kustomization with prune enabled garbage-collects what it applied. For
  `prow-crds` that is the ProwJob CRD, and it would take every ProwJob with it.
- `kustomize` features carry over unchanged. `generatorOptions` — `disableNameSuffixHash`, and
  labels applied to generated ConfigMaps — is plain kustomize, not Flux, so Argo CD honours it.

Verified: all four `secrets` objects render identical to live, and the CRD matches on every field
except `spec.preserveUnknownFields: false`, which the API server accepts and drops as deprecated —
recorded against that Application as the one thing to expect on first sync, with no
`ignoreDifferences` added pre-emptively, per the rule above.

### Deleted rather than migrated: the Prow Grafana dashboards

`prow/prometheus-dashboards/` and the `prow-rules` recording rules in
`flux/prometheus/helm-release.yaml` are gone. They were one artifact set, added together in a
single commit in September 2021 (`93470a6`, taken from `loodse/prow-dashboards`) and never touched
again in the roughly five years since. Nothing outside that set referenced the `prow:pod` /
`prow:job` series the rules computed — the only files mentioning them were the rules themselves
and the four dashboard JSONs — so the rules existed solely to feed dashboards nobody was
maintaining. Carrying them across would have meant an Application, a cutover and a uid check for
5,437 lines of JSON on the assumption someone still opened them.

Both live objects are cleaned up by Flux rather than by hand, which is worth knowing before going
looking for them. The `prometheus-dashboards` Kustomization was applied with `prune: true`, so
deleting it from git garbage-collects the `grafana-prow-dashboards` ConfigMap; the PrometheusRule
disappears as an object dropped from the `prometheus` Helm release. Verified by rendering the chart
without the rules: 124 objects instead of 125, and no `prow` PrometheusRule.

Grafana itself stays. Its sidecar picks up 29 dashboard ConfigMaps and 28 come from the chart; only
the one was ours.

| item | blocker |
|---|---|
| the four converted paths | push, `terraform apply`, then cut over. No code left to write; see the two sections below for their specifics |
| ~~`prow-charts`~~ → ~~`prow-config`~~, ~~`prow-data-plane`~~ | **done.** The data-plane half was free; `prow-config` needed a chart change plus 12 parameters and no `values` block. See below |
| ~~`prow-crds`~~ | **done.** Genuinely just an Application — see below |
| ~~`prometheus-dashboards`~~ | **deleted, not migrated.** Unmaintained since 2021 and nothing referenced its metrics — see below |
| ~~`secrets`~~ | **done**, and it cost the widest grant in the migration. Take the exit condition — see below |
| `prometheus` | **the only path left, and it is not a mechanism problem.** Migrating it as-is would make Argo CD effectively cluster-admin. Measured below; needs a decision, not code |
| Phase 5 deletions | `flux/flux` (Flux itself, 5 tokens), `flux/prow/version`, `flux/prow/build-cluster-kubeconfig`, the root `test-infra` Kustomization, `self-managed-vars`. `flux/argocd/` is the exception: it must survive and needs a new owner, since Argo CD cannot apply the objects that authorise Argo CD |
| `prow-build-cluster-resources` | chart written and Application declared; **needs push, apply and cutover**, none of which has happened. See below |

### Next task in detail: `prow-build-cluster-resources`

The chart exists (`flux/prow/charts/prow-build-cluster-resources`, 13 objects) and its
Application is composed by `prow-build-cluster-connection`'s
`templates/application.yaml` and applied by that chart's Job. **Nothing is live.** Argo CD
reads git, so the branch has to be pushed before either chart renders the new content.

Note what applying it does *not* need: no `terraform apply` creates this Application.
Terraform's only change here is three more parameters and a `values` string on the
*connection* Application, which is hub-targeted. Once that lands, the connection path
syncs, the ConfigMap appears, the Job runs and the build-cluster Application exists.

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
- The Application is **runtime-owned** (D13), composed into a ConfigMap by the connection
  chart and applied by its Job. Terraform declaring it — with the ARN constructed from
  `partition`/`region`/`account_id`/`stack_name` — was tried and reverted; see *Ownership*
  for why "the failure mode is harmless" is not a reason to hold the reference. The content
  is verified intact through all three nesting levels: Terraform `yamlencode` → connection
  `helm.values` → ConfigMap → composed Application `helm.values` → the rendered ConfigMap
  equals both the source file and the live object.
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

1. Push the branch. Both charts are read from git, so nothing before this has any effect.
2. `terraform apply` with the branch override from *Applying Terraform during the
   migration*. Expect **0 to add, 3 to change**: the connection Application gains
   `testInfraOrg`/`testInfraRepo`/`testInfraBranch` parameters and the `values` string, and
   `ack-build-infra`, `prow-build-cluster-connection` and `prow-mirror` each show a
   pre-existing `prune: null -> false` / `selfHeal: null -> false` normalisation. Verified by
   a targeted plan. **No plan entry should mention the build cluster** — that is the check
   that D13 still holds.
3. Let the connection path sync. It has `selfHeal`, so the new ConfigMap and the re-run hook
   follow automatically. Confirm the Job's log shows the spoke registered, the AppProject
   destination present, and the Application applied; then confirm
   `kubectl -n argocd get app prow-build-cluster-resources` exists and is **not** rejected
   (a rejected Application means the destination is missing from the project, i.e. the
   ordering inside the Job broke).
4. Sync it once manually and confirm all 13 uids held against
   `/tmp/prow-build-cluster-resources-uid-baseline.json`. Content is already confirmed
   identical, so the only expected change is annotations — Argo CD's tracking-id plus the
   guards on the Namespace, NodeClass and NodePool.
5. Cut over per *Cutting over a path*, with step 2 replaced by "delete the raw manifests from
   `flux/prow/build-cluster-resources/` in git", then add the `automated` block that
   `templates/application.yaml` carries commented out. `prune` and `selfHeal` stay off, as
   everywhere else.

Nothing Phase 5 deletes needs migrating: `prow-build-cluster-kubeconfig` was dropped for
that reason, and `ack-flux` qualifies too (already cut over, harmless).

### The three generated paths: measured, not estimated

The earlier note said "2–3 tokens each, plus 9 in one Job's env". The counts are now measured,
and the one that matters is that **`jobs.yaml` is not part of any kustomize render**.

`prow/jobs/kustomization.yaml` lists only `job-config-job.yaml` as a resource, so
`kustomize build ./prow/jobs` yields **32 token occurrences, 10 distinct** — and that is the
entire Flux postBuild surface for `prow-jobs`. The 11,511 tokens in `jobs.yaml` (8524 of them
`${TEST_INFRA_ORG}`) are resolved **in-cluster** by the `job-config-substitutor` Job, which
git-clones the branch and runs `envsubst` because the file exceeds the 1 MB ConfigMap limit
and has to be gzipped — and postBuild cannot substitute into `binaryData`. That mechanism is
independent of the reconciler and keeps working unchanged under Argo CD. It is not migration
work.

Measured Flux-substituted surface:

| path | render surface | distinct tokens |
|---|---|---|
| `prow-jobs` | `job-config-job.yaml` + 3 generated ConfigMaps | 10 — org/repo/branch, `PROW_IMAGES_REPO_URI`, `CONTROLLER_ECR_REGISTRY`, `ACCOUNT_ID`, `REGION`, `PROW_VERSION`, `TOOLS_VERSION`, `PROW_PATCH_REVISION` |
| `prow-plugins` | `deployment.yaml` (+ untokenised rbac/service) | 3 — `PROW_IMAGES_REPO_URI`, `STACK_NAME`, `ACCOUNT_ID` |
| `prow-agent-workflows` | one ConfigMap | 2 — `PROW_IMAGES_REPO_URI`, `TEST_INFRA_ORG` |

Seven of those ten already exist in `local.argocd_chart_values`. The gaps:

- `CONTROLLER_ECR_REGISTRY` — in `self-managed-vars`, absent from `argocd_chart_values`. One
  new value. Note it has **zero occurrences in `jobs.yaml`** despite being passed to
  `envsubst`, so check whether it is dead before plumbing it.
- `PROW_VERSION`, `TOOLS_VERSION`, `PROW_PATCH_REVISION` — in **neither**. They come from the
  git-authored `prow-version` ConfigMap, which `prow-jobs` reaches via a second
  `substituteFrom`. Terraform does not own them and should not: they are static git strings.
  `prow-mirror` already set the precedent — it carries them as chart `values.yaml` defaults
  rather than as Terraform parameters. Reuse that, and `flux/prow/version/` becomes another
  Phase 5 deletion rather than something to replace.

#### The pattern, established on `prow-agent-workflows`

**The generator does not change.** That was the plan and it is the wrong lever. The
`${TOKEN}` placeholders are how *every* stage gets per-environment values, and the stages
still on Flux resolve them with `postBuild`; emitting Helm actions instead breaks them the
moment this merges. Regenerating also rewrites all seven generated files whatever else
changes, because `addAutoGenHeader` restamps `# Last generated on <timestamp>` every run.

Instead: **the chart lives in the generated file's own directory** and reads it with
`.Files.Get`, resolving the tokens with `replace`.

- `.Files.Get` is chart-rooted, so this layout is the only one where the chart can read the
  generated file *from git*. Putting the chart under `flux/prow/charts/` would force
  Terraform to read the file with `file()` and pass the content — which works (the
  build-cluster `test_config` does exactly that) but means `make prow-gen` has no effect
  until someone also runs `terraform apply`. For a 226-byte config that never changes, fine.
  For generated Prow config, no: it belongs to git, so git is what Argo CD reads.
- Terraform supplies only the scalars, which are the tokens' values, all of which already
  exist in `local.argocd_chart_values`.
- `templates/` is shared with the generator's own `.tpl` input, which Helm would try to
  render and fail on (`nil pointer evaluating interface {}.ImageRepo`). A `.helmignore`
  naming that file exactly fixes it — verified both ways. Named exactly rather than `*.tpl`
  so a newly emitted template breaks loudly instead of being skipped.
- `replace` leaves an unrecognised token as literal text, which would reach a ConfigMap as
  `image: ${SOMETHING}:tag` and fail later in a pod pull. So the template ends with
  `regexFind` + `fail`, turning that into a render error that names the token. Verified by
  injecting one.
- The kustomize `configMapGenerator` stays for the stages still on Flux. Both read the same
  file and produce the same object, so the two reconcilers cannot disagree on content.

`prow-agent-workflows` renders one ConfigMap, byte-identical to the live
`agent-workflow-config`, same single `workflows.yaml` key.

#### `prow-plugins` is blocked on an RBAC decision, not on rendering

The rendering half is easy and follows the pattern exactly: chart root
`prow/plugins/deployments/`, three tokens (`PROW_IMAGES_REPO_URI`, `STACK_NAME`,
`ACCOUNT_ID`) all present in `argocd_chart_values`, and no `.helmignore` needed because the
generator's templates live in `prow/plugins/templates/`, a different tree.

The blocker is that `agent-plugin/rbac.yaml` contains a **ClusterRole and
ClusterRoleBinding**, granting `prow.k8s.io/prowjobs` create/get/list/watch/update/patch,
`pods` get/list/watch and `pods/log` get. Measured against the live cluster with
`kubectl auth can-i --as-group=argocd-cluster-scoped`, which is exactly the view escalation
prevention has (access policies are enforced by the EKS authorizer and are invisible to it):

```
create clusterroles                no      create prowjobs (all ns)   no
create clusterrolebindings         no      patch  prowjobs (all ns)   no
                                           list   pods     (all ns)   no
                                           get    pods/log (all ns)   no
```

So two separate things are missing, the same pair that `argocd` namespace needed: the ability
to create ClusterRoles at all, and holding what the created ClusterRole grants.
`cluster-scoped-rbac.yaml` currently grants only storageclasses, ingressclasses, nodepools
and nodeclasses.

**This was not a subset-restatement, and that made it a decision rather than a detail.**
Every previous grantor rule was defensible as "no access Argo CD lacked, expressed where the
RBAC authorizer can see it" — `AmazonEKSAdminPolicy` already gave it those permissions,
namespace-scoped. Holding prowjobs write and pod read *cluster-wide* is genuinely wider.

**Decided: grant it, in `cluster-scoped-rbac.yaml`.** Two rules added — `clusterroles` and
`clusterrolebindings` get/create/update/patch, and the plugin ClusterRole's own rules mirrored
exactly. Verified the grantor now covers all 10 of that ClusterRole's (group, resource, verb)
triples, that it can create ClusterRoles, and that it carries no `delete` and no `escalate`.

What bounds it: kustomize-controller already holds strictly more and loses it in Phase 5, so
the count of broadly-privileged principals does not go up.

The better option is still open and is recorded in that file: **narrow the plugin's own
ClusterRole to namespaced Roles**, which the evidence supports — its Deployment pins
`PROW_JOB_NAMESPACE: "prow"` and all 48 live ProwJobs are in `prow`, so the ClusterRole is
wider than the workload needs. It was not taken here because it changes generated RBAC and
the plugin's effective permissions, which belongs to whoever owns agent-plugin. If it lands,
shrink the grantor rules to match; they only need to remain a superset.

**Ordering requirement.** The grantor rules must be live *before* `prow-plugins` first syncs.
They sit on the `flux/argocd` path, so Flux applies them. A sync attempted first fails on
escalation with a message naming the plugin's ClusterRole rather than the missing grantor
rule, which points at the wrong file.

`prow-jobs` is the last and most awkward: its `templates/` holds 26 generator templates, and
it has the two problems below.

#### `prow-jobs`, and the two things that bit

Converted the same way, with three differences worth knowing.

**The immutable Job.** `job-config-job.yaml` carries a `batch/v1` Job whose `spec.template` is
immutable, which is what `force: true` on the Kustomization handles today. Argo CD's
equivalent is the per-resource annotation `Force=true,Replace=true`, which the Argo CD docs
name for exactly this case ("job resources that should run every time when syncing"). The
chart inserts it by anchoring on the Job's four identity lines rather than by parsing and
re-serialising the document, so the file's comments survive — with an assertion that fails
the render if the anchor stops matching, since a silent no-op would bring the immutability
error back later. Scoped to the Job by annotation and **not** set on the Application: as an
Application-level syncOption, `Force` would delete and recreate the ConfigMaps and RBAC too,
handing them new uids, which is the one thing the cutover procedure exists to catch.

**Flux's `$$` unescaping had to be reproduced.** Two sequences in that file are escaped so
postBuild leaves them for the container — `envsubst '$$TEST_INFRA_ORG ...'`, where the
container needs `$VAR` so envsubst restricts substitution to those names, and
`config.yaml: "$${GZIPPED_B64}"`, which the container's shell expands. Helm has no unescaping
step. Both failure modes are silent: `$$TEST_INFRA_ORG` reaching envsubst leaves jobs.yaml
unsubstituted, and `$${GZIPPED_B64}` reaching bash expands `$$` to the shell PID and writes a
corrupt `job-config`. The chart sentinels `$$` before substituting, guards, then unescapes —
in that order, so the guard cannot mistake an escaped sequence for an unresolved token.
Asserted against what the container needs rather than against a reference render, since the
`flux` CLI is not available here.

**`selfHeal` is load-bearing here, not a nicety.** `ttlSecondsAfterFinished` deletes the Job
300s after it finishes; Argo CD sees the absence as drift and recreates it, which re-runs it
and refreshes `job-config`. That reproduces today's behaviour, where the same ttl against a 5m
Kustomization interval means Flux recreates it on most reconciles. Without it the Job would run
once and `job-config` would go stale the next time `jobs.yaml` changed — `jobs.yaml` is not a
tracked object here, so its content cannot be the trigger. It is inert until `automated` is
set at cutover, which is the right order: kustomize-controller keeps recreating the Job until
then.

Also: `jobs.yaml` is in `.helmignore`. At 1.9 MB it is the largest file in the repo, it never
enters the render, and excluding it keeps it out of every manifest generation.

One trap found by verification rather than by reading: **the block scalar's chomping indicator
has to follow the file.** A clipped `|` always emits exactly one trailing newline, which is
right for `test_config.yaml` and `jobs_config.yaml` but adds a byte to `labels.yaml`, which the
generator writes without one. One byte is a real content difference to the API server, so it
would have shown as permanent drift against the object kustomize produced. The template picks
`|` or `|-` per file.

A note that outlives these conversions: regeneration is **not** byte-stable.
`addAutoGenHeader` stamps `# Last generated on <timestamp>` into all seven generated files on
every run, so `make prow-gen` always produces a diff in files dev and prod also consume. That
is a standing reason to run it deliberately rather than incidentally — and part of why none of
these conversions changed the generator.

An earlier draft of this section proposed making the Job a Helm hook with
`before-hook-creation`, on the grounds that Helm's `force` cannot fix Job immutability (it
cannot — see Traps). That was not needed: Argo CD's per-resource `Force=true,Replace=true`
covers it without taking the Job out of the tracked set, which is what keeps `selfHeal` able
to re-run it.

Unrelated but found while measuring, and worth someone's attention: **`periodics_enabled` is
not wired to anything.** `prow/jobs/jobs_config.yaml` commits it as `true`, shared verbatim by
every environment, and it is not declared in `bootstrap/variables.tf` — its only other
appearance is the struct tag in the generator. A `dev.tfvars` was setting it to `"false"`, which
Terraform never read; that file is generated from SSM, untracked, and has been removed, so the
committed `true` is now the only value anywhere. If an environment ever needs periodics off,
note that it changes the *shape* of `jobs.yaml` (`periodics: []` instead of the rendered
directory) rather than a value, so it is a large diff and not a parameter.

Flux removal must be the **last** change merged, after every stage cuts over — and after the
six unstarted paths above, not just these three. The generated paths share one tree, so their
conversions land together or not at all.

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
- **D13** — anything keyed to the build cluster is runtime-owned, never Terraform. Its AWS
  resources are ACK CRs on the hub; the Kubernetes objects that name it — the registration
  Secret, the AppProject destination, the `prow-build-cluster-resources` Application — are
  written by the `prow-build-cluster-connection` Job. **No exceptions**; Terraform supplies
  values to that Job, never objects. See *Ownership*.
- **D14** — CRD write needs `AmazonEKSKROPolicy`. Its claim that in-cluster RBAC is
  impossible was **wrong**: a group can be added to the access entry and is bindable.
- **D16** — registering the cluster by ARN replaces Flux's own kubeconfig but not Prow's, so
  `prow-build-cluster-connection` survives the migration while
  `prow-build-cluster-kubeconfig` does not.
- **D19-P1** — `prune: false` must be live *before* any content change.
