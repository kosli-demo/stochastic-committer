#!/usr/bin/env bash

# Tests for bin/build_attestation_record.py: from each selected repo's flow
# artifacts (GET /artifacts/{org}/<repo>-ci), pick the latest artifact (max
# git_commit_info.timestamp) and emit {repo_name, fingerprint, git_commit,
# creation_timestamp}; self-filter to entries that have a k8s block. The base
# creation_timestamp is the commit time; the workflow adds deploy latency later.
# Black-box via jq.

readonly my_dir="$(cd "$(dirname "${0}")" && pwd)"
readonly BUILDER="${my_dir}/../bin/build_attestation_record.py"

readonly LATEST_FP="d1a92f4f43c7c91c8bf5d1f938e2a3a8fa9ed88fce6bd4a3cdb5207ad2c99d3d"
readonly LATEST_COMMIT="52ec808f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d"

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Two artifacts, the older one listed first: it must pick the LATER one (by
# git_commit_info.timestamp), not index 0.

test_picks_latest_artifact_and_extracts_the_record()
{
  build --selected "${my_dir}/fixtures/shared/attestation-selected.json" \
        --artifacts "${my_dir}/fixtures/shared/attestation-artifacts.json"
  assert_status_0
  assertEquals "record count"       "1" "$(jq 'length' "${stdoutF}")"
  assertEquals "repo_name"          "golden-ledger" "$(jq -r '.[0].repo_name' "${stdoutF}")"
  assertEquals "fingerprint"        "${LATEST_FP}" "$(jq -r '.[0].fingerprint' "${stdoutF}")"
  assertEquals "git_commit"         "${LATEST_COMMIT}" "$(jq -r '.[0].git_commit' "${stdoutF}")"
  assertEquals "creation_timestamp" "1783600000" "$(jq '.[0].creation_timestamp' "${stdoutF}")"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Self-filter (option b): a selected entry with no k8s block (e.g. an ecs one)
# is skipped - snapshot-k8s only records its own type.

test_self_filters_out_entries_without_a_k8s_block()
{
  build --selected "${my_dir}/fixtures/shared/attestation-selected-mixed.json" \
        --artifacts "${my_dir}/fixtures/shared/attestation-artifacts-mixed.json"
  assert_status_0
  assertEquals "record count"    "1" "$(jq 'length' "${stdoutF}")"
  assertEquals "only the k8s repo" "golden-ledger" "$(jq -r '.[0].repo_name' "${stdoutF}")"
  assertEquals "ecs repo skipped"  "" \
    "$(jq -r '.[] | select(.repo_name == "risk-service") | .repo_name' "${stdoutF}")"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

build()
{
  "${BUILDER}" "$@" >"${stdoutF}" 2>"${stderrF}"
  echo $? >"${statusF}"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

echo "::${0##*/}"
. ${my_dir}/shunit2_helpers.sh
. ${my_dir}/shunit2
