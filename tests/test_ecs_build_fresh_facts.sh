#!/usr/bin/env bash

# Tests for bin/ecs_build_fresh_facts.py: join each attested record (fingerprint +
# git_commit fetched from a repo's flow) with its all-repos.json ecs block into
# the --fresh facts that feed ecs_build_snapshot.py. Black-box: run the script,
# assert on its JSON stdout with jq.

readonly my_dir="$(cd "$(dirname "${0}")" && pwd)"
readonly BUILDER="${my_dir}/../bin/ecs_build_fresh_facts.py"

readonly DIGEST="a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4"
readonly TASK_ARN="arn:aws:ecs:eu-central-1:111122223333:task/beta/2f698d3b9c3c4a16912df9c23d6f6508"

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

test_joins_attested_record_with_all_repos_ecs_block()
{
  build --all-repos "${my_dir}/fixtures/ecs/all-repos-risk-service.json" \
        --attested  "${my_dir}/fixtures/shared/one-repo-attested-risk-service.json"
  assert_status_0
  assertEquals "fact count"         "1" "$(jq 'length' "${stdoutF}")"
  assertEquals "repo_name"          "risk-service" "$(jq -r '.[0].repo_name' "${stdoutF}")"
  assertEquals "image_ref"          "ghcr.io/kosli-demo/risk-service:aabbccd" "$(jq -r '.[0].image_ref' "${stdoutF}")"
  assertEquals "digest"             "${DIGEST}" "$(jq -r '.[0].digest' "${stdoutF}")"
  assertEquals "creation_timestamp" "1783500000" "$(jq '.[0].creation_timestamp' "${stdoutF}")"
  assertEquals "task_arn"           "${TASK_ARN}" "$(jq -r '.[0].task_arn' "${stdoutF}")"
  assertEquals "cluster_name"       "beta" "$(jq -r '.[0].cluster_name' "${stdoutF}")"
  assertEquals "service_name"       "risk-service" "$(jq -r '.[0].service_name' "${stdoutF}")"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# An attested repo missing from all-repos.json (no ecs block) is rejected with
# a clean message, not a Python traceback.

test_rejects_an_attested_repo_missing_from_all_repos()
{
  build --all-repos "${my_dir}/fixtures/ecs/all-repos-risk-service.json" \
        --attested  "${my_dir}/fixtures/shared/unknown-repo-attested.json"
  assert_status_equals 1
  assert_stdout_empty
  assert_stderr_equals "error: repo 'rogue-newcomer' has no ecs block in all-repos.json"
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
