
The core job in .github/workflows/main.yml
makes a copy of the spreader repo into N other repos.
Currently N is set to 2 in the line:

```shell
  jq '.[:2]' all-repos.json > "${REPOS_FILENAME}"
```

 The repo copying is done like this:

```shell
    gh repo create kosli-demo/${REPO_NAME} --public || true
    git clone --mirror https://x-access-token:${GH_TOKEN}@github.com/kosli-demo/base.git
    cd base.git
    git remote set-url origin https://x-access-token:${GH_TOKEN}@github.com/kosli-demo/${REPO_NAME}.git
    git push --mirror
```

After the `git clone`, there is NO worktree in the `base.git` dir.
So you cannot customize it to be specific to `REPO_NAME` before the `git push`.
Each new repo, eg `atomic-ledger` has a full set of JSON for
all repos, and must extract its own JSON from `data/all-repos.json`
