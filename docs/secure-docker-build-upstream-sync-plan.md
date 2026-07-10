# Plan: sync `secure-docker-build.yml` to the cyber-dojo upstream

Status: proposal (not yet implemented). Scope: bring
`kosli-demo/actions/.github/workflows/secure-docker-build.yml` (and its
policies) into line with the reworked upstream in
`cyber-dojo/reusable-actions-workflows`, making it effectively a copy adapted for
kosli-demo.

This is the execution plan for the study already written up in
`kosli-demo/actions/secure-docker-build-upstream-sync-report.md`. That report is
the authoritative catalogue of the divergence; this document turns it into
ordered, verifiable steps and records what changes now that the environment work
is done. Read the report alongside this plan.

## 1. Assumption: the first plan is already done

This plan assumes the work in `staging-k8s-fake-snapshot-plan.md` has landed with
its **option A** (real image digest as the Kosli artifact fingerprint). Concretely
that means:

- `secure-docker-build.yml` already attests the **real image digest** to Kosli
  (the fake `kosli fingerprint source/datetime.txt` plumbing has been removed),
  so the Kosli artifact fingerprint, the GitHub/sigstore SLSA subject digest, and
  the `staging-k8s` environment's reported digest are all the **same value**.
- Every fleet repo has run CI at least once since, so its flow holds a
  real-image-digest artifact.

Contingency: if the first plan instead shipped with **option B** (interim file
fingerprint), then step 0 of this plan is to complete the switch to real image
digests first - remove the `sanitize-digest` fake-fingerprint block and attest
the real image digest to Kosli - because everything below depends on it.

## 2. What "first plan done" unblocks (the headline)

The sync report's **section 5** was the blocking constraint: with a fake
fingerprint, the upstream provenance control's identity cross-checks
(`subject_matches_artifact`: SLSA subject digest == Kosli fingerprint, and
`source_commit_matches_trail`) would always fail, forcing either a documented
weakening of the control (report option B) or abandoning the simulation.

With the real image digest now in place, **that constraint is gone**. The SLSA
subject and the Kosli fingerprint are identical, so both cross-checks pass with
honest values. Consequence:

> We adopt the upstream `SDLC-CTRL-0002` rego (and the rest of the control suite)
> **verbatim** - no weakening, no removal of the identity checks. The sync
> report's instruction (section 7, step 7) to "preserve the fake-fingerprint
> plumbing" is now **obsolete** and must NOT be followed.

This removes the largest risk and design decision the report flagged.

## 3. Source of truth

Copy from the upstream at a pinned commit, not from any paraphrase:

- Upstream: `cyber-dojo/reusable-actions-workflows` (the report studied commit
  `7f04995`): the workflow, the `attest-and-evaluate` composite action, both
  per-control directories, the `Makefile`, and the README.
- Adapt each copied file for kosli-demo per section 4 below.

## 4. Changes to make

Grouped; see the sync report sections 1-3 and 6 for the full rationale.

### 4.1 Controls -> per-control directory layout
Replace the single flat `SDLC-CTRL-0002-binary-provenance.rego` at the repo root
with the upstream layout:
- `SDLC-CTRL-0002/` : `slsa-provenance.rego` + `provenance-facts.jq` + `tests/`
- `SDLC-CTRL-0004/` : `sbom.rego` + `sbom-facts.jq` + `sbom-overrides.*.json`
  + JSON schema + `tests/`
- `Makefile` exposing `test-provenance` and `test-sbom`.
Rename/remove the stray root rego once the new layout lands.

### 4.2 SDLC-CTRL-0002 (provenance) - port verbatim, adapt prefixes only
Port `slsa-provenance.rego` and `provenance-facts.jq` as-is (the identity checks
stay). Adapt only the trusted-prefix parameters for kosli-demo:
- `expected_builder_id_prefix`:
  `https://github.com/kosli-demo/actions/.github/workflows/`
- `expected_source_repo_prefix`: `https://github.com/kosli-demo/`

Verify the prefixes against a **real** attestation before trusting them: inspect
the `builder_id` / `source_repo` in an actual sigstore bundle from a kosli-demo
build and confirm they start with the configured prefixes. (Reusable-workflow
builder ids can be subtle; do not assume.)

### 4.3 SDLC-CTRL-0004 (SBOM) - new control
Add the SBOM control (`sbom.rego`, `sbom-facts.jq`, overrides + schema, tests).
It checks the SPDX SBOM for a non-empty, well-formed inventory, a real
dependency graph (`relationship_count > 0`), and concrete version + resolvable
purl per package (unless waived by an override). Overrides are keyed on
`kosli_reference_name`, which kosli-demo callers pass as `artifact`, so add
`sbom-overrides.artifact.json` (a missing overrides file is tolerated as
"no waivers").

**kosli-demo-specific risk (decide before relying on this):** kosli-demo images
are `FROM scratch` with a single static C binary plus `datetime.txt`. Their SPDX
SBOM (`sbom: true` on buildx) may be nearly empty - likely zero packages and
zero relationships - which would make `SDLC-CTRL-0004` **fail every build**
(min_packages / `relationship_count > 0`). Options:
- ship an `sbom-overrides.artifact.json` that waives the empty-inventory checks
  for this demo artifact (reason-required, expiry-dated per the upstream model), or
