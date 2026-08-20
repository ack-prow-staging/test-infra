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

### How the stages reach a different org

Staging and prod are different repos in different orgs, so the commits do not simply advance —
**each stage goes in as its own PR against the target repo** (for prod, `aws-controllers-k8s/test-infra`).
Never push directly to its `main`. One PR per stage keeps the gate between stages, which is the
whole point of the ordering, and every commit in the sequence has been checked to be individually
valid so a PR can stop at any stage boundary.

**Merging is deploying.** Prod's `GitRepository` reads `main` at a **1-minute interval**, so a merged
PR is live in about 60 seconds, with no window to inspect anything first. Two consequences worth
internalising:

- Verify a stage's gate *before* merging the next PR, not after. There is no soak period unless you
  make one.
- Where a stage pairs git changes with Terraform, the git half lands on merge and the Terraform half
  waits for an apply. Have the apply ready to run rather than queued behind a review.

Rebase each PR on the target's `main` before merging. The sequence currently rebases cleanly, but
upstream moves independently and the stages land over days.

#### Cherry-picking a stage is not a prefix of the branch

**Stage order and commit order are different orders**, so a stage's PR is a cherry-pick, not a range.
In the staging branch the cutover sits *before* the root Application, Stage 6 sits before Stage 5, and
Stage 1's last prune commit sits after all of them — because that history was ordered to make each
commit individually valid, not to make stages contiguous. Assembling the stages in stage order
produces conflicts, and they are worth knowing in advance because most are trivial and two are not:

| picking | conflicts with | resolution |
|---|---|---|
| `Convert the remaining paths…` | the added prune commit | comment-only; both set `prune: false`. Take the incoming comment, which is the more specific one |
| `Move the build-cluster connection chart…` | the earlier flux-system comment | comment-only; take incoming. Confirm `targetNamespace: ack-system` survived |
| `Cut every path over to Argo CD` | `flux/kustomization.yaml` | **mutual.** Staging removed `prometheus.yaml` before this commit; in stage order it is still present. Keep `prometheus.yaml` here and remove it at Stage 6 |
| `Remove kube-prometheus-stack…` | `flux/kustomization.yaml` | the mirror of the above: remove `prometheus.yaml`, keep `argocd.yaml` removed |
| `Remove Flux` | `flux/kustomization.yaml` | modify/delete — the commit deletes the file. Accept the deletion |

**Docs conflicts are not worth resolving — drop the file.** Since `docs/` never goes upstream, a
cherry-pick that conflicts on `docs/argocd-migration.md` should be resolved by removing the file from
the commit:

```bash
git rm -q --cached docs/argocd-migration.md && rm -f docs/argocd-migration.md
git add -A && git -c core.editor=true cherry-pick --continue
```

Note that `git checkout upstream/main -- docs/` does **not** work for this: the file does not exist
upstream, so there is nothing to restore and it silently leaves the file in place.

Resolving such a conflict properly is worse than useless here, and the reason is worth recording in
case the decision is ever revisited. Taking the incoming side reverts later corrections, because the
docs were written before the code they describe was finished — doing that reintroduced two
contradictions: a comment claiming the connection chart's objects live in `flux-system` directly above
`targetNamespace: ack-system`, and a passage citing `charts/flux2-2.18.4` and
`scripts/pull-flux-chart.sh` as the house pattern after Stage 8 deletes both. If docs ever do go
upstream, take the final state, not the incoming commit.

The check that catches all of this: the assembled sequence's final tree must equal the source
branch's tree, allowing only for commits the target gained independently.

```bash
git diff --stat <source-branch> HEAD     # expect only upstream's own newer files
```

### Merge order at a glance

Oldest first. The gate column is the short form; the stage section is authoritative.

| stage | merge | gate before proceeding |
|---|---|---|
| 0 | nothing | environment pointed at the target account; baseline captured |
| 1 | `fix(ack): Set enableNetworkAddressUsageMetrics…`, both prune commits, **plus a fourth you write** | `prune: false` on every path's **live** spec except the prometheus pair |
| 2 | `refactor(flux): Render the ACK and Prow paths from Helm charts`, `feat(argocd): Convert the remaining paths and register the build cluster` | unsuspended Kustomizations `Ready=True`, Prow uids unchanged |
| 3 | `feat(argocd): Stand up the capability…`, `feat(argocd): Grant the capability the in-cluster RBAC it needs`, `fix(ack): Seed BootstrapPermissions…`, `fix(prow): Gate the one-shot image bootstrap…` | capability Healthy, RBAC applied, no cluster-admin granted |
| 4 | `feat(argocd): Render the Applications from git via a root Application`, `feat(argocd): Give the Prow namespaces and ServiceAccounts an owner` | every Application Synced+Healthy **while Flux still owns the objects** |
| 5 | `feat(argocd): Cut every path over to Argo CD` | Stage 4's gate passed for *every* path; presubmit runs end to end |
| 6 | `chore: Remove kube-prometheus-stack and the Prow Grafana dashboards` | independent; merge whenever |
| 7 | `refactor(prow): Move the build-cluster connection chart out of flux-system`, `feat(argocd): Remove Flux`, `chore(bootstrap): Remove Terraform's Flux footprint`, `refactor(argocd): Drop flux-system from the hub write grant` — **in that order** | `terraform plan` clean, no Flux in state, CRDs/RBAC/namespace gone |
| 8 | `chore: Sweep the remaining Flux references`, `chore(bootstrap): Remove the nodepool swap` | `terraform plan` clean, `general-purpose` NodePool Ready |

