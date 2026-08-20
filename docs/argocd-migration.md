# Argo CD Migration

Replacing self-managed Flux with the AWS-managed EKS Argo CD capability. Validated on
**staging only** (`086987147623`, us-west-2). Nothing applied to prod.

Detailed rationale lives next to the code: each cut-over path's HelmRelease explains its
own suspension, `bootstrap/argocd-applications.tf` explains the Application shape, and
`bootstrap/argocd-rbac.tf` explains the RBAC grant. This file is the map.

**To migrate an environment, use `docs/argocd-migration-runbook.md`.** That is the executable
sequence: which commits to merge in which stages, what to apply between them, the manual steps
that no merge performs, and the gate that must pass before each next stage. This file explains
why; the runbook says what to do. The single most important thing in it: **merge in stages, not
wholesale** - landing the Flux suspensions at the same time as the charts leaves paths reconciled
by neither reconciler.

## State

| | |
|---|---|
| Kustomizations / HelmReleases | 24 Kustomizations (6 suspended), 16 HelmReleases (14 suspended). Every unsuspended one is Ready. The suspended `prow-build-cluster-resources` reads `Ready=False / DependencyNotReady` — a condition frozen at the moment of suspension, not a live fault; suspension stops reconciliation, it does not clear status |
| Argo CD Applications | **21, all Synced/Healthy, all `automated`.** 19 are rendered from git by `root-applications`, the one Application Terraform declares; the 21st, `prow-build-cluster-resources`, is composed by the connection chart and applied by its Job at runtime (D13) |
| Who owns the Application definitions | **git**, in `argocd/applications/`. Terraform holds the root plus the 16 per-environment values it passes as one `helm.values` blob. Adding or changing a path is a commit, not a `terraform apply` |
| Cut over | **all 20 paths.** The migration is done on staging; every path is Argo CD-reconciled |
| Deleted, not migrated | **2** — the Prow Grafana dashboards with their recording rules (unmaintained since 2021), and `kube-prometheus-stack` itself (no reachable Grafana, alerts routed to `"null"`, and migrating it would have cost Argo CD cluster-admin) |
| uid preservation | **78 of 79 objects adopted in place.** The one exception is the `job-config-substitutor` Job, recreated by design via `Force=true,Replace=true` past its immutable `spec.template` |
| Branch state | `feat/argocd-migration-clean` deployed to staging and cut over. Terraform applied targeted at the Applications and the access-policy association |
| `prometheus` teardown | complete. The namespace and all 10 `monitoring.coreos.com` CRDs are deleted; see below for what Flux left behind and why it had to be done by hand |
| Argo CD's own RBAC | Terraform's, in `bootstrap/argocd-rbac.tf`. 14 objects adopted by import, uids held, and `terraform plan` is a clean no-op so drift detection means something |
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

### Alternatives considered

Recorded because "why not just keep the kustomizations" is the first question this design invites,
and because only one of the alternatives is ruled out by the platform — the rest are judgement.

| alternative | why not |
|---|---|
| **Config management plugin** (envsubst sidecar) — the direct equivalent of `postBuild` | Not available. A CMP is a sidecar on the repo-server, and there is no repo-server to attach one to. The only alternative closed by the platform rather than chosen against |
| **Kustomize `replacements`** from a committed per-env values file | The strongest option: renders from git alone, no Argo CD feature, no cluster read, YAML stays YAML. Rejected because the values that differ are `accountId`, `testInfraOrg`, `testInfraRepo`, `testInfraBranch` — so the repo becomes environment-aware, and org/branch are self-referential, the repo declaring which repo and branch to read. They already live in SSM, which `bootstrap-env.sh` reads to write `tfvars`; committing them to git is a second source of truth that drifts silently |
| **Kustomize patches via the Application spec** (`kustomize.patches`, Terraform-emitted) | Satisfies the off-cluster constraint through the same channel as `helm.parameters`, but patches target objects by group/kind/name. `accountId` appears across 11 apps, so it needs one precisely-targeted patch per occurrence. Fine for a handful of values, not for this surface |
| **Rendered manifests** — CI renders, commits plain YAML to an env branch | Solves substitution outright and gives reviewable pre-merge diffs. Circular here: Prow is the CI and Prow is what is being migrated, so a broken Prow could not be repaired through GitOps |
| **Terraform renders the manifests** (`templatefile` + `kubernetes_manifest`) | Abandons GitOps for the manifest layer and puts Terraform back in the position this migration takes it out of. See *Ownership* |
| **Self-hosted Argo CD on-cluster** | Hands back the repo-server and plugins, so substitution stops being a problem at all. This is the honest answer to whether the constraint was necessary: it was not inherent, it follows from choosing the hosted capability, which bought no controller to run, no cluster-admin, and capability log delivery |

**Two things make the chosen path cheaper than it looks.** Helm was already in the stack before the
migration — four HelmReleases, and `prow/config` and `prow/data-plane` already had `Chart.yaml`,
`values.yaml` and `templates/`, so for those paths this only changed who renders them, from
helm-controller to Argo CD. And the charts are thin: `ack-cluster` has 2 distinct `.Values`
references, `ack-prow` 3, `ack-capability` 2. The whole parameter surface is 14 values across 19
paths, dominated by `accountId` and `stackName` at 11 apps each. The templating layer does nothing
but substitute, so the usual objection about logic accumulating in templates does not apply.

