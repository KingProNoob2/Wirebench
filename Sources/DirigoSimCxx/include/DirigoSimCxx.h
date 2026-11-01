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
    /// `ISwitch`, `LSwitch` and `FSwitch`; `variant` is 1 for the Float form, whose cleared output is a float.
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
    /// `variant` is 1 for set priority (the module's `PRIORITY` or `RS_PRIORITY` is `S`), 0 for reset priority.
    DIRIGO_BLOCK_RS = 19,
    /// `TMIntVar`: "performs no operation; it only allocates space for a variable of type Int". Its
    /// value lives in a field, and `Set`/`SetIdx` write it through — see `writeThroughConnection`.
    DIRIGO_BLOCK_INTVAR = 20,
    /// `TMDiv`: quotient and remainder, with a guard for `B = 0`.
    DIRIGO_BLOCK_DIV = 21,
    /// `TMIntSub`: `Y = A - B`.
    DIRIGO_BLOCK_INTSUB = 22,

    /* Integer, bit and conversion blocks. Each mirrors the Swift class named beside it; where one Swift
       class backs several Dirigo types, the type is told apart by `DirigoModuleDesc.variant`. */
    DIRIGO_BLOCK_YES = 23,           /* YesBlock */
    DIRIGO_BLOCK_SHL = 24,           /* ShlBlock */
    DIRIGO_BLOCK_SAR = 25,           /* SarBlock */
    DIRIGO_BLOCK_EXT = 26,           /* ExtBlock */
    DIRIGO_BLOCK_INS = 27,           /* InsBlock */
    DIRIGO_BLOCK_SINGLEPULSE = 28,   /* SinglePulseBlock */
    DIRIGO_BLOCK_PULSELEN = 29,      /* PulseLengthBlock */
    DIRIGO_BLOCK_IABS = 30,          /* AbsBlock */
    DIRIGO_BLOCK_IINC = 31,          /* IncBlock */
    DIRIGO_BLOCK_INEG = 32,          /* NegBlock */
    DIRIGO_BLOCK_IADD = 33,          /* AddBlock */
    DIRIGO_BLOCK_IMUL = 34,          /* MulBlock */
    DIRIGO_BLOCK_LIMITER = 35,       /* LimiterBlock (ILimiter, LLimiter) */
    DIRIGO_BLOCK_CALIBTRANSF = 36,   /* CalibratedTransformBlock */
    DIRIGO_BLOCK_MEAN = 37,          /* MeanBlock; config[0] = window */
    DIRIGO_BLOCK_FLOATMATH = 38,     /* FloatMathBlock (legacy, Float arithmetic); variant = DirigoFloatMathOp */
    DIRIGO_BLOCK_LONGMATH = 39,      /* LongMathBlock; variant = DirigoLongMathOp */
    DIRIGO_BLOCK_FLOATNUM = 40,      /* FloatMathNumericBlock; variant = DirigoFloatNumOp */
    DIRIGO_BLOCK_MOVE = 41,          /* MoveBlock */
    DIRIGO_BLOCK_COPY = 42,          /* CopyBlock; variant = 1 when it has a Wr pin */
    DIRIGO_BLOCK_ENCODEDATE = 43,    /* EncodeDateBlock */
    DIRIGO_BLOCK_DECODEDATE = 44,    /* DecodeDateBlock */
    DIRIGO_BLOCK_IDEMUX = 45,        /* IntDemuxBlock (IDemux, LDemux) */
    DIRIGO_BLOCK_FDEMUX = 46,        /* FloatDemuxBlock */
    DIRIGO_BLOCK_ADVCOUNTER = 47,    /* AdvCounterBlock */
    DIRIGO_BLOCK_FILTER = 48,        /* FilterBlock */
    DIRIGO_BLOCK_IAND = 49,          /* IntAndBlock */
    DIRIGO_BLOCK_IOR = 50,           /* IntOrBlock */
    DIRIGO_BLOCK_IXOR = 51,          /* IntXorBlock */
    DIRIGO_BLOCK_INOT = 52,          /* IntNotBlock */
    DIRIGO_BLOCK_TRIGGER = 53,       /* TriggerBlock */

    /* A block with no unit attached: when it runs it writes "nothing read" to every output. `variant` picks
       the value — 0 an Int zero (HardwareInputBlock, LoggerBlock, Store*Data), 1 `false` (D3NetRead/Write),
       2 a Float zero (StoreFloatData), 3 ReadDallas's `St = 0, T = 0`. */
    DIRIGO_BLOCK_CONSTOUT = 54,
    DIRIGO_BLOCK_DELAYFILTER = 55,   /* DelayFilterBlock */
    DIRIGO_BLOCK_TIMER = 56,         /* TimerBlock; variant = TimerBlock.Mode */
    DIRIGO_BLOCK_RAMP = 57,          /* RampBlock */
    DIRIGO_BLOCK_VALVE = 58,         /* ValveBlock */
    DIRIGO_BLOCK_WATERREG = 59,      /* WaterRegulatorBlock */
    DIRIGO_BLOCK_STEPDRV = 60,       /* StepDriverBlock */
    DIRIGO_BLOCK_HYSTCOMP = 61,      /* HysteresisComparatorBlock */
    DIRIGO_BLOCK_MCOMPARE = 62,      /* MultiComparatorBlock */

    /* The construct markers. Their bookkeeping is in the step loop (the Swift `stepNode`), because it
       decides whether *other* modules run; `variant` on If/Switch is 1 when the condition pin is inverted. */
    DIRIGO_BLOCK_IF = 63,
    DIRIGO_BLOCK_ELSE = 64,
    DIRIGO_BLOCK_ENDIF = 65,
    DIRIGO_BLOCK_SWITCHCASE = 66,    /* `TMSwitchModule`, the construct (not the `ISwitch` value switch) */
    DIRIGO_BLOCK_CASE = 67,          /* accepted values set by `dirigo_sim_set_case_ranges` */
    DIRIGO_BLOCK_DEFAULT = 68,
    DIRIGO_BLOCK_ENDSWITCH = 69,

    DIRIGO_BLOCK_FLOATVAR = 70,      /* FloatVarBlock: the value is state, written through by Set/SetIdx */
    DIRIGO_BLOCK_CREATEARRAY = 71,   /* CreateArrayBlock */
    DIRIGO_BLOCK_READARRAY = 72,     /* ReadArrayBlock; variant 1 = Float elements */
    DIRIGO_BLOCK_WRITEARRAY = 73,    /* WriteArrayBlock; variant 1 = Float elements */
    DIRIGO_BLOCK_SETIDX = 74         /* SetIdxBlock: like Set, but through the one P pin `Idx` names */
} DirigoBlockKind;