**The `docs(...)` commits are not merged upstream at all.** `docs/argocd-migration.md` and this
runbook are staging artifacts — the record of how the migration was derived and what it cost, which
is worth having while replaying it and is not something the target repo has asked to carry. They stay
on the staging fork. Whether any of it is worth preserving upstream is a separate decision, taken
after the migration lands rather than smuggled in alongside it.

Practically: **drop `docs/` from every stage PR.** Cherry-picking a stage will sometimes pull a doc
change along with the code — resolve that by removing the file from the commit, not by resolving the
conflict. Verify before pushing:

```bash
git diff --name-only upstream/main HEAD -- docs/    # must be empty
```

---

## Prerequisites

- Terraform ≥ 1.7, `kubectl`, `helm`, `aws` CLI, and credentials for the target account.
- `<env>.tfvars` for the environment. Staging's is `bootstrap/environment/staging.tfvars`; prod
  needs its own. Required values: `region`, `account_id`, `flux_version`, `prow_domain`,
  `test_infra_org`, `test_infra_repo`, `test_infra_branch`, `stage`, `kubernetes_org`,
  `redhat_org`, `controllers`, `publish_account_id`.
- **`bootstrap/identity/` must be applied first, and it is a separate Terraform stack.** It creates
  the IAM Identity Center account instance and the `<stack_name>-argocd-admins` group that Stage 3
  consumes by data source. It keeps its own state (`identity/terraform.tfstate`) precisely so the
  main stack's destroy/apply cycle can never delete them, which also means it needs **its own
  generated `backend.tf`** in `bootstrap/identity/` pointing at the same environment bucket.

  Skip it and Stage 3 does not fail late, it fails at plan:

  > `Error: Missing required argument` — `data.aws_identitystore_group.argocd_admins`,
  > `The argument "identity_store_id" is required, but no definition was found.`

  which is `one(data.aws_ssoadmin_instances.this.identity_store_ids)` yielding `null` because the
  account has no instance yet. Verified against prod, where `aws sso-admin list-instances` returns
  nothing. Confirm before Stage 3 rather than reading that error:

  ```bash
  aws sso-admin list-instances --query 'Instances[].IdentityStoreId' --output text   # must be non-empty
  aws identitystore list-groups --identity-store-id <id> \
    --query "Groups[?DisplayName=='<stack_name>-argocd-admins']" --output text
  ```

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

### Stage 0 — Point the workspace at the environment, then baseline it

Nothing to merge.

#### 0a — Generate the environment's Terraform inputs

**Neither `bootstrap/backend.tf` nor `bootstrap/environment/<stage>.tfvars` is in git** — both are
gitignored and generated per environment. A checkout carries no trace of which account it last
pointed at, so a workspace that was just used for staging still has staging's backend on disk.
Getting this wrong points a prod apply at another account's state.

Confirm the credentials first, because everything below silently follows them:

```bash
aws sts get-caller-identity --query '{acct:Account,arn:Arn}' --output text
# must be the target account before continuing
```

**The tfvars come from SSM**, not from a file anyone edits:

```bash
cd bootstrap && ./scripts/bootstrap-env.sh     # writes environment/<stage>.tfvars
```

It reads `/ack/test-infra/bootstrap/env` and prompts for nothing when the parameter already exists.
The `stage` key in that JSON decides the filename, so it writes `prod.tfvars` on its own. Verify
`account_id` and `stage` in the output match the account you just confirmed.

**The backend needs care.** `scripts/bootstrap-backend.sh` finds the bucket by the prefix
`ack-test-infra-terraform-state` and templates `backend.tf` from it, which is the part you want —
each account has its own bucket and the names carry a random suffix, so the value cannot be
guessed or copied between environments.