**The cost accepted:** adding a new value now touches Terraform, not git alone, because the value
has to reach the Application spec. That is the coupling behind the one commit in the sequence whose
git half genuinely depends on its Terraform half (`Give the Prow namespaces and ServiceAccounts an
owner` — the wave-0 Application needs the `namespaces` grant landing in the same stage). Kustomize
replacements from git would have decoupled that, and it is the one dimension on which the rejected
alternative is better. With the environment values living in SSM rather than git, the trade still
favours charts.

The dividing line held: **only paths needing an environment-specific value were converted.** 15 of
19 take `helm.parameters`; the other 4 take none and were left alone. Those 4 are not all the same
shape, which is worth knowing before assuming "no parameters" means "not Helm":

- `prow-crds`, `secrets`, `prow-namespaces` — plain kustomize directories, read exactly as Flux read
  them, with Argo CD running kustomize itself.
- `prow-data-plane` — a Helm chart, and detected as one from its `Chart.yaml`. It templates five
  values, but all of them resolve from its own `values.yaml` (ServiceAccount names), so nothing has
  to reach it from Terraform.

What the 4 share is needing no value from outside the repo, not being token-free YAML.

## Ownership

Terraform owns what Argo CD cannot bootstrap for itself: the capability, the hub
registration Secret (by cluster **ARN**, not URL), access policy associations, the
AppProject, and the Applications (`bootstrap/argocd*.tf`). `bootstrap/identity/` is separate
state so a routine destroy/apply cannot take out the IdC instance. The hub cluster is
`aws_eks_cluster.this`, not an ACK CR.

Argo CD gets cluster-scoped objects without cluster-admin via a Kubernetes group on the
capability's access entry, bound to narrow rules in **`bootstrap/argocd-rbac.tf`**. Argo CD
cannot apply the objects that authorise Argo CD, so that path was never an Application; it
was Flux's until Phase 5, and it is now Terraform's. Terraform is the right owner rather
than the residual one — it already sets the group those objects bind
(`aws_eks_access_entry.argocd_capability_group`), so both halves of one mechanism live
together and neither can change without the other being visible.

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

## What the cutover phase taught

Four things cost real time, none of which was visible from reading. They are here because the same
traps apply to any later path, and to prod.

**A hand-requested sync does not honour the Application's own `syncOptions`.** `prow-crds` failed
identically under a manually patched `operation`, under `automated`, and with `Replace=true` added —
always falling back to a *client-side* patch, which busts the 262144-byte annotation limit on a
667 KB CRD. Proven from outside Argo CD: `kubectl apply --dry-run=server` fails with exactly that
error while `kubectl apply --server-side --dry-run=server` succeeds. The fix was a **per-resource**
`argocd.argoproj.io/sync-options: ServerSideApply=true` annotation on the manifest itself, which
travels with the object rather than depending on the Application.

**`automated` does not retry a failed sync for the same revision.** A path that fails once sits
there looking stuck, with a stale `operationState` that reads like a live failure. A hard refresh
(`argocd.argoproj.io/refresh=hard`) is what triggers a fresh attempt. Distinguish a new attempt from
the old one by `status.operationState.startedAt`, not by the phase.

**An in-flight operation is pinned to the revision it started on.** The connection Job OOMed, which
left its PostSync hook in `Running`; Argo CD then kept recreating the *old* Job spec from the pinned
revision, so a fix pushed afterwards was never used — deleting the Job just produced another copy of
the old one. The operation has to be **terminated** (`status.operationState.phase: Terminating`)
before a new revision is picked up. That cost several cycles and looked like the fix not working.

**A stuck PostSync hook presents as a healthy Application.** The connection Application reported
`Synced` throughout, while its hook Job was being OOMKilled repeatedly. The Job's steps are `kubectl`
pipelines — `kubectl create … | kubectl label --local | kubectl apply -f -` runs three Go binaries
concurrently — and peak usage is concurrent, not sequential, so 128Mi could not clear five such
steps. Raised to 512Mi.

Also worth carrying forward: the RBAC gaps were closed by **binding the built-in `admin` ClusterRole
in the four namespaces `AmazonEKSAdminPolicy` already covers**, rather than by adding rules one
failed sync at a time. That grants no new effective privilege and ends the churn for namespaced
Roles; only cluster-scoped grants and custom resource types still need explicit rules, because
`admin` does not aggregate CRs.

## What is left

Every path on staging is cut over, so what remains is Phase 5 plus the other two environments.
Nothing below is blocked on analysis; each item is work.

