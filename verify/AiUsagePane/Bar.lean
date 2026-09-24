/-!
# `format::bar`

```rust
let filled = ((percent.clamp(0.0, 100.0) / 100.0) * width as f64).round() as usize;
format!("{}{}", "█".repeat(filled), "░".repeat(width - filled))
```

Lean's `Float` is IEEE-754 binary64 like Rust's `f64`, `Float.round` is C `round` (half away
from zero, like `f64::round`), and `Float.toUInt64` saturates and maps NaN to 0 like Rust's
`as` casts (`usize` is 64-bit on the supported targets).

The property proved is `filled ≤ width`. In Rust that is what keeps `width - filled` from
panicking on underflow; in Lean `-` on `Nat` saturates, so it is stated separately.

## Trusted base

The core library has no monotonicity lemmas for `Float` and `Float.round` is opaque, so the
IEEE-754 facts the proof needs are the axioms below. Each is stated with its NaN case, holds
for ±0, ±∞ and subnormals, and is sampled against the compiled (C) float operations by
`lake exe gen --check-axioms`.
-/

namespace AiUsagePane.Bar

/-- Largest `n` with every natural `≤ n` exactly representable as a `Float`. -/
def exactNatBound : Nat := 2 ^ 53

/-- Trichotomy for a non-NaN bound: `¬ (y < x)` leaves `x ≤ y` or `x` is NaN. -/
axiom le_of_not_lt (x y : Float) :
    y.isNaN = false → ¬ y < x → x.isNaN = true ∨ x ≤ y

/-- Division rounds monotonically, and `100 / 100 = 1` exactly. -/
axiom div_100_le_one (x : Float) :
    x.isNaN = true ∨ x ≤ 100 → (x / 100).isNaN = true ∨ x / 100 ≤ 1

/-- Multiplication rounds monotonically, and `1 * n = n`.
(`-∞ * 0` and `0 * ∞` are NaN, hence the NaN case.) -/
axiom mul_le_of_le_one (x : Float) (w : Nat) :
    x.isNaN = true ∨ x ≤ 1 → (x * Float.ofNat w).isNaN = true ∨ x * Float.ofNat w ≤ Float.ofNat w

/-- `round` is monotone and fixes integers (and ∞). -/
axiom round_le_ofNat (x : Float) (w : Nat) :
    x.isNaN = true ∨ x ≤ Float.ofNat w → x.round.isNaN = true ∨ x.round ≤ Float.ofNat w

/-- The saturating cast is monotone, sends NaN and negatives to 0, and is exact on
`Float.ofNat w` for `w ≤ 2^53`. -/
axiom toUInt64_le (x : Float) (w : Nat) :
    w ≤ exactNatBound → x.isNaN = true ∨ x ≤ Float.ofNat w → x.toUInt64.toNat ≤ w

/-- `f64::clamp`: `if self < min { min }`, then `if self > max { max }`; NaN passes through. -/
def clamp (x lo hi : Float) : Float :=
  let x := if x < lo then lo else x
  if x > hi then hi else x

def filled (percent : Float) (width : Nat) : Nat :=
  ((clamp percent 0 100 / 100) * Float.ofNat width).round.toUInt64.toNat

def bar (percent : Float) (width : Nat) : String :=
  String.ofList (List.replicate (filled percent width) '█') ++
    String.ofList (List.replicate (width - filled percent width) '░')

theorem clamp_le_100 (x : Float) : (clamp x 0 100).isNaN = true ∨ clamp x 0 100 ≤ 100 := by
  unfold clamp
  generalize (if x < 0 then 0 else x) = y
  by_cases h : y > 100
  · simp only [h, ↓reduceIte]; exact Or.inr (by decide)
  · simp only [h, ↓reduceIte]; exact le_of_not_lt _ _ (by decide) h

/-- No input — NaN, ±∞, out of range — makes `filled` exceed `width`, as long as `width` is
exactly representable as a `Float`. -/
theorem filled_le (percent : Float) {width : Nat} (hw : width ≤ exactNatBound) :
    filled percent width ≤ width :=
  toUInt64_le _ _ hw <| round_le_ofNat _ _ <| mul_le_of_le_one _ _ <|
    div_100_le_one _ (clamp_le_100 percent)

theorem bar_length (percent : Float) {width : Nat} (hw : width ≤ exactNatBound) :
    (bar percent width).length = width := by
  have := filled_le percent hw
  simp [bar, String.length_append, String.length_ofList]
  omega

end AiUsagePane.Bar
