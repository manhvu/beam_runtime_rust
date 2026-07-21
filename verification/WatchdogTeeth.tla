---------------------------- MODULE WatchdogTeeth ----------------------------
(***************************************************************************)
(* Phase 1 teeth-test (VERIFICATION_RESEARCH_PLAN.md).                     *)
(*                                                                         *)
(* Before trusting any model, it must catch a bug we KNOW was real: the    *)
(* historical Tyn watchdog bug, where the watchdog mutated thread state    *)
(* and run queues directly from INTERRUPT context (holding no locks),      *)
(* racing futex_wake's own state-mutation and double-queuing a thread.     *)
(* The fix was to make the watchdog only SET A FLAG in interrupt context   *)
(* and perform the actual state transition at a safe scheduler point that  *)
(* takes the same locks as futex_wake (so it is mutually exclusive).       *)
(*                                                                         *)
(* Minimal faithful model, uniprocessor (the -smp 1 scope Phase 0 earned): *)
(* one blocked thread W, a futex_wake modelled as check-then-commit with   *)
(* an interrupt point between the two, and the watchdog as either the      *)
(* BUGGY interrupt-context mutator or the FIXED flag+safe-point drain.     *)
(*                                                                         *)
(* Expected: BuggyWatchdog = TRUE  -> TLC finds NoDoubleQueue violated.    *)
(*           BuggyWatchdog = FALSE -> NoDoubleQueue holds on all states.   *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANT BuggyWatchdog          \* TRUE = historical bug; FALSE = the shipped fix

W == 1                          \* the one blocked thread (sufficient to show the race)

VARIABLES
    state,          \* "blocked" or "ready" — W's scheduler state
    runq,           \* the run queue (a sequence of thread ids)
    pc,             \* futex_wake's program counter: "check" -> "commit" -> "done"
    observed,       \* futex_wake observed W as blocked at its check step
    flag            \* the deferred rescue flag (fixed watchdog sets this)

vars == <<state, runq, pc, observed, flag>>

Init ==
    /\ state = "blocked"        \* W is parked on the futex
    /\ runq = << >>
    /\ pc = "check"
    /\ observed = FALSE
    /\ flag = FALSE

(*-------------------------------------------------------------------------*)
(* futex_wake(W): the real code checks the waiter's state and then commits  *)
(* the wake (set Ready + enqueue). We split it into two atomic steps so an  *)
(* interrupt (the watchdog ISR) can land BETWEEN them — which is exactly    *)
(* the window the historical bug lived in (the watchdog could not take the  *)
(* spinlock futex_wake held, so it acted without it).                       *)
(*-------------------------------------------------------------------------*)
FwCheck ==
    /\ pc = "check"
    /\ observed' = (state = "blocked")
    /\ pc' = "commit"
    /\ UNCHANGED <<state, runq, flag>>

FwCommit ==
    /\ pc = "commit"
    /\ pc' = "done"
    /\ IF observed
         THEN /\ state' = "ready"
              /\ runq' = Append(runq, W)
         ELSE UNCHANGED <<state, runq>>
    /\ UNCHANGED <<observed, flag>>

(*-------------------------------------------------------------------------*)
(* The watchdog, two variants.                                             *)
(*-------------------------------------------------------------------------*)

\* BUGGY: interrupt-context mutation, no lock. It can fire between FwCheck
\* and FwCommit; both then enqueue W -> W appears twice on the run queue.
WatchdogBuggy ==
    /\ BuggyWatchdog
    /\ state = "blocked"
    /\ state' = "ready"
    /\ runq' = Append(runq, W)
    /\ UNCHANGED <<pc, observed, flag>>

\* FIXED: in interrupt context, only set a flag. No state/queue mutation.
WatchdogFixed ==
    /\ ~BuggyWatchdog
    /\ state = "blocked"
    /\ flag' = TRUE
    /\ UNCHANGED <<state, runq, pc, observed>>

\* The safe-point drain (process_rescues). It takes the same locks as
\* futex_wake, so it is mutually exclusive with futex_wake's critical
\* section: modelled by requiring pc # "commit" (cannot interleave inside
\* the wake), and it re-checks state under that exclusion.
ProcessRescue ==
    /\ ~BuggyWatchdog
    /\ flag = TRUE
    /\ pc # "commit"
    /\ IF state = "blocked"
         THEN /\ state' = "ready"
              /\ runq' = Append(runq, W)
         ELSE UNCHANGED <<state, runq>>
    /\ flag' = FALSE
    /\ UNCHANGED <<pc, observed>>

\* Terminal stutter so finished executions are not reported as deadlocks.
Terminating ==
    /\ pc = "done"
    /\ flag = FALSE
    /\ UNCHANGED vars

Next ==
    \/ FwCheck \/ FwCommit
    \/ WatchdogBuggy \/ WatchdogFixed \/ ProcessRescue
    \/ Terminating

Spec == Init /\ [][Next]_vars

(*-------------------------------------------------------------------------*)
(* The safety property the historical bug violates: no thread is on the    *)
(* run queue more than once.                                               *)
(*-------------------------------------------------------------------------*)
NoDoubleQueue == \A i, j \in DOMAIN runq : (runq[i] = runq[j]) => (i = j)

=============================================================================
