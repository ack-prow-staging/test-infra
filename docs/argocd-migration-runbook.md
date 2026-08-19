# Flux → Argo CD migration runbook

Operational sequence for migrating one environment. `docs/argocd-migration.md` is the map — it
explains *why* each decision was made and records the traps. This file is what you execute.

Written from the staging migration. Read the whole thing before starting: several steps are
ordered by constraints that are invisible in a diff, and one of them (suspend before Argo CD is
verified) leaves paths reconciled by nothing.

---

## The one thing that matters most

**Merge in stages, not wholesale.** All the commits are on `main`, and merging them in one go
lands the Flux suspensions at the same time as the charts — before Argo CD exists to take over.
Paths would then be reconciled by *neither* reconciler, silently, until someone noticed.

Git order and deploy order are different problems here. The commits are ordered so each is
individually valid (`terraform validate` passes at every one), but the **gates between stages are
reconcile-and-verify steps, not commits.**

If the target environment tracks a branch rather than `main`, stage by cherry-picking or by
advancing the branch stage by stage. If it tracks `main` directly, stage by advancing `main` and
letting each stage converge before pushing the next.

---

## Prerequisites

- Terraform ≥ 1.7, `kubectl`, `helm`, `aws` CLI, and credentials for the target account.
- `<env>.tfvars` for the environment. Staging's is `bootstrap/environment/staging.tfvars`; prod
  needs its own. Required values: `region`, `account_id`, `flux_version`, `prow_domain`,
  `test_infra_org`, `test_infra_repo`, `test_infra_branch`, `stage`, `kubernetes_org`,
  `redhat_org`, `controllers`, `publish_account_id`.
- `test_infra_branch` **must name the branch the reconcilers should read**. Do not rely on a
  `-var` override on the command line: staging spent the whole migration with three different
  values live at once — the root Application on one branch, Flux's ConfigMap on another, and
  `tfvars` saying `main` — because the override was never written down. A plain `terraform apply`
  then resolves to whatever `tfvars` says and unwinds the migration's desired state.

### Two variables that are false by default and must be true on a fresh bootstrap only

| variable | when true | why it must go false afterwards |
|---|---|---|
| `seed_ack_bootstrap_policy` | first apply into an account where ACK has not yet adopted the capability role | ACK replaces `BootstrapPermissions` with its own six policies. Left true, every plan wants to recreate a policy ACK deliberately superseded |
| `bootstrap_prow_images` | first apply, when the ECR repo is empty | it drives two `local-exec` provisioners that build ~15 images, roughly an hour. A provisioner re-runs on every *replacement*, so a taint silently costs that hour |

Neither is needed when migrating an environment that is already running Prow under Flux.

---

## Stages

Each stage lists what to merge, what to run, and a **gate** that must pass before the next.

### Stage 0 — Baseline the environment

Nothing to merge. Capture what "unchanged" means so you can prove it later.

```bash
CTX=<hub-context>
# every object Flux currently manages, with uids
kubectl --context $CTX get kustomizations.kustomize.toolkit.fluxcd.io -A -o json \
  > /tmp/baseline-kustomizations.json
kubectl --context $CTX get helmreleases.helm.toolkit.fluxcd.io -A -o json \
  > /tmp/baseline-helmreleases.json
# Prow's control plane: the thing whose uid must never change
kubectl --context $CTX -n prow get deploy -o json > /tmp/baseline-prow-deploy.json
```

**Gate:** you can answer "how many Kustomizations, how many HelmReleases, which are suspended,
what are the Prow Deployment uids" without running anything.

### Stage 1 — Safety: prune off, deletion protection

Merge: `fix(ack): Set enableNetworkAddressUsageMetrics on the build VPC`,
`chore(flux): Disable prune and make deletion structurally impossible`,
`chore(flux): Disable prune on the last three paths before Flux removal`.

> The last one exists separately only because staging discovered the remainder late. For a fresh
> environment merge it with the other prune commit — they are one concern.

Then force a reconcile rather than waiting for the interval:

```bash
kubectl --context $CTX -n flux-system annotate gitrepository test-infra \
  reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
kubectl --context $CTX -n flux-system annotate kustomization test-infra \
  reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
# the root does not reconcile its children's own specs; nudge this one too
kubectl --context $CTX -n flux-system annotate kustomization flux \
  reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
```

**Gate — do not proceed until every Kustomization has `prune: false`:**

```bash
kubectl --context $CTX get kustomizations.kustomize.toolkit.fluxcd.io -A \
  -o custom-columns='NAME:.metadata.name,PRUNE:.spec.prune' | grep -i true
# must return nothing
```

