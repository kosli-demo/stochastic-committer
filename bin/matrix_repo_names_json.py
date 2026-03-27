#!/usr/bin/env python3

import json
import sys

def print_help():
    print("""
        Reads (from stdin) a JSON data source, eg data/repo_names.json
        Writes (to stdout) a JSON array with one dict for each repo-name.          
        This JSON is intended as the source for a Github Action strategy:matrix:include
        Example:
          $ ./bin/repo_names_json.py
          [
            {
              "repo_name": "golden-ledger"
            },          
            {
              "repo_name": "atomic-ledger"
            },          
            ...
          ]
    """)


def repo_names():
    repos = json.loads(sys.stdin.read())
    result = []
    for repo in repos:
        result.append({
            "repo_name": repo
        })
    return result



if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] in ["-h", "--help"]:
        print_help()
    else:
        # Note: This is expecting input on stdin
        print(json.dumps(repo_names(), indent=2))
