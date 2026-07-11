#!/usr/bin/env bash

# Tests for bin/switch_repos_to_ecs.py: rewrite named repos in all-repos.json from
# their k8s identity block to a deterministic ecs block (env staging-ecs), leaving
# every other repo untouched. Black-box: run with --output, assert on the written
# JSON with jq.

readonly my_dir="$(cd "$(dirname "${0}")" && pwd)"
readonly SWITCHER="${my_dir}/../bin/switch_repos_to_ecs.py"

readonly GL_TASK_ARN="arn:aws:ecs:eu-central-1:111122223333:task/beta/44a8debf592173d75dbe3616d06cf609"
readonly PI_TASK_ARN="arn:aws:ecs:eu-central-1:111122223333:task/beta/495212f6e09363c12dbed55757a8af91"

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# A named repo is rewritten from its k8s block to a deterministic ecs block; env
# flips to staging-ecs and the k8s block is dropped.

test_switches_a_named_repo_from_k8s_to_ecs()
{
  local out="${SHUNIT_TMPDIR}/switched.json"
  switch "${my_dir}/fixtures/k8s/all-repos-two-repos.json" golden-ledger --output "${out}"
  assert_status_0
  assertEquals "env"          "staging-ecs" "$(jq -r '.[] | select(.repo_name=="golden-ledger") | .env' "${out}")"
  assertEquals "k8s dropped"   "false" "$(jq -r '.[] | select(.repo_name=="golden-ledger") | has("k8s")' "${out}")"
  assertEquals "ecs added"     "true" "$(jq -r '.[] | select(.repo_name=="golden-ledger") | has("ecs")' "${out}")"
  assertEquals "taskArn"       "${GL_TASK_ARN}" "$(jq -r '.[] | select(.repo_name=="golden-ledger") | .ecs.taskArn' "${out}")"
  assertEquals "cluster_name"  "beta" "$(jq -r '.[] | select(.repo_name=="golden-ledger") | .ecs.cluster_name' "${out}")"
  assertEquals "service_name"  "golden-ledger" "$(jq -r '.[] | select(.repo_name=="golden-ledger") | .ecs.service_name' "${out}")"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# A repo name that is not in the fleet is rejected loudly (rather than silently
# switching nothing), so a typo can never leave a repo stranded in k8s.

test_rejects_a_repo_name_not_in_all_repos()
{
  local out="${SHUNIT_TMPDIR}/switched.json"
  switch "${my_dir}/fixtures/k8s/all-repos-two-repos.json" no-such-repo --output "${out}"
  assert_status_equals 1
  assert_stderr_equals "error: repo 'no-such-repo' not found in all-repos.json"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Several repos switched in one call: each gets its own distinct deterministic
# ecs block and no k8s block is left behind (the many-repos case).

test_switches_multiple_repos_in_one_call()
{
  local out="${SHUNIT_TMPDIR}/switched.json"
  switch "${my_dir}/fixtures/k8s/all-repos-two-repos.json" golden-ledger price-index --output "${out}"
  assert_status_0
  assertEquals "golden-ledger taskArn" "${GL_TASK_ARN}" "$(jq -r '.[] | select(.repo_name=="golden-ledger") | .ecs.taskArn' "${out}")"
  assertEquals "price-index taskArn"   "${PI_TASK_ARN}" "$(jq -r '.[] | select(.repo_name=="price-index") | .ecs.taskArn' "${out}")"
  assertEquals "no k8s blocks left"    "0" "$(jq '[.[] | select(has("k8s"))] | length' "${out}")"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

switch()
{
  "${SWITCHER}" "$@" >"${stdoutF}" 2>"${stderrF}"
  echo $? >"${statusF}"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

echo "::${0##*/}"
. ${my_dir}/shunit2_helpers.sh
. ${my_dir}/shunit2
