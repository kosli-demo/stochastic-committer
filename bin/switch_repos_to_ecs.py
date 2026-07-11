#!/usr/bin/env python3
"""Switch named repos in all-repos.json from their k8s block to an ecs block.

For each named repo it:
  - drops the k8s identity block
  - adds an ecs identity block {taskArn, cluster_name, service_name}
  - sets env to the ecs environment

All generated values are derived deterministically from repo_name, so the output
is reproducible and re-running the script is a no-op (idempotent). Repos not named
on the command line are left exactly as they are.
"""

import argparse
import hashlib
import json
import sys

_REGION = "eu-central-1"
_ACCOUNT = "111122223333"


def _task_arn(repo_name, cluster):
    """Build the deterministic ECS task ARN for one repo (32-hex task id)."""
    task_id = hashlib.sha256(repo_name.encode("utf-8")).hexdigest()[:32]
    return f"arn:aws:ecs:{_REGION}:{_ACCOUNT}:task/{cluster}/{task_id}"


def _ecs_identity(repo_name, cluster):
    """Build the deterministic ecs identity block for one repo."""
    return {
        "taskArn": _task_arn(repo_name, cluster),
        "cluster_name": cluster,
        "service_name": repo_name,
    }


def switch(entries, repo_names, env, cluster):
    """Return entries with each named repo switched from a k8s to an ecs block.

    Order is preserved and repos not named are returned unchanged. Deterministic,
    so re-running on an already-switched repo reproduces the same ecs block.

    Raises ValueError if a named repo is not in the fleet, so a typo fails loudly
    (before anything is written) rather than silently switching nothing.
    """
    known = {entry["repo_name"] for entry in entries}
    for name in repo_names:
        if name not in known:
            raise ValueError(f"repo '{name}' not found in all-repos.json")
    switch_set = set(repo_names)
    result = []
    for entry in entries:
        if entry["repo_name"] in switch_set:
            switched = {key: value for key, value in entry.items() if key != "k8s"}
            switched["env"] = env
            switched["ecs"] = _ecs_identity(entry["repo_name"], cluster)
            result.append(switched)
        else:
            result.append(entry)
    return result


def _parse_args(argv):
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Switch named repos in all-repos.json from a k8s block to an ecs block.",
        epilog="Example:\n  bin/switch_repos_to_ecs.py ../base/data/all-repos.json risk-service market-feed",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("all_repos_json", help="Path to the all-repos.json file")
    parser.add_argument("repo_names", nargs="+", help="Repo names to switch from k8s to ecs")
    parser.add_argument("--env", default="staging-ecs", help="Environment name (default: staging-ecs)")
    parser.add_argument("--cluster", default="beta", help="ECS cluster name (default: beta)")
    parser.add_argument(
        "--output",
        default=None,
        help="Write result here (default: overwrite the input in place)",
    )
    return parser.parse_args(argv)


def main(argv):
    """Read the input file, switch the named repos, and write the result."""
    args = _parse_args(argv)
    with open(args.all_repos_json) as json_file:
        entries = json.load(json_file)

    try:
        switched = switch(entries, args.repo_names, args.env, args.cluster)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)

    output_path = args.output or args.all_repos_json
    with open(output_path, "w") as json_file:
        json.dump(switched, json_file, indent=2)
        json_file.write("\n")

    print(f"Switched {len(args.repo_names)} repo(s) to ecs -> {output_path}", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[1:])
