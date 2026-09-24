/-!
# `codex::parse` window classification

```rust
for w in [primary_window, secondary_window].into_iter().flatten() {
    let slot = match w.limit_window_seconds {
        FIVE_HOURS_SECS => &mut usage.five_hour,
        WEEK_SECS => &mut usage.weekly,
        _ => continue,
    };
    if slot.as_ref().is_none_or(|old| more_used(&window, old)) { *slot = Some(window); }
}
```

A window is its length in seconds plus `(used_percent, reset_at)`. `more_used` compares those
lexicographically with `f64::total_cmp`, which on the non-negative percentages the endpoint
returns agrees with the order on `Nat` used here.
-/

namespace AiUsagePane.Codex

def fiveHours : Nat := 5 * 3600
def week : Nat := 7 * 24 * 3600

/-- `(used_percent, reset_at)` -/
abbrev Window := Nat × Nat

structure Usage where
  fiveHour : Option Window
  weekly : Option Window
  deriving DecidableEq, Repr

def moreUsed (a b : Window) : Bool := a.1 > b.1 || (a.1 = b.1 && a.2 > b.2)

/-- What a slot holds after `new` arrives. -/
def keep (new : Window) : Option Window → Window
  | none => new
  | some old => if moreUsed new old then new else old

def classifyOne (u : Usage) : Nat × Window → Usage
  | (len, w) =>
    if len = fiveHours then { u with fiveHour := some (keep w u.fiveHour) }
    else if len = week then { u with weekly := some (keep w u.weekly) }
    else u

def classify (primary secondary : Option (Nat × Window)) : Usage :=
  [primary, secondary].filterMap id |>.foldl classifyOne ⟨none, none⟩

/-- Keeping the more used of two windows does not depend on which came first. -/
theorem keep_comm (a b : Window) :
    (if moreUsed b a then b else a) = (if moreUsed a b then a else b) := by
  obtain ⟨a1, a2⟩ := a
  obtain ⟨b1, b2⟩ := b
  simp only [moreUsed]
  by_cases h1 : b1 > a1 <;> by_cases h2 : a1 > b1 <;> by_cases h3 : b2 > a2 <;>
    by_cases h4 : a2 > b2 <;> simp [h1, h2, h3, h4, Prod.ext_iff] <;> omega

/-- The primary/secondary order never matters. -/
theorem classify_comm (p s : Option (Nat × Window)) : classify p s = classify s p := by
  cases p with
  | none => cases s <;> rfl
  | some a =>
    cases s with
    | none => rfl
    | some b =>
      obtain ⟨la, wa⟩ := a
      obtain ⟨lb, wb⟩ := b
      simp only [classify, List.filterMap, id, List.foldl, classifyOne]
      by_cases ha5 : la = fiveHours <;> by_cases haw : la = week <;>
        by_cases hb5 : lb = fiveHours <;> by_cases hbw : lb = week <;>
        (simp_all [fiveHours, week, keep]) <;> exact keep_comm _ _

/-- Of two windows of one length, the more used one is shown. -/
theorem classify_same_length (a b : Window) (h : moreUsed a b) :
    classify (some (fiveHours, a)) (some (fiveHours, b)) = ⟨some a, none⟩ ∧
      classify (some (fiveHours, b)) (some (fiveHours, a)) = ⟨some a, none⟩ := by
  simp [classify, List.filterMap, List.foldl, classifyOne, keep, h]
  obtain ⟨a1, a2⟩ := a
  obtain ⟨b1, b2⟩ := b
  simp only [moreUsed] at *
  by_cases h1 : b1 > a1 <;> simp_all <;> omega

end AiUsagePane.Codex