/* `variant` for `DIRIGO_BLOCK_LONGMATH`, in `LongMathOperation` order. */
typedef enum {
    DIRIGO_LONG_ADD = 0, DIRIGO_LONG_SUB = 1, DIRIGO_LONG_ABS = 2, DIRIGO_LONG_NEG = 3, DIRIGO_LONG_NOT = 4,
    DIRIGO_LONG_INC = 5, DIRIGO_LONG_AND = 6, DIRIGO_LONG_OR = 7, DIRIGO_LONG_XOR = 8
} DirigoLongMathOp;

/* `variant` for `DIRIGO_BLOCK_FLOATNUM`, in `FloatMathOperation` order. */
typedef enum {
    DIRIGO_FNUM_ADD = 0, DIRIGO_FNUM_SUB = 1, DIRIGO_FNUM_MUL = 2, DIRIGO_FNUM_DIV = 3, DIRIGO_FNUM_ABS = 4,
    DIRIGO_FNUM_NEG = 5, DIRIGO_FNUM_SQRT = 6, DIRIGO_FNUM_MOD = 7, DIRIGO_FNUM_SIN = 8, DIRIGO_FNUM_COS = 9,
    DIRIGO_FNUM_ASIN = 10, DIRIGO_FNUM_ACOS = 11
} DirigoFloatNumOp;

