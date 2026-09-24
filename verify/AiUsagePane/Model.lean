/-!
# `model::ProviderState::apply`

The usage payload and the error text are abstract: `apply` never looks inside them.
-/

namespace AiUsagePane.Model

structure ProviderState (U : Type) where
  usage : Option U
  error : Option String

def ProviderState.apply {U : Type} (s : ProviderState U) : Except String U → ProviderState U
  | .ok u => { usage := some u, error := none }
  | .error e => { s with error := some e }

variable {U : Type} (s : ProviderState U)

/-- Once there is usage to show, no fetch result takes it away. -/
theorem apply_keeps_usage (r : Except String U) :
    s.usage.isSome → (s.apply r).usage.isSome := by
  cases r <;> simp_all [ProviderState.apply]

/-- A failed fetch leaves the last good usage untouched. -/
theorem apply_error_usage (e : String) : (s.apply (.error e)).usage = s.usage := rfl

/-- The error shown is exactly the latest fetch's error. -/
theorem apply_error (r : Except String U) :
    (s.apply r).error = match r with | .ok _ => none | .error e => some e := by
  cases r <;> rfl

end AiUsagePane.Model
