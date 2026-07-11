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
   introduces repos that may not exist yet. Creating a repo does NOT attest it:
   `create-new-repo.yml` creates + commits content but does not trigger CI (base
   `main.yml` is `workflow_dispatch`/`workflow_call` only); only the
   `commit-to-repo-and-trigger-ci.yml` path (run for *selected* repos) attests.
   So a created-but-unselected repo has no attestation and cannot be a compliant
   env artifact. **Fix: `select_repos.py` force-selects `exists == false` repos**
   (`selected = (not exists) or (rand <= chance)`), so a new repo is always
   committed + CI'd (real-digest attested) the run it is added, regardless of
   `repo_chance`.

**Unified rule:** eligibility = "has run CI under option-A". How the target set
is driven through commit + CI differs by case:

- **Bootstrap** re-attests the *existing* fleet with real digests, so it uses
  `repo_chance=100` to select (and re-CI) every repo once (section 8).
- **A `repo_count` increase** does NOT need a high `repo_chance`: the new repos
  have `exists == false` and are force-selected by `select_repos.py`, so they are
  committed + CI'd (attested) and enter the env the same run, at the normal
  `repo_chance` (section 10). The already-present repos come from the readback.

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
`bin/k8s_add_identity_to_all_repos.py`, `namespace: beta`):

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

- **`bin/k8s_build_fresh_facts.py`** (harvester, pure join, planned): joins the
  `all-repos.json` k8s block with a per-repo *attested* record
  (`{repo_name, fingerprint, git_commit, creation_timestamp}` fetched from the
  flow) into `--fresh` facts. Constructs `image_ref =
  ghcr.io/kosli-demo/<repo>:<git_commit[:7]>`, `digest = fingerprint`.
- **`bin/k8s_build_snapshot.py`** (reconcile, built + tested): reconciles
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
- `--current` is empty (first run: GET `-1` returns 400 -- the -1 index cannot
  resolve against 0 snapshots -- treated as empty),
  which `k8s_build_snapshot.py` already handles.

So `k8s_build_fresh_facts.py` (over all 200 selected flows) -> `k8s_build_snapshot.py`
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
   fingerprint/commit -> `k8s_build_fresh_facts.py` -> `--fresh`.
3. `k8s_build_snapshot.py --current latest.json --fresh selected.json`: unchanged
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

- **Raise (N -> M):** just bump `repo_count` and run at the normal `repo_chance`.
  The new repos (`exists == false`) are force-selected by `select_repos.py`, so
  they are created, committed, CI'd (real-digest attested) and included as
  `--fresh` that run - appearing compliant, annotated `started`; the existing N
  come from readback. No `repo_chance=100` needed. Caveat: a *large* increase
  whose forced-new count (plus stochastic picks) exceeds GitHub's 256-job matrix
  limit needs batching; small bumps are fine.
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
3. **Rewire** the committer's snapshot job to the K8S path (`k8s_build_fresh_facts.py`
   -> `k8s_build_snapshot.py` -> PUT `.../staging-k8s/report/K8S`, both hosts),
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
- [x] `creationTimestamp` = flow base time (`created_at`/`git_commit_info`) + a
      random 60-180s deploy latency, applied in `snapshot-k8s.yml` for fresh repos
      only (unchanged repos keep their stored value via readback, so no drift).
