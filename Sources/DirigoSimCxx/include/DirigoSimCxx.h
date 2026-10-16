//
//  DirigoSimCxx.h
//  DirigoSwift
//
//  The C surface of the C++ simulation core.
//
//  Deliberately a **plain C** header with `extern "C"` guards: a C++ header would need
//  `-cxx-interoperability-mode` in every target that imports it, and this project builds the same
//  sources twice — through `Package.swift` for the tests and through the generated Xcode project for
//  the app. A C ABI needs no build setting at all, and keeps C++ types, exceptions and the standard
//  library on the C++ side of the boundary.
//
//  Values cross as a tagged struct rather than as `PinValue`, so neither side depends on the other's
//  representation.
//

#ifndef DIRIGO_SIM_CXX_H
#define DIRIGO_SIM_CXX_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    DIRIGO_VALUE_UNDEFINED = 0,
    DIRIGO_VALUE_BOOL = 1,
    DIRIGO_VALUE_INT16 = 2,
    DIRIGO_VALUE_INT32 = 3,
    DIRIGO_VALUE_INT64 = 4,
    DIRIGO_VALUE_FLOAT = 5
} DirigoValueKind;

typedef struct {
    int32_t kind;
    int32_t i;      /* bool, int16, int32 */
    int64_t i64;    /* int64, kept exact rather than squeezed into `i` */
    double f;       /* float */
} DirigoValue;

/// The block kinds the core implements. Anything else maps to `DIRIGO_BLOCK_UNRESOLVED`,
/// which holds its inputs and does nothing, the same contract the Swift `UnresolvedBlock` keeps. Which
/// kinds are ported is therefore visible from the outside: `dirigo_sim_portable_kind_count()` reports
/// the number, and a caller can compare pin-for-pin against the Swift engine to see how far the port
/// reaches rather than trusting a claim.
typedef enum {
    DIRIGO_BLOCK_UNRESOLVED = 0,
    DIRIGO_BLOCK_NOT = 1,
    DIRIGO_BLOCK_AND = 2,
    DIRIGO_BLOCK_OR = 3,
    DIRIGO_BLOCK_XOR = 4,
    DIRIGO_BLOCK_BOOLVAR = 5,
    DIRIGO_BLOCK_PULSEGEN = 6,
    DIRIGO_BLOCK_COUNTER = 7,
    DIRIGO_BLOCK_COMPARATOR = 8,
    DIRIGO_BLOCK_INT2BITS = 9,
    DIRIGO_BLOCK_SYSTEMCMD = 10,
    DIRIGO_BLOCK_SWITCH = 11,
    /// A block with no behaviour of its own: the I/O channels and the displays. Ported in the sense
    /// that the core is complete for it — its pins are the interface, and whoever drives them does the
    /// work — as opposed to `DIRIGO_BLOCK_UNRESOLVED`, which is a behaviour that is still missing.
    DIRIGO_BLOCK_PASSIVE = 12,

    /// `TMSetPins`. It computes nothing: it writes its `X` input through to the *producers* that its
    /// `P1..Pn` pins and its param pin are wired from. That needs the connection graph, so unlike every
    /// other kind it is implemented in the step loop rather than in `processModule`.
    DIRIGO_BLOCK_SET = 13,

    /// `TMInRange`: a window test with a wrapping case, used as a time switch.
    DIRIGO_BLOCK_INRANGE = 14,

    /// `TMEquitherm`: the heating curve — the line through two configured points, extrapolated.
    DIRIGO_BLOCK_EQUITHERM = 15,

    /// `TMacroInterface`: the `Inputs` / `Outputs` module that carries values across a macro's
    /// caller/subpage boundary. It computes nothing — the two blocks have empty `process` bodies and
    /// only hold their pins — and the copying is done by `dirigo_sim_set_macro_bridges`. It needs its
    /// own kind rather than `PASSIVE` because a `PASSIVE` module is not in the *evaluated* set, and
    /// `isFullyPorted` gates whether a project runs on the core at all.
    ///
    /// Note that `Inputs` and `Outputs` **share one GUID** in the block table (`3FFBEEC3-…`) and are
    /// told apart by the module's `KIND` attribute, so nothing here may assume the GUID identifies which.
    DIRIGO_BLOCK_MACRO_IO = 16,

    /// `TMDateTime`: decomposes a wall clock into `D, H, M, S, DOW, SOD`.
    ///
    /// The core does **not** read a clock of its own. Both engines have to answer the same question with
    /// the same instant or a time-dependent pin can never be compared — and two `Date()` calls cannot
    /// agree. So the calendar components are pushed in once per step through
    /// `dirigo_sim_set_wall_clock`, and the Swift side is the single place the clock is read (see
    /// `SimulationEngine.now` and `DirigoEpoch`).
    DIRIGO_BLOCK_DATETIME = 17,

    /// `TMBits2Int`: packs `B0..Bn-1` into one Int. The five kinds below this one are what the rest of
    /// the corpus needs — measured from the projects, not from the module documentation.
    DIRIGO_BLOCK_BITS2INT = 18,
    /// `TMRS`: a set/reset latch that **holds its state**, so it has a field rather than reading a pin.
    DIRIGO_BLOCK_RS = 19,
    /// `TMIntVar`: "performs no operation; it only allocates space for a variable of type Int". Its
    /// value lives in a field, and `Set`/`SetIdx` write it through — see `writeThroughConnection`.
    DIRIGO_BLOCK_INTVAR = 20,
    /// `TMDiv`: quotient and remainder, with a guard for `B = 0`.
    DIRIGO_BLOCK_DIV = 21,
    /// `TMIntSub`: `Y = A - B`.
    DIRIGO_BLOCK_INTSUB = 22
} DirigoBlockKind;

