#!/usr/bin/env python3
"""Build the next fake K8S environment snapshot report for Kosli.

Reconciles the current snapshot with this run's fresh facts (new or changed
repos) into the report payload for
  PUT /api/v2/environments/{org}/{env}/report/K8S

With no --current snapshot this is the bootstrap case: every fresh fact is
introduced as a running artifact. Repos in --current that are not in --fresh are
copied verbatim, so unchanged repos never need re-harvesting and do not churn.
"""

import argparse
import json
import re
import sys


_DIGEST_RE = re.compile(r"^[a-f0-9]{64}$")


def repo_name_from_image_ref(image_ref):
    """Extract the repo name from an image ref, e.g. ghcr.io/kosli-demo/x:tag -> x."""
    last_segment = image_ref.rsplit("/", 1)[-1]
    return last_segment.split("@", 1)[0].split(":", 1)[0]


def _validate_digest(digest, image_ref):
    """Raise ValueError unless digest is a bare 64-hex sha256 (no sha256: prefix)."""
    if not isinstance(digest, str) or not _DIGEST_RE.match(digest):
        raise ValueError(
            f"digest for '{image_ref}' must be 64 lowercase hex chars "
            f"(no 'sha256:' prefix), got '{digest}'"
        )


def artifact_entry(fact):
    """Build one K8SArtifact wire entry from a facts dict."""
    _validate_digest(fact["digest"], fact["image_ref"])
    return {
        "podName": fact["pod_name"],
        "namespace": fact["namespace"],
        "digests": {fact["image_ref"]: fact["digest"]},
        "creationTimestamp": fact["creation_timestamp"],
        "owners": fact["owners"],
    }


def build_report(facts):
    """Assemble the K8S report payload from an iterable of facts dicts."""
    return {"type": "K8S", "artifacts": [artifact_entry(fact) for fact in facts]}


def facts_from_snapshot(snapshot):
    """Reconstruct facts from a GET-snapshot response, one per running pod.

    Skips artifacts with annotation.now == 0 (exited / not running) -- the same
    inclusion test the server's own snapshot diff uses -- so re-reporting never
    resurrects an artifact that has exited.
    """
    facts = []
    for artifact in snapshot["artifacts"]:
        if artifact.get("annotation", {}).get("now", 0) == 0:
            continue
        image_ref = artifact["name"]
        digest = artifact["fingerprint"]
        repo_name = repo_name_from_image_ref(image_ref)
        for pod_name, pod in artifact["pods"].items():
            facts.append(
                {
                    "repo_name": repo_name,
                    "image_ref": image_ref,
                    "digest": digest,
                    "creation_timestamp": pod["creationTimestamp"],
                    "namespace": pod["namespace"],
                    "pod_name": pod_name,
                    "owners": pod["owners"],
                }
            )
    return facts


def reconcile(current_facts, fresh_facts):
    """Merge fresh facts over current facts, keyed by repo_name (fresh wins)."""
    by_repo = {}
    for fact in current_facts:
        by_repo[fact["repo_name"]] = fact
    for fact in fresh_facts:
        by_repo[fact["repo_name"]] = fact
    return list(by_repo.values())


def _parse_args(argv):
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Reconcile the current K8S snapshot with fresh facts into the next report payload.",
        epilog="Example:\n  bin/build_k8s_snapshot.py --current latest.json --fresh fresh-facts.json > report.json",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--current",
        metavar="FILE",
        default=None,
        help="Current snapshot JSON (GET .../snapshots/{org}/{env}/-1); omit for bootstrap",
    )
    parser.add_argument(
        "--fresh",
        metavar="FILE",
        default=None,
        help="JSON list of full facts for repos new or changed this run",
    )
    parser.add_argument(
        "--drop",
        metavar="REPO_NAME",
        action="append",
        default=[],
        help="repo_name to remove from the output (repeatable); e.g. rogue-trader",
    )
    return parser.parse_args(argv)


def _load(path):
    """Load and return JSON parsed from the given file path."""
    with open(path) as json_file:
        return json.load(json_file)


def main(argv):
    """Reconcile --current and --fresh into the report and write it to stdout."""
    args = _parse_args(argv)
    current_facts = facts_from_snapshot(_load(args.current)) if args.current else []
    fresh_facts = _load(args.fresh) if args.fresh else []
    facts = reconcile(current_facts, fresh_facts)
    if args.drop:
        dropped = set(args.drop)
        facts = [fact for fact in facts if fact["repo_name"] not in dropped]
    try:
        report = build_report(facts)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
    json.dump(report, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main(sys.argv[1:])
