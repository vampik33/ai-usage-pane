import AiUsagePane

/-! Lists what each headline theorem rests on. Only Lean's standard axioms (`propext`,
`Classical.choice`, `Quot.sound`) and, for `bar`, the float axioms in `AiUsagePane.Bar` may appear. -/

open AiUsagePane

#print axioms Format.countdown_valid
#print axioms Format.ago_valid
#print axioms Bar.filled_le
#print axioms Bar.bar_length
#print axioms Model.apply_keeps_usage
#print axioms Model.apply_error
#print axioms Cache.shouldFetch_false_iff
#print axioms Cache.step_blocked
#print axioms Cache.run_throttled
#print axioms Cache.run_floor
#print axioms Codex.classify_comm
#print axioms Codex.classify_same_length