| item | note |
|---|---|
| **Flux removal** | the point of all this. `flux/flux`, `flux/prow/version`, `flux/prow/build-cluster-kubeconfig`, the root `test-infra` Kustomization, `self-managed-vars`, and the now-redundant raw manifests under `flux/prow/build-cluster-resources/`. Also the six suspended Kustomizations and fourteen suspended HelmReleases, which exist only as reversal switches — deleting them is what makes the cutover irreversible, so it goes last |
| dev and prod | this is staging only. The same branch drives all three, so each needs its own `terraform apply` and its own cutover, and prod deserves more care than the eight syncs took here |
| the `secrets` grant's exit condition | narrow the CSI driver's ClusterRole to namespaced Roles, then delete the cluster-wide secrets rule outright. Written up beside the rule |
| a fresh bootstrap has one ordering race left | `ack-system` and `flux-system` are created by `null_resource.{ack,flux}_system_namespace` running `bootstrap-namespaces.sh`, so they do exist - but nothing orders those provisioners against `kubernetes_manifest.argocd_root`, so wave 0 can sync before `ack-system` exists and fail on a missing namespace. Argo CD retries, so it self-corrects and only looks broken. A `depends_on` from the root Application to both provisioners removes it. The `prow`/`test-pods` half of this is fixed: they are now `prow/namespaces` at wave 0 |
| **adopt the hub cluster back into ACK** | deliberately deferred, not abandoned — see below |
| `periodics_enabled` | declared in no variable and plumbed nowhere; `jobs_config.yaml` commits `true` for every environment. Found while converting `prow-jobs`, unrelated to the migration |

### The hub cluster is Terraform-owned for now, and that is a decision to revisit

The chart conversion drops the hub's own `Cluster` CR. The commit doing it gives the reason: it
carried *"the last render-time cluster read, which Argo CD could not have satisfied: it renders
off-cluster, so Helm's `lookup` returns empty."* No later stage re-adopts it — in the end state only
`ack-build-infra` declares a `Cluster`, and that one is the **build** cluster's.

**The intent is to adopt the hub cluster back into ACK once the migration has settled.** Leaving it
to Terraform is a scope decision, not the target design: the migration already changes the reconciler
for every other path, and making the cluster that hosts all of it simultaneously change owner would
have put the one object whose loss is unrecoverable on the critical path. Terraform owns it through
`aws_eks_cluster.this` in the meantime, which is where it was already declared.

Three things make coming back to this cheap, and they are worth not undoing:

- the live CR keeps `services.k8s.aws/adoption-policy: adopt-or-create`, so ACK adopts the existing
  cluster rather than trying to build one
- it keeps `services.k8s.aws/deletion-policy: retain`, so even deleting the CR leaves the cluster
- prune is off, so the CR is still there to adopt rather than needing to be recreated from scratch

What the work actually is: replace the render-time read with values passed in explicitly. Terraform
already threads 14 parameters into Applications via `helm.parameters`, so the mechanism exists — the
open question is which fields of the live cluster the CR must reproduce without drifting, since a
`Cluster` spec that omits a field ACK considers managed is how you get a controller fighting the
console. Answer that against a real cluster before writing the chart, not from the CRD schema.

Until then, treat the hub `Cluster` CR as an orphan that is safe by construction, and do not "tidy"
it away — deleting it is harmless to the cluster but throws away the adoption annotations that make
this reversible.

## How each path was converted

The rest of this document is the record of the conversion, one path at a time. It is kept
because dev and prod still have to go through it, and because most of these sections exist to
stop a wrong conclusion being re-derived. Read it as history, not as a plan.

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

**`prow-config` was the largest path, and both halves are done.** Its 25 token
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

### `prometheus`: deleted, because migrating it cost cluster-admin and nothing used it

**Outcome: `kube-prometheus-stack` is gone from the repo** — `flux/prometheus/`,
`flux/prometheus.yaml`, and the `prometheus` entry in `local.argocd_hub_namespaces`. The analysis
below is kept because it is why deleting was preferable to migrating, and because the same trap
applies to any future chart that ships its own ClusterRoles.

The usage evidence, gathered before deciding:

- **Grafana was unreachable.** Every service in the namespace was ClusterIP and there was no
  Ingress; the only Ingress in the cluster is Prow's. Viewable only by deliberate `port-forward`.
- **Alerts went nowhere.** The generated Alertmanager config routed everything to receiver
  `"null"`, the chart default. No Slack, PagerDuty, SNS or email, ever.
- **The `/metrics` Ingress path was already dead** — it points at a `pushgateway-external` service
  that does not exist anywhere in the cluster.
- Its only bespoke content, the Prow dashboards and their recording rules, had been untouched since
  2021 and was deleted the commit before.

Prometheus *was* scraping — `scrapeMetrics` is on for hook, prow-controller-manager and tide — into
a store nobody queried, alerting nobody. That is the signature of monitoring set up and never
finished, which is a fair reason to remove it and re-add it deliberately if it is ever wanted.

Deletion was self-contained, which is what made it safe: `scrapeMetrics` in `prow/config` only adds
pod annotations and a metrics Service — **no ServiceMonitor or PodMonitor CRs** — and all 13 live
ServiceMonitors were Helm-owned by the chart itself. So nothing outside the chart depended on the
`monitoring.coreos.com` CRDs. The annotations are left in place, inert without a scraper, so
re-adding a stack later needs no change to Prow.

