//
//  WirebenchSimCxx.h
//  Wirebench
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

#ifndef WIREBENCH_SIM_CXX_H
#define WIREBENCH_SIM_CXX_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    WIREBENCH_VALUE_UNDEFINED = 0,
    WIREBENCH_VALUE_BOOL = 1,
    WIREBENCH_VALUE_INT16 = 2,
    WIREBENCH_VALUE_INT32 = 3,
    WIREBENCH_VALUE_INT64 = 4,
    WIREBENCH_VALUE_FLOAT = 5
} WirebenchValueKind;

typedef struct {
    int32_t kind;
    int32_t i;      /* bool, int16, int32 */
    int64_t i64;    /* int64, kept exact rather than squeezed into `i` */
    double f;       /* float */
} WirebenchValue;

/// The block kinds the core implements. Anything else maps to `WIREBENCH_BLOCK_UNRESOLVED`,
/// which holds its inputs and does nothing, the same contract the Swift `UnresolvedBlock` keeps. Which
/// kinds are ported is therefore visible from the outside: `wirebench_sim_portable_kind_count()` reports
/// the number, and a caller can compare pin-for-pin against the Swift engine to see how far the port
/// reaches rather than trusting a claim.
typedef enum {
    WIREBENCH_BLOCK_UNRESOLVED = 0,
    WIREBENCH_BLOCK_NOT = 1,
    WIREBENCH_BLOCK_AND = 2,
    WIREBENCH_BLOCK_OR = 3,
    WIREBENCH_BLOCK_XOR = 4,
    WIREBENCH_BLOCK_BOOLVAR = 5,
    WIREBENCH_BLOCK_PULSEGEN = 6,
    WIREBENCH_BLOCK_COUNTER = 7,
    WIREBENCH_BLOCK_COMPARATOR = 8,
    WIREBENCH_BLOCK_INT2BITS = 9,
    WIREBENCH_BLOCK_SYSTEMCMD = 10,
    /// `ISwitch`, `LSwitch` and `FSwitch`; `variant` is 1 for the Float form, whose cleared output is a float.
    WIREBENCH_BLOCK_SWITCH = 11,
    /// A block with no behaviour of its own: the I/O channels and the displays. Ported in the sense
    /// that the core is complete for it — its pins are the interface, and whoever drives them does the
    /// work — as opposed to `WIREBENCH_BLOCK_UNRESOLVED`, which is a behaviour that is still missing.
    WIREBENCH_BLOCK_PASSIVE = 12,

    /// `TMSetPins`. It computes nothing: it writes its `X` input through to the *producers* that its
    /// `P1..Pn` pins and its param pin are wired from. That needs the connection graph, so unlike every
    /// other kind it is implemented in the step loop rather than in `processModule`.
    WIREBENCH_BLOCK_SET = 13,

    /// `TMInRange`: a window test with a wrapping case, used as a time switch.
    WIREBENCH_BLOCK_INRANGE = 14,

    /// `TMEquitherm`: the heating curve — the line through two configured points, extrapolated.
    WIREBENCH_BLOCK_EQUITHERM = 15,

    /// `TMacroInterface`: the `Inputs` / `Outputs` module that carries values across a macro's
    /// caller/subpage boundary. It computes nothing — the two blocks have empty `process` bodies and
    /// only hold their pins — and the copying is done by `wirebench_sim_set_macro_bridges`. It needs its
    /// own kind rather than `PASSIVE` because a `PASSIVE` module is not in the *evaluated* set, and
    /// `isFullyPorted` gates whether a project runs on the core at all.
    ///
    /// Note that `Inputs` and `Outputs` **share one GUID** in the block table (`3FFBEEC3-…`) and are
    /// told apart by the module's `KIND` attribute, so nothing here may assume the GUID identifies which.
    WIREBENCH_BLOCK_MACRO_IO = 16,

    /// `TMDateTime`: decomposes a wall clock into `D, H, M, S, DOW, SOD`.
    ///
    /// The core does **not** read a clock of its own. Both engines have to answer the same question with
    /// the same instant or a time-dependent pin can never be compared — and two `Date()` calls cannot
    /// agree. So the calendar components are pushed in once per step through
    /// `wirebench_sim_set_wall_clock`, and the Swift side is the single place the clock is read (see
    /// `DirigoEpoch`).
    WIREBENCH_BLOCK_DATETIME = 17,

    /// `TMBits2Int`: packs `B0..Bn-1` into one Int. The five kinds below this one are what the rest of
    /// the corpus needs — measured from the projects, not from the module documentation.
    WIREBENCH_BLOCK_BITS2INT = 18,
    /// `TMRS`: a set/reset latch that **holds its state**, so it has a field rather than reading a pin.
    /// `variant` is 1 for set priority (the module's `PRIORITY` or `RS_PRIORITY` is `S`), 0 for reset priority.
    WIREBENCH_BLOCK_RS = 19,
    /// `TMIntVar`: "performs no operation; it only allocates space for a variable of type Int". Its
    /// value lives in a field, and `Set`/`SetIdx` write it through — see `writeThroughConnection`.
    WIREBENCH_BLOCK_INTVAR = 20,
    /// `TMDiv`: quotient and remainder, with a guard for `B = 0`.
    WIREBENCH_BLOCK_DIV = 21,
    /// `TMIntSub`: `Y = A - B`.
    WIREBENCH_BLOCK_INTSUB = 22,

    /* Integer, bit and conversion blocks. Each mirrors the Swift class named beside it; where one Swift
       class backs several Dirigo types, the type is told apart by `WirebenchModuleDesc.variant`. */
    WIREBENCH_BLOCK_YES = 23,           /* YesBlock */
    WIREBENCH_BLOCK_SHL = 24,           /* ShlBlock */
    WIREBENCH_BLOCK_SAR = 25,           /* SarBlock */
    WIREBENCH_BLOCK_EXT = 26,           /* ExtBlock */
    WIREBENCH_BLOCK_INS = 27,           /* InsBlock */
    WIREBENCH_BLOCK_SINGLEPULSE = 28,   /* SinglePulseBlock */
    WIREBENCH_BLOCK_PULSELEN = 29,      /* PulseLengthBlock */
    WIREBENCH_BLOCK_IABS = 30,          /* AbsBlock */
    WIREBENCH_BLOCK_IINC = 31,          /* IncBlock */
    WIREBENCH_BLOCK_INEG = 32,          /* NegBlock */
    WIREBENCH_BLOCK_IADD = 33,          /* AddBlock */
    WIREBENCH_BLOCK_IMUL = 34,          /* MulBlock */
    WIREBENCH_BLOCK_LIMITER = 35,       /* LimiterBlock (ILimiter, LLimiter) */
    WIREBENCH_BLOCK_CALIBTRANSF = 36,   /* CalibratedTransformBlock */
    WIREBENCH_BLOCK_MEAN = 37,          /* MeanBlock; config[0] = window */
    WIREBENCH_BLOCK_FLOATMATH = 38,     /* FloatMathBlock (legacy, Float arithmetic); variant = WirebenchFloatMathOp */
    WIREBENCH_BLOCK_LONGMATH = 39,      /* LongMathBlock; variant = WirebenchLongMathOp */
    WIREBENCH_BLOCK_FLOATNUM = 40,      /* FloatMathNumericBlock; variant = WirebenchFloatNumOp */
    WIREBENCH_BLOCK_MOVE = 41,          /* MoveBlock */
    WIREBENCH_BLOCK_COPY = 42,          /* CopyBlock; variant = 1 when it has a Wr pin */
    WIREBENCH_BLOCK_ENCODEDATE = 43,    /* EncodeDateBlock */
    WIREBENCH_BLOCK_DECODEDATE = 44,    /* DecodeDateBlock */
    WIREBENCH_BLOCK_IDEMUX = 45,        /* IntDemuxBlock (IDemux, LDemux) */
    WIREBENCH_BLOCK_FDEMUX = 46,        /* FloatDemuxBlock */
    WIREBENCH_BLOCK_ADVCOUNTER = 47,    /* AdvCounterBlock */
    WIREBENCH_BLOCK_FILTER = 48,        /* FilterBlock */
    WIREBENCH_BLOCK_IAND = 49,          /* IntAndBlock */
    WIREBENCH_BLOCK_IOR = 50,           /* IntOrBlock */
    WIREBENCH_BLOCK_IXOR = 51,          /* IntXorBlock */
    WIREBENCH_BLOCK_INOT = 52,          /* IntNotBlock */
    WIREBENCH_BLOCK_TRIGGER = 53,       /* TriggerBlock */

    /* A block with no unit attached: when it runs it writes "nothing read" to every output. `variant` picks
       the value — 0 an Int zero (HardwareInputBlock, LoggerBlock, Store*Data), 1 `false` (D3NetRead/Write),
       2 a Float zero (StoreFloatData), 3 ReadDallas's `St = 0, T = 0`. */
    WIREBENCH_BLOCK_CONSTOUT = 54,
    WIREBENCH_BLOCK_DELAYFILTER = 55,   /* DelayFilterBlock */
    WIREBENCH_BLOCK_TIMER = 56,         /* TimerBlock; variant = TimerBlock.Mode */
    WIREBENCH_BLOCK_RAMP = 57,          /* RampBlock */
    WIREBENCH_BLOCK_VALVE = 58,         /* ValveBlock */
    WIREBENCH_BLOCK_WATERREG = 59,      /* WaterRegulatorBlock */
    WIREBENCH_BLOCK_STEPDRV = 60,       /* StepDriverBlock */
    WIREBENCH_BLOCK_HYSTCOMP = 61,      /* HysteresisComparatorBlock */
    WIREBENCH_BLOCK_MCOMPARE = 62,      /* MultiComparatorBlock */

    /* The construct markers. Their bookkeeping is in the step loop (the Swift `stepNode`), because it
       decides whether *other* modules run; `variant` on If/Switch is 1 when the condition pin is inverted. */
    WIREBENCH_BLOCK_IF = 63,
    WIREBENCH_BLOCK_ELSE = 64,
    WIREBENCH_BLOCK_ENDIF = 65,
    WIREBENCH_BLOCK_SWITCHCASE = 66,    /* `TMSwitchModule`, the construct (not the `ISwitch` value switch) */
    WIREBENCH_BLOCK_CASE = 67,          /* accepted values set by `wirebench_sim_set_case_ranges` */
    WIREBENCH_BLOCK_DEFAULT = 68,
    WIREBENCH_BLOCK_ENDSWITCH = 69,

    WIREBENCH_BLOCK_FLOATVAR = 70,      /* FloatVarBlock: the value is state, written through by Set/SetIdx */
    WIREBENCH_BLOCK_CREATEARRAY = 71,   /* CreateArrayBlock */
    WIREBENCH_BLOCK_READARRAY = 72,     /* ReadArrayBlock; variant 1 = Float elements */
    WIREBENCH_BLOCK_WRITEARRAY = 73,    /* WriteArrayBlock; variant 1 = Float elements */
    WIREBENCH_BLOCK_SETIDX = 74,        /* SetIdxBlock: like Set, but through the one P pin `Idx` names */
    /* Synthetic blocks imported from Maraflow. `variant` is the index in Swift's `MaraflowCatalog.all`; the core
       implements the semantics that have been ported so far, and the rest hold their pins. */
    WIREBENCH_BLOCK_MARAFLOW = 75,
    /// One Maraflow Structured Text page; the core compiles and runs it against the operand namespace.
    WIREBENCH_BLOCK_MARAFLOW_ST = 76,
    /// One Maraflow ladder page (or one thread's rungs from it), evaluated against the operand namespace.
    WIREBENCH_BLOCK_MARAFLOW_LD = 77
} WirebenchBlockKind;