> **It also rewrites the bucket's versioning, encryption and public-access-block on every run, and
> its encryption payload is not necessarily what the bucket already has.** Prod's state bucket
> additionally blocks `SSE-C` via `BlockedEncryptionTypes`, which the script's payload omits — so
> running it there silently drops that restriction. On an environment whose bucket already exists
> and is already hardened, read the bucket name and write `backend.tf` by hand instead:

```bash
aws s3api list-buckets \
  --query "Buckets[?starts_with(Name,'ack-test-infra-terraform-state')].Name" --output text
# then write bootstrap/backend.tf with that bucket, key bootstrap/terraform.tfstate,
# the region, use_lockfile = true, encrypt = true
terraform init -reconfigure -input=false
```

Reserve the script for a genuinely fresh account, where it has a bucket to create.

#### 0c — Plan once, and read it for destroy-time provisioners

Run a plan before any stage needs one, and read it for **replacements**, not just for the summary
line. Terraform's own summary hides the danger: a replaced `null_resource` reports as one add and
one destroy, and if it carries a `when = destroy` provisioner, that provisioner *runs* — against the
old trigger values.

```bash
terraform plan -input=false -no-color -var-file=environment/<stage>.tfvars > /tmp/plan.log 2>&1
grep -E "must be replaced|will be destroyed" /tmp/plan.log
grep -rn "when *= *destroy" *.tf          # which of those actually do something on destroy
```

Prod is a live example, and it has nothing to do with the migration — it is state drift the first
apply would have executed. `null_resource.cleanup_prow_hosted_zone` triggers on `prow_domain`, and
prod's state held `prow-v2.ack.aws.dev` while the SSM-derived tfvars says `prow.ack.aws.dev`. That
one-word difference forces a replacement, and the resource's destroy provisioner looks up a hosted
zone by name and deletes it. It would have run with the *old* value and deleted the
`prow-v2.ack.aws.dev` zone — which still exists, with five records including an ACM DNS-validation
CNAME.

So: reconcile the drift, or accept the deletion deliberately, before the first apply. Do not
discover it from an apply.

**What prod did, and why it is the cheaper of the two fixes.** The stale value was the wrong one —
`prow.ack.aws.dev` serves traffic, `prow-v2.ack.aws.dev` did not — and the `prow-v2` zone turned out
to be debris: a redundant alias to the *same* live ALB, plus an ACM validation CNAME for a
certificate reporting `InUse=False`. Deleting the zone and that certificate up front makes the
replacement harmless, because the provisioner opens with

```sh
if [ -z "$ZONE_ID" ]; then echo "  Hosted zone not found. Nothing to clean up."; exit 0; fi
```

and carries `on_failure = continue`. So a missing zone is a clean no-op, the resource is recreated
carrying the correct trigger, and a genuine future `terraform destroy` would then target the right
zone.

The alternative was `terraform state rm null_resource.cleanup_prow_hosted_zone`, which also works —
state operations never run provisioners, and this resource has **zero** create-time provisioners, so
recreating it does nothing. Prefer deleting the stale object when it is genuinely debris, and reserve
the state surgery for when the object must survive.

Two related pieces of debris surfaced while checking whether the zone was safe to delete, both from
cluster generations that no longer exist — worth looking for in any long-lived account, since neither
is referenced by DNS or by any Ingress:

- an ALB tagged `elbv2.k8s.aws/cluster = TestInfraCluster`, created 2023-02-16, all targets unhealthy
- four target groups tagged for `TestInfraCluster` and `TestInfraCluster15BBC7AB-…`

Confirm the owning cluster is absent from `aws eks list-clusters` first. If it still exists, the AWS
Load Balancer Controller simply recreates whatever you delete.

There are four of these in `ack.tf`, and it is worth knowing what each would do and what makes it
fire:

| resource | trigger | what its destroy provisioner does |
|---|---|---|
| `cleanup_prow_hosted_zone` | `prow_domain`, `region` | deletes the Route53 hosted zone, records first |
| `cleanup_prow_logs_bucket` | `bucket_name` | empties the bucket, all versions, then deletes it |
| `cleanup_ack_capability_role` | `role_name` | detaches and deletes the IAM role and its policies |
| `cleanup_ack_resources` | `cluster_name`, `region`, `script` | runs `cleanup-ack-resources.sh` |

The first three trigger on values derived from `stack_name`, `account_id` and `prow_domain`, so they
are stable unless one of those changes — which is exactly what happened to `prow_domain`. The
fourth's `script` trigger is a **path string, not file content**, so editing
`cleanup-ack-resources.sh` does not force a replacement; only moving it would. None of the migration
commits change any of these triggers.

By contrast the two one-shot `null_resource`s that Stage 3 destroys — `bootstrap_prow_images` and
`bootstrap_prow_images_job`, both dropping to `count = 0` — carry no destroy-time provisioner, so
their removal is inert. Confirm that rather than assuming it.

