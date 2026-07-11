#!/usr/bin/env bash

# Tests for bin/k8s_build_snapshot.py: reconcile the current K8S snapshot (empty
# on the first/bootstrap run) with this run's fresh facts (new or changed repos)
# into the next snapshot report payload. Black-box: run the script, assert on its
# JSON stdout with jq.

readonly my_dir="$(cd "$(dirname "${0}")" && pwd)"
readonly BUILDER="${my_dir}/../bin/k8s_build_snapshot.py"

readonly IMAGE_REF="ghcr.io/kosli-demo/golden-ledger:52ec808"
readonly DIGEST="d1a92f4f43c7c91c8bf5d1f938e2a3a8fa9ed88fce6bd4a3cdb5207ad2c99d3d"

readonly PRICE_INDEX_REF="ghcr.io/kosli-demo/price-index:abc1234"
readonly PRICE_INDEX_DIGEST="3f0a1c5e9b2d4a6f8c1e0b7d5a9f2c4e6b8d0a1c3e5f7a9b1d3f5a7c9e1b3d5f"
readonly ROGUE_REF="ghcr.io/kosli-demo/rogue-trader:rogue"

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Bootstrap case: no current snapshot, so every fresh repo is introduced.

test_fresh_repo_with_no_current_snapshot_produces_one_artifact()
{
  build --fresh "${my_dir}/fixtures/k8s/one-repo-fresh-facts.json"
  assert_status_0
  assertEquals "type"              "K8S" "$(jq -r '.type' "${stdoutF}")"
  assertEquals "artifact count"    "1"   "$(jq '.artifacts | length' "${stdoutF}")"
  assertEquals "podName"           "golden-ledger-7d9f8c6b5-x4k2p" "$(jq -r '.artifacts[0].podName' "${stdoutF}")"
  assertEquals "namespace"         "beta" "$(jq -r '.artifacts[0].namespace' "${stdoutF}")"
  assertEquals "digest mapping"    "${DIGEST}" "$(jq -r --arg r "${IMAGE_REF}" '.artifacts[0].digests[$r]' "${stdoutF}")"
  assertEquals "creationTimestamp" "1783600000" "$(jq '.artifacts[0].creationTimestamp' "${stdoutF}")"
  assertEquals "owner kind"        "ReplicaSet" "$(jq -r '.artifacts[0].owners[0].kind' "${stdoutF}")"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# A repo present in the current snapshot (and not in fresh) is copied verbatim.

test_repo_in_current_snapshot_only_is_copied_verbatim()
{
  build --current "${my_dir}/fixtures/k8s/one-repo-current-snapshot.json"
  assert_status_0
  assertEquals "artifact count"    "1" "$(jq '.artifacts | length' "${stdoutF}")"
  assertEquals "podName"           "price-index-fxblt7pxf-d4xvq" "$(jq -r '.artifacts[0].podName' "${stdoutF}")"
  assertEquals "namespace"         "beta" "$(jq -r '.artifacts[0].namespace' "${stdoutF}")"
  assertEquals "digest mapping"    "${PRICE_INDEX_DIGEST}" "$(jq -r --arg r "${PRICE_INDEX_REF}" '.artifacts[0].digests[$r]' "${stdoutF}")"
  assertEquals "creationTimestamp" "1783500000" "$(jq '.artifacts[0].creationTimestamp' "${stdoutF}")"
  assertEquals "owner kind"        "ReplicaSet" "$(jq -r '.artifacts[0].owners[0].kind' "${stdoutF}")"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Steady state, multiple repos: an unchanged repo is copied verbatim while a
# repo also present in fresh is replaced by the fresh (new digest) fact.

test_reconcile_keeps_unchanged_verbatim_and_replaces_the_changed_repo()
{
  build --current "${my_dir}/fixtures/k8s/two-repo-current-snapshot.json" \
        --fresh   "${my_dir}/fixtures/k8s/one-repo-fresh-facts.json"
  assert_status_0
  assertEquals "artifact count"           "2" "$(jq '.artifacts | length' "${stdoutF}")"
  assertEquals "golden-ledger new digest" "${DIGEST}" \
    "$(jq -r --arg r "${IMAGE_REF}" '.artifacts[] | .digests[$r] // empty' "${stdoutF}")"
  assertEquals "golden-ledger old ref gone" "" \
    "$(jq -r '.artifacts[] | .digests["ghcr.io/kosli-demo/golden-ledger:0011223"] // empty' "${stdoutF}")"
  assertEquals "price-index preserved"    "${PRICE_INDEX_DIGEST}" \
    "$(jq -r --arg r "${PRICE_INDEX_REF}" '.artifacts[] | .digests[$r] // empty' "${stdoutF}")"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# An exited artifact (annotation.now == 0) in the current snapshot must NOT be
# carried forward -- otherwise re-reporting would resurrect it (e.g. the rogue
# artifact after a reset-to-green).

test_exited_artifact_in_current_snapshot_is_not_carried_forward()
{
  build --current "${my_dir}/fixtures/k8s/current-snapshot-with-exited-artifact.json"
  assert_status_0
  assertEquals "artifact count" "1" "$(jq '.artifacts | length' "${stdoutF}")"
  assertEquals "running kept"   "${PRICE_INDEX_DIGEST}" \
    "$(jq -r --arg r "${PRICE_INDEX_REF}" '.artifacts[] | .digests[$r] // empty' "${stdoutF}")"
  assertEquals "exited dropped" "" \
    "$(jq -r '.artifacts[] | .digests["ghcr.io/kosli-demo/rogue-trader:badf00d"] // empty' "${stdoutF}")"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# A malformed digest (not 64 lowercase hex, e.g. a sha256: prefix) must be
# rejected with a non-zero exit, not emitted into the payload.

test_rejects_a_fact_with_an_invalid_digest()
{
  build --fresh "${my_dir}/fixtures/k8s/bad-digest-fresh-facts.json"
  assert_status_equals 1
  assert_stdout_empty
  assert_stderr_equals "error: digest for '${IMAGE_REF}' must be 64 lowercase hex chars (no 'sha256:' prefix), got 'sha256:${DIGEST}'"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# --drop removes a named artifact from the output (used by reset-to-green to
# remove the rogue-trader artifact from the readback).

test_drop_removes_a_named_artifact()
{
  build --current "${my_dir}/fixtures/k8s/current-snapshot-with-rogue.json" --drop rogue-trader
  assert_status_0
  assertEquals "artifact count"  "1" "$(jq '.artifacts | length' "${stdoutF}")"
  assertEquals "price-index kept" "${PRICE_INDEX_DIGEST}" \
    "$(jq -r --arg r "${PRICE_INDEX_REF}" '.artifacts[] | .digests[$r] // empty' "${stdoutF}")"
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
