
# spreader

Stochastically simulate a large Kosli organization, to get:
- a large data set
- a large demo


Each `.github/workflows/main.yml` run makes a simluated push to N other repos.
N is set with the `repo_count` input parameter. 
These repos are clones of the [base](https://github.com/kosli-demo/base) repo.

