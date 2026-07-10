# Plan: fake a K8S environment (`staging-k8s`) via direct snapshot reports

Status: proposal (in progress). Scope: replace the current server-type
`staging` environment with a new K8S-type environment `staging-k8s` in the
`kosli-demo` Org, populated by hand-built snapshot reports (direct API PUT)
rather than a real cluster.

## 1. Why a new environment, not a conversion

A Kosli environment's `type` is fixed at creation. The create endpoint
(`PUT /api/v2/environments/{org}`, schema `CreateEnvironmentPutInput`) requires
`type`; the update endpoint (`PATCH /api/v2/environments/{org}/{env_name}`,
schema `UpdateEnvironmentPatchInput`) exposes only `description`,
`include_scaling`, `included_environments`, and `policies` - there is no `type`
field. So a server-type environment cannot become K8S in place.

The diff logic also refuses to compare across types
(`lib/snapshot_differ.py` raises `EnvDiffTypeError` when two snapshots'
environment types differ), so the boundary must be a clean cut, not a mutation.

Therefore: **archive the current `staging` env and create a new `staging-k8s`
env.** This also matches the forward plan to split the fleet across several
environment types (`staging-k8s`, `staging-ecs`, ...) - each type is its own
environment.

## 2. Naming and the multi-env-type future

- Now: one new environment `staging-k8s` (type `K8S`) holding the whole fleet.
- Later: additional typed environments (`staging-ecs`, `staging-lambda`, ...),
  with the fleet partitioned across them via the per-repo `env` field (section 6).

## 3. Digest source (decided)

A K8S report artifact maps `{ "<image-ref>": "<64-hex sha256>" }`. That 64-hex
value is the fingerprint Kosli matches against the repo's flow.

**Decision: option A - the real image digest, sourced from the repo's Kosli
flow latest-attested artifact.** `GET /api/v2/artifacts/{org}/<repo>-ci` returns
the latest artifact's `fingerprint` (the digest) and `git_commit`.

The governing invariant: **the env fingerprint must equal the fingerprint the
flow attested**, or the artifact has no provenance match and is non-compliant.
So we always take the digest *from the flow* - never from the ghcr.io registry
directly, because a registry digest that the flow never attested would not
match. Making that fingerprint a *real* image digest (not the current fake
`kosli fingerprint source/datetime.txt` value) is the job of the
`secure-docker-build.yml` option-A change tracked in
`secure-docker-build-upstream-sync-report.md` / `-plan.md`.

## 4. Eligibility: a repo can only enter the env after CI under option-A

This is the central sequencing constraint. **A repo is eligible for
`staging-k8s` only once it has run CI under option-A**, i.e. its flow holds a
latest-attested artifact whose fingerprint is the real image digest. Two
consequences we hit:

1. **Existing flows are faked.** Today every flow's latest artifact is the
   `datetime.txt` file hash, not the image digest. We cannot harvest real
   digests from them, and we cannot substitute a ghcr.io registry digest (it
   would not match the flow -> non-compliant, per section 3). **Fix: the existing
   repos must re-run CI under option-A** so their flows re-attest real digests.

2. **New repos have no flow at all.** Bumping `repo_count` (e.g. 200 -> 300)
   introduces repos that may not exist yet, and pushing a repo does not trigger
   CI (base `main.yml` is `workflow_dispatch`/`workflow_call` only). So a
   newly-created-but-unselected repo has no attestation. **Fix: create it and
   run its CI under option-A** before it can be reported.

**Unified rule:** eligibility = "has run CI under option-A". Bootstrap and any
`repo_count` increase both perform the same pre-step - the existing
`create-new-repos` + `trigger-ci` + `await-ci` machinery, but driven over the
**target set** rather than only the stochastically-selected subset. In practice
this is just a high `repo_chance` (100 for bootstrap - section 8), which selects
every target repo and so commits + CIs them all.

## 5. Prerequisites

1. **Option A landed** (`secure-docker-build.yml` attests the real image digest) -
   a hard, up-front dependency for everything below. Attesting the real digest is
   enough for compliance under the current presence-based rego; adopting the
   fuller upstream SLSA controls (`subject_matches_artifact`, SBOM) is a separate
   workstream (`secure-docker-build-upstream-sync-plan.md`) that becomes safe once
   digests are real but is not required here.
2. `staging-k8s` created on both Kosli hosts - **done** (already created on the
   Kosli servers). The demo reports the same env to both.
3. Environment policies on `staging-k8s`: **deferred** - attach after snapshots
   are working (an env with no policies simply reports artifacts without a
   compliance verdict; policies can be added later without changing the reports).

## 6. `all-repos.json` augmentation (done)

