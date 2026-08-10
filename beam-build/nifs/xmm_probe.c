/* XMM-preemption detector NIF for Tyn (directions/XMM_DETECTOR.md).
 *
 * Purpose: the amplifier's md5/bincopy detectors catch MEMORY corruption, not
 * XMM-register corruption (scalar md5 can't be affected by XMM), and BeamAsm
 * boxes floats too fast to keep a value live in XMM across the ~10 ms tick.
 * This NIF keeps a KNOWN value live in xmm0/xmm1 across a long, CALL-FREE spin
 * so a timer preemption lands while it is live, then checks it. If Tyn's
 * preemptive context switch loses/garbles XMM, the value comes back wrong.
 *
 * The spin does NOT touch xmm0/xmm1 — they stay in the physical registers across
 * the loop (verify in the disassembly: no xmm spill inside the loop). A mismatch
 * therefore means the register itself was corrupted by a preemption, i.e. it is
 * a true XMM-register-corruption detector (unlike md5/bincopy). Runs in
 * beam.smp .text (is_user) so the timer redirects it through sched_yield_-
 * trampoline — exactly the path the fix targets.
 *
 * probe(Outer, Spin) -> integer(): count of the Outer live-spans in which xmm0
 * or xmm1 came back != its known value.
 *
 * Erlang side: src/erl/xmm_probe.erl calls erlang:load_nif("xmm_probe", 0).
 * Built into beam.smp via --enable-static-nifs (compiled -DSTATIC_ERLANG_NIF). */
#include <erl_nif.h>
#include <stdint.h>

static ERL_NIF_TERM probe_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    long outer, spin;
    if (argc != 2 ||
        !enif_get_long(env, argv[0], &outer) ||
        !enif_get_long(env, argv[1], &spin)) {
        return enif_make_badarg(env);
    }

    const uint64_t V0 = 0x0123456789ABCDEFULL;
    const uint64_t V1 = 0x55AA55AA33CC33CCULL;
    long bad = 0;

    for (long i = 0; i < outer; i++) {
        uint64_t o0 = 0, o1 = 0;
        long cnt = spin;
        /* Load knowns into xmm0/xmm1, spin on a GP counter (call-free, no xmm
         * touch), then read xmm0/xmm1 back. xmm0/xmm1 stay live in the physical
         * registers across the whole loop; a preemption that clobbers XMM and
         * fails to restore it corrupts them. */
        __asm__ __volatile__ (
            "movq %3, %%xmm0\n\t"
            "movq %4, %%xmm1\n\t"
            "1:\n\t"
            "dec %0\n\t"
            "jnz 1b\n\t"
            "movq %%xmm0, %1\n\t"
            "movq %%xmm1, %2\n\t"
            : "+r"(cnt), "=r"(o0), "=r"(o1)
            : "r"(V0), "r"(V1)
            : "xmm0", "xmm1", "cc"
        );
        if (o0 != V0 || o1 != V1) bad++;
    }

    return enif_make_long(env, bad);
}

static ErlNifFunc nif_funcs[] = {
    {"probe", 2, probe_nif},
};

/* Module name MUST match the Erlang module (xmm_probe). */
ERL_NIF_INIT(xmm_probe, nif_funcs, NULL, NULL, NULL, NULL)
