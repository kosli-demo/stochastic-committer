#!/usr/bin/env python3

import json
import random
import subprocess
import sys


def print_help():
    print("""
        argv[1] == JSON filename containing list of repo names
        argv[2] == number of entries in JSON filename to process
        argv[3] == chance (1-100) that each entry will be selected
          
        Entries that are selected will have an additional field boolean "repo_exists" key.
        Writes (to stdout) a JSON array with one dict for each entry.
        This JSON can be used as the source for a Github Action strategy:matrix:include to run a parallel job for each entry.

        Example:
          $ ./bin/add-repo-exists.py ./docs/temp.json 5 100 | jq .
          [
            {
              "repo_name": "golden-ledger",
              "repo_exists": true
            },
            {
              "repo_name": "atomic-ledger",
              "repo_exists": true
            },
            {
              "repo_name": "distributed-ledger",
              "repo_exists": false
            },
            {
              "repo_name": "immutable-ledger",
              "repo_exists": false
            },
            {
              "repo_name": "canonical-ledger",
              "repo_exists": false
            }
        ]          
    """)


def repo_exists(repo_name):
    # HTTP_CODE="$(curl -s -o /dev/null -I -w "%{http_code}" https://github.com/kosli-demo/${REPO_NAME})"
    command = [
        'curl', '-s', '-o', '/dev/null', '-I', '-w', '%{http_code}',
        f"https://github.com/kosli-demo/{repo_name}"
    ]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode == 0:
        http_code = result.stdout
        return http_code.startswith('200')
    else:
        print(result.stderr)
        sys.exit(result.returncode)


def add_repo_exists():
    json_filename = sys.argv[1]
    n = int(sys.argv[2])
    chance = int(sys.argv[3])

    with open(json_filename) as json_file:
        json_data = json.load(json_file)

    repos = []
    for i in range(0, n):
        r = random.randint(1, 100)
        if r < chance:
            repo = json_data[i]
            repo["repo_exists"] = repo_exists(repo["repo_name"])
            repos.append(repo)
    return repos


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] in ["-h", "--help"]:
        print_help()
    else:
        print(json.dumps(add_repo_exists(), default=str))
