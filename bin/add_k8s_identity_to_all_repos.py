#!/usr/bin/env python3
"""Augment all-repos.json with staging-k8s env assignment and k8s identity.

For every entry it adds:
  - env : the Kosli environment the artifact is assigned to
  - k8s : {namespace, podName, owners} runtime-identity used to build fake
          K8S snapshot reports

All generated values are derived deterministically from repo_name, so the
output is reproducible and re-running the script is a no-op (idempotent).
"""

import argparse
import hashlib
import json
import sys
import uuid

# K8S names use a vowel-free lower-case alphanumeric set so generated hashes
# never spell accidental words, matching real pod-template-hash / pod suffixes.
_K8S_ALPHABET = "bcdfghjklmnpqrstvwxz2456789"
_REPLICASET_HASH_LEN = 9
_POD_SUFFIX_LEN = 5


def _encode(salt, repo_name, length):
    """Map a salted sha256 of repo_name onto `length` chars of _K8S_ALPHABET."""
    digest = hashlib.sha256(f"{salt}:{repo_name}".encode("utf-8")).digest()
    return "".join(_K8S_ALPHABET[b % len(_K8S_ALPHABET)] for b in digest[:length])


def _k8s_identity(repo_name, namespace):
    """Build the deterministic k8s identity block for one repo.

    Models a Deployment -> ReplicaSet -> Pod chain: the pod's single owner
    reference is its controlling ReplicaSet.
    """
    replicaset_hash = _encode("rs", repo_name, _REPLICASET_HASH_LEN)
    pod_suffix = _encode("pod", repo_name, _POD_SUFFIX_LEN)
    replicaset_name = f"{repo_name}-{replicaset_hash}"
    pod_name = f"{replicaset_name}-{pod_suffix}"
    owner_uid = str(uuid.uuid5(uuid.NAMESPACE_DNS, repo_name))
    return {
        "namespace": namespace,
        "podName": pod_name,
        "owners": [
            {
                "apiVersion": "apps/v1",
                "kind": "ReplicaSet",
                "name": replicaset_name,
                "uid": owner_uid,
                "controller": True,
                "blockOwnerDeletion": True,
            }
        ],
    }


def augment(entries, env, namespace):
    """Return entries with env + k8s identity added to each, order preserved."""
    result = []
    for entry in entries:
        augmented = dict(entry)
        augmented["env"] = env
        augmented["k8s"] = _k8s_identity(entry["repo_name"], namespace)
        result.append(augmented)
    return result


def _parse_args(argv):
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Add staging-k8s env + k8s identity to all-repos.json entries.",
        epilog="Example:\n  bin/add_k8s_identity_to_all_repos.py ../base/data/all-repos.json",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("all_repos_json", help="Path to the all-repos.json file")
    parser.add_argument("--env", default="staging-k8s", help="Environment name (default: staging-k8s)")
    parser.add_argument("--namespace", default="beta", help="K8S namespace (default: beta)")
    parser.add_argument(
        "--output",
        default=None,
        help="Write result here (default: overwrite the input in place)",
    )
    return parser.parse_args(argv)


def main(argv):
    """Read the input file, augment every entry, and write the result."""
    args = _parse_args(argv)
    with open(args.all_repos_json) as json_file:
        entries = json.load(json_file)

    augmented = augment(entries, args.env, args.namespace)

    output_path = args.output or args.all_repos_json
    with open(output_path, "w") as json_file:
        json.dump(augmented, json_file, indent=2)
        json_file.write("\n")

    print(f"Augmented {len(augmented)} entries -> {output_path}", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[1:])