> **A wart to expect, not to fix yet.** The SSM JSON is emitted key-for-key, so the generated
> tfvars includes `flux_version`. Stage 7 deletes that variable, after which every plan prints
> `Warning: Value for undeclared variable`. It is a warning and the plan still exits 0 — verified on
> Terraform 1.15.2 — so it breaks nothing. Drop `flux_version` from the SSM parameter once Stage 7
> is done.

#### 0b — Baseline the cluster

Capture what "unchanged" means so you can prove it later.

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

Also capture the Flux source of truth, because it decides what merging does:

```bash
kubectl --context $CTX -n flux-system get gitrepository -o json \
  | jq '.items[] | {url: .spec.url, ref: .spec.ref, interval: .spec.interval}'
```

**And look for a second Flux.** `bootstrap-flux.sh` installs a namespace-scoped instance in
`bootstrap-flux-system` to deploy the real one, and is supposed to tear it down. Prod's was still
there 84 days later. It is declared nowhere in git, so no stage removes it.

**Do not probe for it with `get ns`.** In prod the `Namespace` object is gone while its contents
survive — the signature of a namespace force-deleted by stripping its finalizers, which orphans the
objects instead of collecting them. `kubectl get ns bootstrap-flux-system` answers `NotFound` there
while six Deployments, a `GitRepository` and a `Kustomization` are all still queryable inside it. Ask
for the objects, not the namespace:

```bash
kubectl --context $CTX get kustomizations.kustomize.toolkit.fluxcd.io,gitrepositories.source.toolkit.fluxcd.io \
  -A -o custom-columns='NS:.metadata.namespace,KIND:.kind,NAME:.metadata.name' | grep -v '^flux-system'
kubectl --context $CTX -n bootstrap-flux-system get deploy 2>/dev/null
```

Confirm it is frozen rather than live before treating it as harmless: compare the Ready condition's
`lastTransitionTime` against the declared `interval`. Prod's read `2026-05-28` with intervals of 5m
and 1m, so nothing had reconciled it in 84 days. Had those timestamps been recent it would have been
a second reconciler applying a stale branch, which is a different problem entirely.

**Gate:** you can answer all of these without running anything —

- how many Kustomizations and HelmReleases, and which are suspended
- the Prow Deployment uids
- which repo and ref the hub's `GitRepository` reads, and its interval, so you know how long after
  a merge the change is live
- whether a `bootstrap-flux-system` exists, and if so what is left in it
- that `backend.tf` names the target account's bucket and `terraform init` succeeded against it
- that `<stage>.tfvars` reports the `account_id` and `stage` you expect

The last two are the ones that cause damage rather than delay if they are wrong.

### Stage 1 — Safety: prune off, deletion protection

Merge: `fix(ack): Set enableNetworkAddressUsageMetrics on the build VPC`,
`chore(flux): Disable prune and make deletion structurally impossible`,
`chore(flux): Disable prune on the last three paths before Flux removal`.

> These two exist separately only because staging discovered the remainder late. For a fresh
> environment merge both prune commits together — they are one concern.

**Then write a fourth commit, because those three are not sufficient.** There is nothing to
cherry-pick for it: `prow-agent-workflows`, `prow-crds`, `prow-plugins` and `secrets` had prune
disabled by commits belonging to Stages 2, 5 and 6, every one of which sits *earlier* in the linear
order than "Disable prune on the last three paths". Deliver Stage 1 on its own and those four stay
`prune: true` — the precise condition this stage exists to prevent, since deleting a Kustomization
with prune enabled garbage-collects its inventory.

They live in `flux/prow.yaml` (`prow-crds`), `flux/secrets.yaml`, and
`flux/prow/charts/prow-agent-workflows.yaml` and `prow-plugins.yaml`. Setting `prune: false` on those
four is the whole change. Expect the later `Convert the remaining paths…` pick to conflict on the
comments, which is harmless — see *Cherry-picking a stage is not a prefix of the branch*.

Verify with the gate below rather than by reading the diff: the four are easy to miss precisely
because three separate commits appear to have covered them.

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
  -o custom-columns='NAME:.metadata.name,PRUNE:.spec.prune' \
  | grep -i true | grep -vE 'prometheus'
