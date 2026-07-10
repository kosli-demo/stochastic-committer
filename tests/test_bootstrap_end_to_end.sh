#!/usr/bin/env bash

# End-to-end: build_fresh_facts.py -> build_k8s_snapshot.py (empty --current)
# produces a valid bootstrap K8S report. Locks the fact-contract between the two
# scripts and mirrors the real bootstrap path. Black-box via jq.

readonly my_dir="$(cd "$(dirname "${0}")" && pwd)"
readonly FRESH_FACTS="${my_dir}/../bin/build_fresh_facts.py"
readonly SNAPSHOT="${my_dir}/../bin/build_k8s_snapshot.py"

readonly IMAGE_REF="ghcr.io/kosli-demo/golden-ledger:52ec808"
readonly DIGEST="d1a92f4f43c7c91c8bf5d1f938e2a3a8fa9ed88fce6bd4a3cdb5207ad2c99d3d"

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

test_fresh_facts_feed_the_snapshot_builder_into_a_valid_bootstrap_report()
{
  bootstrap
  assert_status_0
  assertEquals "type"              "K8S" "$(jq -r '.type' "${stdoutF}")"
  assertEquals "artifact count"    "1" "$(jq '.artifacts | length' "${stdoutF}")"
  assertEquals "digest mapping"    "${DIGEST}" "$(jq -r --arg r "${IMAGE_REF}" '.artifacts[0].digests[$r]' "${stdoutF}")"
  assertEquals "podName"           "golden-ledger-7d9f8c6b5-x4k2p" "$(jq -r '.artifacts[0].podName' "${stdoutF}")"
  assertEquals "creationTimestamp" "1783600000" "$(jq '.artifacts[0].creationTimestamp' "${stdoutF}")"
  assertEquals "owner kind"        "ReplicaSet" "$(jq -r '.artifacts[0].owners[0].kind' "${stdoutF}")"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

bootstrap()
{
  "${FRESH_FACTS}" \
      --all-repos "${my_dir}/fixtures/all-repos-golden-ledger.json" \
      --attested  "${my_dir}/fixtures/one-repo-attested.json" \
      > "${SHUNIT_TMPDIR}/fresh.json" 2>"${stderrF}" \
    && "${SNAPSHOT}" --fresh "${SHUNIT_TMPDIR}/fresh.json" >"${stdoutF}" 2>>"${stderrF}"
  echo $? >"${statusF}"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

echo "::${0##*/}"
. ${my_dir}/shunit2_helpers.sh
. ${my_dir}/shunit2
