#!/usr/bin/env bash

# Tests for bin/k8s_build_fresh_facts.py: join each attested record (fingerprint +
# git_commit fetched from a repo's flow) with its all-repos.json k8s block into
# the --fresh facts that feed k8s_build_snapshot.py. Black-box: run the script,
# assert on its JSON stdout with jq.

readonly my_dir="$(cd "$(dirname "${0}")" && pwd)"
readonly BUILDER="${my_dir}/../bin/k8s_build_fresh_facts.py"

readonly DIGEST="d1a92f4f43c7c91c8bf5d1f938e2a3a8fa9ed88fce6bd4a3cdb5207ad2c99d3d"

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

test_joins_attested_record_with_all_repos_k8s_block()
{
  build --all-repos "${my_dir}/fixtures/k8s/all-repos-golden-ledger.json" \
        --attested  "${my_dir}/fixtures/shared/one-repo-attested.json"
  assert_status_0
  assertEquals "fact count"         "1" "$(jq 'length' "${stdoutF}")"
  assertEquals "repo_name"          "golden-ledger" "$(jq -r '.[0].repo_name' "${stdoutF}")"
  assertEquals "image_ref"          "ghcr.io/kosli-demo/golden-ledger:52ec808" "$(jq -r '.[0].image_ref' "${stdoutF}")"
  assertEquals "digest"             "${DIGEST}" "$(jq -r '.[0].digest' "${stdoutF}")"
  assertEquals "creation_timestamp" "1783600000" "$(jq '.[0].creation_timestamp' "${stdoutF}")"
  assertEquals "namespace"          "beta" "$(jq -r '.[0].namespace' "${stdoutF}")"
  assertEquals "pod_name"           "golden-ledger-7d9f8c6b5-x4k2p" "$(jq -r '.[0].pod_name' "${stdoutF}")"
  assertEquals "owner kind"         "ReplicaSet" "$(jq -r '.[0].owners[0].kind' "${stdoutF}")"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# An attested repo missing from all-repos.json (no k8s block) is rejected with
# a clean message, not a Python traceback.

test_rejects_an_attested_repo_missing_from_all_repos()
{
  build --all-repos "${my_dir}/fixtures/k8s/all-repos-golden-ledger.json" \
        --attested  "${my_dir}/fixtures/shared/unknown-repo-attested.json"
  assert_status_equals 1
  assert_stdout_empty
  assert_stderr_equals "error: repo 'rogue-newcomer' has no k8s block in all-repos.json"
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
