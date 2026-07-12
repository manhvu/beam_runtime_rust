/* Trivial static-NIF spike for Tyn (CRYPTO_NIF.md Step 1).
 *
 * Goal: prove erlang:load_nif/2 resolves a *statically linked* NIF on Tyn,
 * which has no dynamic linker (no dlopen). Built into beam.smp via
 * --enable-static-nifs; compiled with -DSTATIC_ERLANG_NIF so ERL_NIF_INIT
 * emits the static-mode init symbol that ERTS's generated table references
 * (instead of the dlopen'd `nif_init`).
 *
 * The Erlang side (src/erl/tyn_nif.erl) calls erlang:load_nif("tyn_nif", 0)
 * in on_load; tyn_nif:add(1,2) should return 3 from this C code. */
#include <erl_nif.h>

static ERL_NIF_TERM add_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    long a, b;
    if (argc != 2 ||
        !enif_get_long(env, argv[0], &a) ||
        !enif_get_long(env, argv[1], &b)) {
        return enif_make_badarg(env);
    }
    return enif_make_long(env, a + b);
}

static ErlNifFunc nif_funcs[] = {
    {"add", 2, add_nif},
};

/* Module name MUST match the Erlang module (tyn_nif). In static mode this
 * expands to tyn_nif's static init entry, not a dlopen symbol. */
ERL_NIF_INIT(tyn_nif, nif_funcs, NULL, NULL, NULL, NULL)