/* `variant` for `DIRIGO_BLOCK_FLOATMATH`, in `FloatMathBlock.Operation` order. */
typedef enum {
    DIRIGO_FMATH_ADD = 0, DIRIGO_FMATH_SUB = 1, DIRIGO_FMATH_MUL = 2, DIRIGO_FMATH_DIV = 3,
    DIRIGO_FMATH_SQRT = 4, DIRIGO_FMATH_SIN = 5, DIRIGO_FMATH_COS = 6
} DirigoFloatMathOp;

/// A step's wall clock, already decomposed. `DOW` is 0 = Monday, as the help specifies.
typedef struct {
    int32_t days;        /* days since 1 Jan 1980 */
    int32_t hour;
    int32_t minute;
    int32_t second;
    int32_t dayOfWeek;   /* 0 = Monday */
    /// The same instant in seconds since 1970 (UTC). `DateTime` decomposes this itself, because a module's
    /// configured offset (`OFFS`) shifts the instant before it is split into days, hours and minutes.
    double unixSeconds;
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
    /// Per-instance configuration the Swift registry reads from module *attributes* when it builds a block
    /// (an RS block's priority, a math block's operation, a window length). The core cannot read attributes,
    /// so Swift resolves them and hands the result over; what each kind expects is noted on its enum value.
    int32_t variant;
    int64_t config[4];
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
    DIRIGO_MACRO_OUTPUTS = 1,
    /// The caller's `paramPins` onto the subpage `Params` module's `outPins`.
    DIRIGO_MACRO_PARAMS = 2
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

/// A thread's period from the hardware profile. A thread with none set runs at the project's cycle.
void dirigo_sim_set_thread_interval(DirigoSim *sim, int32_t threadId, double intervalMs);

/// A `Case` module's accepted values: `count` inclusive ranges as `lo, hi` pairs in `ranges`.
void dirigo_sim_set_case_ranges(DirigoSim *sim, int32_t index, const int64_t *ranges, int32_t count);

void dirigo_sim_destroy(DirigoSim *sim);
void dirigo_sim_reset(DirigoSim *sim);

/// One cycle. Returns 1 when a thread ran, matching `SimulationEngine.stepIfDue`.
int32_t dirigo_sim_step(DirigoSim *sim, double deltaMs);

/// One pass of *every* thread now, without advancing any thread's timer: what an edit made while paused
/// needs to show its effect, whatever the threads' periods. Counts as a tick.
void dirigo_sim_evaluate_now(DirigoSim *sim);

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

/* --- What the app needs to drive the core directly, with no Swift engine beside it. --- */

/// Sets an output high for `cycles` passes of its module, then low: a push button's single click
/// (`BoolVarBlock.trigger`). Writing the pin with `dirigo_sim_set_out` would clear any pending pulse instead.
void dirigo_sim_pulse_out(DirigoSim *sim, int32_t index, int32_t pin, int32_t cycles);

/// Winds one module's internal state and outputs back to its reset values, keeping its inputs and
/// parameters — what a block's own `reset()` does, as the inspector's Reset button asks.
void dirigo_sim_reset_module(DirigoSim *sim, int32_t index);

/// Changes a module's `variant` live (an RS block's priority, a timer's mode), keeping its state.
void dirigo_sim_set_variant(DirigoSim *sim, int32_t index, int32_t variant);

/// The whole-project wire and macro sweep, outside a step: an edit made by hand reaches its consumers now.
void dirigo_sim_propagate(DirigoSim *sim);

/// How many times a thread has run since the runtime was built or reset.
uint64_t dirigo_sim_thread_run_count(const DirigoSim *sim, int32_t threadId);

/// A thread's period: the profile's when it has one, otherwise the project's cycle.
double dirigo_sim_thread_interval_ms(const DirigoSim *sim, int32_t threadId);

/// A digest of every pin value, for "did anything change?". Faithful: every pin's kind and exact bits are
/// mixed in (FNV-1a), so equal digests mean equal pins, short of a hash collision.
uint64_t dirigo_sim_pins_digest(const DirigoSim *sim);

/// How many of `DirigoBlockKind` the core implements (i.e. excluding `DIRIGO_BLOCK_UNRESOLVED`).
int32_t dirigo_sim_portable_kind_count(void);

#ifdef __cplusplus
}
#endif

#endif /* DIRIGO_SIM_CXX_H */
