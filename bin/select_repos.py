#!/usr/bin/env python3

import json
import random
import sys


def print_help():
    print("""
        argv[1] == JSON filename containing list of repo names
        argv[2] == number of entries in JSON filename to select
        argv[3] == %chance (1-100) that each entry will be selected
          
        Writes (to stdout) a JSON array with one dict for each entry.
        This JSON can be used as the source for a Github Action strategy:matrix:include to run a parallel job for each entry.

        Example: Process 1st 3 entries in temp.json and select with 50% chance
          
          $ ./bin/select_repos.py ./docs/temp.json 3 50 | jq .

          [
            {
              "repo_name": "data-adapter",
              "selected": false
            },
            {
              "repo_name": "golden-ledger",
              "selected": true
            },
            {
              "repo_name": "commercial-loan",
              "selected": true
            }
        ]      
    """)


def select_repos():
    json_filename = sys.argv[1]
    n = int(sys.argv[2])
    chance = int(sys.argv[3])

    with open(json_filename) as json_file:
        json_data = json.load(json_file)

    repos = []
    for i in range(0, n):
        selected = random.randint(1, 100) <= chance
        json_data[i]["selected"] = selected
        repos.append(json_data[i])
    return repos


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] in ["-h", "--help"]:
        print_help()
    else:
        print(json.dumps(select_repos(), default=str))
