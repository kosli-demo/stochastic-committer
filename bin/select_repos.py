#!/usr/bin/env python3

import json
import os
import random
import sys
import urllib.error
import urllib.request


def print_help():
    """Print usage information."""
    print("""
        argv[1] == JSON filename containing list of repo names
        argv[2] == number of entries in JSON filename to select
        argv[3] == %chance (1-100) that each entry will be selected
        argv[4] == GitHub org the repos belong to (e.g. kosli-demo)

        Reads GH_TOKEN from the environment to authenticate GitHub API calls.

        Writes (to stdout) a JSON array with one dict for each entry.
        Each dict has:
          repo_name -- the repo name
          selected  -- true if randomly chosen for a commit this run
          exists    -- true if the repo already exists on GitHub

        This JSON can be used as the source for a Github Action strategy:matrix:include
        to run a parallel job for each entry.

        Example: process 1st 3 entries in temp.json, select with 50% chance

          $ GH_TOKEN=... ./bin/select_repos.py ./docs/temp.json 3 50 kosli-demo | jq .

          [
            {
              "repo_name": "data-adapter",
              "selected": false,
              "exists": true
            },
            {
              "repo_name": "golden-ledger",
              "selected": true,
              "exists": true
            },
            {
              "repo_name": "commercial-loan",
              "selected": true,
              "exists": false
            }
          ]
    """)


def repo_exists(github_org, repo_name):
    """Return True if github_org/repo_name exists on GitHub, False on 404."""
    token = os.environ.get("GH_TOKEN", "")
    url = f"https://api.github.com/repos/{github_org}/{repo_name}"
    req = urllib.request.Request(url)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    try:
        urllib.request.urlopen(req)
        return True
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return False
        raise


def select_repos(github_org):
    """Read repos from argv[1], tag each with selected and exists fields."""
    json_filename = sys.argv[1]
    n = int(sys.argv[2])
    chance = int(sys.argv[3])

    with open(json_filename) as json_file:
        json_data = json.load(json_file)

    repos = []
    for repo in json_data[:n]:
        repo["selected"] = random.randint(1, 100) <= chance
        repo["exists"] = repo_exists(github_org, repo["repo_name"])
        repos.append(repo)
    return repos


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] in ["-h", "--help"]:
        print_help()
    else:
        print(json.dumps(select_repos(sys.argv[4]), default=str))
