/-!
# `format::countdown` and `format::ago`

Both are modelled over `s = d.num_seconds()`. chrono computes `num_minutes`, `num_hours` and
`num_days` as `num_seconds() / k` with Rust's truncating `/`, and the Rust code uses the
truncating `%`, so `Int.tdiv` / `Int.tmod` over `s` is exact.
-/

namespace AiUsagePane.Format

/-- What `countdown` shows, before rendering. -/
inductive Countdown where
  | now
  | underMinute
  | minutes (m : Int)
  | hoursMinutes (h m : Int)
  | daysHours (d h : Int)
  deriving DecidableEq, Repr

def countdown (s : Int) : Countdown :=
  if s ≤ 0 then .now
  else
    let d := s.tdiv 86400
    let h := (s.tdiv 3600).tmod 24
    let m := (s.tdiv 60).tmod 60
    if d = 0 ∧ h = 0 ∧ m = 0 then .underMinute
    else if d = 0 ∧ h = 0 then .minutes m
    else if d = 0 then .hoursMinutes h m
    else .daysHours d h

/-- Rust's `{m:02}` for `0 ≤ m`. -/
def pad2 (n : Int) : String := if n < 10 then "0" ++ toString n else toString n

def Countdown.render : Countdown → String
  | .now => "now"
  | .underMinute => "<1m"
  | .minutes m => s!"{m}m"
  | .hoursMinutes h m => s!"{h}h{pad2 m}m"
  | .daysHours d h => s!"{d}d{h}h"

/-- The spec: every shown field is in range, and the shown time is the remaining time truncated
to the shown precision (never more than what is left, less by under one unit). -/
def Countdown.Valid (s : Int) : Countdown → Prop
  | .now => s ≤ 0
  | .underMinute => 0 < s ∧ s < 60
  | .minutes m => 1 ≤ m ∧ m ≤ 59 ∧ m * 60 ≤ s ∧ s < (m + 1) * 60
  | .hoursMinutes h m =>
      1 ≤ h ∧ h ≤ 23 ∧ 0 ≤ m ∧ m ≤ 59 ∧ h * 3600 + m * 60 ≤ s ∧ s < h * 3600 + (m + 1) * 60
  | .daysHours d h =>
      1 ≤ d ∧ 0 ≤ h ∧ h ≤ 23 ∧ d * 86400 + h * 3600 ≤ s ∧ s < d * 86400 + (h + 1) * 3600

theorem countdown_valid (s : Int) : (countdown s).Valid s := by
  unfold countdown
  split
  · simp_all [Countdown.Valid]
  · have hs : 0 ≤ s := by omega
    have h3600 : 0 ≤ s / 3600 := Int.ediv_nonneg hs (by decide)
    have h60 : 0 ≤ s / 60 := Int.ediv_nonneg hs (by decide)
    simp only [Int.tdiv_eq_ediv_of_nonneg hs, Int.tmod_eq_emod_of_nonneg h3600,
      Int.tmod_eq_emod_of_nonneg h60]
    repeat' split
    all_goals simp only [Countdown.Valid]; omega

/-- What `ago` shows, before rendering. -/
inductive Ago where
  | justNow
  | minutes (m : Int)
  | hours (h : Int)
  deriving DecidableEq, Repr

def ago (s : Int) : Ago :=
  let m := s.tdiv 60
  if m < 1 then .justNow
  else if m < 60 then .minutes m
  else .hours (m.tdiv 60)

def Ago.render : Ago → String
  | .justNow => "just now"
  | .minutes m => s!"{m}m ago"
  | .hours h => s!"{h}h ago"

def Ago.Valid (s : Int) : Ago → Prop
  | .justNow => s < 60
  | .minutes m => 1 ≤ m ∧ m ≤ 59 ∧ m * 60 ≤ s ∧ s < (m + 1) * 60
  | .hours h => 1 ≤ h ∧ h * 3600 ≤ s ∧ s < (h + 1) * 3600

theorem ago_valid (s : Int) : (ago s).Valid s := by
  unfold ago
  by_cases hs : 0 ≤ s
  · have h60 : 0 ≤ s / 60 := Int.ediv_nonneg hs (by decide)
    simp only [Int.tdiv_eq_ediv_of_nonneg hs, Int.tdiv_eq_ediv_of_nonneg h60]
    repeat' split
    all_goals simp only [Ago.Valid]; omega
  · -- Negative (clock skew): truncation toward zero gives `m ≤ 0`.
    have hm : 0 ≤ (-s).tdiv 60 := Int.tdiv_nonneg (by omega) (by decide)
    rw [Int.neg_tdiv] at hm
    simp only [show s.tdiv 60 < 1 by omega, ite_true, Ago.Valid]
    omega

end AiUsagePane.Format