# must return nothing
```

**`prometheus` and `prometheus-dashboards` are the exception, and stay `prune: true`.** The rule
exists because converting a path to a chart makes every raw object stale and prune deletes stale
objects. Those two are never converted — Stage 6 deletes them outright — so there is no stale
window for prune to act in, and when the Kustomization goes, prune reclaiming its inventory is the
outcome you want rather than the hazard. Staging confirmed it: everything the release owned was
pruned correctly, and only what Helm and Flux structurally never delete was left by hand (see
*Manual steps*). If Stage 6 has already been merged they will be absent entirely and the plain
`grep -i true` returns nothing on its own.

This is the most important gate in the runbook. Every later step deletes or suspends something,
and a Kustomization with prune enabled garbage-collects its inventory when deleted. On staging
`prow-charts` held the `prow-config` HelmRelease, whose release owns Prow's nine Deployments.

Expect 60–90 seconds of churn after any root reconcile: a dozen Kustomizations go `Ready=False`
with `DependencyNotReady` and converge in waves. That is `dependsOn` polling, not a fault.

### Stage 2 — Chart conversions (inert)

Merge: `refactor(flux): Render the ACK and Prow paths from Helm charts`,
`feat(argocd): Convert the remaining paths and register the build cluster`.

> **`refactor(prow): Move the build-cluster connection chart out of flux-system` cannot go here**,
> though it is a chart conversion in spirit. It edits `argocd/applications/values.yaml`, which does
> not exist until Stage 4 creates it, so applied at this stage it does not merely misbehave — it
> fails to apply at all. It moves to Stage 7, ahead of the `flux-system` deletion.

These are inert by construction: Flux keeps reconciling and keeps passing the same values, and the
charts render byte-identically to what the Kustomizations produced. Nothing in this stage requires
Argo CD to exist.

**With one deliberate exception: this stage stops managing the hub cluster.** The old
`flux/ack/cluster/cluster.yaml` declared the hub's own `Cluster` CR and carried the last render-time
cluster read in the repo, which Argo CD cannot satisfy — it renders off-cluster, so Helm's `lookup`
returns empty. The chart therefore omits it, and no later stage re-adopts it: in the final state only
`ack-build-infra` declares a `Cluster`, and that one is the *build* cluster's.

So after this stage the live hub `Cluster` CR is declared nowhere. That is safe, and for three
reasons worth confirming rather than assuming:

- Stage 1 disabled prune, so nothing collects it
- the CR carries `services.k8s.aws/deletion-policy: retain`, so even deleting it leaves the EKS
  cluster alone
- Terraform owns the actual cluster through `aws_eks_cluster.this`, so the CR was only ever an
  adoption

```bash
kubectl --context $CTX -n ack-system get clusters.eks.services.k8s.aws \
  -o custom-columns='NAME:.metadata.name,DELETION:.metadata.annotations.services\.k8s\.aws/deletion-policy'
