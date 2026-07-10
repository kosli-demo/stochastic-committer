#!/usr/bin/env bash

# Tests for bin/select_repos.py. A repo that does not yet exist (exists=false)
# must be force-selected regardless of repo_chance, so a newly-added fleet repo
# always gets committed + CI'd (attested) and can enter the environment this run.
# Existing repos stay governed by the stochastic repo_chance. Black-box via jq.

readonly my_dir="$(cd "$(dirname "${0}")" && pwd)"
readonly SELECTOR="${my_dir}/../bin/select_repos.py"

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# chance=0 means the stochastic selection can never fire, so only the force rule
# can select a repo: the existing repo stays unselected, the new one is selected.

test_new_repo_is_force_selected_even_at_zero_chance()
{
  select_repos "${my_dir}/fixtures/select-repos-mixed.json" 2 0
  assert_status_0
  assertEquals "existing repo not selected" "false" \
    "$(jq -c '.[] | select(.repo_name == "golden-ledger") | .selected' "${stdoutF}")"
  assertEquals "new repo force-selected" "true" \
    "$(jq -c '.[] | select(.repo_name == "new-frontier") | .selected' "${stdoutF}")"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

select_repos()
{
  "${SELECTOR}" "$@" >"${stdoutF}" 2>"${stderrF}"
  echo $? >"${statusF}"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

echo "::${0##*/}"
. ${my_dir}/shunit2_helpers.sh
. ${my_dir}/shunit2