/* `variant` for `WIREBENCH_BLOCK_LONGMATH`, in `LongMathOperation` order. */
typedef enum {
    WIREBENCH_LONG_ADD = 0, WIREBENCH_LONG_SUB = 1, WIREBENCH_LONG_ABS = 2, WIREBENCH_LONG_NEG = 3, WIREBENCH_LONG_NOT = 4,
    WIREBENCH_LONG_INC = 5, WIREBENCH_LONG_AND = 6, WIREBENCH_LONG_OR = 7, WIREBENCH_LONG_XOR = 8
} WirebenchLongMathOp;

/* `variant` for `WIREBENCH_BLOCK_FLOATNUM`, in `FloatMathOperation` order. */
typedef enum {
    WIREBENCH_FNUM_ADD = 0, WIREBENCH_FNUM_SUB = 1, WIREBENCH_FNUM_MUL = 2, WIREBENCH_FNUM_DIV = 3, WIREBENCH_FNUM_ABS = 4,
    WIREBENCH_FNUM_NEG = 5, WIREBENCH_FNUM_SQRT = 6, WIREBENCH_FNUM_MOD = 7, WIREBENCH_FNUM_SIN = 8, WIREBENCH_FNUM_COS = 9,
    WIREBENCH_FNUM_ASIN = 10, WIREBENCH_FNUM_ACOS = 11
} WirebenchFloatNumOp;