One consequence to expect on apply: narrowing `argocd_hub_namespaces` **replaces**
`aws_eks_access_policy_association.argocd_hub_write` (its ID is cluster + principal + policy, so a
namespace-list change cannot be an update). Argo CD loses namespace-scoped write for the moment
between destroy and create; syncs in flight fail and retry. Nothing else in the full plan is caused
by this change.

**Removing it from git did not remove it from the cluster.** Three classes of object outlived the
release, and each for a different reason, which is the part worth carrying to dev and prod:

- **The 10 `monitoring.coreos.com` CRDs.** Helm never deletes CRDs installed from a chart's `crds/`
  directory — by design, since deleting a CRD deletes every CR of that kind cluster-wide. They
  carried no `meta.helm.sh/release-name`, so helm-controller had no claim on them either.
- **The namespace.** helm-controller does not delete a namespace it created.
- **`prometheus-prometheus-kube-admission`**, the admission webhook's TLS Secret. It was written by
  the chart's `admission-create` Job, and objects created by a *hook* are not part of the release,
  so nothing pruned it.

Everything the release *did* own was pruned correctly: all five ClusterRoles, the
ClusterRoleBindings, and both webhook configurations were already gone before the hand-cleanup —
verified, not assumed, since those grants were the reason migrating would have cost cluster-admin.

Deleted by hand after confirming **zero CRs across all ten kinds**, that the namespace held nothing
but that Secret and the two auto-created defaults (`kube-root-ca.crt`, the `default`
ServiceAccount), and that the only remaining git reference to the API group is a `PodMonitor`
template in the vendored `flux2` chart gated on `prometheus.podMonitor.create`, which is `false` by
chart default and unset by the HelmRelease — so nothing renders it, and `flux2` goes in Phase 5
regardless. Prow was unaffected: all 20 Applications stayed Synced/Healthy and all 10 Prow
deployments stayed at their desired replicas.

One trap while checking this: `v1alpha1.prometheusservice.services.k8s.aws` shows up in any search
for "prometheus" among cluster-scoped objects. It is **ACK's Amazon Managed Prometheus controller**,
unrelated to `kube-prometheus-stack`, and deleting it would break an ACK capability. Match on the
`monitoring.coreos.com` group, not on the substring.

#### Why migrating it would have cost cluster-admin

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
authorizer can actually see — `bootstrap/argocd-rbac.tf`, not the access policies:

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

Granting all 112 was not a bigger version of the `prow-plugins` or `secrets` decisions. It is
`AmazonEKSClusterAdminPolicy` by another route — the exact thing the header of
`cluster-scoped-rbac.yaml` records as refused — and it would have been spent on the least critical
thing in the repo.

**If monitoring is ever wanted back**, the option that avoids the grant is: set `rbac.create: false`
on the subcharts and let Terraform own the five ClusterRoles, since Terraform is cluster-admin and
hub-owned, so Argo CD never applies an RBAC object for that path. The cost is 121 upstream rules
copied into Terraform, re-synced on every chart upgrade, with drift silent. AWS-managed monitoring
(AMP plus managed Grafana, or the EKS observability add-on) sidesteps it entirely and is the option
to weigh first.

Two measurements worth keeping so they are not redone: the chart is 7.2 MB unpacked across 297 files
and five subcharts, so vendoring it into `charts/` — the house pattern at the time, which
existed to vendor the flux2 chart and was removed with Flux — would have been 12× that chart. And a multi-source Application with
a `$values` ref avoids vendoring but adds the repo's first multi-source Application, needs the Helm
repo in the AppProject's `sourceRepos`, and assumes the managed capability's repo-server has egress
to a third-party Helm repo, which was never verified. Vendoring depends on nothing but git.

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

### `prow-build-cluster-resources`: the only path that is not hub-targeted

The chart is `flux/prow/charts/prow-build-cluster-resources` (13 objects) and its Application is
composed by `prow-build-cluster-connection`'s `templates/application.yaml` and applied by that
chart's Job. Argo CD reads git, so the branch has to be pushed before either chart renders the new
content — which is why this path cannot be tested by a local apply.

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

The order it ran in, which dev and prod need too:

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

#### `prow-plugins` needed an RBAC decision, not a rendering fix

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
They sit in `bootstrap/argocd-rbac.tf`, so Terraform applies them. A sync attempted first fails on
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

### `flux/argocd/` moved to Terraform, adopted rather than recreated

This was the one path that could never be an Application, and it was the last thing Flux
owned, so it blocked Flux removal outright. It is now `bootstrap/argocd-rbac.tf`: 14 objects —
one ClusterRole and its binding, four `admin` RoleBindings, and four grantor Roles with their
bindings.

**Typed resources, not `kubernetes_manifest` over the YAML.** The alternative was keeping the
files and having Terraform apply them with `yamldecode`, which preserves the comments verbatim.
Rejected because Terraform has no multi-document YAML decoder, so it needs `split("---", …)` —
and these files are roughly half comment, including `---` separators inside comment blocks and
`####` banners. A split on a delimiter that also appears in prose is a silent corruption
waiting to happen. Typed resources also make the plan show the rules diff, which for an RBAC
change is the thing a reviewer needs to see.