Each entry in `kosli-demo/base` `data/all-repos.json` carries an `env`
assignment and a K8S runtime-identity block (applied to all 500 entries by
`bin/add_k8s_identity_to_all_repos.py`, `namespace: beta`):

```json
{
  "repo_name": "golden-ledger",
  "exists": true,
  "has_junit": true,
  "env": "staging-k8s",
  "k8s": {
    "namespace": "beta",
    "podName": "golden-ledger-7d9f8c6b5-x4k2p",
    "owners": [
      { "apiVersion": "apps/v1", "kind": "ReplicaSet", "name": "golden-ledger-7d9f8c6b5",
        "uid": "...", "controller": true, "blockOwnerDeletion": true }
    ]
  }
}
```

- `podName`, `namespace`, `owners[].name/uid` are **stable per repo** (derived
  deterministically from `repo_name`). Keeping them fixed is what makes an
  unchanged repo serialize byte-identically across reports (section 9), so only
  the digest and creationTimestamp move on a redeploy.
- `owners` matches the `K8SOwner` schema (`apiVersion`/`kind`/`name`/`uid`
  required; `controller`/`blockOwnerDeletion` optional).
- Not stored here (dynamic): the image `digest` and `git_commit` (from the
  flow), and the `creationTimestamp` (the repo's commit time, carried with the
  harvested attested record).
- `env` is the hook for the future multi-env-type split; all repos are
  `staging-k8s` for now.

## 7. The two scripts (pure, no network, TDD)

The payload assembly is split from the (network) Kosli fetches so both pieces
stay unit-testable with fixtures (shunit2, black-box). The actual `GET`s live in
the orchestration workflow.

- **`bin/build_fresh_facts.py`** (harvester, pure join, planned): joins the
  `all-repos.json` k8s block with a per-repo *attested* record
  (`{repo_name, fingerprint, git_commit, creation_timestamp}` fetched from the
  flow) into `--fresh` facts. Constructs `image_ref =
  ghcr.io/kosli-demo/<repo>:<git_commit[:7]>`, `digest = fingerprint`.
- **`bin/build_k8s_snapshot.py`** (reconcile, built + tested): reconciles
  `--current` (the latest snapshot, empty on bootstrap) with `--fresh` into the
  K8S report payload. Copies unchanged repos verbatim, replaces changed ones,
  skips exited artifacts (`annotation.now == 0`), and rejects malformed digests.
  Bootstrap is just the empty-`--current` case.

## 8. Bootstrap: one `repo_chance=100` run

Bootstrap needs no special code path - it is the normal steady-state pipeline
run once with `repo_chance=100` against an empty environment. With every repo
selected:
- every repo gets a commit + CI run, so every flow attests a real image digest
  (this is the "force-CI all target repos" of section 4, realized by selection);
- every repo is therefore `--fresh`, harvested from its just-attested flow;
- `--current` is empty (first run: GET `-1` returns 404 -> treated as empty),
  which `build_k8s_snapshot.py` already handles.

So `build_fresh_facts.py` (over all 200 selected flows) -> `build_k8s_snapshot.py`
(empty `--current`) -> PUT to both hosts produces the full first snapshot, using
the exact same scripts as steady state. The committer's snapshot job is rewired
to this K8S path (replacing the server-type `demo-snapshot.yml`), reporting to
`staging-k8s`.

Do NOT let a normal stochastic cron run be the bootstrap - at `repo_chance=5`
the env would start with only ~10 artifacts and fill in over weeks. Bootstrap is
the deliberate `repo_chance=100` run in the migration runbook (section 12).

## 9. Steady state: read back, mutate only the changes, re-report

Each 6-hourly run does NOT rebuild the fleet:

1. `GET /api/v2/snapshots/kosli-demo/staging-k8s/-1` -> current snapshot.
2. For the ~selected repos (committed this run), fetch their flow's new attested
   fingerprint/commit -> `build_fresh_facts.py` -> `--fresh`.
3. `build_k8s_snapshot.py --current latest.json --fresh selected.json`: unchanged
   repos are copied verbatim (byte-identical -> annotated `unchanged`), the
   selected repos are replaced (old digest exits, new digest starts), exited
   artifacts are dropped.
4. PUT to both hosts.

Why it is safe (server change-detection, `model/environment_snapshots.py`):
- New-snapshot creation (`changed_except_kosli_cli`) keys on digest presence,
  compliance, provenance/flows, and (only if `include_scaling`) instance count -
  it ignores timestamps and pod names.
- Per-artifact event annotation (`annotate_common`) does a full-dict comparison
  and would flag an unchanged repo as `changed` if its timestamp/podName/
  namespace/owners drifted. Copying unchanged entries verbatim guarantees they
  are byte-identical, so only the mutated repos produce events.