/* `variant` for `WIREBENCH_BLOCK_FLOATMATH`, in `FloatMathBlock.Operation` order. */
typedef enum {
    WIREBENCH_FMATH_ADD = 0, WIREBENCH_FMATH_SUB = 1, WIREBENCH_FMATH_MUL = 2, WIREBENCH_FMATH_DIV = 3,
    WIREBENCH_FMATH_SQRT = 4, WIREBENCH_FMATH_SIN = 5, WIREBENCH_FMATH_COS = 6
} WirebenchFloatMathOp;

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
} WirebenchWallClock;

typedef struct {
    int32_t id;             /* the project's module ID */
    int32_t order;          /* ORDER */
    int32_t threadId;       /* THREAD_ID */
    int32_t kind;           /* WirebenchBlockKind */
    int32_t inCount;
    int32_t paramCount;
    int32_t outCount;
    const WirebenchValue *initialOut;   /* `outCount` entries, or NULL */
    const WirebenchValue *initialIn;    /* `inCount` entries, or NULL */
    /// Per-instance configuration the Swift registry reads from module *attributes* when it builds a block
    /// (an RS block's priority, a math block's operation, a window length). The core cannot read attributes,
    /// so Swift resolves them and hands the result over; what each kind expects is noted on its enum value.
    int32_t variant;
    int64_t config[4];
    /// 1 when the block's first pin is its `En` (the help's pin table), so the engine's gate is the block's own
    /// enable. A block whose first pin is data (`Yes`, `Int2Bits`, `Limiter`) must always run.
    int32_t hasEnable;
} WirebenchModuleDesc;

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
/// page names, which the core cannot do — `WirebenchModuleDesc` carries no attributes, and doing it in
/// Swift keeps the string matching in one place rather than in a C++ port of it.
///
/// The core's job is then mechanical:
///
/// * `WIREBENCH_MACRO_INPUTS` — copy the caller's `inPins` onto this module's `outPins`, so the subpage's
///   first block reads the caller's arguments;
/// * `WIREBENCH_MACRO_OUTPUTS` — copy this module's `inPins` back onto the caller's `outPins`, so the
///   caller reads the subpage's results.
typedef struct {
    int32_t callerModule;      /* the macro call site, on a non-`*` page */
    int32_t interfaceModule;   /* the `Inputs` / `Outputs` module on the `*` subpage */
    int32_t kind;              /* WirebenchMacroInterfaceKind */
} WirebenchMacroBridge;

