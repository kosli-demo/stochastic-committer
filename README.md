
# stochastic-committer

Stochastically simulate commits to a large number of repos attesting to a Kosli organization.
Aim is to provide:
- a large data set (eg for stress test data)
- a large demo


Each `.github/workflows/main.yml` run makes a simluated commit+push to N other repos.
N is set with the `repo_count` input parameter. 
These repos are clones of the [base](https://github.com/kosli-demo/base) repo.

