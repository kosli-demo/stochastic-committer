#!/usr/bin/env bash

# End-to-end: ecs_build_fresh_facts.py -> ecs_build_snapshot.py (empty --current)
# produces a valid ECS report, locking the fact-contract between the two scripts.
# Empty --current is the simplest end-to-end input (it is also the first-run
# case). Black-box via jq.

readonly my_dir="$(cd "$(dirname "${0}")" && pwd)"
readonly FRESH_FACTS="${my_dir}/../bin/ecs_build_fresh_facts.py"
readonly SNAPSHOT="${my_dir}/../bin/ecs_build_snapshot.py"

readonly IMAGE_REF="ghcr.io/kosli-demo/risk-service:aabbccd"
readonly DIGEST="a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4"
readonly TASK_ARN="arn:aws:ecs:eu-central-1:111122223333:task/beta/2f698d3b9c3c4a16912df9c23d6f6508"

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

test_fresh_facts_feed_the_snapshot_builder_into_a_valid_report()
{
  run_pipeline
  assert_status_0
  assertEquals "type"              "ECS" "$(jq -r '.type' "${stdoutF}")"
  assertEquals "artifact count"    "1" "$(jq '.artifacts | length' "${stdoutF}")"
  assertEquals "digest mapping"    "${DIGEST}" "$(jq -r --arg r "${IMAGE_REF}" '.artifacts[0].digests[$r]' "${stdoutF}")"
  assertEquals "taskArn"           "${TASK_ARN}" "$(jq -r '.artifacts[0].taskArn' "${stdoutF}")"
  assertEquals "cluster_name"      "beta" "$(jq -r '.artifacts[0].cluster_name' "${stdoutF}")"
  assertEquals "service_name"      "risk-service" "$(jq -r '.artifacts[0].service_name' "${stdoutF}")"
  assertEquals "creationTimestamp" "1783500000" "$(jq '.artifacts[0].creationTimestamp' "${stdoutF}")"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

run_pipeline()
{
  "${FRESH_FACTS}" \
      --all-repos "${my_dir}/fixtures/ecs/all-repos-risk-service.json" \
      --attested  "${my_dir}/fixtures/shared/one-repo-attested-risk-service.json" \
      > "${SHUNIT_TMPDIR}/fresh.json" 2>"${stderrF}" \
    && "${SNAPSHOT}" --fresh "${SHUNIT_TMPDIR}/fresh.json" >"${stdoutF}" 2>>"${stderrF}"
  echo $? >"${statusF}"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

echo "::${0##*/}"
. ${my_dir}/shunit2_helpers.sh
. ${my_dir}/shunit2