/// A step's wall clock, already decomposed. `DOW` is 0 = Monday, as the help specifies.
typedef struct {
    int32_t days;        /* days since 1 Jan 1980 */
    int32_t hour;
    int32_t minute;
    int32_t second;
    int32_t dayOfWeek;   /* 0 = Monday */
} DirigoWallClock;

typedef struct {
    int32_t id;             /* the project's module ID */
    int32_t order;          /* ORDER */
    int32_t threadId;       /* THREAD_ID */
    int32_t kind;           /* DirigoBlockKind */
    int32_t inCount;
    int32_t paramCount;
    int32_t outCount;
    const DirigoValue *initialOut;   /* `outCount` entries, or NULL */
    const DirigoValue *initialIn;    /* `inCount` entries, or NULL */
} DirigoModuleDesc;

typedef struct {
    int32_t inModule;
    int32_t inPin;
    int32_t outModule;
    int32_t outPin;
    int32_t inverted;
    /// 0 for an in-pin, 1 for a param pin. The Swift engine keeps two separate maps, so the
    /// destination kind cannot be inferred from the pin index.
    int32_t toParamPins;
} DirigoConnection;

/// One interface of a macro: which module on a subpage carries the caller's values across.
///
/// The Swift engine discovers these by reading module *attributes* (`MACRO_NAME`, `KIND`) and matching
/// page names, which the core cannot do — `DirigoModuleDesc` carries no attributes, and doing it in
/// Swift keeps the string matching in one place rather than in a C++ port of it.
///
/// The core's job is then mechanical and mirrors `SimulationEngine.propagateMacroCalls`:
///
/// * `DIRIGO_MACRO_INPUTS` — copy the caller's `inPins` onto this module's `outPins`, so the subpage's
///   first block reads the caller's arguments;
/// * `DIRIGO_MACRO_OUTPUTS` — copy this module's `inPins` back onto the caller's `outPins`, so the
///   caller reads the subpage's results.
typedef struct {
    int32_t callerModule;      /* the macro call site, on a non-`*` page */
    int32_t interfaceModule;   /* the `Inputs` / `Outputs` module on the `*` subpage */
    int32_t kind;              /* DirigoMacroInterfaceKind */
} DirigoMacroBridge;

typedef enum {
    DIRIGO_MACRO_INPUTS = 0,
    DIRIGO_MACRO_OUTPUTS = 1
} DirigoMacroInterfaceKind;

typedef struct DirigoSim DirigoSim;

/// Builds a runtime. `profileScheduling` is non-zero for per-thread periods (the app's mode) and zero
/// for "every thread on every step" (the engine's historical default, which the tests use).
DirigoSim *dirigo_sim_create(const DirigoModuleDesc *modules, int32_t count,
                             const DirigoConnection *connections, int32_t connectionCount,
                             double cycleDelayMs, int32_t profileScheduling);

/// Adds the macro bridges after `dirigo_sim_create`.
///
/// Separate from `create` deliberately: the bridges are *derived* from module attributes rather than
/// present in the project file, so a caller that cannot work them out (or a project with no macros)
/// passes none, and the core then behaves exactly as it did before macros existed.
void dirigo_sim_set_macro_bridges(DirigoSim *sim, const DirigoMacroBridge *bridges, int32_t count);

/* How many times one propagation sweeps "bridges, wires, bridges": 1 unless macros nest, then two per level, so a
   value crosses the whole stack within one propagation. */
void dirigo_sim_set_macro_sweeps(DirigoSim *sim, int32_t sweeps);

/// Sets the wall clock every `DIRIGO_BLOCK_DATETIME` module will read until the next call.
///
/// Called once per step by the caller that owns the clock. A time-dependent block that read its own
/// clock could never be checked against another engine, so this is the only way the block gets a time.
void dirigo_sim_set_wall_clock(DirigoSim *sim, DirigoWallClock clock);

void dirigo_sim_destroy(DirigoSim *sim);
void dirigo_sim_reset(DirigoSim *sim);

/// One cycle. Returns 1 when a thread ran, matching `SimulationEngine.stepIfDue`.
int32_t dirigo_sim_step(DirigoSim *sim, double deltaMs);

/// Milliseconds until the earliest thread is due next; 0 when one already is.
double dirigo_sim_next_due_ms(const DirigoSim *sim);

/* Simulated milliseconds until some thread next runs; 0 when one would on the next step. Exact, where
   `next_due_ms` counts a thread within one project cycle of its period as due. */
double dirigo_sim_ms_until_run(const DirigoSim *sim);

uint64_t dirigo_sim_tick_count(const DirigoSim *sim);

DirigoValue dirigo_sim_get_in(const DirigoSim *sim, int32_t index, int32_t pin);
DirigoValue dirigo_sim_get_param(const DirigoSim *sim, int32_t index, int32_t pin);
DirigoValue dirigo_sim_get_out(const DirigoSim *sim, int32_t index, int32_t pin);
void dirigo_sim_set_in(DirigoSim *sim, int32_t index, int32_t pin, DirigoValue value);
void dirigo_sim_set_param(DirigoSim *sim, int32_t index, int32_t pin, DirigoValue value);
void dirigo_sim_set_out(DirigoSim *sim, int32_t index, int32_t pin, DirigoValue value);

/// How many of `DirigoBlockKind` the core implements (i.e. excluding `DIRIGO_BLOCK_UNRESOLVED`).
int32_t dirigo_sim_portable_kind_count(void);

#ifdef __cplusplus
}
#endif

#endif /* DIRIGO_SIM_CXX_H */
