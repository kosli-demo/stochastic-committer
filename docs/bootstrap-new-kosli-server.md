# Bootstrapping ground-state provenance on a new Kosli server

## Summary

When you point the `kosli-demo` demo at a **fresh Kosli server** (a Kosli host
that has never received data for this org, e.g. a newly provisioned
`app.kosli.com`), you must run `stochastic-committer` **once** with:

```
repo_count = 200
repo_chance = 100
```

before letting the normal cronjob take over. This single run establishes
"ground-state" provenance: it gives every one of the 200 environment artifacts
a matching attestation, so the `staging` environment starts compliant instead
of drowning in no-provenance artifacts.

## Why this is necessary

The `stochastic-committer` workflow has two tracks that touch a different set of
repos each run (see `stochastic-committer.yml`):

1. **`simulate-commits-to-selected-repos`** runs the per-repo CI (`main.yml`),
   which is what actually creates the Kosli flow (`kosli create flow`), begins a
   trail, and attests the artifact. This runs **only for the repos selected this
   run** -- the ones that won the `repo_chance`% random draw in
   `bin/select_repos.py`.

2. **`simulate-deployments-from-selected-repos`** reports the running state of
   the environment via `kosli snapshot paths`. This covers **all `repo_count`
   repos every run**, whether or not they were selected for a commit.

Provenance in Kosli is matched by **fingerprint**: an environment artifact is
compliant only if some flow has attested an artifact with the same fingerprint.

On an **established** server this asymmetry is harmless: over many runs the
random draws eventually attest every repo, and the environment converges to
compliant.

On a **fresh** server it is not. The very first cronjob run snapshots all 200
repos into the environment but, with the default `repo_chance=5`, runs CI for
only about 10 of them. The other ~190 appear as artifacts with **no flow and no
provenance**, so the environment is immediately and heavily non-compliant.

Worse, it does not fix itself quickly. At ~5% per run (roughly 10 of 200), it
takes on the order of a hundred 6-hourly runs -- weeks -- for the random draws
to have touched every repo. Until then the environment stays non-compliant.

Setting `repo_chance=100` forces `select_repos.py` to select **all** 200 repos
in a single run, so all 200 get committed, CI-run, and attested in one pass. The
snapshot (which `needs` the commit job, so runs after it) then reports the same
200 fingerprints that were just attested, and the environment starts fully
compliant.

## Procedure

1. **Confirm the target server and secrets.** The `scope` input decides which
   Kosli host is written to:

   | scope     | Kosli host(s)                                              |
   |-----------|------------------------------------------------------------|
   | `staging` | `https://staging.app.kosli.com`                            |
   | `prod`    | `https://app.kosli.com`                                    |
   | `both`    | both of the above                                          |

   The corresponding `KOSLI_API_TOKEN_STAGING` / `KOSLI_API_TOKEN_PROD` secrets
   must be set for the server you are booting.

2. **Dispatch the bootstrap run.** Trigger `stochastic-committer.yml` via
   `workflow_dispatch` with the bootstrap parameters. For example, to boot
   `app.kosli.com`:

   ```
   gh workflow run stochastic-committer.yml \
     --repo kosli-demo/stochastic-committer \
     --ref main \
     --field scope=prod \
     --field repo_count=200 \
     --field repo_chance=100
   ```

   (Use `scope=staging` for `staging.app.kosli.com`, or `scope=both`.)

3. **Wait for the run to finish and check the environment.** After
   `simulate-deployments-from-selected-repos` completes, the `staging`
   environment on the target server should show 200 artifacts, all compliant on
   the `provenance` policy.

4. **Let the normal cronjob resume.** No further action is needed. The scheduled
   `main-cronjob.yml` (every 6 hours, `repo_chance=5`) keeps the demo alive from
   the ground state you just established. Do **not** leave `repo_chance=100`
   as the steady-state cadence -- it commits to all 200 repos every run, which is
   far more churn than the demo needs.

## Notes and caveats

- **This covers the first 200 repos only.** `select_repos.py` takes the first
  `repo_count` entries of `base/data/all-repos.json` (`json_data[:n]`).
  `all-repos.json` currently holds 500 entries; the environment and this
  bootstrap only concern the first 200. If `repo_count` is ever raised, re-run
  the bootstrap with the new count and `repo_chance=100`.

- **GitHub API rate limits.** The `CLONE_PUSH_REPOS` token is shared across all
  legs and carries GitHub's standard **5000-requests-per-hour primary limit**.
  Per-leg REST usage is kept minimal so this limit does not scale with fan-out:
  each `trigger-ci` leg makes a single `gh workflow run` POST (plus a short
  workflow-availability poll only for repos being created this run), and
  `commit-to-repo` clones and pushes over git rather than the REST API. Waiting
  for the dispatched CI to finish is not done per leg: the `await-selected-repos-ci`
  job polls the whole fleet with one batched GraphQL query, which bills against
  GraphQL's separate **5000-points-per-hour** budget (~1 point per poll).

  The rate-limit consideration that remains is GitHub's **secondary** limit on
  bursts of concurrent requests -- hundreds of simultaneous `gh workflow run` POSTs
  can trip it. `max-parallel` (20 in `simulate-commits-to-selected-repos`) caps
  that concurrency.

  `select_repos.py` takes the **first** `repo_count` entries of `all-repos.json`
  (`json_data[:n]`), so you cannot select an arbitrary slice such as repos 51-100;
  lowering `repo_count` only re-processes the front of the list. Slicing the
  bootstrap into ranges would need an `offset`/start argument added to
  `select_repos.py` and threaded through the workflow.

- **Partial failures are tolerated, so re-run to mop up.** The commit matrix
  uses `fail-fast: false` and the snapshot runs under
  `if: always() && needs.select-n-repos.result == 'success'`, so one repo's
  failing CI does not cancel the others or discard the snapshot. Any repo
  whose CI failed will be snapshotted with no provenance and show as
  non-compliant (this is the correct, honest outcome). Simply run the bootstrap
  again to attest the stragglers -- a second `repo_chance=100` pass re-runs CI
  for all 200 and picks up whatever failed the first time.

- **Compliance direction.** A bootstrap that under-attests is safe: missing
  provenance shows as non-compliant, which is acceptable. The one thing to
  verify before declaring the server "booted" is that the environment actually
  reached 200/200 compliant -- never assume it did.
