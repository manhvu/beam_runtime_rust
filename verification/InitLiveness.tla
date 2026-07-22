---------------------------- MODULE InitLiveness ----------------------------
(***************************************************************************)
(* Phase 1, the mechanism-pinning model. Phase 0 identified the shape of   *)
(* the cold-boot stall but did not PIN it: schedulers park on their        *)
(* ethr_events, a thread blocks on a contended mutex whose owner is itself  *)
(* parked, no wake is ever issued (ever=0), real blocking causes it,        *)
(* spin-yield removes it. The open question: the SAME ERTS runs fine on     *)
(* Linux against a real blocking futex, so Tyn's *cooperative uniprocessor* *)
(* scheduling must admit an interleaving Linux's parallelism does not.      *)
(*                                                                         *)
(* This model encodes that hypothesis and runs it as an EXPERIMENT across   *)
(* four combinations of two parameters. Whether the deadlock appears is     *)
(* the result, not the goal — the model is a faithful encoding of the       *)
(* protocol as understood; it is NOT tuned to reproduce the bug. If it is   *)
(* live everywhere, that is a real finding (the deadlock lives in structure *)
(* not yet modelled), and it BOUNDS where the mechanism is not.             *)
(*                                                                         *)
(*   Sched = "uni"  : cooperative uniprocessor — one thread runs at a time; *)
(*                    a real-blocked thread is not runnable; if every       *)
(*                    thread is blocked, the system is stuck (Tyn -smp 1).  *)
(*   Sched = "smp"  : free interleaving — any non-blocked thread may step   *)
(*                    (a model of Linux's parallelism).                     *)
(*   Valve = "block"     : futex_wait really blocks (removes from runnable).*)
(*   Valve = "spinyield" : futex_wait yields but stays runnable & re-checks *)
(*                    (Tyn's spin-yield valve — the shipped fix).           *)
(*                                                                         *)
(* Scope (Phase-0-earned): uniprocessor is the point of comparison; the     *)
(* futex is TRUSTED and abstracted (block-until-wake + the ethr_event       *)
(* cmpxchg-abort that Phase 0 proved sound); we do NOT re-model the futex.  *)
(*                                                                         *)
(* Structure modelled: two ERTS threads that must each (1) do a unit of     *)
(* init WORK that requires a shared init lock L, then (2) wait on the        *)
(* other's readiness event. This is the minimal shape with both a mutex     *)
(* (the contended 0x…3964 in the trace) and cross-thread event waits (the   *)
(* parked schedulers). The experiment: can the wait-graph close into a      *)
(* cycle with no wake pending under (uni, block) but not the others?        *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Sched, Valve

T1 == 1
T2 == 2
Threads == {T1, T2}
Other(t) == IF t = T1 THEN T2 ELSE T1

(* ethr_event values *)
OFF    == "OFF"
ON     == "ON"
WAITER == "WAITER"

VARIABLES
    pc,        \* per thread: init program counter (see steps below)
    ev,        \* [t -> OFF|ON|WAITER] : readiness event thread t SETS; Other(t) waits on it
    lockOwner, \* the init lock L: a thread id, or 0 for free
    blocked,   \* [t -> BOOL] : real-blocked (not runnable) waiting for its event
    running    \* uniprocessor: the thread currently on the CPU (or 0 = none scheduled)

vars == <<pc, ev, lockOwner, blocked, running>>

(* Program counters. Each thread:                                          *)
(*  start  -> acquire the init lock L                                      *)
(*  crit   -> (holding L) publish readiness: set ev[self] = ON, release L  *)
(*  wait   -> wait on Other(self)'s event ev[Other]  (ethr_event protocol) *)
(*  done                                                                   *)
PCs == {"start", "crit", "wait_cas", "wait_block", "done"}

Init ==
    /\ pc = [t \in Threads |-> "start"]
    /\ ev = [t \in Threads |-> OFF]
    /\ lockOwner = 0
    /\ blocked = [t \in Threads |-> FALSE]
    /\ running = 0

(*-------------------------------------------------------------------------*)
(* Scheduling gate. A thread may take a step only if it is runnable, and    *)
(* — under "uni" — only if it is the running thread (or the CPU is free and *)
(* it grabs it). Under "smp", any runnable thread may step.                 *)
(*-------------------------------------------------------------------------*)
Runnable(t) == ~blocked[t] /\ pc[t] # "done"

CanStep(t) ==
    /\ Runnable(t)
    /\ (Sched = "smp" \/ running = 0 \/ running = t)

\* On "uni", grabbing/keeping the CPU is folded into every step.
TakeCPU(t) == running' = (IF Sched = "uni" THEN t ELSE running)

\* When a thread blocks or finishes, under "uni" it relinquishes the CPU.
DropCPU == running' = 0

(*-------------------------------------------------------------------------*)
(* Steps.                                                                   *)
(*-------------------------------------------------------------------------*)

\* Acquire the init lock (or wait for it — modelled as: only enabled when free).
Acquire(t) ==
    /\ CanStep(t)
    /\ pc[t] = "start"
    /\ lockOwner = 0
    /\ lockOwner' = t
    /\ pc' = [pc EXCEPT ![t] = "crit"]
    /\ TakeCPU(t)
    /\ UNCHANGED <<ev, blocked>>

\* In the critical section: publish readiness (set own event ON, waking a
\* partner already parked on it), then release the lock.
Crit(t) ==
    /\ CanStep(t)
    /\ pc[t] = "crit"
    /\ lockOwner = t
    /\ ev' = [ev EXCEPT ![t] = ON]
    \* setting ev[t] = ON wakes Other(t) iff it was parked (WAITER) on ev[t]
    /\ blocked' = IF ev[t] = WAITER
                    THEN [blocked EXCEPT ![Other(t)] = FALSE]
                    ELSE blocked
    /\ lockOwner' = 0
    /\ pc' = [pc EXCEPT ![t] = "wait_cas"]
    /\ TakeCPU(t)

\* ethr_event wait, step 1: the cmpxchg OFF->WAITER (with abort).
\* If the partner's event is already ON, the wait is aborted (proceed).
\* If it is OFF, commit to WAITER and go to block.
WaitCas(t) ==
    /\ CanStep(t)
    /\ pc[t] = "wait_cas"
    /\ LET e == ev[Other(t)] IN
         IF e = OFF
           THEN /\ ev' = [ev EXCEPT ![Other(t)] = WAITER]
                /\ pc' = [pc EXCEPT ![t] = "wait_block"]
                /\ UNCHANGED blocked
           ELSE \* e = ON (partner already published) — abort the wait, done
                /\ pc' = [pc EXCEPT ![t] = "done"]
                /\ UNCHANGED <<ev, blocked>>
    /\ TakeCPU(t)
    /\ UNCHANGED lockOwner

\* ethr_event wait, step 2: block on the futex (or spin-yield).
WaitBlock(t) ==
    /\ CanStep(t)
    /\ pc[t] = "wait_block"
    /\ LET e == ev[Other(t)] IN
         IF e # WAITER
           THEN \* woken (or changed): proceed
                /\ pc' = [pc EXCEPT ![t] = "done"]
                /\ UNCHANGED <<blocked, running>>
           ELSE IF Valve = "block"
                  THEN \* real block: leave runnable set, relinquish CPU
                       /\ blocked' = [blocked EXCEPT ![t] = TRUE]
                       /\ DropCPU
                       /\ UNCHANGED pc
                  ELSE \* spin-yield: stay runnable, relinquish CPU, re-check later
                       /\ DropCPU
                       /\ UNCHANGED <<pc, blocked>>
    /\ UNCHANGED <<ev, lockOwner>>

\* Reaching done relinquishes the CPU (so the other thread can run).
Finish(t) ==
    /\ pc[t] = "done"
    /\ running = t
    /\ DropCPU
    /\ UNCHANGED <<pc, ev, lockOwner, blocked>>

Next ==
    \/ \E t \in Threads : Acquire(t) \/ Crit(t) \/ WaitCas(t) \/ WaitBlock(t) \/ Finish(t)

(*-------------------------------------------------------------------------*)
(* Fairness. This is the fussy part: a liveness "violation" under the wrong *)
(* fairness is an artifact. We assume weak fairness on each thread's        *)
(* enabled steps — a continuously-runnable thread eventually runs. Under    *)
(* "uni" this is exactly the guarantee a fair cooperative scheduler gives;  *)
(* under "smp" it is per-thread progress. We do NOT assume fairness of the  *)
(* wake itself (that would assume away the very lost-wake question).        *)
(*-------------------------------------------------------------------------*)
Fairness ==
    /\ \A t \in Threads : WF_vars(Acquire(t) \/ Crit(t) \/ WaitCas(t)
                                   \/ WaitBlock(t) \/ Finish(t))

Spec == Init /\ [][Next]_vars /\ Fairness

(*-------------------------------------------------------------------------*)
(* The liveness property: every thread eventually finishes init.           *)
(* A deadlock (both parked, no wake to come) makes this FALSE.             *)
(*-------------------------------------------------------------------------*)
AllDone == \A t \in Threads : pc[t] = "done"
Terminates == <>AllDone

\* Safety companion: never all-blocked (the concrete deadlock signature).
NotAllBlocked == ~(\A t \in Threads : blocked[t])

=============================================================================