**Adopted with `terraform import`, all 14.** A gap in the ClusterRoleBinding is a gap in Argo
CD's authorisation, so delete-and-recreate was not acceptable even briefly. The gate on the
transcription was the plan: `0 to add, 14 to change, 0 to destroy`, with every diff confined to
removing the four now-meaningless metadata keys (`kustomize.toolkit.fluxcd.io/{name,namespace}`,
`kustomize.toolkit.fluxcd.io/prune`, `helm.sh/resource-policy`). Checked against the plan JSON
rather than by reading it, asserting that no `rules`, `role_ref` or `subject` differed. Then
verified after apply: 14/14 uids held, and all **89** (group, resource, verb) triples across the
ClusterRole and the four Roles probe as granted.

**Suspend before deleting from git.** The root Kustomization has `prune: true`, so dropping
`argocd.yaml` deletes the `argocd-rbac` Kustomization. That one has `prune: false`, so its
objects should survive — but the whole grant rides on that reading being right, so it was
suspended live first. kustomize-controller's delete path skips pruning when suspended, which
makes the outcome independent of the flag. Cheap insurance on an object whose absence breaks
every sync.

Two traps, both of which produced a wrong answer before being understood:

- **`kubectl auth can-i` reports a false `no` for cluster-scoped resources unless you pass
  `--all-namespaces`.** Without it kubectl sends the context's namespace in the
  SubjectAccessReview, and a namespaced request for a cluster-scoped resource matches nothing.
  Probing the group for `create storageclasses` returned `no` while the grant was live and
  working. This is the probe several comments in this repo cite as evidence, so read any `no`
  from it twice — once for this, and once for the fact that access-policy grants are invisible
  to it entirely.
- **The Kubernetes provider defaults `subject.namespace` to `"default"`.** On a `Group` subject
  that field is meaningless to the authorizer, but the provider writes it, so every binding
  planned a `"" -> "default"` change on a field nothing reads. Setting `namespace = ""`
  explicitly is what makes the plan clean, and a clean plan is what lets drift detection mean
  something here.

Also fixed while in the file: the `kubernetes` provider was never declared in
`required_providers` and was being resolved implicitly, unpinned. It now carries a floor like
the others. Six pre-existing files fail `terraform fmt -check` and were deliberately left
alone — reformatting them would bury this change.

### The Applications moved to git behind one root Application

Terraform declared 19 Applications, one `kubernetes_manifest` each. It now declares one,
`root-applications`, which renders the rest from `argocd/applications/`. The structure those
19 carried - chart path, target namespace, which parameters each chart needs, sync behaviour -
is all git-authored, so this is the `prow-mirror` rule applied one level above the charts. The
day-to-day consequence is that adding or changing a path no longer needs an apply.

