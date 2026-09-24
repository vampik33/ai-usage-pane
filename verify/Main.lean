import Lean.Data.Json
import AiUsagePane

/-!
`lake exe gen` prints the conformance vectors that `src/conformance.rs` checks the Rust code
against, so the proved models and the shipped code cannot drift apart unnoticed.

`lake exe gen --check-axioms` samples the float axioms of `AiUsagePane.Bar` against the compiled
(C) float operations.
-/

open Lean (Json toJson)
open AiUsagePane

/-- Around every unit boundary the formatters care about, plus negatives and large values. -/
def seconds : List Int :=
  let boundaries : List Int :=
    [0, 60, 120, 600, 3540, 3600, 3660, 7200, 36000, 82800, 86400, 90000, 172800, 604800,
      1000000]
  let near := boundaries.flatMap fun b => [b - 61, b - 60, b - 59, b - 1, b, b + 1, b + 59, b + 60]
  (near ++ [-1000000, -86400, -3600, -121, -120, -90, -61, 5 * 3600 - 1, 10 ^ 9]).eraseDups

/-- A flat JSON array (`toJson` nests tuples as pairs). -/
def tuple (xs : List Json) : Json := Json.arr xs.toArray

def formatVectors : Json × Json :=
  (toJson (seconds.map fun s => tuple [toJson s, toJson (Format.countdown s).render]),
   toJson (seconds.map fun s => tuple [toJson s, toJson (Format.ago s).render]))

def specials : List Float :=
  [Float.nan, Float.inf, -Float.inf, 0, -0, 1e-320, -1e-320, 1e-300, 1e308, -1e308,
    1, 100, 100.00000000000001, 99.99999999999999, 1e2 + 1e-13]

def percents : List Float :=
  specials ++ [-3, -0.5, 0.1, 4.9, 5, 5.000001, 12.5, 25, 37.5, 49.99, 50, 62.5, 75, 87.5, 95,
    99.9, 100.0001, 150] ++ (List.range 101).map (fun i => i.toFloat * 0.999)

def barVectors : Json :=
  toJson <| percents.flatMap fun p =>
    (List.range 13 ++ [40, 100]).map fun w =>
      tuple [toJson p.toBits.toNat, toJson w, toJson (Bar.bar p w)]

def modeName : Cache.Mode → String
  | .auto => "auto"
  | .manual => "manual"

def refreshVectors : Json :=
  let stamps : List (Option Int) := [none, some 0, some 100, some 1000]
  let nows : List Int := [-500, 0, 29, 30, 99, 129, 130, 299, 300, 399, 400, 1000, 1029, 1030,
    1299, 1300]
  toJson <| stamps.flatMap fun cached => stamps.flatMap fun last => nows.flatMap fun now =>
    [Cache.Mode.auto, .manual].map fun mode =>
      let source := Cache.pick now cached last
      Json.mkObj [
        ("cached", toJson cached), ("last", toJson last), ("now", toJson now),
        ("mode", toJson (modeName mode)),
        ("source", toJson (match source with | .last => "last" | .cached => "cached")),
        ("fetch", toJson (Cache.shouldFetch (source.get cached last) now mode))]

/-- Payload: `(used_percent, reset_at)`. -/
def codexVectors : Json :=
  let windows : List (Option (Nat × Nat × Nat)) :=
    [none, some (Codex.fiveHours, 28, 1), some (Codex.week, 79, 2), some (60, 5, 3),
      some (Codex.fiveHours, 11, 4), some (Codex.fiveHours, 28, 9), some (Codex.week, 12, 5)]
  toJson <| windows.flatMap fun p => windows.map fun s =>
    let u := Codex.classify p s
    let window := fun (w : Option (Nat × Nat × Nat)) =>
      w.elim Json.null fun (len, pct, reset) => tuple [toJson len, toJson pct, toJson reset]
    let result := fun (w : Option (Nat × Nat)) =>
      w.elim Json.null fun (pct, reset) => tuple [toJson pct, toJson reset]
    Json.mkObj [("primary", window p), ("secondary", window s),
      ("five_hour", result u.fiveHour), ("weekly", result u.weekly)]

def vectors : Json :=
  let (countdown, ago) := formatVectors
  Json.mkObj [("countdown", countdown), ("ago", ago), ("bar", barVectors),
    ("refresh", refreshVectors), ("codex", codexVectors)]

/-! ### Axiom sampling -/

/-- Special values, every bar input, and pseudo-random bit patterns. -/
def floatSamples : Array Float := Id.run do
  let mut xs := (percents ++ specials.map (· / 100) ++ [0.99, 1.0000000000000002,
    0.9999999999999999, 9007199254740992, 9007199254740993, 18446744073709551616]).toArray
  let mut seed : UInt64 := 0x9E3779B97F4A7C15
  for _ in [0:200000] do
    seed := seed * 6364136223846793005 + 1442695040888963407
    xs := xs.push (Float.ofBits seed)
    -- Also sample near the bounds the axioms compare against.
    xs := xs.push (Float.ofBits ((0x4059000000000000 : UInt64) + (seed >>> 44) - 0x80000))
  return xs

def widthSamples : List Nat :=
  List.range 64 ++ [100, 1000, 2 ^ 52, 2 ^ 53 - 1, 2 ^ 53]

def implies (a b : Bool) : Bool := !a || b
def nanOrLe (x y : Float) : Bool := x.isNaN || x ≤ y

def axiomFailures : List String := Id.run do
  let mut bad := #[]
  for x in floatSamples do
    for y in [(0 : Float), 1, 100, 1e308, Float.inf, -Float.inf] do
      if !implies (!y.isNaN && !(y < x)) (nanOrLe x y) then bad := bad.push s!"le_of_not_lt {x} {y}"
    if !implies (nanOrLe x 100) (nanOrLe (x / 100) 1) then bad := bad.push s!"div_100_le_one {x}"
    for w in widthSamples do
      let n := Float.ofNat w
      if !implies (nanOrLe x 1) (nanOrLe (x * n) n) then bad := bad.push s!"mul_le_of_le_one {x} {w}"
      if !implies (nanOrLe x n) (nanOrLe x.round n) then bad := bad.push s!"round_le_ofNat {x} {w}"
      if !implies (w ≤ Bar.exactNatBound && nanOrLe x n) (x.toUInt64.toNat ≤ w) then
        bad := bad.push s!"toUInt64_le {x} {w}"
  return bad.toList

def main (args : List String) : IO UInt32 := do
  if args == ["--check-axioms"] then
    let bad := axiomFailures
    for b in bad.take 20 do IO.eprintln s!"axiom violated: {b}"
    IO.println s!"sampled {floatSamples.size} floats × {widthSamples.length} widths: {bad.length} violations"
    return if bad.isEmpty then 0 else 1
  IO.println vectors.pretty
  return 0