- relax the kosli-demo copy's thresholds for scratch images, documented as a
  deliberate demo divergence, or
- defer SDLC-CTRL-0004 adoption until the demo images carry a meaningful SBOM.
Under the Kosli asymmetry rule a failing SBOM decision is "safe" (never falsely
compliant) but would make the whole environment non-compliant, so this must be
settled, not left to fail silently.

### 4.4 attest-and-evaluate composite action
Adopt (or inline) the upstream `.github/actions/attest-and-evaluate/action.yml`:
distill `provenance-facts` and `sbom-facts` with the `.jq` files, attest each as
`kosli attest custom` (rego can only read structured custom-attestation data, not
raw sigstore/SPDX blobs), evaluate both controls, and attest
`provenance-decision` and `sbom-decision`. The real image digest is the
fingerprint for every attest/decision.

### 4.5 Policy delivery + build gate
- Replace the `curl` of the rego from raw.githubusercontent (429-prone) with an
  `actions/checkout` of `kosli-demo/actions` into a sibling path, in both the
  gate job and the composite.
- Add a `test-policies` gate job that runs `make test-provenance test-sbom`
  before any image is built.

### 4.6 Keep ghcr.io (drop the AWS/ECR parts)
Upstream pushes to AWS ECR via OIDC. kosli-demo stays on ghcr.io: drop
`configure-aws-credentials` / `amazon-ecr-login` and the `AWS_*` env; keep
`docker/login-action`, `GITHUB_TOKEN`, and `packages: write`.

### 4.7 Skip tar-save / upload-artifact
Upstream saves the image to a tar and uploads it for a `download-artifact`
partner action. kosli-demo has no such partner, so omit those steps unless one is
added.

### 4.8 Decision names
Upstream uses `provenance-decision` and `sbom-decision`; the current kosli-demo
uses `--name provenance`. Pick the upstream names and make the env-policies and
any dashboards consistent (see section 5). Also remove the now-superseded
`kosli attest generic ... --name sbom` step to avoid a stale, unevaluated
"sbom" attestation.

## 5. `kosli-environment-policies` update

`policies/provenance.yml` currently requires a `decision` attestation for
`SDLC-CTRL-0002` only. Adopting `SDLC-CTRL-0004` means the environment gate must
also require its decision (otherwise a failing/absent SBOM decision would still
pass the environment policy - a compliance gap). Either add a second
`for_control: SDLC-CTRL-0004` entry, or add a new `sbom.yml` env-policy.

Apply to **both** `app.kosli.com` and `staging.app.kosli.com`, and to the new
`staging-k8s` environment (coordinated with the first plan's policy-attach step) -
policies must stay identical across hosts (per commit `5558115`). The env-policy
keys on `for_control`, so the decision-name change alone does not break it, but
update anything that keys on the old `--name provenance`.

## 6. Migration checklist (ordered; land and verify each, do not batch)

0. (Only if first plan shipped option B) Switch `secure-docker-build.yml` to
   attest the real image digest; remove the fake-fingerprint plumbing.
1. Restructure to per-control directories + `Makefile` (4.1).
2. Port `SDLC-CTRL-0002` verbatim with kosli-demo prefixes + tests (4.2).
3. Add `SDLC-CTRL-0004` + overrides + schema + tests, and settle the scratch-image
   SBOM decision (4.3).
4. Switch policy delivery to `checkout`; add the `test-policies` gate (4.5).
5. Adopt the `attest-and-evaluate` composite (4.4), keeping ghcr.io (4.6),
   skipping tar/upload (4.7), and using the upstream decision names (4.8).
6. Update `kosli-environment-policies` for `SDLC-CTRL-0004`; push to both hosts (5).
7. Fix the nits (section 8) and tag a new `v0.0.x` release (callers pin by tag).

## 7. Verification

- `make test-provenance test-sbom` passes locally (the gate job runs the same).
- Trigger one repo's CI (e.g. `golden-ledger`): confirm the build attests the
  real image digest to Kosli, and that both `provenance-decision` and
  `sbom-decision` land as **compliant** on the trail.
- Confirm the identity checks actually fire: in the eval evidence,
  `subject_matches_artifact` and `source_commit_matches_trail` are true (not
  skipped) - proving the real-digest foundation is doing its job.
- Confirm the `staging-k8s` environment shows that repo's artifact **compliant**
  under the new controls after its next snapshot.

## 8. Nits (from sync report section 8)

- README typo: "kosli-demi Org" -> "kosli-demo Org".
- Remove the stale `kosli attest generic ... --name sbom` step (superseded by
  the sbom-facts + sbom-decision model).
- Rename the stray root `SDLC-CTRL-0002-binary-provenance.rego` once the
  per-control layout lands.
- Update the README to document the facts/decision model and both controls.

## 9. Guardrails

Attesting to Kosli and evaluating trails happen inside CI with the repo's own
token; that is expected. Any manual `kosli` writes done while implementing this
(e.g. re-pushing env-policies, re-triggering a build) are writes and must only be
run on explicit instruction, never autonomously. Copying the upstream files and
editing the rego/workflow locally is safe read/write on disk.
