//! Minimal pure-Rust static NIF for Tyn (CRYPTO_NIF.md Step 1, Rust variant).
//!
//! Confirms a Rust `staticlib` (no_std) linked into beam.smp via
//! --enable-static-nifs loads on Tyn with no dynamic linker — the path the
//! Rust crypto NIF (Option A) will take. Hand-rolls the erl_nif ABI (NIF 2.17,
//! OTP 27) so it stays no_std with zero deps.
//!
//! OTP derives the expected static-init symbol from the archive basename:
//! tyn_rust_nif.a -> `tyn_rust_nif_nif_init`, and registers the NIF under
//! "tyn_rust_nif" for erlang:load_nif("tyn_rust_nif", _).

#![no_std]

use core::ffi::{c_char, c_int, c_uint, c_void};

// ERL_NIF_TERM is uintptr-sized; ErlNifEnv is opaque.
type ErlNifTerm = usize;
#[repr(C)]
pub struct ErlNifEnv {
    _private: [u8; 0],
}

#[repr(C)]
struct ErlNifFunc {
    name: *const c_char,
    arity: c_uint,
    fptr: extern "C" fn(*mut ErlNifEnv, c_int, *const ErlNifTerm) -> ErlNifTerm,
    flags: c_uint,
}

type LoadFn = extern "C" fn(*mut ErlNifEnv, *mut *mut c_void, ErlNifTerm) -> c_int;
type UnloadFn = extern "C" fn(*mut ErlNifEnv, *mut c_void);
type UpgradeFn = extern "C" fn(*mut ErlNifEnv, *mut *mut c_void, *mut *mut c_void, ErlNifTerm) -> c_int;

#[repr(C)]
struct ErlNifEntry {
    major: c_int,
    minor: c_int,
    name: *const c_char,
    num_of_funcs: c_int,
    funcs: *const ErlNifFunc,
    load: Option<LoadFn>,
    reload: Option<LoadFn>,
    upgrade: Option<UpgradeFn>,
    unload: Option<UnloadFn>,
    vm_variant: *const c_char,
    options: c_uint,
    sizeof_resource_type_init: usize, // sizeof(ErlNifResourceTypeInit) = 40 on x86_64
    min_erts: *const c_char,
}

// enif_* are provided by beam.smp; resolved at the final static link.
extern "C" {
    fn enif_get_long(env: *mut ErlNifEnv, term: ErlNifTerm, ip: *mut i64) -> c_int;
    fn enif_make_long(env: *mut ErlNifEnv, i: i64) -> ErlNifTerm;
    fn enif_make_badarg(env: *mut ErlNifEnv) -> ErlNifTerm;
}

extern "C" fn add_nif(env: *mut ErlNifEnv, argc: c_int, argv: *const ErlNifTerm) -> ErlNifTerm {
    unsafe {
        if argc != 2 {
            return enif_make_badarg(env);
        }
        let a_term = *argv;
        let b_term = *argv.add(1);
        let mut a: i64 = 0;
        let mut b: i64 = 0;
        if enif_get_long(env, a_term, &mut a) == 0 || enif_get_long(env, b_term, &mut b) == 0 {
            return enif_make_badarg(env);
        }
        enif_make_long(env, a + b)
    }
}

extern "C" fn load(_env: *mut ErlNifEnv, _priv: *mut *mut c_void, _info: ErlNifTerm) -> c_int {
    0
}

// NUL-terminated static C strings.
const NAME: &[u8] = b"tyn_rust_nif\0";
const FN_ADD: &[u8] = b"add\0";
const VM_VARIANT: &[u8] = b"beam.vanilla\0";
const MIN_ERTS: &[u8] = b"erts-14.0\0";

// Raw pointers aren't Sync; wrap so we can hold them in statics (single-threaded
// init read; ERTS only reads the returned entry).
struct Sync<T>(T);
unsafe impl<T> core::marker::Sync for Sync<T> {}

static FUNCS: Sync<[ErlNifFunc; 1]> = Sync([ErlNifFunc {
    name: FN_ADD.as_ptr() as *const c_char,
    arity: 2,
    fptr: add_nif,
    flags: 0,
}]);

static ENTRY: Sync<ErlNifEntry> = Sync(ErlNifEntry {
    major: 2,
    minor: 17,
    name: NAME.as_ptr() as *const c_char,
    num_of_funcs: 1,
    funcs: FUNCS.0.as_ptr(),
    load: Some(load),
    reload: None,
    upgrade: None,
    unload: None,
    vm_variant: VM_VARIANT.as_ptr() as *const c_char,
    options: 1,
    sizeof_resource_type_init: 40,
    min_erts: MIN_ERTS.as_ptr() as *const c_char,
});

/// The static-NIF init symbol OTP expects for archive `tyn_rust_nif.a`.
#[no_mangle]
pub extern "C" fn tyn_rust_nif_nif_init() -> *const ErlNifEntry {
    &ENTRY.0
}

#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}
