# ADR 001 - Avoiding Large GitHub Actions matrix and API rate limits

## Status

Accepted

## Context

This system fans out work across a large number of demo repos by using GitHub
Actions `strategy:matrix` jobs. GitHub enforces a hard limit of **256 jobs per
matrix**. With `repo_count` currently defaulting to 100 and designed to grow,
the matrix strategy must be applied selectively.

Two separate matrix jobs exist in `main.yml`:

- `create-new-repos` -- creates repos that do not yet exist
- `simulate-commits-to-selected-repos` -- makes a simulated commit to each
  chosen repo and triggers its CI pipeline

A third job, `simulate-deployments-from-selected-repos`, must also process all
`repo_count` repos but deliberately does **not** use a matrix (see below).

In addition to the 256-job matrix limit, the GitHub REST API enforces secondary
rate limits on write operations. Bulk repo creation (e.g. when `repo_count` is
raised significantly) triggers these limits if requests are issued in full
parallel.

A historical performance problem also existed: `select_repos.py` originally
checked each repo's existence via the GitHub REST API on every run. At
`repo_count=100` this meant ~100 sequential HTTPS calls, adding roughly 100
seconds to every run and approaching REST API rate limits.

## Decision

### 1. Matrix over selected repos only, not all repos

`simulate-commits-to-selected-repos` fans out only over repos where
`selected == true` in the `select_repos.py` output -- that is, repos that won
the `repo_chance`% random draw this run. With the defaults (`repo_count=100`,
`repo_chance=5`) the expected matrix size is approximately 5 jobs, well under
the 256-job limit. Even at `repo_count=256` with `repo_chance=100` the limit
is exactly met, so scaling further requires keeping `repo_chance` proportionally
low or accepting that not all repos will be committed to in a single run.

Fanning out over all `repo_count` repos regardless of selection would waste
runner-minutes on repos with nothing to do and, with a large enough `repo_count`,
would hit the 256-job ceiling and cause the workflow to fail.

### 2. Matrix over non-existent repos only, not all repos

`create-new-repos` fans out only over repos where `exists == false`. On the
vast majority of runs all repos already exist, so the matrix is empty and the
job is skipped entirely via its `if` condition:

```yaml
if: ${{ needs.select-n-repos.outputs.non_existent_repos != '[]' }}
```

This avoids running the job -- and consuming the matrix budget -- when there is
nothing to create.

### 3. Cap parallel repo creation at 5

When `repo_count` is raised significantly, many repos may need to be created in
a single run. `create-new-repos` sets `max-parallel: 5` to avoid triggering
GitHub's secondary API rate limits, which apply to write operations issued in
rapid parallel.

### 4. Deployments/snapshots use a single job with a shell loop, not a matrix

`simulate-deployments-from-selected-repos` must process all `repo_count` repos
(not just the selected subset) because the Kosli snapshot covers the state of
every repo, whether or not it received a commit this run.

A matrix over all `repo_count` repos would:
- spin up one runner per repo just to fetch a single small file, wasting resources
- hit the 256-job limit once `repo_count` exceeds 256

Instead, the job runs on a single runner and fetches each repo's
`source/datetime.txt` in a shell `while` loop via `raw.githubusercontent.com`.
That endpoint is a CDN serving static files with no per-token rate limits, so
sequential fetches at any repo count are not a concern. All repos are then
snapshotted in one `kosli snapshot paths --paths-file` call.

### 5. Cache repo existence in all-repos.json

`select_repos.py` no longer queries the GitHub API to check whether each repo
exists. Instead, an `exists` boolean field is maintained in
`data/all-repos.json` inside the `kosli-demo/base` repo. After a
`create-new-repos` run, the `mark-new-repos-as-existing` job flips `exists` to
`true` for each newly created repo and pushes the update back to `base`.

This eliminates the ~100-second sequential API-check overhead on every run and
removes the rate-limit risk that came with it.

## Consequences

- `repo_count` can scale beyond 256 as long as `repo_chance` is kept low enough
  that the expected number of selected repos stays under 256 per run.
- A large one-time jump in `repo_count` (causing many new repos to be created)
  is safe but slow due to the `max-parallel: 5` cap on creation.
- The deployment snapshot always covers all `repo_count` repos, so it grows
  linearly in time with `repo_count`. At very high counts the shell loop in
  `simulate-deployments-from-selected-repos` may become a bottleneck.
