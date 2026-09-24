/-!
# `cache::refresh` throttling

Times are whole seconds; only `0 < minAge m` is used by the protocol proofs, so they hold in any
unit. A snapshot is reduced to its `attempted_at`, the only field the decision reads.

## One call

```rust
let attempted = |s: &Snapshot| s.attempted_at.filter(|&t| t <= now);
let mut snap = if attempted(&last) > attempted(&cached) { last } else { cached };
if attempted(&snap).is_some_and(|t| now - t < min_age) { return /* no fetch */ }
```

## Many panes

Each pane calls `refresh` sequentially (`ui::App::spawn_refresh` refuses while one is in flight,
and the result replaces the pane's snapshot before the next call). Calls that hold the lock are
serialised by it, so each is one atomic `step`, and `now` is read once the lock is held, so the
steps' `now`s increase unless the wall clock steps back.

A call whose lock failed never writes the cache and reads it through an atomic rename, so it acts
at the moment it reads. Its `now` is in lock order too unless another call holds the lock at that
moment; the lock file is shared, so lock failures are normally all-or-nothing.

`Event.saved` is whether the new snapshot reached the cache (lock and write both succeeded).
-/

namespace AiUsagePane.Cache

inductive Mode where
  | auto
  | manual
  deriving DecidableEq, Repr

/-- `AUTO_TTL` and `MANUAL_FLOOR`, in seconds. -/
def minAge : Mode → Int
  | .auto => 300
  | .manual => 30

theorem minAge_pos (m : Mode) : 0 < minAge m := by cases m <;> decide

theorem minAge_floor (m : Mode) : minAge .manual ≤ minAge m := by cases m <;> decide

/-- Rust's `a > b` on `Option<DateTime>`: `None` is less than every `Some`. -/
def after : Option Int → Option Int → Bool
  | some a, some b => decide (a > b)
  | some _, none => true
  | none, _ => false

/-- The `attempted` closure: a time in the future counts as never attempted. -/
def seen (now : Int) (a : Option Int) : Option Int := a.filter (fun t => decide (t ≤ now))

inductive Source where
  | last
  | cached
  deriving DecidableEq, Repr

def Source.get {β : Type} (cached last : β) : Source → β
  | .last => last
  | .cached => cached

/-- Which snapshot to keep, given the two `attempted` values. -/
def pickSeen (cached last : Option Int) : Source :=
  if after last cached then .last else .cached

def pick (now : Int) (cached last : Option Int) : Source :=
  pickSeen (seen now cached) (seen now last)

def shouldFetch (attempted : Option Int) (now : Int) (mode : Mode) : Bool :=
  match seen now attempted with
  | none => true
  | some t => !decide (now - t < minAge mode)

theorem seen_of_le {t now : Int} (h : t ≤ now) : seen now (some t) = some t := by
  simp [seen, h]

theorem seen_of_gt {t now : Int} (h : ¬t ≤ now) : seen now (some t) = none := by
  simp [seen]; omega

/-- **Liveness.** A call is held back only by an attempt in the last `minAge` of its clock; no
timestamp, past or future, blocks fetching for longer. -/
theorem shouldFetch_false_iff (a : Option Int) (now : Int) (mode : Mode) :
    shouldFetch a now mode = false ↔ ∃ t, a = some t ∧ t ≤ now ∧ now < t + minAge mode := by
  cases a with
  | none => simp [shouldFetch, seen]
  | some t =>
    by_cases h : t ≤ now
    · simp only [shouldFetch, seen_of_le h, Bool.not_eq_false', decide_eq_true_eq,
        Option.some.injEq]
      constructor
      · intro h'; exact ⟨t, rfl, h, by omega⟩
      · rintro ⟨_, rfl, _, h'⟩; omega
    · simp only [shouldFetch, seen_of_gt h]
      simp only [Bool.true_eq_false, false_iff, not_exists, not_and, Option.some.injEq]
      intro _ ht; subst ht; omega

/-! ### Order on `Option Int` with `none` at the bottom -/

def ole : Option Int → Option Int → Prop
  | none, _ => True
  | some _, none => False
  | some a, some b => a ≤ b

theorem ole_trans {a b c : Option Int} : ole a b → ole b c → ole a c := by
  cases a <;> cases b <;> cases c <;> simp_all [ole]; omega

/-- The kept snapshot is at least as new as both candidates. -/
theorem ole_pickSeen (cached last : Option Int) :
    ole cached ((pickSeen cached last).get cached last) ∧
      ole last ((pickSeen cached last).get cached last) := by
  unfold pickSeen
  split <;> cases cached <;> cases last <;> simp_all [after, Source.get, ole] <;> omega

theorem seen_get (now : Int) (src : Source) (cached last : Option Int) :
    seen now (src.get cached last) = src.get (seen now cached) (seen now last) := by
  cases src <;> rfl


/-! ### The multi-pane system -/

structure Event where
  pane : Nat
  now : Int
  mode : Mode
  saved : Bool

structure Fetch where
  pane : Nat
  time : Int
  mode : Mode
  saved : Bool

structure State where
  cache : Option Int
  /-- Each pane's in-memory snapshot (`last`). -/
  mem : Nat → Option Int

def setMem (s : State) (p : Nat) (v : Option Int) : Nat → Option Int :=
  fun q => if q = p then v else s.mem q

/-- The `attempted_at` of the snapshot the call keeps. -/
def chosen (s : State) (e : Event) : Option Int :=
  (pick e.now s.cache (s.mem e.pane)).get s.cache (s.mem e.pane)

def fetched (s : State) (e : Event) : State :=
  { cache := if e.saved then some e.now else s.cache, mem := setMem s e.pane (some e.now) }

def step (s : State) (e : Event) : State × Option Fetch :=
  if shouldFetch (chosen s e) e.now e.mode then
    (fetched s e, some ⟨e.pane, e.now, e.mode, e.saved⟩)
  else
    ({ s with mem := setMem s e.pane (chosen s e) }, none)

/-- Runs the events in lock order; returns the final state and the fetches, in order. -/
def run (s : State) : List Event → State × List Fetch
  | [] => (s, [])
  | e :: es =>
    let r := step s e
    let rest := run r.1 es
    (rest.1, r.2.toList ++ rest.2)

theorem step_of_fetch {s : State} {e : Event} (h : shouldFetch (chosen s e) e.now e.mode) :
    step s e = (fetched s e, some ⟨e.pane, e.now, e.mode, e.saved⟩) := by
  simp [step, h]

theorem step_of_skip {s : State} {e : Event} (h : shouldFetch (chosen s e) e.now e.mode = false) :
    step s e = ({ s with mem := setMem s e.pane (chosen s e) }, none) := by
  simp [step, h]

/-- A call that fetches nothing was held back by an attempt within its `minAge`. -/
theorem step_blocked {s : State} {e : Event} (h : (step s e).2 = none) :
    ∃ t, chosen s e = some t ∧ t ≤ e.now ∧ e.now < t + minAge e.mode := by
  cases hf : shouldFetch (chosen s e) e.now e.mode
  · exact (shouldFetch_false_iff _ _ _).mp hf
  · rw [step_of_fetch hf] at h; simp at h

/-- `f` happened before `g`, and `g` could see it: through the cache, or through its own pane's
memory. Then `g` came at least `g`'s `minAge` later. -/
def Throttled (f g : Fetch) : Prop :=
  (f.saved = true ∨ f.pane = g.pane) → f.time + minAge g.mode ≤ g.time

/-- `s` remembers fetch `f` everywhere a later fetch that must see it looks, with a time no
later than `T`, the clock of the last call. -/
def Covers (s : State) (T : Int) (f : Fetch) : Prop :=
  (f.saved = true → ∃ c, s.cache = some c ∧ f.time ≤ c ∧ c ≤ T) ∧
    ∃ m, s.mem f.pane = some m ∧ f.time ≤ m ∧ m ≤ T

/-- The call's `attempted` value is at least as new as every candidate it sees. -/
theorem seen_chosen (s : State) (e : Event) :
    ole (seen e.now s.cache) (seen e.now (chosen s e)) ∧
      ole (seen e.now (s.mem e.pane)) (seen e.now (chosen s e)) := by
  unfold chosen pick
  rw [seen_get]
  exact ole_pickSeen _ _

/-- A covered fetch visible to the call bounds what the call sees from below. -/
theorem seen_covered {s : State} {T : Int} {e : Event} {f : Fetch} (hf : Covers s T f)
    (hT : T ≤ e.now) (hvis : f.saved = true ∨ f.pane = e.pane) :
    ∃ t, seen e.now (chosen s e) = some t ∧ f.time ≤ t := by
  have hc := seen_chosen s e
  have hle : ole (some f.time) (seen e.now (chosen s e)) := by
    rcases hvis with hs | hsame
    · obtain ⟨c, hc', hfc, hcT⟩ := hf.1 hs
      rw [hc', seen_of_le (by omega)] at hc
      exact ole_trans (by simp [ole]; omega) hc.1
    · obtain ⟨m, hm, hfm, hmT⟩ := hf.2
      rw [hsame] at hm
      rw [hm, seen_of_le (by omega)] at hc
      exact ole_trans (by simp [ole]; omega) hc.2
  cases h : seen e.now (chosen s e) with
  | none => rw [h] at hle; simp [ole] at hle
  | some t => rw [h] at hle; exact ⟨t, rfl, by simpa [ole] using hle⟩

theorem seen_some {now t : Int} {a : Option Int} (h : seen now a = some t) :
    a = some t ∧ t ≤ now := by
  cases a with
  | none => simp [seen] at h
  | some a =>
    simp [seen] at h
    obtain ⟨rfl, h'⟩ := h
    exact ⟨rfl, h'⟩

theorem step_covers (s : State) (e : Event) (f : Fetch) {T : Int} (hT : T ≤ e.now) :
    Covers s T f → Covers (step s e).1 e.now f := by
  intro hf
  obtain ⟨hsc, m, hm, hfm, hmT⟩ := id hf
  cases hfe : shouldFetch (chosen s e) e.now e.mode
  · rw [step_of_skip hfe]
    refine ⟨fun hs => ?_, ?_⟩
    · obtain ⟨c, hc, h1, h2⟩ := hsc hs; exact ⟨c, hc, h1, by omega⟩
    · simp only [setMem]
      split
      · rename_i hp
        -- The pane keeps what it saw, which is at least as new as its own memory.
        obtain ⟨t, ht, hft⟩ := seen_covered hf hT (Or.inr hp)
        obtain ⟨hct, htn⟩ := seen_some ht
        exact ⟨t, hct, hft, htn⟩
      · exact ⟨m, hm, hfm, by omega⟩
  · rw [step_of_fetch hfe]
    refine ⟨fun hs => ?_, ?_⟩
    · obtain ⟨c, hc, h1, h2⟩ := hsc hs
      simp only [fetched]
      split
      · exact ⟨e.now, rfl, by omega, by omega⟩
      · exact ⟨c, hc, h1, by omega⟩
    · simp only [fetched, setMem]
      split
      · exact ⟨e.now, rfl, by omega, by omega⟩
      · exact ⟨m, hm, hfm, by omega⟩

/-- A fetch that happened is recorded where later fetches look. -/
theorem step_covers_new {s : State} {e : Event} {g : Fetch} (h : (step s e).2 = some g) :
    Covers (step s e).1 e.now g := by
  cases hf : shouldFetch (chosen s e) e.now e.mode
  · rw [step_of_skip hf] at h; simp at h
  · rw [step_of_fetch hf] at h ⊢
    simp only [Option.some.injEq] at h
    subst h
    refine ⟨fun hs => ?_, ?_⟩
    · simp only at hs; simp [fetched, hs]
    · simp [fetched, setMem]

theorem step_throttled {s : State} {e : Event} {f g : Fetch} {T : Int} (hf : Covers s T f)
    (hT : T ≤ e.now) (h : (step s e).2 = some g) : Throttled f g := by
  cases hfetch : shouldFetch (chosen s e) e.now e.mode
  · rw [step_of_skip hfetch] at h; simp at h
  · rw [step_of_fetch hfetch] at h
    simp only [Option.some.injEq] at h
    subst h
    intro hvis
    obtain ⟨t, ht, hft⟩ := seen_covered hf hT hvis
    simp only [shouldFetch, ht] at hfetch
    simp at hfetch
    simp only; omega

/-- The wall clock does not step back during the run. -/
def ClockMonotone (es : List Event) : Prop := es.Pairwise (fun e e' => e.now ≤ e'.now)

theorem run_throttled_after (s : State) (es : List Event) (f : Fetch) (T : Int)
    (hf : Covers s T f) (hT : ∀ e ∈ es, T ≤ e.now) (hmono : ClockMonotone es) :
    ∀ g ∈ (run s es).2, Throttled f g := by
  induction es generalizing s T with
  | nil => simp [run]
  | cons e es ih =>
    intro g hg
    rw [ClockMonotone, List.pairwise_cons] at hmono
    have hTe := hT e (by simp)
    simp only [run, List.mem_append] at hg
    rcases hg with hg | hg
    · cases hs : (step s e).2 with
      | none => simp [hs] at hg
      | some g' =>
        simp [hs] at hg; subst hg
        exact step_throttled hf hTe hs
    · exact ih _ e.now (step_covers s e f hTe hf) hmono.1 hmono.2 g hg

/-- **Throttling.** While the clock does not step back, any two fetches in any run, where the
later one can see the earlier one (it reached the cache, or it is the same pane), are at least
the later one's `minAge` apart: `MANUAL_FLOOR` always, `AUTO_TTL` when the later one is
automatic. The initial state is arbitrary, including timestamps from the future. -/
theorem run_throttled (s : State) (es : List Event) (hmono : ClockMonotone es) :
    (run s es).2.Pairwise Throttled := by
  induction es generalizing s with
  | nil => simp [run]
  | cons e es ih =>
    rw [ClockMonotone, List.pairwise_cons] at hmono
    simp only [run]
    cases hs : (step s e).2 with
    | none => simpa using ih _ hmono.2
    | some g =>
      simp only [Option.toList, List.singleton_append, List.pairwise_cons]
      exact ⟨run_throttled_after _ es g e.now (step_covers_new hs) hmono.1 hmono.2, ih _ hmono.2⟩

theorem run_saved (s : State) (es : List Event) (hsaved : ∀ e ∈ es, e.saved = true) :
    ∀ f ∈ (run s es).2, f.saved = true := by
  induction es generalizing s with
  | nil => simp [run]
  | cons e es ih =>
    intro f hf
    simp only [run, List.mem_append] at hf
    rcases hf with hf | hf
    · cases hs : (step s e).2 with
      | none => simp [hs] at hf
      | some g =>
        simp [hs] at hf; subst hf
        cases hfe : shouldFetch (chosen s e) e.now e.mode
        · rw [step_of_skip hfe] at hs; simp at hs
        · rw [step_of_fetch hfe] at hs
          simp only [Option.some.injEq] at hs; subst hs; exact hsaved e (by simp)
    · exact ih _ (fun e he => hsaved e (by simp [he])) f hf

/-- With a working cache, fetches across all panes are at least `MANUAL_FLOOR` apart. -/
theorem run_floor (s : State) (es : List Event) (hmono : ClockMonotone es)
    (hsaved : ∀ e ∈ es, e.saved = true) :
    (run s es).2.Pairwise (fun f g => f.time + minAge .manual ≤ g.time) := by
  have hfs := run_saved s es hsaved
  refine List.Pairwise.imp_of_mem ?_ (run_throttled s es hmono)
  intro f g hf _ h
  have := h (Or.inl (hfs f hf))
  have := minAge_floor g.mode
  omega

end AiUsagePane.Cache
