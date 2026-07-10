#!/usr/bin/env python3
"""Build the --fresh facts for build_k8s_snapshot.py.

Joins each attested flow record (a repo's latest flow artifact: repo_name,
fingerprint, git_commit, creation_timestamp) with that repo's k8s identity block
from all-repos.json (namespace, podName, owners) into one fresh fact.
"""

import argparse
import json
import sys

_REGISTRY = "ghcr.io/kosli-demo"


def fresh_fact(attested, k8s):
    """Join one attested flow record with its all-repos.json k8s block."""
    repo_name = attested["repo_name"]
    short_sha = attested["git_commit"][:7]
    return {
        "repo_name": repo_name,
        "image_ref": f"{_REGISTRY}/{repo_name}:{short_sha}",
        "digest": attested["fingerprint"],
        "creation_timestamp": attested["creation_timestamp"],
        "namespace": k8s["namespace"],
        "pod_name": k8s["podName"],
        "owners": k8s["owners"],
    }


def build_fresh_facts(attested_records, k8s_by_repo):
    """Return a fresh fact for each attested record, joined by repo_name.

    Raises ValueError if an attested repo has no k8s block in all-repos.json.
    """
    facts = []
    for attested in attested_records:
        repo_name = attested["repo_name"]
        if repo_name not in k8s_by_repo:
            raise ValueError(f"repo '{repo_name}' has no k8s block in all-repos.json")
        facts.append(fresh_fact(attested, k8s_by_repo[repo_name]))
    return facts


def _parse_args(argv):
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Join flow attestations with all-repos.json k8s blocks into --fresh facts.",
        epilog="Example:\n  bin/build_fresh_facts.py --all-repos all-repos.json --attested attested.json > fresh.json",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--all-repos",
        metavar="FILE",
        required=True,
        help="all-repos.json with per-repo k8s blocks",
    )
    parser.add_argument(
        "--attested",
        metavar="FILE",
        required=True,
        help="JSON list of flow records {repo_name, fingerprint, git_commit, creation_timestamp}",
    )
    return parser.parse_args(argv)


def _load(path):
    """Load and return JSON parsed from the given file path."""
    with open(path) as json_file:
        return json.load(json_file)


def main(argv):
    """Join attested records with all-repos k8s blocks and print fresh facts."""
    args = _parse_args(argv)
    all_repos = _load(args.all_repos)
    k8s_by_repo = {entry["repo_name"]: entry["k8s"] for entry in all_repos if "k8s" in entry}
    attested_records = _load(args.attested)
    try:
        facts = build_fresh_facts(attested_records, k8s_by_repo)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
    json.dump(facts, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main(sys.argv[1:])
