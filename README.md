# stochastic-committer

Stochastically simulate commits to a large number of repos attesting to a Kosli organization.
Aim is to provide:
- a large data set (eg for stress test data)
- a large demo

## How it works

Each `.github/workflows/main-cronjob.yml` run (scheduled every 6 hours) calls
`.github/workflows/stochastic-committer.yml`, which:

1. Selects the first `repo_count` repos from
   [kosli-demo/base](https://github.com/kosli-demo/base)'s `data/all-repos.json`.
2. For each selected repo, independently rolls a random number (1-100). If it
   falls within `repo_chance`, that repo is chosen for a simulated commit+push.
3. Creates any repos that do not yet exist on GitHub.
4. Fans out in parallel, making a simulated commit to each chosen repo and
   running its CI pipeline.
5. Snapshots all `repo_count` repos to Kosli (staging and/or prod).

## Inputs

| Input | Description | workflow_call default | workflow_dispatch default |
|---|---|---|---|
| `scope` | Where to attest: `staging`, `prod`, or `both` | `both` | (required choice) |
| `repo_count` | How many repos to draw from the pool | `100` | `30` |
| `repo_chance` | Percentage chance (1-100) that each repo receives a commit this run | `5` | `10` |

### repo_chance in detail

`repo_chance` controls the density of simulated activity. Each of the
`repo_count` repos is independently given a `repo_chance`% probability of
being committed to on any given run. At the defaults (`repo_count=100`,
`repo_chance=5`) you expect roughly 5 repos to receive commits per run, though
the actual number varies randomly each time.

Raising `repo_chance` toward 100 makes nearly every repo active on every run.
Lowering it toward 0 makes runs sparse, with many repos sitting quiet.

## Repos

The demo repos are clones of [kosli-demo/base](https://github.com/kosli-demo/base).
The full pool of available repos and their existence status is tracked in
`data/all-repos.json` inside that repo.
