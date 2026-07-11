# Plan: fake artifact promotion from `staging-k8s` to `prod-k8s`

Status: proposal (in progress). Scope: fake "deployments" (promotions) of
artifacts from the `staging-k8s` environment to a new `prod-k8s` environment in
the `kosli-demo` Org, by hand-built snapshot reports (direct API PUT) rather
than a real cluster - the same approach as `staging-k8s` itself
(see `staging-k8s-fake-snapshot-plan.md`).

## 1. Goal and the key idea

Promotion is modelled as a blue-green deploy on `prod-k8s` where the incoming
("green") artifacts come from `staging-k8s`'s current snapshot instead of from a
fresh CI attestation. So promotion reuses the blue-green machinery already built
(`--blue-green` overlap reconcile + the double-PUT in the snapshot workflow):

1. Read both readbacks: `staging-k8s` (source) and `prod-k8s` (target).
2. Diff them by repo: a repo whose staging digest differs from its prod digest
   (or that prod lacks entirely) is the one to promote.
3. PUT the overlap snapshot to `prod-k8s` (old prod = blue, promoted = green).
4. PUT the cutover snapshot to `prod-k8s` (promoted only; old drained).

The only genuinely new logic is step 2 (derive the `--fresh` facts for prod from
staging's readback, filtered against prod's). Steps 3-4 are the existing overlap
reconcile, double-PUT, and self-heal, unchanged.

## 2. What gets promoted (the diff)

For each repo present in `staging-k8s`:
- if `prod-k8s` has no artifact for that repo, or its digest differs from
  staging's, promote staging's digest;
- otherwise (same digest) there is nothing to promote for that repo.

The digest (fingerprint) is what moves - it is env-independent (the same image
runs in both envs). Keyed by repo name (section 3).

## 3. Identity

### 3.1 Matching key: repo name (resolved)

Because we do not simulate a monorepo, one repo == one service == one artifact.
So `repo_name` unambiguously matches a staging artifact to the prod artifact it
supersedes. This is the same key `reconcile` already uses.

### 3.2 Target-env identity of the promoted artifact (OPEN)

This is the main unresolved question. Staging's snapshot carries *staging*
PodData (staging namespace, staging pod names, staging owners). Reporting those
verbatim to `prod-k8s` would stamp staging identity into prod - functionally the
snapshot still shows the promoted artifact (Kosli groups by fingerprint), but the
pod/namespace metadata would read as staging, which is unrealistic if a viewer
inspects it.

The promoted *digest* is correct and env-independent; the *identity* is
env-specific. Options, to decide:
- synthesize a deterministic `prod-k8s` identity per repo (like
  `k8s_add_identity_to_all_repos.py` does, but for a prod namespace);
- carry a second, prod identity block per repo in `all-repos.json`;
- accept staging identity in prod for the demo (simplest, least realistic).

## 4. Provenance / compliance

The promoted digest was already attested to the repo's flow at build time, and
Kosli matches provenance by fingerprint, so a promoted artifact is compliant in
`prod-k8s` with no re-attestation. Confirm `prod-k8s`'s policy is not stricter
(e.g. it must not additionally require a "deployed to staging" attestation unless
we intend to add one). Follows the asymmetry rule: never report compliant when
non-compliant; when in doubt, fail toward non-compliant.

## 5. Demotion (repos in prod but not in staging)

Default: leave them. Promotion only adds/updates - a repo absent from staging is
carried forward verbatim from the prod readback (it is not in the "green" set, so
the overlap/cutover never touches it). Reconsider only if we later want prod to
mirror staging exactly.

## 6. Scheduling

Promotion must never read `staging-k8s` while the committer is mid-write to it -
especially during the transient blue-green windows where a repo briefly shows two
artifacts between the overlap PUT and the cutover PUT. A promotion reading then
could promote a stale/blue digest or a half-updated staging.

Decision: **chain** promotion after the committer's staging snapshot, and also
keep it manually dispatchable.

- `promote-k8s.yml` is a reusable workflow with **both** `workflow_call` (chained)
  and `workflow_dispatch` (manual) triggers - the same dual-trigger pattern
  `stochastic-committer.yml` already uses.
- The committer cron runs promotion as a downstream job:
  `uses: ./.github/workflows/promote-k8s.yml` with
  `needs: [simulate-k8s-deployments-from-selected-repos]`. It therefore reads a
  *settled* staging (post-cutover, one digest per repo), serial by construction -
  no race, no time-of-check/time-of-use gap.
- A separate, independent promotion cron is rejected: two independent schedules
  will eventually overlap the committer.

Residual race: a *manual* dispatch fired while the committer cron is mid-run
(the chained path cannot race itself). Handling:
- default: rely on the cron-pause switch - manual promotions happen during demos,
  when the cron is paused anyway;
- optional hardening: a shared `concurrency: { group: kosli-k8s-writes,
  cancel-in-progress: false }` so a manual promotion queues behind a running
  committer. Caveat: `concurrency` on a workflow that is both called and
  dispatched has fiddly GitHub Actions semantics - verify the exact behavior, or
  put the group on a thin `workflow_dispatch`-only wrapper that `uses:` the
  reusable file, keeping `concurrency` off the reusable workflow.

## 7. Reused machinery (already built and tested)

- `--blue-green` overlap reconcile (keep the single newest superseded fact as
  blue) in `k8s_build_snapshot.py`.
- The double-PUT (overlap then cutover, only when they differ) in
  `snapshot-k8s.yml`.
- The self-heal (collapse a repo's multiple current artifacts to the newest by
  `creationTimestamp`) that makes a failed cutover PUT converge rather than pile
  up - directly relevant, since promotion adds a second env whose PUTs can also
  fail without transaction semantics.

## 8. Open questions / next steps

- [ ] Resolve target-env identity (section 3.2).
- [ ] Create the `prod-k8s` environment (type `K8S`) via the
      `create_environments` workflow, alongside `staging-k8s` / `staging-ecs`.
- [ ] Write the staging-vs-prod diff step that emits prod `--fresh` facts
      (TDD, a pure `bin/` script).
- [ ] Add `promote-k8s.yml` (reusable + dispatch) and the chained job in the
      committer.
- [ ] ECS generalizes identically (`prod-ecs`), once k8s promotion is proven.
