
The core job in .github/workflows/spreader.yml
makes a copy of the spreader repo into N other repos like this:

```shell
    gh repo create kosli-demo/${REPO_NAME} --public || true
    git clone --mirror https://x-access-token:${GH_TOKEN}@github.com/kosli-demo/spreader.git
    cd spreader.git
    git remote set-url origin https://x-access-token:${GH_TOKEN}@github.com/kosli-demo/${REPO_NAME}.git
    git push --mirror
```

After the `git clone`, there is NO worktree in the `spreader.git` dir.
So you cannot customize it to be specific to `REPO_NAME` before the `git push`.
Each new repo, eg `atomic-ledger` has a full set of JSON for
all repos, and must extract its own JSON from `data/all-repos.json`