# the hub's own CR should read retain -- it becomes an orphan from here on
```

It is an eighth object with no owner, on top of the seven in `docs/argocd-migration.md`. **This is
temporary by intent** — the plan is to adopt the hub cluster back into ACK once the migration has
settled, and Terraform owns it in the meantime to keep the one irreplaceable object off the critical
path. `docs/argocd-migration.md` has what that work involves. Do not delete the orphaned CR to tidy
up: it is harmless to the cluster, but it carries the `adopt-or-create` and `retain` annotations that
make re-adoption cheap.

Verifying
"inert" per path is still worth doing, but expect this one difference and do not treat it as a
regression: comparing `kustomize build` at the previous revision against `helm template` of the new
chart shows every path identical except this CR, plus `external-dns-role` moving out of the `addons`
path into the `addons/roles` path that already had its own Kustomization.

#### Expect one HelmRelease to land in the wrong namespace

This stage removes `targetNamespace: ack-system` from eight Kustomizations, and it has to: with it
set, Flux rewrites the namespace of everything the path applies, including the `HelmRelease` object
itself, which must stay in `flux-system`.

**A child Kustomization's spec and the content it applies do not update atomically.** The parent
applies the new `flux/ack.yaml` (dropping `targetNamespace`) while each child applies its own new
`helm-release.yaml`, and a child that reconciles first still carries the old spec. It then rewrites
the HelmRelease into `ack-system`, where `valuesFrom` cannot find `self-managed-vars` — that ConfigMap
lives in `flux-system`:

> `could not resolve ConfigMap chart values reference 'ack-system/self-managed-vars' with key
> 'ACCOUNT_ID': configmaps "self-managed-vars" not found`

On prod exactly one path lost this race, `ack-capability-role`, the first in the dependency chain.
Because these Kustomizations carry `wait: true`, that single failure held **seventeen** dependents at
`dependency ... is not ready`. Prow was never affected — it is not downstream of these paths — but the
stage cannot pass its gate until it clears.

```bash
# the tell: a HelmRelease anywhere other than flux-system
kubectl --context $CTX get helmreleases.helm.toolkit.fluxcd.io -A \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status'
```

**Fixing it needs a controller restart, not a nudge.** Suspend/resume and
`reconcile.fluxcd.io/requestedAt` both appear to do nothing, and the reason is worth knowing: the
Kustomization's health check is a *blocking wait inside the reconcile goroutine*, holding for the full
timeout — `Running health checks for revision … with a timeout of 59m30s`. Mutating the resource does
not interrupt a goroutine that is not re-reading it.

```bash
# 1. suspend FIRST, so the health check cannot re-park on the object you are about to delete
kubectl --context $CTX -n flux-system patch kustomization <name> --type=merge -p '{"spec":{"suspend":true}}'
# 2. delete the misplaced HelmRelease -- check for a release first; if it never installed there is
#    nothing to uninstall (no helm.sh/release.v1 secret in that namespace)
kubectl --context $CTX -n ack-system delete helmrelease <name>
# 3. resume, then restart the controller to abandon any goroutine already parked
kubectl --context $CTX -n flux-system patch kustomization <name> --type=merge -p '{"spec":{"suspend":false}}'
kubectl --context $CTX -n flux-system rollout restart deploy/kustomize-controller
```

Deleting before suspending is what makes this expensive: the reconcile parks on an object that no
longer exists and the stale inventory entry keeps naming the old namespace. After the restart the
child re-applies under its corrected spec, the HelmRelease appears in `flux-system`, and the health
check passes in milliseconds. The cascade then clears in a few minutes.

Restarting `kustomize-controller` is low risk here: it is stateless, `prune` is off everywhere so
nothing can be collected, and a pause in reconciliation changes nothing already running.

#### Two Kustomizations cannot reach Ready in this stage, and both are expected

Prod hit both. Neither is degradation — no object is deleted or changed — but the literal gate
"all unsuspended Kustomizations `Ready=True`" cannot pass, so know which two before deciding whether
to proceed.

**`argocd-rbac` — `kustomization path not found: .../flux/argocd`.** `flux/argocd.yaml` declares a
Kustomization pointing at `./flux/argocd`, and **no commit in the sequence creates that directory** —
not the conversion commit that adds the declaration, not the Stage 3 commit that grants the same RBAC,
not the final state. In staging its objects were adopted into Terraform by `terraform import`, so the
directory only ever existed as live objects, never as committed files. It is harmless because prune is
off: a path-not-found applies nothing. Stage 5 removes the declaration, and the live Kustomization
object then lingers and needs hand deletion — it is on that list.

**`prow-build-cluster-connection` — `Helm upgrade failed … testConfig is required`.** The chart it now
renders cannot be rendered by Flux at all, as its own comment explains: it composes the
`prow-build-cluster-resources` Application, which needs the *contents* of `prow/jobs/test_config.yaml`,
and `valuesFrom` reads only ConfigMaps and Secrets. Only Terraform can supply it, via `file()`.

The subtlety worth knowing: **shipping the chart change and its `suspend: true` in the same commit
does not prevent one upgrade attempt.** helm-controller picks up the new chart revision and runs the
upgrade before, or despite, the suspend landing; the attempt fails, and because the HelmRelease is then
suspended nothing ever retries, so it stays `Ready=False` permanently. With `wait: true` on its
Kustomization that holds every dependent — on prod, `prow-charts`, `prometheus` and
`prometheus-dashboards`. Those paths stop *reconciling*; their objects stay live and healthy, which is
why Prow is unaffected. It clears at Stage 5, when these HelmReleases are deleted.

```bash
# distinguish "not reconciling" from "not working" before treating either as a problem
kubectl --context $CTX -n prow get deploy          # must still be fully available
kubectl --context $CTX -n prow get configmap build-cluster-kubeconfig   # must still exist
```

**Gate — judge it on these, not on the Ready count:** the Prow Deployment uids from Stage 0 unchanged,
no ACK CR recreated, and every Kustomization Ready except the two above. Expect the ACK CR count to
rise by one: `AccessEntry/argocd-build-cluster-access` is new content from registering the build
cluster, not a recreate.

```bash
kubectl --context $CTX -n prow get deploy -o json | \
  python3 -c 'import json,sys; print(sorted((d["metadata"]["name"],d["metadata"]["uid"]) for d in json.load(sys.stdin)["items"]))'
# compare against /tmp/baseline-prow-deploy.json
```

**The stronger check is that no ACK CR was recreated**, since this stage hands their ownership from
kustomize-controller to helm-controller and a recreate would mean ACK deleting and rebuilding an AWS
resource. Deployment uids only cover Prow. There is no uid baseline for the CRs, but a recreate leaves
a fresh `creationTimestamp`, which is sufficient:

```bash
kubectl --context $CTX get -A accessentries,addons,podidentityassociations,repositories,\
roles.iam.services.k8s.aws,buckets,hostedzones,pullthroughcacherules,clusters.eks.services.k8s.aws \
  -o json | python3 -c '