This is the most important gate in the runbook. Every later step deletes or suspends something,
and a Kustomization with prune enabled garbage-collects its inventory when deleted. On staging
`prow-charts` held the `prow-config` HelmRelease, whose release owns Prow's nine Deployments.

Expect 60–90 seconds of churn after any root reconcile: a dozen Kustomizations go `Ready=False`
with `DependencyNotReady` and converge in waves. That is `dependsOn` polling, not a fault.

### Stage 2 — Chart conversions (inert)

Merge: `refactor(flux): Render the ACK and Prow paths from Helm charts`,
`feat(argocd): Convert the remaining paths and register the build cluster`,
`refactor(prow): Move the build-cluster connection chart out of flux-system`.

These are inert by construction: Flux keeps reconciling and keeps passing the same values, and the
charts render byte-identically to what the Kustomizations produced. Nothing in this stage requires
Argo CD to exist.

**Gate:** all unsuspended Kustomizations `Ready=True`, and the Prow Deployment uids from Stage 0
unchanged.

```bash
kubectl --context $CTX -n prow get deploy -o json | \
  python3 -c 'import json,sys; print(sorted((d["metadata"]["name"],d["metadata"]["uid"]) for d in json.load(sys.stdin)["items"]))'
# compare against /tmp/baseline-prow-deploy.json
```

### Stage 3 — Argo CD standup and authorisation

Merge: `feat(argocd): Stand up the capability and authorise it without cluster-admin`,
`feat(argocd): Grant the capability the in-cluster RBAC it needs`,
`fix(ack): Seed BootstrapPermissions only on a fresh bootstrap`,
`fix(prow): Gate the one-shot image bootstrap behind a variable`,
`refactor(argocd): Drop flux-system from the hub write grant`.

**The Argo CD CRDs must exist before Terraform can plan.** `kubernetes_manifest` validates against
the live API at plan time, so on a fresh account the capability comes first:

```bash
cd bootstrap
terraform apply -var-file=environment/<env>.tfvars -target='awscc_eks_capability.argocd'
terraform apply -var-file=environment/<env>.tfvars     # the rest
```

For prod, run without `-auto-approve` and read the plan.

**Gate — the grants must be live before any Application syncs.** A sync attempted first fails on
escalation prevention with a message naming the *chart's* ClusterRole rather than the missing
grantor rule, which sends you to the wrong file.

```bash
# cluster-scoped resources need --all-namespaces or the SAR carries a namespace and matches nothing
for r in storageclasses ingressclasses nodepools.karpenter.sh namespaces clusterroles; do
  echo "$r: $(kubectl --context $CTX auth can-i create $r -A \
    --as=probe --as-group=argocd-cluster-scoped)"
done
# namespaces must be create=yes and delete=NO
kubectl --context $CTX auth can-i delete namespaces -A --as=probe --as-group=argocd-cluster-scoped
```

`can-i` reports `no` for anything granted by an EKS **access policy** — those are enforced by the
EKS authorizer and are invisible to a SubjectAccessReview. Only use it to check the in-cluster
rules in `argocd-rbac.tf`.

### Stage 4 — Applications from git

Merge: `feat(argocd): Render the Applications from git via a root Application`,
`feat(argocd): Give the Prow namespaces and ServiceAccounts an owner`.

**Push the branch before applying.** Argo CD reads git; the root Application resolves nothing until
the chart is pushed.

```bash
cd bootstrap && terraform apply -var-file=environment/<env>.tfvars
```

The root creates the child Applications, which sync wave by wave. Waves exist because Argo CD has
no `dependsOn`; they are derived from Flux's graph plus three edges Flux omitted.

**Gate — every Application Synced and Healthy, and every adopted object's uid held.** Adoption
happens under `ServerSideApply=true`: the Applications describe objects Flux already applied, so
Argo CD takes over field ownership in place rather than recreating. Check the ones where a recreate
is destructive:

