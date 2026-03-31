#!/usr/bin/env python3

import json
import subprocess
import sys


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



if __name__ == "__main__":
    n = int(sys.argv[1])
    json_filename = sys.argv[2]

    with open(json_filename) as json_file:
        json_data = json.load(json_file)

    repos = []
    for i in range(0, n):
        repo = json_data[i]
        repo["repo_exists"] = repo_exists(repo["repo_name"])
        repos.append(repo)

    print(json.dumps(repos, default=str))