import json,sys,datetime
now=datetime.datetime.now(datetime.timezone.utc)
for o in json.load(sys.stdin)["items"]:
    t=datetime.datetime.fromisoformat(o["metadata"]["creationTimestamp"].replace("Z","+00:00"))
    if (now-t).total_seconds()<7200: print("RECREATED",o["kind"],o["metadata"]["name"])'
# must print nothing
```

Prod passed both: 10/10 uids held and 0 of 53 ACK CRs recreated. Also confirm the HelmRelease count
rose by the number of new charts — 4 to 17 on prod, all Ready — and that none sits outside
`flux-system`.

### Stage 3 — Argo CD standup and authorisation

Merge: `feat(argocd): Stand up the capability and authorise it without cluster-admin`,
`feat(argocd): Grant the capability the in-cluster RBAC it needs`,
`fix(ack): Seed BootstrapPermissions only on a fresh bootstrap`,
`fix(prow): Gate the one-shot image bootstrap behind a variable`.

> **`refactor(argocd): Drop flux-system from the hub write grant` cannot go here either.** Its only
> functional change is removing `"flux-system"` from `argocd_hub_namespaces`, and the connection
> chart still renders into that namespace until the move above happens. Drop the grant first and
> that chart loses its authorisation to sync. It must follow the move, so both land in Stage 7.

The two `fix(...)` commits belong here rather than later: they gate `bootstrap_prow_images` and
`seed_ack_bootstrap_policy` behind variables defaulting false, and this stage is the first apply.
Landing them afterwards leaves a window in which an apply can fire the image-build provisioner —
roughly an hour — or recreate a bootstrap policy ACK has deliberately superseded.

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

**A stalled wave blocks every wave behind it.** The root waits for each wave to report healthy
before starting the next, so one child that cannot sync stops the rollout rather than being
skipped. What that looks like is nothing happening: the later Applications sit `OutOfSync` with no
error of their own, because they were never attempted. **Read the lowest wave that is not healthy
and diagnose there** — an error on a wave-5 Application is a symptom, not a cause.

```bash
# lowest unhealthy wave first -- that is the only one worth reading
kubectl --context $CTX -n argocd get applications.argoproj.io \
  -o custom-columns='WAVE:.metadata.annotations.argocd\.argoproj\.io/sync-wave,NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
  --sort-by='.metadata.annotations.argocd\.argoproj\.io/sync-wave'
```

Wave 0 is `ack-capability-role` and `prow-namespaces`, and `prow-namespaces` is the one to suspect
on this stage specifically: it needs the `namespaces` `create/update/patch` grant that
`Give the Prow namespaces and ServiceAccounts an owner` adds to `bootstrap/argocd-rbac.tf`. Merging
that commit without applying the Terraform in the same stage leaves the Application unable to sync
and the whole tree parked behind it, presenting as a stall rather than as the permission error it
is. Nothing is damaged — the Namespaces and ServiceAccounts already exist, and this path adopts
rather than creates them — so the apply clears it.

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

Merge, **in this order**: `refactor(prow): Move the build-cluster connection chart out of flux-system`,
`feat(argocd): Remove Flux`, `chore(bootstrap): Remove Terraform's Flux footprint`,
`refactor(argocd): Drop flux-system from the hub write grant`.

The first and last are here rather than in Stages 2 and 3 for reasons given there, and the order
among them is a dependency chain, not a preference: the chart has to leave `flux-system` before the
namespace is deleted, and the grant for `flux-system` cannot be withdrawn until nothing renders into
it. Let the move sync and confirm the connection chart is Healthy in `ack-system` before merging the
removal.

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
  Kustomizations. The only one is `swap_nodepool`, and it goes in Stage 8 rather than here — the
  edge is harmless in the meantime because the resource it gates never re-runs. If some other
  resource carries such an edge, note that what it waited for is now delivered by an Application,
  which Terraform cannot observe — the script must poll for itself.
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

### Stage 8 — What outlived Flux

Merge: `chore: Sweep the remaining Flux references`, `chore(bootstrap): Remove the nodepool swap`.

Safe to merge together, and safe to defer — nothing here blocks anything. Both are cleanup of
things that were only load-bearing while Flux existed, and both contain one item that is *not*
inert.

**The sweep** deletes the vendored `flux2` chart (46 files under `charts/`) and
`scripts/pull-flux-chart.sh` that fetched it. The part to notice is
**`scripts/upgrade-prow.sh`**, which read the Prow version from the `prow-version` ConfigMap in
`flux-system`. That namespace is gone as of Stage 7, so the script was already broken at this
point and would have failed the next time anyone bumped Prow. It now reads and writes the three
chart values files directly. If the environment has automation or a documented procedure that
calls it, re-read it after merging — the inputs and the files it edits both changed.