Only the ~selected repos need a Kosli fetch; the unchanged majority come from
the readback. No per-repo runtime state is persisted between runs.

## 10. `repo_count` changes

- **Raise (N -> M):** the new repos are eligible only after CI under option-A
  (section 4). On the bump, create them and trigger their CI, then include them
  as `--fresh`; the existing N come from readback. They annotate as `started`.
- **Lower (M -> N):** out of scope for now - excess repos would linger rather
  than auto-drop (no `--fleet`/membership input). Handle out-of-band
  (re-bootstrap a fresh env) if it ever comes up.

## 11. Policies and the two hosts

- Environment policies on `staging-k8s` are **deferred** until snapshots are
  working (section 5); attach the same provenance policy `staging` has (plus
  SDLC-CTRL-0004 if/when adopted) at that point, on both hosts. Keep
  `include_scaling` off so a repo's event is driven purely by its digest.
- Reports go to **both** hosts (`app.kosli.com` and `staging.app.kosli.com`),
  matching the existing "report the same env to both" pattern in
  `demo-snapshot.yml`.

## 12. Migration runbook

1. **Turn OFF** the `stochastic-committer.yml` cronjob (stop the `schedule:` in
   `main-cronjob.yml`) so nothing runs mid-migration.
2. **Land option A** in `secure-docker-build.yml` (attest the real image digest).
3. **Rewire** the committer's snapshot job to the K8S path (`build_fresh_facts.py`
   -> `build_k8s_snapshot.py` -> PUT `.../staging-k8s/report/K8S`, both hosts),
   replacing the server-type `demo-snapshot.yml`.
4. **Run once** with `repo_count=200`, `repo_chance=100`: commits + CIs all 200
   (real-digest attestations land first), then the rewired snapshot job harvests
   all 200 flows and PUTs the full bootstrap snapshot to `staging-k8s`
   (empty `--current`).
5. **Verify:** `staging-k8s` shows 200 artifacts; then run a normal
   `repo_chance=5` cycle and confirm only the ~selected repos produce events and
   the rest are `unchanged`.
6. **Turn the cronjob back ON** (schedule -> `stochastic-committer.yml` at the
   usual `repo_chance=5`).
7. **Later, once stable:** attach env-policies to `staging-k8s`, and archive the
   old server `staging` env (`kosli archive environment staging`, per host).

`staging-k8s` already exists on both hosts (section 5), so its creation is not a
runbook step. `repo_chance=100` at `repo_count=200` = 200 commits + 200 CI runs
in one workflow: fine (200 < the 256 matrix limit; `max-parallel: 20`; `await`
waits via batched GraphQL), but a long, Actions-heavy one-off. Bootstrapping at
a `repo_count` whose selected set exceeds 256 would need batching.

## 13. Commands and endpoints (reference)

```
# archive old server env (after cutover, per host)
kosli archive environment staging
# fetch a repo's latest attested digest+commit (read-only)
GET  /api/v2/artifacts/kosli-demo/<repo>-ci
# read latest snapshot (read-only)
GET  /api/v2/snapshots/kosli-demo/staging-k8s/-1
# report a snapshot (WRITE; real token; never sent autonomously)
PUT  /api/v2/environments/kosli-demo/staging-k8s/report/K8S
```

## 14. Open decisions

- [ ] `include_scaling` on `staging-k8s`: keep off (recommended) or model replicas.
- [ ] Exact policy set to attach later (provenance only, or + SDLC-CTRL-0004).
- [ ] `creationTimestamp` source for a fresh fact: the committer's commit time vs
      the flow artifact's commit timestamp (both are the repo's current commit).
- [ ] Cleanup (don't forget): `stochastic-committer2.yml`'s `select-n-repos` job
      still carries a comment claiming the `simulate-deployments-from-selected-repos`
      job "snapshots all N repos, so all N repos must exist before it runs" - stale
      in v2, where that job is a TODO no-op. Fix it when the K8S snapshot replaces
      the no-op (or sooner).

Resolved: new env (not conversion); option A + flow-latest-attested digest
source; `all-repos.json` augmentation done (stored, `namespace: beta`);
eligibility = has-run-CI-under-option-A; bootstrap = one `repo_chance=100` run
with empty `--current`; `staging-k8s` created; policies deferred until snapshots
work.

## 15. Guardrails

Snapshot reports and environment create/archive are **writes** to Kosli. They
require a real write-scoped API token and must only be sent on explicit
instruction - never autonomously. Reads (artifacts, snapshots) are GETs and work
with any token in the demo setup.
