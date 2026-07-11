#!/usr/bin/env bash

# Tests for bin/ecs_build_snapshot.py: reconcile the current ECS snapshot (empty
# on the first run) with this run's fresh facts (new or changed repos) into the
# next snapshot report payload. Black-box: run the script, assert on its JSON
# stdout with jq.

readonly my_dir="$(cd "$(dirname "${0}")" && pwd)"
readonly BUILDER="${my_dir}/../bin/ecs_build_snapshot.py"

readonly IMAGE_REF="ghcr.io/kosli-demo/risk-service:aabbccd"
readonly DIGEST="a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4"
readonly TASK_ARN="arn:aws:ecs:eu-central-1:111122223333:task/beta/2f698d3b9c3c4a16912df9c23d6f6508"

readonly CURRENT_REF="ghcr.io/kosli-demo/market-feed:d4e5f6a"
readonly CURRENT_DIGEST="b2c3d4e5b2c3d4e5b2c3d4e5b2c3d4e5b2c3d4e5b2c3d4e5b2c3d4e5b2c3d4e5"
readonly CURRENT_TASK_ARN="arn:aws:ecs:eu-central-1:111122223333:task/beta/1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d"

readonly ROGUE_REF="ghcr.io/kosli-demo/rogue-task:badf00d"

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Bootstrap case: no current snapshot, so every fresh repo is introduced.

test_fresh_repo_with_no_current_snapshot_produces_one_artifact()
{
  build --fresh "${my_dir}/fixtures/ecs/one-repo-fresh-facts.json"
  assert_status_0
  assertEquals "type"              "ECS" "$(jq -r '.type' "${stdoutF}")"
  assertEquals "artifact count"    "1"   "$(jq '.artifacts | length' "${stdoutF}")"
  assertEquals "taskArn"           "${TASK_ARN}" "$(jq -r '.artifacts[0].taskArn' "${stdoutF}")"
  assertEquals "cluster_name"      "beta" "$(jq -r '.artifacts[0].cluster_name' "${stdoutF}")"
  assertEquals "service_name"      "risk-service" "$(jq -r '.artifacts[0].service_name' "${stdoutF}")"
  assertEquals "digest mapping"    "${DIGEST}" "$(jq -r --arg r "${IMAGE_REF}" '.artifacts[0].digests[$r]' "${stdoutF}")"
  assertEquals "creationTimestamp" "1783500000" "$(jq '.artifacts[0].creationTimestamp' "${stdoutF}")"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# A repo present in the current snapshot (and not in fresh) is copied verbatim.

test_repo_in_current_snapshot_only_is_copied_verbatim()
{
  build --current "${my_dir}/fixtures/ecs/one-repo-current-snapshot.json"
  assert_status_0
  assertEquals "artifact count"    "1" "$(jq '.artifacts | length' "${stdoutF}")"
  assertEquals "taskArn"           "${CURRENT_TASK_ARN}" "$(jq -r '.artifacts[0].taskArn' "${stdoutF}")"
  assertEquals "cluster_name"      "beta" "$(jq -r '.artifacts[0].cluster_name' "${stdoutF}")"
  assertEquals "service_name"      "market-feed" "$(jq -r '.artifacts[0].service_name' "${stdoutF}")"
  assertEquals "digest mapping"    "${CURRENT_DIGEST}" "$(jq -r --arg r "${CURRENT_REF}" '.artifacts[0].digests[$r]' "${stdoutF}")"
  assertEquals "creationTimestamp" "1783550000" "$(jq '.artifacts[0].creationTimestamp' "${stdoutF}")"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# An exited artifact (annotation.now == 0) in the current snapshot must NOT be
# carried forward -- otherwise re-reporting would resurrect it (e.g. the rogue
# artifact after a reset-to-green).

test_exited_artifact_in_current_snapshot_is_not_carried_forward()
{
  build --current "${my_dir}/fixtures/ecs/current-snapshot-with-exited-artifact.json"
  assert_status_0
  assertEquals "artifact count" "1" "$(jq '.artifacts | length' "${stdoutF}")"
  assertEquals "running kept"   "${CURRENT_DIGEST}" \
    "$(jq -r --arg r "${CURRENT_REF}" '.artifacts[] | .digests[$r] // empty' "${stdoutF}")"
  assertEquals "exited dropped" "" \
    "$(jq -r --arg r "${ROGUE_REF}" '.artifacts[] | .digests[$r] // empty' "${stdoutF}")"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Steady state, multiple repos: an unchanged repo is copied verbatim while a
# repo also present in fresh is replaced by the fresh (new digest) fact.

test_reconcile_keeps_unchanged_verbatim_and_replaces_the_changed_repo()
{
  build --current "${my_dir}/fixtures/ecs/two-repo-current-snapshot.json" \
        --fresh   "${my_dir}/fixtures/ecs/one-repo-fresh-facts.json"
  assert_status_0
  assertEquals "artifact count"            "2" "$(jq '.artifacts | length' "${stdoutF}")"
  assertEquals "risk-service new digest"   "${DIGEST}" \
    "$(jq -r --arg r "${IMAGE_REF}" '.artifacts[] | .digests[$r] // empty' "${stdoutF}")"
  assertEquals "risk-service old ref gone" "" \
    "$(jq -r '.artifacts[] | .digests["ghcr.io/kosli-demo/risk-service:0011223"] // empty' "${stdoutF}")"
  assertEquals "market-feed preserved"     "${CURRENT_DIGEST}" \
    "$(jq -r --arg r "${CURRENT_REF}" '.artifacts[] | .digests[$r] // empty' "${stdoutF}")"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# A malformed digest (not 64 lowercase hex, e.g. a sha256: prefix) must be
# rejected with a non-zero exit, not emitted into the payload.

test_rejects_a_fact_with_an_invalid_digest()
{
  build --fresh "${my_dir}/fixtures/ecs/bad-digest-fresh-facts.json"
  assert_status_equals 1
  assert_stdout_empty
  assert_stderr_equals "error: digest for '${IMAGE_REF}' must be 64 lowercase hex chars (no 'sha256:' prefix), got 'sha256:${DIGEST}'"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# --drop removes a named artifact from the output (used by reset-to-green to
# remove the rogue-task artifact from the readback).

test_drop_removes_a_named_artifact()
{
  build --current "${my_dir}/fixtures/ecs/current-snapshot-with-rogue.json" --drop rogue-task
  assert_status_0
  assertEquals "artifact count"   "1" "$(jq '.artifacts | length' "${stdoutF}")"
  assertEquals "market-feed kept" "${CURRENT_DIGEST}" \
    "$(jq -r --arg r "${CURRENT_REF}" '.artifacts[] | .digests[$r] // empty' "${stdoutF}")"
  assertEquals "rogue dropped"    "" \
    "$(jq -r --arg r "${ROGUE_REF}" '.artifacts[] | .digests[$r] // empty' "${stdoutF}")"
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