**Terraform still supplies the values, and that does not change.** The 16 entries in
`local.argocd_chart_values` are per-environment and Argo CD cannot read them at render time:
it renders off-cluster, `valuesFrom` against a ConfigMap does not exist (argo-cd#12060),
Helm's `lookup` returns empty, and there is no repo-server to attach a plugin to. What
changed is that they travel **once, as one `helm.values` blob**, instead of as parameters on
19 Applications.

**That blob is also what makes the account id safe, and it is worth knowing why.** Parameters
are `--set`, which reads `.` as a path separator and `,` as a list separator. `yamlencode`
quotes every scalar, so `"086987147623"` stays a string. Written unquoted, Go's YAML parser
reads it as a **float** - a leading zero with `8` and `9` in it is not valid octal, so it
falls through to float rather than int - and `printf %s` then yields
`%!s(float64=8.6987147623e+10)`, a syntactically valid image reference that fails at pull
time rather than at render time. The chart guards every value with `kindIs "string"`, and the
guard was confirmed by accident: a verification harness dumped the values with PyYAML, which
does not quote, and the render failed with exactly that message. PyYAML reads it back as a
string, so the harness looked correct and only Go disagreed.

**Argo CD had no dependency ordering at all before this.** No `sync-wave` on any of the 19,
while Flux carries 15 `dependsOn` edges. The migration never noticed, because paths were cut
over one at a time into a cluster where the graph was already satisfied; on a fresh bootstrap
it is not. Each child now carries a wave, derived from that graph by script rather than by
eye - a node sits one deeper than its **deepest** dependency, so nothing can sync ahead of a
transitive dependency it shares no direct edge with.

| wave | applications |
|---|---|
| 0 | `ack-capability-role` |
| 1 | `ack-capability` |
| 2 | `ack-addons-roles`, `ack-build-infra`, `ack-cluster`, `ack-flux`, `ack-pod-identity-roles`, `ack-prow` |
| 3 | `ack-addons`, `ack-pod-identities`, `prow-build-cluster-connection` |
| 4 | `prow-agent-workflows`, `prow-crds`, `prow-mirror`, `secrets` |
| 5 | `prow-config`, `prow-data-plane`, `prow-jobs`, `prow-plugins` |

**Flux's graph was incomplete, and three edges had to be added.** Without them
`prow-agent-workflows`, `prow-jobs` and `prow-plugins` landed in wave 0 - ahead of the ACK
capability - because Flux declares no `dependsOn` for any of them. Both missing edges are
real and both were verified rather than assumed:

- **`ack-pod-identities` creates the `prow` and `test-pods` namespaces**
  (`flux/ack/cluster/pod-identities/prow-namespaces.yaml`, confirmed by the
  `kustomize.toolkit.fluxcd.io/name` label on both live namespaces). Every Application carries
  `CreateNamespace=false`, so a path targeting either namespace **fails outright** before that
  path has run. Applied to every path targeting those namespaces, which the existing edges
  already covered for the rest.
- **`prow-mirror` runs `Job/prow-mirror-images`**, which publishes into the repo
  `prowImagesRepoUri` names. Added only where something actually pulls - checked per path from
  the live image reference. `prow-agent-workflows` renders a ConfigMap that *names* a mirrored
  image without pulling one, so it does not get this edge.

Flux got away without all three because both conditions were already true by the time those
paths were first applied. That is worth generalising: a dependency graph that has only ever
run against a converged cluster has not been tested.

**The handover was an adoption, not a recreate.** The 19 were removed from Terraform state
with `terraform state rm` - which leaves the live objects untouched - and the root then adopted
them under `ServerSideApply=true`. Confirmed safe *before* committing to it, with a
server-side dry-run apply as `argocd-controller` against all 19: zero conflicts, because SSA
only conflicts where two managers set **different** values and the render had already been
verified equal to live field by field. Result: 19/19 uids held, `automated` preserved on every
path, `source`/`destination`/`project` unchanged.

Two things to know about the pattern's limits:

- **Removing a path orphans its Application.** `prune` is false on the root, and Argo CD
  cannot delete Applications anyway - `argocd-rbac.tf` grants get/create/update/patch and no
  delete. Deleting the leftover is a manual step. That is the accepted cost; the alternative is
  `prune: true` on the root, where a chart that renders empty for any reason deletes all 19
  Application objects at once.
- **`automated` on the root is written as `{}`, not `{prune: false, selfHeal: false}`.** Absent
  means false, and the API server drops both zero values on Terraform's write, so spelling them
  out leaves `prune: null -> false` in every future plan on a field nothing reads. The children
  can spell them out, because `argocd-controller`'s server-side apply keeps them. Same class of
  problem as the Kubernetes provider defaulting `subject.namespace` to `"default"`: a
  permanently dirty plan costs more than the explicitness is worth.

**What did not move, and cannot.** The AppProject (children reference it; a child cannot create
the project that admits it), the hub registration Secret (nothing deploys until a cluster is
registered), `argocd-rbac.tf` (Argo CD cannot apply what authorises Argo CD), and the root
itself - an Application that renders itself is a loop with no seam, and the seam is the point.
`prow-build-cluster-resources` stays out of the chart permanently: D13 puts anything keyed to
the build cluster beyond Terraform's reach, and that now includes anything Terraform renders.

**ApplicationSets were considered and not taken.** The CRD is present and AWS documents git
generators for the managed capability, so it was available. Rejected for this repo: the
multi-cluster and multi-environment fan-out they exist for does not apply (two clusters, one of
which Terraform must not target; three environments with separate states), a directory
generator cannot express per-path config that is not derivable from the path, and it would need
`applicationsets` plus `delete` on applications - a wider grant than app-of-apps, which needed
none. Worth revisiting only if path churn ever makes the manual-delete cost real.

## Traps

- `AmazonEKSAdminPolicy` at cluster scope **replaces** a namespace-scoped association of the
  same policy, silently widening it. Verify with `list-associated-access-policies`.
- `AmazonEKSBlockStorageClusterPolicy` / `ComputeClusterPolicy` cannot be associated at all —
  service-linked roles only. Declaring either makes every apply fail.
- Argo CD cannot apply Role/RoleBinding objects unaided: escalation prevention only sees
  in-cluster RBAC, so access-policy authorisation counts for nothing. See
  `bootstrap/argocd-rbac.tf`.
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

### `syncPolicy.automated` has exactly one shape a rendered manifest can hold

Found by cleaning up the branch history and re-syncing: the root reported
`Application.argoproj.io "secrets" is invalid: spec.syncPolicy.automated: Invalid value:
"null": ... must be of type object`, and sat in retry.

Argo CD parses a rendered Application into its typed Go struct and re-serialises it with
`omitempty` before applying. That makes three of the four obvious shapes unstable:

| rendered | what Argo CD applies | result |
|---|---|---|
| `{prune: false, selfHeal: false}` | `null` | CRD rejects it; the root retries forever |
| `{}` | `null` | same |
| `{prune: false, selfHeal: true}` | `{selfHeal: true}` | applies, but rendered `prune` can never match live, so the child is **permanently OutOfSync** |
| `{enabled: true}` | `{enabled: true}` | stable |

`enabled` is a `*bool`, so a non-nil `true` survives `omitempty`. It states what the other
shapes could only imply, and `prune`/`selfHeal` keep their false defaults by absence.

**The API server was never the constraint.** All four shapes round-trip unchanged through
`kubectl apply --server-side`, which is what made this confusing — the rejection only
appears when Argo CD is the applier. Test the applier you actually use.

Two things this explains in passing. The 13 Applications still carrying
`prune: false, selfHeal: false` alongside `enabled: true` got those fields from Terraform's
field manager, and Argo CD has never been able to re-apply them; they are inert and
identical in effect. And a bare `automated:` key with nothing under it is worse than either
- it renders as `automated: null`, which **disables** auto-sync while still looking
declared, so 17 paths would have quietly stopped reconciling.

`prow-build-cluster-resources` is the one Application still rendered with
`prune: false, selfHeal: false`, and it is fine: its composed manifest is applied by the
connection Job with `kubectl`, not by Argo CD, so it never passes through that serialiser.

### The conversion left seven objects with no owner, and Flux was hiding it

Found by asking whether Flux could simply be deleted. It could not. Beyond Flux's own
machinery, the `prow` and `test-pods` Namespaces and the five ServiceAccounts every
`PodIdentityAssociation` binds to were owned by **nothing that survives Flux**.

They live in `prow-namespaces.yaml`, which Flux applied as a raw manifest *alongside* the
`ack-pod-identities` chart rather than inside it, for a reason worth preserving:

> no chart may own a Namespace: if Helm ever uninstalled or rolled back the release it would
> target the namespace, and deleting a namespace cascades to everything inside it, including
> all of Prow

That reasoning is sound, and the chart conversion respected it — but the Argo CD Application
points at the chart, so nothing replaced the raw manifest. The objects survived only because
`prune` is disabled on the Flux side. **On a fresh bootstrap they would never have existed at
all**: Argo CD would deploy six PodIdentityAssociations naming ServiceAccounts that do not
exist, into namespaces that do not exist, with `CreateNamespace=false` everywhere.

**This also corrects the wave derivation recorded above.** It justified the wave-3 edge with
"ack-pod-identities creates the prow and test-pods namespaces", which is true of the Flux
*Kustomization* and false of the Argo CD *Application*. The edge was necessary and
insufficient: later waves were ordered behind something that never delivered the namespaces.

Fixed by moving the manifest to `prow/namespaces/` with its own Application at **wave 0**,
ahead of everything. Still a plain kustomize directory, not a chart — the same reasoning that
kept it out of one still applies, and it is token-free so Argo CD reads it unchanged. It sits
under `prow/` rather than `flux/` because everything under `flux/` is deleted in Phase 5 and
these objects outlive it. Dropping it from the Flux kustomization was the cutover; `prune`
stays false, so all seven were adopted with uids held — which mattered more here than
anywhere else, since recreating a Namespace cascades to everything inside it.

It needed one new cluster-scoped grant, `namespaces` **without delete**. Namespaces are
cluster-scoped, so no namespace-scoped access policy reaches them: `AmazonEKSAdminPolicy` is
associated per namespace and cannot grant creating one. Argo CD needs to create these and
reconcile their labels, never to remove one, and `delete` was verified still denied after the
grant landed.

The generalisable point: **a path converted from a Kustomization that applied both a chart
and raw manifests is only half converted.** Check `resources:` in the old
`kustomization.yaml` against what the chart contains, not just that the chart renders.

### `flux-system` holds nothing but Flux now

Phase 5 looked like it needed a decision here: this document claimed the connection Job writes
`build-cluster-kubeconfig` into `flux-system` and that Prow's components mount it from there,
which would have forced either a move or a vestigial namespace. **The claim was wrong, and not
just imprecise** - a ConfigMap mount is namespace-local, so a pod in `prow` cannot mount from
`flux-system` at all. Measured: `build-cluster-kubeconfig` is in **`prow`**, written there by the
Job, and that is what crier, deck, sinker and prow-controller-manager mount. The `flux-system`
copy is `build-cluster-flux-kubeconfig`, a different object from a different chart
(`prow-build-cluster-kubeconfig`), used only by kustomize-controller's `kubeConfig.configMapRef`
for remote apply - and its only consumer, the `prow-build-cluster-resources` Kustomization, is
already suspended. That path is dead weight that is still being reconciled.

**Then the harder question: was any of `prow-build-cluster-connection` Flux wiring?** It lived in
`flux-system`, so it looked like it. It is not. The Job does three things: assembles the
kubeconfig Prow mounts, which is a **Prow** requirement under either reconciler; registers the
build cluster as an Argo CD **spoke**; and authorises it in the AppProject then applies its
Application. The last two exist only *because* of Argo CD. Nothing it does is Flux's.

Checking that took reading `managedFields` rather than labels. The mounted ConfigMap carries
`helm.toolkit.fluxcd.io/name: prow-config`, which reads as though prow-config still owns it - but
the field managers show `helm-controller` at 02:41 and `kubectl-client-side-apply` at 07:44, and
the later write is the Job. prow-config's template is gated on `buildCluster.server`, which
nothing sets any more, so the labels are residue from before D16.

**So the chart moved to `ack-system`, and an earlier version of this section recommended the
opposite.** That recommendation was made before establishing that none of the chart is Flux's,
and it argued the move bought only a tidier name. It buys more than that: leaving it there means
a namespace named after a reconciler that no longer exists holding the chart that replaced it.
`ack-system` is where the Cluster CR the Job reads already lives, and it is already in
`argocd_hub_namespaces`, so the admin RoleBinding covers creating the Roles with no new grant.

Three things made the move safe rather than a rewrite:

- **The chart now uses `.Release.Namespace`** for its own objects, with the `ack-system`, `prow`
  and `argocd` references left literal, because those name where the TARGET objects live rather
  than where the chart is installed. Rendering with `targetNamespace: flux-system` is unchanged,
  so stages still on Flux are untouched and this is hub-only.
- **A vestigial ConfigMap went with it.** The chart also wrote `build-cluster-connection` in its
  own namespace so `prow-charts` could substitute `BUILD_CLUSTER_ENDPOINT` / `BUILD_CLUSTER_CA` at
  render time. Argo CD cannot substitute, which is why the Job assembles the finished kubeconfig -
  so that ConfigMap had no reader. `flux/prow.yaml` already recorded the substitution being
  removed. It and its Role are deleted.
- **The Job is idempotent, which is what made a namespace change survivable.** Re-run from
  `ack-system` it reported `unchanged` for all three objects it owns - the kubeconfig, the spoke
  Secret and the Application - and `already authorises` for the AppProject. Verified after: Prow's
  ten Deployments available, the build cluster reachable, `prow-build-cluster-resources` still
  Synced against the spoke.

Moving a namespace is a **recreate, not an adoption** - new namespace means new object identity -
so the six objects left in `flux-system` were orphaned rather than pruned, `prune` being off, and
deleted by hand. `flux-system` now holds only Flux's own machinery plus the Terraform-owned
`argocd-namespace-admin` RoleBinding, which is the next thing that can go: with nothing Argo CD
manages in that namespace, `flux-system` can come out of `argocd_hub_namespaces` and narrow the
access policy. Worth knowing that change **replaces** the access-policy association rather than
updating it, so syncs in flight fail and retry.

**One orphan found and removed while checking this.** `Role`/`RoleBinding` `argocd-rbac-grantor`
in `flux-system`, still labelled `kustomize.toolkit.fluxcd.io/name: argocd-rbac` from the deleted
Flux path, managed by nothing: `argocd-rbac.tf` grants grantor Roles in `{ack-system, prow,
test-pods, argocd}` and not there. It granted `configmaps get/create/update/patch`, which the
built-in `admin` ClusterRole already covers - verified by reading `admin`'s own rules rather than
by probing, since a `can-i` probe cannot say which binding answered.

The generalisable point, and the second time this migration has produced it: **deleting a path
from git does not delete what it applied.** `prune: false` is what makes cutover reversible, and
it is also what leaves debris. Anything retired that way needs its objects reconciled down by
hand, or they sit unowned until someone reads a label and wonders.

### Dropping the built-in node pool takes two invisible things with it

Removing the nodepool swap raised the question of whether the `general-purpose` pool was needed at
all. With Flux gone and both Argo CD and ACK running off-cluster, nothing needs capacity before
Argo CD syncs, so `compute_config.node_pools = []` looks free. It is not, and the reasons were
established by trying it against staging rather than by reading.

`node_pools` is the only lever. The NodePool object itself carries
`app.kubernetes.io/managed-by: eks` with no owner references and no field managers, so the control
plane reconciles it back after deletion — which is why the old `swap_nodepool` never durably
removed anything.

Setting it empty removes two things the cluster depends on and neither is named in the diff:

- the EKS-managed **`default` NodeClass**, which both hub NodePools reference by name. They
  keep existing and reporting as healthy objects while launching nothing.
- the auto-created **node-role AccessEntry**. Without it a node boots, fails to authenticate,
  and never registers — which presents as a capacity problem, not an authorisation one.

Both must be declared explicitly *before* the pool goes. The build cluster has run that way
since it was created and carries both, so it is the working reference rather than a design
question. Repointing the pools also drifts existing nodes, so Karpenter replaces them: sequence
it before the Terraform change, not with it.

**Declaring the AccessEntry is where this stops being mechanical.** Adopting the auto-created
entry with an `accessPolicies` block fails permanently:

> `InvalidParameterException: This operation can only be performed on Access Entries with a
> type of "STANDARD"`

The entry EKS creates for Auto Mode nodes is type **EC2**, and policy association is a
STANDARD-only operation. The build cluster's equivalent CR carries `accessPolicies` and syncs
fine because ACK **created** it — type and policy in one call. Adoption cannot reach the same
end state, because it arrives as a second association call against an EC2-type entry. An
adopting CR must therefore omit `accessPolicies` entirely and let the existing association
stand, which also means the CR no longer describes the permissions it appears to own.

Two mechanics worth knowing before touching any of this, both observed here. **`deletion-policy:
retain` is what makes an AccessEntry CR safe to remove** — the CR goes, the AWS entry stays, and
since the nodes authenticate through that entry the alternative is an outage rather than a tidy-up.
And **the NodeClass's `eks.amazonaws.com/termination` finalizer is not a hang.** It holds the
object until the nodes launched from it have drained, and releases on its own once Karpenter
finishes the replacement. Forcing it strands the nodes.

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