```bash
# Prow's Deployments carry immutable spec.selector -- a recreate takes the control plane down
# Namespaces cascade to everything inside them
kubectl --context $CTX -n argocd get applications.argoproj.io \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

If an Application reports `OutOfSync` on nothing but Flux's `kustomize.toolkit.fluxcd.io/*` labels,
that is expected at this point — content matches, ownership metadata does not.

### Stage 5 — Cutover

Merge: `feat(argocd): Cut every path over to Argo CD`.

This suspends every converted path's HelmRelease or Kustomization in git and enables `automated`
sync on the Applications. **It is the point of no return for "both reconcilers idle":** a suspended
HelmRelease plus a manual-sync Application means nothing reconciles that path.

Do not merge this until Stage 4's gate passed for *every* path.

**Gate:**

```bash
# nothing unsuspended is unhealthy, and every Application is automated
kubectl --context $CTX get helmreleases.helm.toolkit.fluxcd.io -A \
  -o custom-columns='NAME:.metadata.name,SUSPEND:.spec.suspend'
kubectl --context $CTX -n argocd get applications.argoproj.io -o json | python3 -c '
import json,sys
d=json.load(sys.stdin)["items"]
print("automated:", sum(1 for a in d if (a["spec"].get("syncPolicy") or {}).get("automated") is not None), "of", len(d))'
```

Then exercise it end to end — trigger a presubmit and confirm it schedules onto the build cluster.

### Stage 6 — Deletions that are not migrations

Merge: `chore: Remove kube-prometheus-stack and the Prow Grafana dashboards`.

Independent of everything else; merge whenever. **Leaves two things behind that Helm and Flux do
not remove, which must be deleted by hand** (see Manual steps).

### Stage 7 — Flux removal

Irreversible. Deleting the suspended HelmReleases and Kustomizations removes the reversal
switches, so after this, going back to Flux means re-deriving them from git history.

Merge: `feat(argocd): Remove Flux`, `chore(bootstrap): Remove Terraform's Flux footprint`.

**Order matters more here than anywhere else, and one ordering is not obvious — see 7.5.**

#### 7.1 Scale the controllers down before touching any CR

```bash
kubectl --context $CTX -n flux-system get deploy -o name | \
  xargs -I{} kubectl --context $CTX -n flux-system scale {} --replicas=0
```

With no controller running, no finalizer can prune or uninstall regardless of what any spec
says. Belt-and-braces once prune is off everywhere, but it costs nothing.

#### 7.2 Clear finalizers, then delete the CRs

The two steps are in this order *because* the controllers are down: a finalizer with no
controller to process it blocks deletion forever.

```bash
for kind in helmreleases.helm.toolkit.fluxcd.io kustomizations.kustomize.toolkit.fluxcd.io \
            helmcharts.source.toolkit.fluxcd.io gitrepositories.source.toolkit.fluxcd.io; do
  kubectl --context $CTX get $kind -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' | \
  while IFS=/ read ns name; do
    [ -n "$name" ] && kubectl --context $CTX -n "$ns" patch $kind "$name" \
      --type=merge -p '{"metadata":{"finalizers":null}}'
  done
done
# then delete every Flux kind, including the ones with no instances
```

**Verify finalizers are actually clear before deleting**, and re-read if the answer looks
inconsistent — the API served a stale list once during the staging run, showing finalizers
that had already been removed.

#### 7.3 Verify nothing else moved

This is the moment a missed `prune: true` would show up.

```bash
# uids must be unchanged, counts must match the Stage 0 baseline
kubectl --context $CTX -n prow get deploy -o json | python3 -c 'import json,sys; print(sorted((d["metadata"]["name"],d["metadata"]["uid"]) for d in json.load(sys.stdin)["items"]))'
kubectl --context $CTX get ns; kubectl --context $CTX -n ack-system get crds 2>/dev/null
kubectl --context $CTX -n argocd get applications.argoproj.io
```

Staging: 10/10 Prow Deployment uids held, ProwJob CRD held, 11 namespaces held, 23 ACK CRs
intact, 172/172 Argo CD-tracked objects still tracked.

#### 7.4 Delete Flux itself

```bash
kubectl --context $CTX get crds -o name | grep toolkit.fluxcd.io | xargs -r kubectl --context $CTX delete
kubectl --context $CTX delete clusterrole crd-controller flux-edit flux-view --ignore-not-found
kubectl --context $CTX delete clusterrolebinding cluster-reconciler crd-controller --ignore-not-found
kubectl --context $CTX delete ns flux-system
```

**A CRD can hang on an orphaned CR in a namespace that no longer exists.** Staging hit this:
`gitrepositories.source.toolkit.fluxcd.io` sat in `Terminating` on its
`customresourcecleanup` finalizer because one GitRepository remained in a deleted namespace —
readable, but every write rejected with `namespaces "..." not found`. The fix is to recreate
the namespace, clear the CR's finalizer, then delete both:

```bash
kubectl --context $CTX create namespace <the-missing-namespace>
kubectl --context $CTX -n <the-missing-namespace> patch gitrepository <name> \
  --type=merge -p '{"metadata":{"finalizers":[]}}'
kubectl --context $CTX delete namespace <the-missing-namespace>
```

#### 7.5 Remove from git BEFORE deleting Flux's ACK CRs

**This is the step whose order is easy to get wrong, and staging got it wrong.** Flux's own
AWS footprint is declared in charts that Argo CD now reconciles:

- the `ghcr.io/fluxcd` pull-through cache rule (the `ack-flux` chart)
- the kustomize-controller `PodIdentityAssociation`, its build-cluster `AccessEntry` and the
  IAM role behind it (all in `ack-build-infra`)

Delete those CRs while they are still in a synced Application's desired state and **Argo CD
recreates them within seconds** — `automated` is on. Push the git removal first, hard-refresh
the owning Application, confirm the objects are no longer in its desired state, and only then
delete them. They will then show as extraneous rather than missing, and stay deleted.

Refresh the **owning Application directly**. Refreshing the root does not re-render its
children.

Then, in dependency order:

```bash
# 1. pod identity association -- it references the IAM role
# 2. the access entry CR
# 3. the AWS access entry, explicitly, IF its CR carried deletion-policy: retain
aws eks delete-access-entry --cluster-name <build-cluster> --principal-arn <flux-role-arn>
# 4. the IAM role CR -- after the entry, or the entry is left naming a principal that is gone
# 5. the pull-through cache rule CR
```

Check `services.k8s.aws/deletion-policy` on each first. On staging the access entry was
`retain` and the other three were not, so only that one needed an explicit AWS delete.

**Also delete the orphaned Application.** Removing the `ack-flux` entry from the chart stops
the root rendering it, but Argo CD cannot delete Applications — `argocd-rbac.tf` grants
get/create/update/patch and no delete — so it lingers, pointing at a path that no longer
exists. Delete it by hand.

#### 7.6 Terraform

`flux.tf` goes entirely. Watch for things that outlive it:

- **any script reading `self-managed-vars`.** `bootstrap-prow-images.sh` read four values from
  it; that ConfigMap was Flux's substitution source and went with the namespace, so the script
  would have failed on the next fresh bootstrap. Pass the values from the provisioner instead.
- **`depends_on` edges into `null_resource.validate_kustomizations`**, which polled Flux
  Kustomizations. `swap_nodepool` had one. Nothing replaces it: what it waited for is now
  delivered by an Application, which Terraform cannot observe. Check the script polls for
  itself before dropping the gate — `swap-nodepool.sh` does.
- **the node role's ECR pull-through-cache policy**, scoped to `repository/fluxcd/*`.
- **the `ghcr-fluxcd` Secret lookup** and the `ghcrPtcSecretArn` chart value that fed
  `ack-flux`.
- **`var.flux_version`**, its `tfvars` entry, and any prompt reading a default from a deleted
  file (`bootstrap-env.sh` read one out of `flux/flux/version-configmap.yaml`).

The `kubernetes_config_map_v1` resources for `self-managed-vars` and `flux-version` need no
special handling: their namespace is already gone, so refresh drops them from state and they do
not appear in the plan.

**Gate:** `terraform plan` clean, `terraform state list | grep -i flux` empty, and every
remaining mention of "flux" in `bootstrap/` is a comment.

#### 7.7 What legitimately stays

The **charts** live under `flux/` — `flux/ack/charts/`, `flux/prow/charts/`, `flux/prow/crds/`
and `flux/secrets/` are Argo CD Application sources. Only the Kustomization and HelmRelease
*definitions* are deleted. The directory name is now a misnomer; renaming it means touching
every Application path and is a separate change.

Staging end state: 21 Applications Synced and Healthy, 10 Prow Deployments available, zero Flux
CRDs, zero Flux namespaces, zero Flux cluster RBAC, no Flux access entries or pull-through cache
rules in AWS, and a clean `terraform plan`.

---

## Manual steps

Everything that is not a merge or a `terraform apply`. Each is required; none is optional.

### Reconcile triggers

Flux waits for its interval (60m on most paths here), so every stage needs a nudge:

```bash
kubectl --context $CTX -n flux-system annotate gitrepository test-infra \
  reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
kubectl --context $CTX -n flux-system annotate kustomization <name> \
  reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
```

**Reconciling the root does not reconcile a child's own spec.** Changing a child Kustomization's
`prune`, or the GitRepository's branch, needs that child — or the `flux` Kustomization that applies
it — annotated directly. Staging lost time to this twice.

For Argo CD, `automated` does **not** retry a revision it has already reported on. A hard refresh
is what forces re-evaluation:

```bash
kubectl --context $CTX -n argocd annotate applications.argoproj.io <app> \
  argocd.argoproj.io/refresh=hard --overwrite
```

### Objects to delete by hand

Nothing here is deleted by merging, because `prune: false` is set everywhere — which is what makes
cutover reversible and also what leaves debris.

| after stage | delete | why it lingers |
|---|---|---|
| 6 | the `prometheus` namespace | helm-controller does not delete a namespace it created |
| 6 | 10 `monitoring.coreos.com` CRDs | Helm never deletes CRDs installed from a chart's `crds/` directory |
| 6 | `prometheus-prometheus-kube-admission` Secret | written by a chart *hook*, so it was never part of the release |
| 2 | the six objects the connection chart left in its old namespace | moving a namespace is a recreate, not an adoption |
| 7 | Flux's ACK CRs — cache rule, pod identity, access entry, IAM role | declared in charts Argo CD reconciles; **push the git removal first or `automated` recreates them** |
| 7 | the retained AWS access entry | its CR carried `deletion-policy: retain`, so ACK leaves the AWS object |
| 7 | the orphaned `ack-flux` Application | Argo CD has no `delete` on Applications, so a removed entry lingers |
| 7 | Flux CRDs, cluster RBAC, the `flux-system` namespace | never owned by any Application |

**The recurring shape:** `prune: false` is what makes every cutover reversible, and it is also
what leaves debris at every step. Nothing on this list is deleted by merging. Budget for a
sweep after each stage rather than discovering them months later by grepping for a label.

Before deleting a namespace or CRD, confirm nothing remains that depends on it:

```bash
for k in $(kubectl --context $CTX get crds -o name | grep monitoring.coreos.com); do
  echo "$k: $(kubectl --context $CTX get ${k#*/} -A --no-headers 2>/dev/null | wc -l) CRs"
