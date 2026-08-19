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
| Argo CD Applications | 12 live, all Synced/Healthy — all 12 Terraform-declared and hub-targeted. A 13th (`prow-build-cluster-resources`, build-cluster-targeted) is composed by the connection chart and applied by its Job, and is **not live yet** — see below |
| Cut over | **12 of 14** chart paths, all `automated`, prune off everywhere. The two uncut are `prow-build-cluster-resources` and `prow-agent-workflows`: both have charts and Applications written, neither is live |
| ACK CRs | 64, all Argo CD-tracked, 0 deleting |
| Still on Flux | `prow-build-cluster-resources`, `prow-agent-workflows` (both awaiting cutover), plus `prow-jobs` and `prow-plugins` |
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

| item | blocker |
|---|---|
| `prow-jobs`, `prow-plugins` | still `${TOKEN}`-bearing, so they block Flux removal. `prow-agent-workflows` is done and is the worked example — the generator does **not** change; see below |
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

**This one is not a subset-restatement, and that is the decision.** Every previous grantor
rule was defensible as "no access Argo CD lacked, expressed where the RBAC authorizer can see
it" — `AmazonEKSAdminPolicy` already gave it those permissions, namespace-scoped. Holding
prowjobs write and pod read *cluster-wide* is genuinely wider than Argo CD has today. Three
options, in order of preference:

1. **Narrow the plugin's RBAC to namespaced Roles** and keep the grantor namespaced too. The
   evidence says this is achievable: the Deployment pins `PROW_JOB_NAMESPACE: "prow"` and all
   48 live ProwJobs are in `prow`, so the ClusterRole is wider than the workload needs. Cost:
   it changes `rbac.tpl`, so it is a generator change and a behavioural change to the
   plugin's permissions — needs the plugin owner, and needs checking whether it reads pod logs
   for jobs running on the build cluster.
2. **Grant the two rule sets cluster-wide in `cluster-scoped-rbac.yaml`.** Mechanical, matches
   the existing pattern, and widens Argo CD's effective access. Defensible only because
   kustomize-controller already holds more than this and loses it in Phase 5.
3. **Leave `prow-plugins` on Flux** and accept that Flux removal waits on it. Not really an
   option, since Flux removal is the goal.

Option 1 is right if the plugin genuinely only needs `prow`; option 2 if it does not.
Answering that is the next step, and it is a question for whoever owns agent-plugin.

`prow-jobs` is the last and most awkward: its `templates/` holds 26 generator templates, and
it has the two problems below.

Two things that will bite on `prow-jobs`:

- `job-config-job.yaml` contains a `batch/v1` **Job** whose `spec.template` is immutable,
  which is why `prow-jobs` carries `force: true` today. Helm's `force` is not a substitute
  (see Traps); the Job has to become a hook with `before-hook-creation`, like `prow-mirror`
  and `prow-build-cluster-connection`. It then needs a tracked object to trigger it — the
  three generated ConfigMaps (`jobs-config`, `label-config`, `test-config`) serve, since a
  content change to any of them is drift.
- Regeneration is **not** byte-stable: `addAutoGenHeader` stamps `# Last generated on
  <timestamp>` into all seven generated files on every run, so `make prow-gen` always
  produces a diff in files dev and prod also consume. That is the real reason to touch the
  generator deliberately rather than incidentally.

Unrelated but found while measuring, and worth someone's attention: `dev.tfvars` sets
`periodics_enabled = "false"`, but that variable is not declared in `bootstrap/variables.tf`
and nothing plumbs it into `prow/jobs/jobs_config.yaml`, which is committed as `true` and
shared by every environment. Dev's intent to disable periodics has no effect today. Flipping
it also changes the *shape* of `jobs.yaml` (`periodics: []` instead of the rendered dir), so
it is not a value swap.

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
