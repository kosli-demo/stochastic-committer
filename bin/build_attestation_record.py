#!/usr/bin/env python3
"""Build attestation records for the fresh-facts builders from flow artifacts.

For each selected repo, picks the latest artifact (max git_commit_info.timestamp)
from that repo's flow-artifacts response and emits
{repo_name, fingerprint, git_commit, creation_timestamp}. creation_timestamp is
the commit time (the base); the snapshot workflow adds a random deploy latency
on top before handing the records to the env's fresh-facts builder.
"""

import argparse
import json
import sys


def latest_artifact(artifacts):
    """Return the artifact with the greatest git_commit_info.timestamp."""
    return max(artifacts, key=lambda a: a["git_commit_info"]["timestamp"])


def attestation_record(repo_name, artifacts):
    """Build one attestation record from a repo's flow artifacts."""
    latest = latest_artifact(artifacts)
    return {
        "repo_name": repo_name,
        "fingerprint": latest["fingerprint"],
        "git_commit": latest["git_commit"],
        "creation_timestamp": latest["git_commit_info"]["timestamp"],
    }


def build_attestation_records(selected, artifacts_by_repo):
    """Build an attestation record for each selected repo.

    Env-agnostic: the caller passes an env-pure selected list, so every entry
    gets a record regardless of its deploy target (k8s or ecs).
    """
    return [
        attestation_record(entry["repo_name"], artifacts_by_repo[entry["repo_name"]])
        for entry in selected
    ]


def _parse_args(argv):
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Pick each selected repo's latest flow artifact into an attestation record.",
        epilog="Example:\n  bin/build_attestation_record.py --selected selected.json --artifacts artifacts.json > attested.json",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--selected",
        metavar="FILE",
        required=True,
        help="selected_repos JSON (list of entries with repo_name)",
    )
    parser.add_argument(
        "--artifacts",
        metavar="FILE",
        required=True,
        help="JSON map repo_name -> that flow's artifacts list",
    )
    return parser.parse_args(argv)


def _load(path):
    """Load and return JSON parsed from the given file path."""
    with open(path) as json_file:
        return json.load(json_file)


def main(argv):
    """Build attestation records and write them to stdout."""
    args = _parse_args(argv)
    selected = _load(args.selected)
    artifacts_by_repo = _load(args.artifacts)
    records = build_attestation_records(selected, artifacts_by_repo)
    json.dump(records, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main(sys.argv[1:])