typedef enum {
    WIREBENCH_MACRO_INPUTS = 0,
    WIREBENCH_MACRO_OUTPUTS = 1,
    /// The caller's `paramPins` onto the subpage `Params` module's `outPins`.
    WIREBENCH_MACRO_PARAMS = 2
} WirebenchMacroInterfaceKind;

typedef struct WirebenchSim WirebenchSim;

/// Builds a runtime. `profileScheduling` is non-zero for per-thread periods (the app's mode) and zero
/// for "every thread on every step" (the engine's historical default, which the tests use).
WirebenchSim *wirebench_sim_create(const WirebenchModuleDesc *modules, int32_t count,
                             const DirigoConnection *connections, int32_t connectionCount,
                             double cycleDelayMs, int32_t profileScheduling);

/// Adds the macro bridges after `wirebench_sim_create`.
///
/// Separate from `create` deliberately: the bridges are *derived* from module attributes rather than
/// present in the project file, so a caller that cannot work them out (or a project with no macros)
/// passes none, and the core then behaves exactly as it did before macros existed.
void wirebench_sim_set_macro_bridges(WirebenchSim *sim, const WirebenchMacroBridge *bridges, int32_t count);

/* How many times one propagation sweeps "bridges, wires, bridges": 1 unless macros nest, then two per level, so a
   value crosses the whole stack within one propagation. */
void wirebench_sim_set_macro_sweeps(WirebenchSim *sim, int32_t sweeps);

