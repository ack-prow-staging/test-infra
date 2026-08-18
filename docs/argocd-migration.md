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
| Argo CD Applications | 12, all Synced/Healthy |
| Cut over | **10** — every ACK path, Argo CD-reconciled (`automated`, prune off) |
| ACK CRs | 63, all Argo CD-tracked, 0 deleting |
| Still on Flux | `prow-build-cluster-connection`, `prow-mirror` |

`Synced` is not progress. An Application whose objects are all Helm hooks has nothing to
compare and is permanently Synced while Flux does the work. The real signal is
`suspend: true` on the path's HelmRelease.

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
2. Set `suspend: true` on the path's **HelmRelease, in git**.
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

**Ignore rendered-vs-live spec diffs.** ACK late-initialises fields the charts never set
(`addonVersion`, `registryID`, `maxSessionDuration`, `disableSessionTags`, …). `ack-prow`
shows 32 such diffs and none is drift: under `ServerSideApply` Argo CD compares only fields
it manages. Do not add `ignoreDifferences` for them — exceptions were tried and removed.
Serialized-JSON fields (`inlinePolicies`, policy documents) cannot be compared as strings at
all; parse them. They also rewrite `generation` harmlessly on sync.

## What is left

| item | blocker |
|---|---|
| `prow-build-cluster-connection`, `prow-mirror` | Argo CD runs hooks only during a sync, and syncs only on drift. A hook Job is excluded from the comparison, so nothing ever triggers it — `automated` included. Both need the Job moved out of the sync path onto a schedule Prow owns (D3). Then the former keeps its 7 RBAC objects and loses the Job; the latter disappears |
| `prow-jobs`, `prow-plugins`, `prow-agent-workflows` | still `${TOKEN}`-bearing, so they block Flux removal. Generated by `prow/jobs/generator.go`; the fix belongs in the `.tpl` files and generator, which must emit Helm placeholders rather than baked values so config stays per-environment. Small: 2–3 tokens each, plus 9 in one Job's env for `prow-jobs` |
| `prow-build-cluster-resources` | one token, but its `configMapGenerator` reads `prow/jobs/test_config.yaml` from outside its path, needing `LoadRestrictionsNone` — a repo-server setting the capability does not expose. Needs the shared file relocated, and the build cluster registered as a spoke |

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
- A sync requested with `syncStrategy.apply` skips hooks, and it is the default when patching
  `operation`. It cannot be cleared that way.
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
- **D14** — CRD write needs `AmazonEKSKROPolicy`. Its claim that in-cluster RBAC is
  impossible was **wrong**: a group can be added to the access entry and is bindable.
- **D16** — registering the cluster by ARN replaces Flux's own kubeconfig but not Prow's, so
  `prow-build-cluster-connection` survives the migration while
  `prow-build-cluster-kubeconfig` does not.
- **D19-P1** — `prune: false` must be live *before* any content change.
