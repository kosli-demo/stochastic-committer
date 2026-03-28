
# spreader

Stochastically simulate a large Kosli organization, to get:
- a large data set
- a large demo


Each `.github/workflows/main.yml` run makes a copy of the [base](https://github.com/kosli-demo/base) repo into N other repos. Currently N is set to 2 in the line:
```shell
  jq '.[:2]' all-repos.json > "${REPOS_FILENAME}"
```