done
# all must be 0
```

**Do not pattern-match on names when deleting.** `v1alpha1.prometheusservice.services.k8s.aws`
matches a search for "prometheus" and is ACK's Amazon Managed Prometheus controller. Match on the
API group.

### Verification that has to be done by hand

- **uid preservation** on every adopted object, before enabling `automated`. Compare against the
  Stage 0 baseline. The paths where a recreate is destructive: `prow-config` (nine Deployments with
  immutable `spec.selector`), `prow-namespaces` (namespaces cascade), `prow-crds` (the ProwJob CRD
  and every ProwJob with it).
- **an end-to-end job** after Stage 5: trigger a presubmit routed to the build cluster and confirm
  it schedules, runs and reports.

---

## What prod must NOT copy from staging

Staging reached this state incrementally, and some of what it did was cleaning up after itself.
**The cleaned history does not contain those states, so prod must not perform the fixes for them.**

| staging did | prod should not | why |
|---|---|---|
| `terraform import` of 14 RBAC objects | skip entirely | staging had them as Flux-applied objects under `flux/argocd/`. That path **never exists** in the merged history — `argocd-rbac.tf` creates them fresh |
| `terraform state rm` of 19 Applications | skip entirely | staging declared them one-per-resource in Terraform before the root Application existed. Prod's Terraform never holds them |
| `terraform state rm` of `aws_iam_role_policy.ack_capability_bootstrap` | only if ACK has already replaced it | on a fresh bootstrap, seed it with `-var seed_ack_bootstrap_policy=true`, then drop the flag once ACK writes its own policies |
| deleting orphans in the connection chart's old namespace | only if that environment ran an older revision | prod deploys the chart into `ack-system` from the start |

---

## Rollback

Every stage before 5 is reversible by reverting the merge and reconciling, because Flux still owns
everything and `prune` is off.

**Stage 5 is the boundary.** After it, reverting the suspend hands paths back to Flux — but Argo CD
still has `automated` on, so both reconcilers own the same objects and will fight. To roll back
after Stage 5, disable `automated` first (or delete the Applications, which with `prune: false`
leaves objects in place), *then* unsuspend Flux.

**Stage 7 is irreversible.** Deleting the suspended HelmReleases and Kustomizations removes the
reversal switches.

---

## Environment differences

`bootstrap/images.tf` marks several resources non-prod:

- per-controller public ECR repos — in prod, controllers publish to
  `public.ecr.aws/aws-controllers-k8s`
- the ACK parent chart repo — in prod, `public.ecr.aws/aws-controllers-k8s/ack-chart`
- the `ArtifactReader` role — in prod it lives in the shared publishing account

`local.controller_ecr_alias` derives from the first controller repo URI in non-prod. Confirm how it
resolves for prod before Stage 3, because `controllerEcrRegistry` is threaded into `prow-config`
and `prow-jobs` as a chart value.

Prod is a different org and package from staging, so `test_infra_org` / `test_infra_repo` differ and
the fork that the reconcilers read is not the one staging used.