/// Sets the wall clock every `WIREBENCH_BLOCK_DATETIME` module will read until the next call.
///
/// Called once per step by the caller that owns the clock. A time-dependent block that read its own
/// clock could never be checked against another engine, so this is the only way the block gets a time.
void wirebench_sim_set_wall_clock(WirebenchSim *sim, WirebenchWallClock clock);

/// A thread's period from the hardware profile. A thread with none set runs at the project's cycle.
void wirebench_sim_set_thread_interval(WirebenchSim *sim, int32_t threadId, double intervalMs);

/// A `Case` module's accepted values: `count` inclusive ranges as `lo, hi` pairs in `ranges`.
void wirebench_sim_set_case_ranges(WirebenchSim *sim, int32_t index, const int64_t *ranges, int32_t count);

void wirebench_sim_destroy(WirebenchSim *sim);
void wirebench_sim_reset(WirebenchSim *sim);

/// One cycle. Returns 1 when a thread ran.
int32_t wirebench_sim_step(WirebenchSim *sim, double deltaMs);

/// One pass of *every* thread now, without advancing any thread's timer: what an edit made while paused
/// needs to show its effect, whatever the threads' periods. Counts as a tick.
void wirebench_sim_evaluate_now(WirebenchSim *sim);

/* Simulated milliseconds until some thread next runs; 0 when one would on the next step. */
double wirebench_sim_ms_until_run(const WirebenchSim *sim);

uint64_t wirebench_sim_tick_count(const WirebenchSim *sim);

WirebenchValue wirebench_sim_get_in(const WirebenchSim *sim, int32_t index, int32_t pin);
WirebenchValue wirebench_sim_get_param(const WirebenchSim *sim, int32_t index, int32_t pin);
WirebenchValue wirebench_sim_get_out(const WirebenchSim *sim, int32_t index, int32_t pin);
void wirebench_sim_set_in(WirebenchSim *sim, int32_t index, int32_t pin, WirebenchValue value);
void wirebench_sim_set_param(WirebenchSim *sim, int32_t index, int32_t pin, WirebenchValue value);
void wirebench_sim_set_out(WirebenchSim *sim, int32_t index, int32_t pin, WirebenchValue value);

/* --- What the app needs to drive the core directly, with no Swift engine beside it. --- */

/// Sets an output high for `cycles` passes of its module, then low: a push button's single click
/// (`BoolVarBlock.trigger`). Writing the pin with `wirebench_sim_set_out` would clear any pending pulse instead.
void wirebench_sim_pulse_out(WirebenchSim *sim, int32_t index, int32_t pin, int32_t cycles);

/// Winds one module's internal state and outputs back to its reset values, keeping its inputs and
/// parameters — what a block's own `reset()` does, as the inspector's Reset button asks.
void wirebench_sim_reset_module(WirebenchSim *sim, int32_t index);

/// Changes a module's `variant` live (an RS block's priority, a timer's mode), keeping its state.
void wirebench_sim_set_variant(WirebenchSim *sim, int32_t index, int32_t variant);

/// Per-module string configuration the C++ core cannot read from a project (a register name, an interrupt source).
void wirebench_sim_set_string(WirebenchSim *sim, int32_t index, const char *key, const char *value);

/// A Maraflow ST page's compile error, or NULL. Valid after the page has first run.
const char *wirebench_sim_maraflow_st_error(WirebenchSim *sim, int32_t index);

/// The whole-project wire and macro sweep, outside a step: an edit made by hand reaches its consumers now.
void wirebench_sim_propagate(WirebenchSim *sim);

/// How many times a thread has run since the runtime was built or reset.
uint64_t wirebench_sim_thread_run_count(const WirebenchSim *sim, int32_t threadId);

/// A thread's period: the profile's when it has one, otherwise the project's cycle.
double wirebench_sim_thread_interval_ms(const WirebenchSim *sim, int32_t threadId);

/// A digest of every pin value, for "did anything change?". Faithful: every pin's kind and exact bits are
/// mixed in (FNV-1a), so equal digests mean equal pins, short of a hash collision.
uint64_t wirebench_sim_pins_digest(const WirebenchSim *sim);

/// How many of `WirebenchBlockKind` the core implements (i.e. excluding `WIREBENCH_BLOCK_UNRESOLVED`).
int32_t wirebench_sim_portable_kind_count(void);

#ifdef __cplusplus
}
#endif

#endif /* WIREBENCH_SIM_CXX_H */
