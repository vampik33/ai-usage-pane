#!/usr/bin/env bash
# Checks the proofs, the float axioms, and that the Rust code still matches the models.
set -euo pipefail
cd "$(dirname "$0")"

lake build
# No `sorry` and no compiler-trusted `native_decide` behind any headline theorem.
audit=$(lake env lean Audit.lean)
echo "$audit"
if grep -q 'sorryAx\|ofReduceBool' <<<"$audit"; then
  echo "proof audit failed" >&2
  exit 1
fi
lake exe gen --check-axioms
lake exe gen >vectors.json
git diff --exit-code vectors.json || {
  echo "vectors.json was stale and has been regenerated; commit it" >&2
  exit 1
}
cargo test --manifest-path ../Cargo.toml conformance