**The nodepool swap** removes `null_resource.swap_nodepool` and
`bootstrap/scripts/swap-nodepool.sh`, which deleted the built-in `general-purpose` NodePool once
`prow-compute` was Ready. It existed because Flux ran on-cluster and needed capacity before the
real pools were created. Argo CD and ACK both run off-cluster, so nothing needs capacity before
the first sync.

It was also never durable, which is the stronger reason to drop it. The NodePool carries
`app.kubernetes.io/managed-by: eks` and has no owner references or field managers: while
`compute_config.node_pools` lists it, the EKS control plane reconciles it back after deletion.
Staging ran the swap and still has the pool. The `null_resource` was fighting the control plane
and losing.

This also drops the last `depends_on` edge into `null_resource.validate_kustomizations`, which
polled Flux Kustomizations and has nothing left to poll.

Apply is the only action: `terraform apply` destroys one `null_resource` and touches nothing else.

**Do not take the next step of setting `compute_config.node_pools = []`.** It looks free once
nothing needs bootstrap capacity, and it is not: it also removes the EKS-managed `default`
NodeClass that both hub NodePools reference, and the auto-created node-role AccessEntry. The
failure modes are quiet — pools that launch nothing while reporting as healthy objects, and nodes
that fail to register in a way that reads as a capacity shortfall rather than an authorisation
failure. `docs/argocd-migration.md` has the full account, including why an adopting AccessEntry CR
cannot carry `accessPolicies`.

**Gate:** `terraform plan` clean, `terraform state list | grep swap` empty, the `general-purpose`
NodePool present and `Ready=True`, and every node `Ready` on the `default` NodeClass.

```bash
kubectl --context $CTX get nodepools.karpenter.sh \
  -o custom-columns='NAME:.metadata.name,CLASS:.spec.template.spec.nodeClassRef.name,READY:.status.conditions[?(@.type=="Ready")].status'
kubectl --context $CTX get nodeclass   # `default` only
```

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
| 7 | the six objects the connection chart left in its old namespace | moving a namespace is a recreate, not an adoption. Moot if `flux-system` is deleted in the same stage, which it now is — but check, because the deletion is what collects them |
| 7 | Flux's ACK CRs — cache rule, pod identity, access entry, IAM role | declared in charts Argo CD reconciles; **push the git removal first or `automated` recreates them** |
| 7 | the retained AWS access entry | its CR carried `deletion-policy: retain`, so ACK leaves the AWS object |
| 7 | the orphaned `ack-flux` Application | Argo CD has no `delete` on Applications, so a removed entry lingers |
| 7 | Flux CRDs, cluster RBAC, the `flux-system` namespace | never owned by any Application |
| 7 | the `argocd-rbac` Kustomization object | it points at `./flux/argocd`, which no commit creates, so it has been `Ready=False` since the conversion landed. Stage 5 removes the declaration but prune is off, so the object itself survives and must go by hand |
| 7 | **the orphaned objects in `bootstrap-flux-system`**, if the environment has any — six Deployments, a `GitRepository`, a `Kustomization` | a second, namespace-scoped Flux that `bootstrap/scripts/bootstrap-flux.sh` installs to deploy the real one and is supposed to tear down. Prod still had it 84 days on, frozen. Declared nowhere in git, so no stage removes it. **Delete the objects, not the namespace: the `Namespace` object is already gone** (force-deleted, orphaning its contents), so `kubectl delete ns` fails and `get ns` wrongly reports nothing to clean. The `Kustomization` carries `prune: false`, so removing it collects nothing. Staging never had this — check rather than assume |

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

`local.controller_ecr_alias` derives from the first controller repo URI in non-prod. **Resolved: for
prod it does not derive at all** — `images.tf` returns the literal `aws-controllers-k8s` whenever
`stage == "prod"`, so it carries no dependency on the non-prod ECR repos that the same file gates
off. Confirmed against prod's own `self-managed-vars`, where `CONTROLLER_ECR_REGISTRY` already reads
`public.ecr.aws/aws-controllers-k8s`. Nothing to check before Stage 3.

The neighbouring value is worth a glance for the same reason: `ecrPublicReaderRoleArn` is built as a
string from `var.publish_account_id` rather than from the `ArtifactReader` resource, so it too
survives that resource being absent in prod.

Prod is a different org and package from staging, so `test_infra_org` / `test_infra_repo` differ and
the fork that the reconcilers read is not the one staging used.
