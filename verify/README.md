# Formal verification (Lean 4)

Lean models of the crate's pure logic, with machine-checked proofs, tied to the Rust code by
conformance vectors.

| Rust | Lean | Proved |
|---|---|---|
| `format::countdown`, `ago` | `Format.lean` | Fields in range; shown time is the remaining time truncated to the shown unit (`countdown_valid`, `ago_valid`) |
| `format::bar` | `Bar.lean` | `filled ≤ width` for every `f64`, incl. NaN/±∞, for `width ≤ 2^53`, so `width - filled` cannot underflow (`filled_le`, `bar_length`) |
| `ProviderState::apply` | `Model.lean` | Usage, once present, is never lost; error is exactly the latest fetch's (`apply_keeps_usage`, `apply_error`) |
| `cache::refresh` | `Cache.lean` | While the clock does not step back, across any interleaving of panes and from any starting cache: two fetches where the later can see the earlier (saved to the cache, or same pane) are ≥ `MANUAL_FLOOR` apart, ≥ `AUTO_TTL` if the later is automatic (`run_throttled`, `run_floor`). Whatever the clock does, a call is held back only by an attempt within the last `minAge` of its clock, never by a future timestamp (`shouldFetch_false_iff`, `step_blocked`) |
| `codex::parse` | `Codex.lean` | Window order never matters; of two same-length windows the more used one is shown (`classify_comm`, `classify_same_length`) |

## Trust base

- The models are hand-written. `src/conformance.rs` checks the real Rust functions against
  `vectors.json`, which the models generate (`lake exe gen`); a drifted model or code fails
  `cargo test`.
- `Bar.lean` rests on five IEEE-754 axioms (Lean's core library has no float monotonicity
  lemmas, and `Float.round` is opaque). `lake exe gen --check-axioms` samples them against the
  compiled float operations.
- `Audit.lean` prints the axioms behind each headline theorem; `check.sh` fails on `sorry` or
  `native_decide`.

## Limits of the guarantees

- **Clock steps back.** Throttling assumes the wall clock is monotone during the run (`now` is
  read once the lock is held, so the calls it serialises see increasing times). When the clock
  steps back, timestamps from the future count as never attempted, so the next call fetches
  rather than waiting for the clock to catch up.
- **Cache failures.** Throttling across panes needs the earlier fetch to have reached the cache;
  a pane whose lock or write fails is throttled only against itself. Without shared state there
  is nothing else to coordinate through.
- **Lock-failed calls** are modelled at the moment they read the cache. That keeps `now` in
  order unless another pane holds the lock at the time; since the lock file is shared, lock
  failures are normally all-or-nothing.

## Running

Install Lean with [elan](https://github.com/leanprover/elan), then:

```sh
verify/check.sh
```

It builds the proofs, audits their axioms, samples the float axioms, regenerates
`vectors.json` (failing if it changed) and runs the conformance tests.