- [ ] Cleanup (don't forget): `stochastic-committer2.yml`'s `select-n-repos` job
      still carries a comment claiming the `simulate-k8s-deployments-from-selected-repos`
      job "snapshots all N repos, so all N repos must exist before it runs". Stale:
      the K8S snapshot reconciles readback + fresh (it never harvests all N), and
      with force-selection only the selected/new repos are created + committed.
      Deliberately left as-is for now; fix when convenient.
- [x] `snapshot-k8s.yml`: a *selected* repo whose CI failed (no new attestation;
      `simulate-deployments` runs under `always()`) is skipped - let the readback
      carry it, never fabricate a change. Decided.
- [ ] `snapshot-k8s.yml`: fetch the flow attestation once (the digest is
      host-independent) or per host? GET `-1` and PUT are per host regardless.
- [ ] A K8S equivalent of the rogue-deploy / reset-to-green demo (deferred; no
      `rogue_artifact` input on `snapshot-k8s.yml`).

Resolved: new env (not conversion); option A + flow-latest-attested digest
source; `all-repos.json` augmentation done (stored, `namespace: beta`);
eligibility = has-run-CI-under-option-A; bootstrap = one `repo_chance=100` run
with empty `--current`; `staging-k8s` created; policies deferred until snapshots
work; new repos force-selected in `select_repos.py` so a `repo_count` bump works
at the normal `repo_chance` (no `repo_chance=100` needed for bumps).

## 15. snapshot-k8s.yml (reusable snapshot workflow)

The reusable workflow the committer calls to build and PUT the K8S snapshot,
wiring the two pure scripts (section 7) to the Kosli GET/PUT calls. Both
bootstrap (section 8) and steady state (section 9) use it unchanged.

Inputs (and how they differ from `demo-snapshot.yml`):
- `selected_repos` (required) - the JSON from
  `select-n-repos.outputs.selected_repos`; each entry carries `repo_name`, its
  `k8s` block, and `env`. Replaces `repo_count`.
- `scope` (required) - `staging` | `prod` | `both`; which host(s) to GET/PUT.
- secrets `KOSLI_API_TOKEN_STAGING`, `KOSLI_API_TOKEN_PROD`; `KOSLI_ORG` via `vars`.
- NOT inputs: `repo_count` (never harvests all N - readback covers the rest),
  `rogue_artifact` (no rogue concept yet), `env_name` (read from the data).

The env comes from the data, not a parameter. Every entry has `env` (all
`staging-k8s` today). The workflow groups its entries by `.env` and does one
reconcile+PUT per distinct env - a single group now. This is how the multi-env
split works with no `env_name` input.

One workflow per env *type* (self-filtering). The report body differs by type,
so there is one workflow per type: `snapshot-k8s.yml` reads each entry's `k8s`
block and builds a K8S report; a future `snapshot-ecs.yml` reads an `ecs` block.
Upstream jobs (`select-n-repos`, `simulate-commits`, `await-ci`) are env-agnostic
and shared; only `simulate-deployments` fans out into one job per type. Each type
workflow **self-filters** the full `selected_repos` to the entries it owns
(`snapshot-k8s` keeps entries with a `k8s` block) and ignores the rest, so the
committer hands the full `selected_repos` to every type workflow. Today every
entry is K8S, so the filter is a no-op.

Steps (per host in `scope`, per env group):
1. For each selected repo: `GET /api/v2/artifacts/{org}/<repo>-ci` -> latest
   `fingerprint` + `git_commit` + base time (`created_at`/`git_commit_info`). Set
   the attested record's `creation_timestamp` = base + a random 60-180s deploy
   latency (pod "started" a realistic 1-3 min after the build). Done here, not in
   `k8s_build_fresh_facts.py` (which stays pure), and only for fresh repos - unchanged
   repos keep their stored timestamp via readback, so no drift.
2. `k8s_build_fresh_facts.py` join with the `k8s` blocks -> fresh facts.
3. `GET /api/v2/snapshots/{org}/<env>/-1` -> current (400/404 -> empty; a fresh
   env with no snapshots returns 400).
4. `k8s_build_snapshot.py --current current --fresh fresh` -> report.
5. `PUT /api/v2/environments/{org}/<env>/report/K8S`.

Open questions for this workflow are tracked in section 14 (creationTimestamp
source, failed-CI selected repo, per-host readback, K8S rogue path).

## 16. Guardrails

Snapshot reports and environment create/archive are **writes** to Kosli. They
require a real write-scoped API token and must only be sent on explicit
instruction - never autonomously. Reads (artifacts, snapshots) are GETs and work
with any token in the demo setup.
