//
//  DirigoSimCore.cpp
//  DirigoSwift
//
//  The simulation core, in C++.
//
//  This is a port of `SimulationEngine` plus the block behaviours it drives, kept deliberately
//  line-for-line comparable with the Swift so the two can be run side by side and their pin values
//  compared. Where a rule is subtle the Swift is the reference and the comment below says which rule it
//  mirrors, because "it compiles" is not evidence that a simulation agrees with the one it replaced.
//
//  Ported so far: the runtime mechanics (schedule by thread and ORDER, per-thread periods, wire
//  propagation, the tick counter) and six block behaviours — `Not`, `And`, `Or`, `Xor`, `BoolVar` and
//  `PulseGen`. Everything else is `UNRESOLVED`: present, holding its inputs, contributing nothing.
//

#include "DirigoSimCxx.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <deque>
#include <limits>
#include <map>
#include <unordered_map>
#include <vector>

namespace {

inline bool asBool(const DirigoValue &v) {
    switch (v.kind) {
        case DIRIGO_VALUE_BOOL:
        case DIRIGO_VALUE_INT16:
        case DIRIGO_VALUE_INT32: return v.i != 0;
        case DIRIGO_VALUE_INT64: return v.i64 != 0;
        case DIRIGO_VALUE_FLOAT: return v.f != 0.0;
        default: return false;
    }
}

/// `PinValue.saturating`: a float as an Int32, truncated toward zero, clamped to the range, NaN as 0.
inline int32_t saturatingInt32(double f) {
    const float v = static_cast<float>(f);
    if (std::isnan(v)) return 0;
    if (v >= 2147483648.0f) return std::numeric_limits<int32_t>::max();
    if (v <= -2147483648.0f) return std::numeric_limits<int32_t>::min();
    return static_cast<int32_t>(v);
}

/// `PinValue.asInt`.
inline int64_t asInt(const DirigoValue &v) {
    switch (v.kind) {
        case DIRIGO_VALUE_BOOL:
        case DIRIGO_VALUE_INT16:
        case DIRIGO_VALUE_INT32: return v.i;
        case DIRIGO_VALUE_INT64: return v.i64;
        case DIRIGO_VALUE_FLOAT: return saturatingInt32(v.f);
        default: return 0;
    }
}

/// `PinValue.asInt32`: an Int64 truncates, a float saturates.
inline int32_t asInt32(const DirigoValue &v) {
    switch (v.kind) {
        case DIRIGO_VALUE_BOOL:
        case DIRIGO_VALUE_INT16:
        case DIRIGO_VALUE_INT32: return v.i;
        case DIRIGO_VALUE_INT64: return static_cast<int32_t>(v.i64);
        case DIRIGO_VALUE_FLOAT: return saturatingInt32(v.f);
        default: return 0;
    }
}

/// `PinValue.asFloat`, which is a Swift `Float`: every result is rounded to single precision.
inline float asFloat(const DirigoValue &v) {
    switch (v.kind) {
        case DIRIGO_VALUE_BOOL:
        case DIRIGO_VALUE_INT16:
        case DIRIGO_VALUE_INT32: return static_cast<float>(v.i);
        case DIRIGO_VALUE_INT64: return static_cast<float>(v.i64);
        case DIRIGO_VALUE_FLOAT: return static_cast<float>(v.f);
        default: return 0.0f;
    }
}

/// `PinValue ==`: the kind is part of the value, so `.bool(true)` is not `.int32(1)`, and NaN is unequal.
inline bool valuesEqual(const DirigoValue &a, const DirigoValue &b) {
    if (a.kind != b.kind) return false;
    switch (a.kind) {
        case DIRIGO_VALUE_BOOL:
        case DIRIGO_VALUE_INT16:
        case DIRIGO_VALUE_INT32: return a.i == b.i;
        case DIRIGO_VALUE_INT64: return a.i64 == b.i64;
        case DIRIGO_VALUE_FLOAT: return static_cast<float>(a.f) == static_cast<float>(b.f);
        default: return true;
    }
}

inline DirigoValue boolean(bool value) {
    DirigoValue v{};
    v.kind = DIRIGO_VALUE_BOOL;
    v.i = value ? 1 : 0;
    return v;
}

inline DirigoValue int32Value(int32_t value) {
    DirigoValue v{};
    v.kind = DIRIGO_VALUE_INT32;
    v.i = value;
    return v;
}

/// A float pin. Stored as a double for the C ABI, but always a value a Swift `Float` can hold.
inline DirigoValue floatValue(double value) {
    DirigoValue v{};
    v.kind = DIRIGO_VALUE_FLOAT;
    v.f = static_cast<float>(value);
    return v;
}

/// Days since 1 Jan 1980 for a proleptic Gregorian date — `DirigoEpoch.days`, by Howard Hinnant's
/// `days_from_civil`. A day past the end of its month rolls into the next, as `Calendar.date(from:)` does.
inline int64_t daysSince1980(int64_t year, int64_t month, int64_t day) {
    auto fromCivil = [](int64_t y, int64_t m, int64_t d) {
        y -= m <= 2;
        const int64_t era = (y >= 0 ? y : y - 399) / 400;
        const int64_t yoe = y - era * 400;
        const int64_t doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
        const int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146097 + doe - 719468;
    };
    return fromCivil(year, month, 1) + (day - 1) - fromCivil(1980, 1, 1);
}

/// The inverse: the calendar date `days` after 1 Jan 1980 (`civil_from_days`).
inline void civilFrom1980(int64_t days, int64_t &year, int64_t &month, int64_t &day) {
    const int64_t z = days + 3652 + 719468;     /* 1980-01-01 is 3652 days after the Unix epoch */
    const int64_t era = (z >= 0 ? z : z - 146096) / 146097;
    const int64_t doe = z - era * 146097;
    const int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const int64_t mp = (5 * doy + 2) / 153;
    day = doy - (153 * mp + 2) / 5 + 1;
    month = mp + (mp < 10 ? 3 : -9);
    year = yoe + era * 400 + (month <= 2);
}

inline DirigoValue undefinedValue() {
    DirigoValue v{};
    v.kind = DIRIGO_VALUE_UNDEFINED;
    return v;
}

struct Module {
    int32_t id = 0;
    int32_t order = 0;
    int32_t threadId = 0;
    int32_t kind = DIRIGO_BLOCK_UNRESOLVED;
    std::vector<DirigoValue> inPins;
    std::vector<DirigoValue> paramPins;
    std::vector<DirigoValue> outPins;
    int32_t cycleCounter = 0;      /* PulseGen */
    int32_t pulseRemaining = 0;    /* BoolVar */
    int32_t currentCount = 0;      /* Counter */
    int32_t intValue = 0;          /* IntVar: the variable itself, not a pin */
    bool lastTr = false;           /* Counter: for the 0->1 edge */
    int32_t variant = 0;           /* DirigoModuleDesc.variant */
    int64_t config[4] = {0, 0, 0, 0};
    int64_t remaining = 0;         /* SinglePulse */
    int64_t total = 0;             /* SinglePulse; PulseLen's active cycles; AdvCounter's value */
    double filterValue = 0;        /* Filter */
    std::deque<int64_t> history;   /* Mean */
    DirigoValue lastValue{};       /* Trigger; `undefined` until it has run */
    bool processedOnce = false;    /* Trigger; DelayFilter's "armed" */
    bool flagA = false;            /* WaterRegulator's open latch, HystComparator's "greater", StepDriver's commanded */
    bool flagB = false;            /* WaterRegulator's close latch, HystComparator's "less" */
    int64_t s[3] = {0, 0, 0};      /* StepDriver: position, speed, target */
    double floatVar = 0;           /* FloatVar: the variable itself, not a pin */
    std::vector<std::pair<int64_t, int64_t>> caseRanges;   /* Case */
};

struct Connection {
    int32_t inModule = 0;
    int32_t inPin = 0;
    int32_t outModule = 0;
    int32_t outPin = 0;
    bool inverted = false;
    bool toParamPins = false;
};

struct Sample {
    uint64_t tickCount = 0;
    double deltaMs = 0;
};

}  // namespace

struct DirigoSim {
    std::vector<Module> modules;
    std::unordered_map<int32_t, size_t> indexById;
    std::vector<Connection> connections;
    std::unordered_map<int32_t, std::vector<size_t>> outgoingByModule;
    /// Connections *into* a module, which is what `Set`'s write-through walks (the Swift
    /// `inConnectionMap`). Built alongside `outgoingByModule`.
    std::unordered_map<int32_t, std::vector<size_t>> incomingByModule;
    /// Macro interfaces, resolved from module attributes Swift-side. See `DirigoMacroBridge`.
    std::vector<DirigoMacroBridge> macroBridges;
    int32_t macroSweeps = 1;
    /// The step's wall clock, decomposed by Swift. See `dirigo_sim_set_wall_clock`.
    DirigoWallClock wallClock{0, 0, 0, 0, 0};
    std::vector<std::vector<size_t>> schedule;   /* by thread id, in ORDER */
    std::vector<int32_t> threadIds;              /* ascending */
    std::map<int32_t, double> threadElapsedMs;
    /// Thread periods from the hardware profile.
    std::map<int32_t, double> threadIntervalMs;
    /// How many times each thread has run.
    std::map<int32_t, uint64_t> threadRunCounts;
    uint64_t tickCount = 0;
    double cycleDelayMs = 1;
    bool profileScheduling = false;

    /// The PLC's array data area, addressed by `Id` (`IntArrayStore`). Doubles, so one array can be read as
    /// Int, Long or Float, as in the original's single data area.
    std::map<int64_t, std::vector<double>> arrays;

    /* Construct state (the Swift `condStack` and friends), reset at the start of every step. */
    int64_t condStack = 0;
    std::vector<size_t> constructStack;
    std::map<size_t, std::pair<bool, int64_t>> switchSelector;   /* captured?, value */
    std::map<size_t, bool> switchMatched;
};

namespace {

/// A thread's period: the profile's when it gives one, otherwise the project's cycle.
double intervalMs(const DirigoSim *sim, int32_t threadId) {
    auto found = sim->threadIntervalMs.find(threadId);
    if (found != sim->threadIntervalMs.end() && found->second > 0) return found->second;
    return std::max(1.0, sim->cycleDelayMs);
}

/// One module, mirroring its Swift block's `process(sample:)` exactly — including the `En = 0` rule,
/// which holds the output rather than clearing it (docs/spec/blocks-datapath.md §0.5).
void processModule(DirigoSim *sim, Module &m, const Sample &sample, const DirigoWallClock &clock) {
    (void)sample;
    /* Every kind below writes outputs and nothing else a reader can see (`Set` works in the step loop, not
       here), so a module without out pins has nothing to do — and the cases may then index `outPins[0]`. */
    if (m.outPins.empty()) return;
    switch (m.kind) {
        case DIRIGO_BLOCK_NOT: {
            const bool enabled = m.inPins.empty() ? true : asBool(m.inPins[0]);
            if (!enabled) return;                                   /* holds */
            const bool value = m.inPins.size() > 1 ? asBool(m.inPins[1]) : false;
            if (!m.outPins.empty()) m.outPins[0] = boolean(!value);
            return;
        }
        case DIRIGO_BLOCK_AND:
        case DIRIGO_BLOCK_OR:
        case DIRIGO_BLOCK_XOR: {
            if (m.inPins.empty()) return;
            if (!asBool(m.inPins[0])) return;                        /* holds */
            bool result = m.kind == DIRIGO_BLOCK_AND;
            for (size_t i = 1; i < m.inPins.size(); ++i) {
                const bool bit = asBool(m.inPins[i]);
                if (m.kind == DIRIGO_BLOCK_AND) {
                    result = result && bit;
                    if (!result) break;
                } else if (m.kind == DIRIGO_BLOCK_OR) {
                    result = result || bit;
                    if (result) break;
                } else {
                    result = result != bit;
                }
            }
            if (!m.outPins.empty()) m.outPins[0] = boolean(result);
            return;
        }
        case DIRIGO_BLOCK_BOOLVAR: {
            /* A held button owns its value; only an un-held single-shot pulse expires. */
            if (m.pulseRemaining > 0) {
                m.pulseRemaining -= 1;
                if (m.pulseRemaining == 0 && !m.outPins.empty()) m.outPins[0] = boolean(false);
            }
            return;
        }
        case DIRIGO_BLOCK_PULSEGEN: {
            const bool enabled = m.inPins.empty() ? true : asBool(m.inPins[0]);
            const bool active = m.inPins.size() > 1 ? asBool(m.inPins[1]) : false;
            if (!enabled || !active) {                               /* "If Act=0 both outputs are cleared" */
                m.cycleCounter = 0;
                if (!m.outPins.empty()) m.outPins[0] = int32Value(0);
                if (m.outPins.size() > 1) m.outPins[1] = boolean(false);
                return;
            }
            const int64_t tOn = std::max<int64_t>(1, m.paramPins.size() > 0 ? asInt(m.paramPins[0]) : 1);
            const int64_t tOff = std::max<int64_t>(1, m.paramPins.size() > 1 ? asInt(m.paramPins[1]) : 1);
            const int64_t period = tOn + tOff;
            if (m.outPins.size() > 1) m.outPins[1] = boolean(m.cycleCounter < tOn);
            if (!m.outPins.empty()) m.outPins[0] = int32Value(static_cast<int32_t>(m.cycleCounter + 1));
            m.cycleCounter += 1;
            if (m.cycleCounter >= period) m.cycleCounter = 0;
            return;
        }
        case DIRIGO_BLOCK_COUNTER: {
            bool enabled, tr, rst;
            if (m.inPins.size() <= 2) {                              /* the two-pin form has no En */
                enabled = true;
                tr = m.inPins.size() > 0 ? asBool(m.inPins[0]) : false;
                rst = m.inPins.size() > 1 ? asBool(m.inPins[1]) : false;
            } else {
                enabled = asBool(m.inPins[0]);
                tr = asBool(m.inPins[1]);
                rst = asBool(m.inPins[2]);
            }
            const int32_t step = m.paramPins.size() > 0
                ? static_cast<int32_t>(asInt(m.paramPins[0])) : 1;
            if (rst) {
                m.currentCount = 0;
                m.lastTr = tr;
                if (!m.outPins.empty()) m.outPins[0] = int32Value(0);
                return;
            }
            if (!enabled) { m.lastTr = tr; return; }                 /* holds, but the edge is tracked */
            const bool rising = !m.lastTr && tr;
            m.lastTr = tr;
            if (rising) {                                            /* `&+=`: wrapping, as in the Swift */
                m.currentCount = static_cast<int32_t>(
                    static_cast<uint32_t>(m.currentCount) + static_cast<uint32_t>(step));
            }
            if (!m.outPins.empty()) m.outPins[0] = int32Value(m.currentCount);
            return;
        }
        case DIRIGO_BLOCK_COMPARATOR: {
            // The Swift compares whether or not `En` is set — a quirk of the block, mirrored here.
            int64_t a, b;
            if (m.inPins.size() <= 2) {
                a = m.inPins.size() > 0 ? asInt(m.inPins[0]) : 0;
                b = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            } else {
                a = asInt(m.inPins[1]);
                b = asInt(m.inPins[2]);
            }
            if (m.outPins.size() > 0) m.outPins[0] = boolean(a > b);
            if (m.outPins.size() > 1) m.outPins[1] = boolean(a == b);
            if (m.outPins.size() > 2) m.outPins[2] = boolean(a < b);
            return;
        }
        case DIRIGO_BLOCK_INT2BITS: {
            const int64_t value = m.inPins.empty() ? 0 : asInt(m.inPins[0]);
            for (size_t i = 0; i < m.outPins.size(); ++i) {
                m.outPins[i] = boolean(i < 63 && (value & (static_cast<int64_t>(1) << i)) != 0);
            }
            return;
        }
        case DIRIGO_BLOCK_SYSTEMCMD: {
            const bool enabled = m.inPins.empty() ? true : asBool(m.inPins[0]);
            if (!enabled) return;                                    /* holds */
            /* Mirrors `SystemCommandSimulation.result`: arithmetic is computed, a command that sets something
               answers with what it set, and a query of the unit reads 0. */
            const int64_t command = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            const int64_t par1 = m.paramPins.size() > 0 ? asInt(m.paramPins[0]) : 0;
            const int64_t par2 = m.paramPins.size() > 1 ? asInt(m.paramPins[1]) : 0;
            auto isqrt = [](uint64_t v) -> int64_t {
                if (v < 2) return static_cast<int64_t>(v);
                uint64_t x = static_cast<uint64_t>(std::sqrt(static_cast<double>(v)));
                while (x * x > v) --x;
                while ((x + 1) * (x + 1) <= v) ++x;
                return static_cast<int64_t>(x);
            };
            int64_t value = 0;
            switch (command) {
                case 0x0022:
                    value = isqrt((static_cast<uint64_t>(static_cast<uint32_t>(par2)) << 32)
                                  | static_cast<uint64_t>(static_cast<uint32_t>(par1)));
                    break;
                case 0x0023: {
                    const uint64_t a = static_cast<uint64_t>(par1 < 0 ? -par1 : par1);
                    const uint64_t b = static_cast<uint64_t>(par2 < 0 ? -par2 : par2);
                    value = isqrt(a * a + b * b);
                    break;
                }
                case 0x0024: {
                    const uint64_t c = static_cast<uint64_t>(par1 < 0 ? -par1 : par1);
                    const uint64_t b = static_cast<uint64_t>(par2 < 0 ? -par2 : par2);
                    value = c * c >= b * b ? isqrt(c * c - b * b) : 0;
                    break;
                }
                case 0x0101: case 0x0201: case 0x0301: case 0x0302: case 0x0400: case 0x0402:
                    value = par1;
                    break;
                case 0x0303: case 0x0304: case 0x0401:
                    value = par2;
                    break;
                default:
                    value = 0;
            }
            for (DirigoValue &out : m.outPins) out = int32Value(static_cast<int32_t>(value));
            return;
        }
        case DIRIGO_BLOCK_SWITCH: {
            if (m.inPins.size() < 2) return;
            if (!asBool(m.inPins[0])) return;                        /* En = 0 holds */
            const int64_t sw = asInt(m.inPins[1]);
            const int64_t target = 2 + sw;
            if (target >= 2 && target < static_cast<int64_t>(m.inPins.size())) {
                if (!m.outPins.empty()) m.outPins[0] = m.inPins[target];
            } else if (!m.outPins.empty()) {
                /* "If the Sw input is outside the range 0 to (N-1), output Y is cleared." */
                m.outPins[0] = m.variant == 1 ? floatValue(0) : int32Value(0);
            }
            return;
        }
        case DIRIGO_BLOCK_INRANGE: {
            /* `En` holds rather than clearing, like the rest. `L` and `H` are *parameters*, not pins. */
            const bool enabled = m.inPins.empty() ? true : asBool(m.inPins[0]);
            if (!enabled) return;
            const int64_t x = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            if (m.paramPins.size() < 2) return;
            const int64_t l = asInt(m.paramPins[0]);
            const int64_t h = asInt(m.paramPins[1]);
            /* H is exclusive, and L > H wraps — the time switch that spans midnight. The Swift
               transposes the help's two comparisons deliberately; mirror the Swift. */
            const bool inRange = l <= h ? (x >= l && x < h) : (x >= l || x < h);
            if (!m.outPins.empty()) m.outPins[0] = boolean(inRange);
            return;
        }
        case DIRIGO_BLOCK_EQUITHERM: {
            const bool enabled = m.inPins.empty() ? true : asBool(m.inPins[0]);
            if (!enabled) return;
            const int64_t ot = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            if (m.paramPins.size() < 4) return;
            const int64_t ax = asInt(m.paramPins[0]), ay = asInt(m.paramPins[1]);
            const int64_t bx = asInt(m.paramPins[2]), by = asInt(m.paramPins[3]);
            /* The line through A and B, extrapolated beyond the segment. Integer division truncates
               toward zero in both languages, and `int64_t` is wide enough for `(by-ay)*(ot-ax)`. */
            const int64_t wt = bx == ax ? ay : ay + (by - ay) * (ot - ax) / (bx - ax);
            if (!m.outPins.empty()) m.outPins[0] = int32Value(static_cast<int32_t>(wt));
            return;
        }
        case DIRIGO_BLOCK_DATETIME: {
            /* The clock is handed in, never read here — see `DirigoWallClock`. `En` holds, as usual.
               The output set is per-instance (a real module carries 5 out pins, the help table says 6),
               so this writes as many of the six values as the module actually has. */
            const bool enabled = m.inPins.empty() ? true : asBool(m.inPins[0]);
            if (!enabled) return;
            /* `DateTimeBlock`: the step's instant plus the module's offset (a legacy param pin wins over
               the `OFFS` attribute), split in UTC. Days count whole days since 1980 and truncate toward
               zero, as `Calendar.dateComponents([.day], from:to:)` does; the time of day and the weekday
               come from the calendar day the instant falls in. */
            const int64_t offset = m.paramPins.empty() ? m.config[0] : asInt(m.paramPins[0]);
            const int64_t secs = static_cast<int64_t>(std::floor(clock.unixSeconds)) + offset;
            const int64_t since1980 = secs - 315532800;            /* 1980-01-01T00:00:00Z */
            const int64_t unixDay = secs >= 0 ? secs / 86400 : -((-secs + 86399) / 86400);
            const int64_t sod = secs - unixDay * 86400;
            const int64_t values[6] = {
                since1980 / 86400, sod / 3600, (sod / 60) % 60, sod % 60,
                ((unixDay + 3) % 7 + 7) % 7,                      /* 1 Jan 1970 was a Thursday; 0 = Monday */
                sod,
            };
            for (size_t i = 0; i < m.outPins.size() && i < 6; ++i) {
                m.outPins[i] = int32Value(static_cast<int32_t>(values[i]));
            }
            return;
        }
        case DIRIGO_BLOCK_BITS2INT: {
            /* In 0 is `En`, then B0..Bn-1. Treating `En` as B0 shifts every bit up one place, which is
               a bug this port would otherwise inherit. */
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;      /* holds */
            const size_t bits = m.inPins.empty() ? 0 : m.inPins.size() - 1;
            int32_t packed = 0;
            for (size_t i = 0; i < bits && i < 32; ++i) {
                if (asBool(m.inPins[i + 1])) packed |= static_cast<int32_t>(1u << i);
            }
            /* An Int is a 16-bit signed word: all sixteen bits set read back as -1, which is how a sign bit
               copied into the upper inputs gives a negative number. */
            if (bits >= 16) packed = static_cast<int16_t>(packed);
            if (!m.outPins.empty()) m.outPins[0] = int32Value(packed);
            return;
        }
        case DIRIGO_BLOCK_RS: {
            /* A latch: `En = 0` holds. Reset priority unless `variant` asks for set priority. Like the Swift
               `RSBlock`, the state *is* the output pin: a value written into Q (by `Set`, or by hand) is
               what the next pass keeps. */
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;      /* holds */
            const bool setIn = m.inPins.size() > 1 ? asBool(m.inPins[1]) : false;
            const bool resetIn = m.inPins.size() > 2 ? asBool(m.inPins[2]) : false;
            if (m.outPins.empty()) return;
            if (m.variant == 1) {
                if (setIn) m.outPins[0] = boolean(true);
                else if (resetIn) m.outPins[0] = boolean(false);
            } else {
                if (resetIn) m.outPins[0] = boolean(false);
                else if (setIn) m.outPins[0] = boolean(true);
            }
            return;
        }
        case DIRIGO_BLOCK_INTVAR: {
            /* "Performs no operation; it only allocates space for a variable of type Int." The value is
               `m.intValue`, which survives this pass and is written by `Set`/`SetIdx`. */
            if (!m.outPins.empty()) m.outPins[0] = int32Value(m.intValue);
            return;
        }
        case DIRIGO_BLOCK_DIV: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;      /* holds */
            const int64_t a = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            const int64_t b = m.inPins.size() > 2 ? asInt(m.inPins[2]) : 0;
            if (b == 0) {                                               /* guarded, not undefined */
                if (!m.outPins.empty()) m.outPins[0] = int32Value(0);
                if (m.outPins.size() > 1) m.outPins[1] = int32Value(0);
                return;
            }
            if (!m.outPins.empty()) m.outPins[0] = int32Value(static_cast<int32_t>(a / b));
            if (m.outPins.size() > 1) m.outPins[1] = int32Value(static_cast<int32_t>(a % b));
            return;
        }
        case DIRIGO_BLOCK_INTSUB: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;      /* holds */
            const int64_t a = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            const int64_t b = m.inPins.size() > 2 ? asInt(m.inPins[2]) : 0;
            if (!m.outPins.empty()) m.outPins[0] = int32Value(static_cast<int32_t>(a - b));
            return;
        }
        case DIRIGO_BLOCK_YES: {
            for (size_t i = 0; i < m.inPins.size() && i < m.outPins.size(); ++i) m.outPins[i] = m.inPins[i];
            return;
        }
        case DIRIGO_BLOCK_SHL:
        case DIRIGO_BLOCK_SAR: {
            if (m.inPins.empty() || !asBool(m.inPins[0])) return;
            const int64_t value = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            const int64_t shift = m.inPins.size() > 2
                ? std::max<int64_t>(0, std::min<int64_t>(31, asInt(m.inPins[2]))) : 0;
            const int64_t shifted = m.kind == DIRIGO_BLOCK_SHL
                ? static_cast<int64_t>(static_cast<uint64_t>(value) << shift) : value >> shift;
            m.outPins[0] = int32Value(static_cast<int32_t>(shifted));
            return;
        }
        case DIRIGO_BLOCK_EXT: {
            if (m.inPins.empty() || !asBool(m.inPins[0])) return;
            const int64_t value = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            const int64_t offset = m.inPins.size() > 2
                ? std::max<int64_t>(0, std::min<int64_t>(31, asInt(m.inPins[2]))) : 0;
            const int64_t length = m.inPins.size() > 3
                ? std::max<int64_t>(1, std::min<int64_t>(32 - offset, asInt(m.inPins[3]))) : 16;
            const int64_t mask = (static_cast<int64_t>(1) << length) - 1;
            m.outPins[0] = int32Value(static_cast<int32_t>((value >> offset) & mask));
            return;
        }
        case DIRIGO_BLOCK_INS: {
            if (m.inPins.empty() || !asBool(m.inPins[0])) return;
            const int64_t target = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            const int64_t value = m.inPins.size() > 2 ? asInt(m.inPins[2]) : 0;
            const int64_t offset = m.inPins.size() > 3
                ? std::max<int64_t>(0, std::min<int64_t>(31, asInt(m.inPins[3]))) : 0;
            const int64_t length = m.inPins.size() > 4
                ? std::max<int64_t>(1, std::min<int64_t>(32 - offset, asInt(m.inPins[4]))) : 16;
            const int64_t mask = ((static_cast<int64_t>(1) << length) - 1) << offset;
            const int64_t inserted = (target & ~mask)
                | (static_cast<int64_t>(static_cast<uint64_t>(value) << offset) & mask);
            m.outPins[0] = int32Value(static_cast<int32_t>(inserted));
            return;
        }
        case DIRIGO_BLOCK_SINGLEPULSE: {
            const bool twoPins = m.inPins.size() >= 2;
            const bool enabled = twoPins ? asBool(m.inPins[0]) : true;
            const bool tr = twoPins ? asBool(m.inPins[1]) : (!m.inPins.empty() && asBool(m.inPins[0]));
            const bool rising = !m.lastTr && tr;
            m.lastTr = tr;
            auto write = [&m](int64_t count, bool on) {
                if (m.outPins.size() >= 2) { m.outPins[0] = int32Value(static_cast<int32_t>(count)); m.outPins[1] = boolean(on); }
                else if (m.outPins.size() == 1) m.outPins[0] = boolean(on);
            };
            if (!enabled) {                                           /* `reset()` */
                m.remaining = 0; m.total = 0; m.lastTr = false;
                write(0, false);
                return;
            }
            const int64_t tOn = m.paramPins.empty() ? 1 : std::max<int64_t>(1, asInt(m.paramPins[0]));
            if (rising) { m.remaining = tOn; m.total = tOn; }
            if (m.remaining > 0) {
                write(m.total - m.remaining + 1, true);
                m.remaining -= 1;
            } else {
                write(0, false);
            }
            return;
        }
        case DIRIGO_BLOCK_PULSELEN: {
            const bool twoPins = m.inPins.size() >= 2;
            const bool enabled = twoPins ? asBool(m.inPins[0]) : true;
            const bool input = twoPins ? asBool(m.inPins[1]) : (!m.inPins.empty() && asBool(m.inPins[0]));
            if (!enabled) {                                           /* `reset()` */
                m.total = 0; m.lastTr = false;
                if (!m.outPins.empty()) m.outPins[0] = int32Value(0);
                return;
            }
            if (input) {
                m.total += 1;
                if (!m.outPins.empty()) m.outPins[0] = int32Value(static_cast<int32_t>(m.total));
            } else {
                if (m.lastTr && !m.outPins.empty()) m.outPins[0] = int32Value(static_cast<int32_t>(m.total));
                m.total = 0;
            }
            m.lastTr = input;
            return;
        }
        case DIRIGO_BLOCK_IABS:
        case DIRIGO_BLOCK_IINC:
        case DIRIGO_BLOCK_INEG: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            const int64_t x = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            const int64_t y = m.kind == DIRIGO_BLOCK_IABS ? (x < 0 ? -x : x)
                            : m.kind == DIRIGO_BLOCK_IINC ? x + 1 : -x;
            m.outPins[0] = int32Value(static_cast<int32_t>(y));
            return;
        }
        case DIRIGO_BLOCK_IADD:
        case DIRIGO_BLOCK_IMUL: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            const int64_t a = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            const int64_t b = m.inPins.size() > 2 ? asInt(m.inPins[2]) : 0;
            m.outPins[0] = int32Value(static_cast<int32_t>(m.kind == DIRIGO_BLOCK_IADD ? a + b : a * b));
            return;
        }
        case DIRIGO_BLOCK_LIMITER: {
            /* No En on this block: pin 0 is X. */
            const int64_t x = m.inPins.empty() ? 0 : asInt(m.inPins[0]);
            const int64_t maximum = m.paramPins.size() > 0 ? asInt(m.paramPins[0]) : 0;
            const int64_t minimum = m.paramPins.size() > 1 ? asInt(m.paramPins[1]) : 0;
            m.outPins[0] = int32Value(static_cast<int32_t>(std::min(std::max(x, minimum), maximum)));
            return;
        }
        case DIRIGO_BLOCK_CALIBTRANSF: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            const int64_t x = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            if (m.paramPins.size() < 6) return;
            const int64_t xMax = asInt(m.paramPins[0]), xMid = asInt(m.paramPins[1]), xMin = asInt(m.paramPins[2]);
            const int64_t yMax = asInt(m.paramPins[3]), yMid = asInt(m.paramPins[4]), yMin = asInt(m.paramPins[5]);
            auto interpolate = [x](int64_t x0, int64_t y0, int64_t x1, int64_t y1) {
                return x1 == x0 ? y0 : y0 + (y1 - y0) * (x - x0) / (x1 - x0);
            };
            int64_t result;
            if (x <= xMin) result = yMin;
            else if (x <= xMid) result = interpolate(xMin, yMin, xMid, yMid);
            else if (x <= xMax) result = interpolate(xMid, yMid, xMax, yMax);
            else result = yMax;
            m.outPins[0] = int32Value(static_cast<int32_t>(result));
            return;
        }
        case DIRIGO_BLOCK_MEAN: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            const bool trigger = m.inPins.size() > 1 && asBool(m.inPins[1]);
            const int64_t value = m.inPins.size() > 2 ? asInt(m.inPins[2]) : 0;
            const size_t window = static_cast<size_t>(std::max<int64_t>(1, m.config[0]));
            if (trigger) {
                m.history.push_back(value);
                while (m.history.size() > window) m.history.pop_front();
            }
            if (m.history.empty()) return;                          /* no samples yet: hold */
            int64_t sum = 0;
            for (int64_t v : m.history) sum += v;
            m.outPins[0] = int32Value(static_cast<int32_t>(sum / static_cast<int64_t>(m.history.size())));
            return;
        }
        case DIRIGO_BLOCK_FLOATMATH: {
            /* The legacy block computes in `Float` throughout, so every step is single precision here. */
            const float a = m.inPins.size() > 0 ? asFloat(m.inPins[0]) : 0.0f;
            const float b = m.inPins.size() > 1 ? asFloat(m.inPins[1]) : 0.0f;
            float y = 0.0f;
            switch (m.variant) {
                case DIRIGO_FMATH_SUB: y = a - b; break;
                case DIRIGO_FMATH_MUL: y = a * b; break;
                case DIRIGO_FMATH_DIV: y = b != 0.0f ? a / b : 0.0f; break;
                case DIRIGO_FMATH_SQRT: y = a >= 0.0f ? std::sqrt(a) : 0.0f; break;
                case DIRIGO_FMATH_SIN: y = std::sin(a); break;
                case DIRIGO_FMATH_COS: y = std::cos(a); break;
                default: y = a + b; break;
            }
            m.outPins[0] = floatValue(y);
            return;
        }
        case DIRIGO_BLOCK_LONGMATH: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            std::vector<int64_t> ops;
            for (size_t i = 1; i < m.inPins.size(); ++i) ops.push_back(asInt(m.inPins[i]));
            const int64_t first = ops.empty() ? 0 : ops[0];
            int64_t result = 0;
            switch (m.variant) {
                case DIRIGO_LONG_ADD: for (int64_t v : ops) result += v; break;
                case DIRIGO_LONG_SUB: result = first; for (size_t i = 1; i < ops.size(); ++i) result -= ops[i]; break;
                case DIRIGO_LONG_ABS: result = first < 0 ? -first : first; break;
                case DIRIGO_LONG_NEG: result = -first; break;
                case DIRIGO_LONG_NOT: result = ~first; break;
                case DIRIGO_LONG_INC: result = first + 1; break;
                case DIRIGO_LONG_AND: result = first; for (size_t i = 1; i < ops.size(); ++i) result &= ops[i]; break;
                case DIRIGO_LONG_OR: result = first; for (size_t i = 1; i < ops.size(); ++i) result |= ops[i]; break;
                case DIRIGO_LONG_XOR: result = first; for (size_t i = 1; i < ops.size(); ++i) result ^= ops[i]; break;
            }
            for (DirigoValue &out : m.outPins) out = int32Value(static_cast<int32_t>(result));
            return;
        }
        case DIRIGO_BLOCK_FLOATNUM: {
            /* `FloatMathNumericBlock` widens each operand to Double, computes, and rounds back to Float. */
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            std::vector<double> ops;
            for (size_t i = 1; i < m.inPins.size(); ++i) ops.push_back(static_cast<double>(asFloat(m.inPins[i])));
            const double x = ops.empty() ? 0.0 : ops[0];
            const double k = ops.size() > 1 ? ops[1]
                           : (m.paramPins.empty() ? 1.0 : static_cast<double>(asFloat(m.paramPins[0])));
            double result = 0.0;
            switch (m.variant) {
                case DIRIGO_FNUM_ADD: for (double v : ops) result += v; break;
                case DIRIGO_FNUM_SUB: result = x; for (size_t i = 1; i < ops.size(); ++i) result -= ops[i]; break;
                case DIRIGO_FNUM_MUL: result = 1.0; for (double v : ops) result *= v; break;
                case DIRIGO_FNUM_DIV:
                    result = x;
                    for (size_t i = 1; i < ops.size(); ++i) if (ops[i] != 0.0) result /= ops[i];
                    break;
                case DIRIGO_FNUM_ABS: result = std::fabs(x); break;
                case DIRIGO_FNUM_NEG: result = -x; break;
                case DIRIGO_FNUM_SQRT: result = x < 0 ? 0.0 : std::sqrt(x); break;
                case DIRIGO_FNUM_MOD: result = ops.size() > 1 && ops[1] != 0.0 ? std::fmod(x, ops[1]) : 0.0; break;
                case DIRIGO_FNUM_SIN: result = std::sin(x * k); break;
                case DIRIGO_FNUM_COS: result = std::cos(x * k); break;
                case DIRIGO_FNUM_ASIN: result = x < -1 || x > 1 ? 0.0 : std::asin(x) * k; break;
                case DIRIGO_FNUM_ACOS: result = x < -1 || x > 1 ? 0.0 : std::acos(x) * k; break;
            }
            for (DirigoValue &out : m.outPins) out = floatValue(result);
            return;
        }
        case DIRIGO_BLOCK_MOVE: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            const bool trigger = m.inPins.size() > 1 && asBool(m.inPins[1]);
            const bool rising = trigger && !m.lastTr;
            m.lastTr = trigger;
            if (rising && m.inPins.size() > 2) m.outPins[0] = m.inPins[2];
            return;
        }
        case DIRIGO_BLOCK_COPY: {
            if (m.variant == 1) {
                if (!m.inPins.empty() && !asBool(m.inPins[0])) return;   /* Wr = 0 holds */
                for (size_t i = 0; i < m.outPins.size(); ++i) {
                    if (i + 1 < m.inPins.size()) m.outPins[i] = m.inPins[i + 1];
                }
            } else {
                for (size_t i = 0; i < m.inPins.size() && i < m.outPins.size(); ++i) m.outPins[i] = m.inPins[i];
            }
            return;
        }
        case DIRIGO_BLOCK_ENCODEDATE: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            const int64_t day = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 1;
            const int64_t month = m.inPins.size() > 2 ? asInt(m.inPins[2]) : 1;
            const int64_t year = m.inPins.size() > 3 ? asInt(m.inPins[3]) : 2000;
            if (day < 1 || day > 31 || month < 1 || month > 12 || year < 1980 || year > 2190) return;   /* hold */
            m.outPins[0] = int32Value(static_cast<int32_t>(daysSince1980(year, month, day)));
            return;
        }
        case DIRIGO_BLOCK_DECODEDATE: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            const int64_t days = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            int64_t year = 1980, month = 1, day = 1;
            civilFrom1980(days, year, month, day);
            if (m.outPins.size() > 0) m.outPins[0] = int32Value(static_cast<int32_t>(day));
            if (m.outPins.size() > 1) m.outPins[1] = int32Value(static_cast<int32_t>(month));
            if (m.outPins.size() > 2) m.outPins[2] = int32Value(static_cast<int32_t>(year));
            if (m.outPins.size() > 3) m.outPins[3] = int32Value(static_cast<int32_t>(month * 100 + day));
            return;
        }
        case DIRIGO_BLOCK_IDEMUX:
        case DIRIGO_BLOCK_FDEMUX: {
            /* "The values of the other Y outputs remain unchanged"; an out-of-range selector writes nothing. */
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            const int64_t sel = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            if (sel < 0 || sel >= static_cast<int64_t>(m.outPins.size())) return;
            if (m.kind == DIRIGO_BLOCK_IDEMUX) {
                m.outPins[sel] = int32Value(m.inPins.size() > 2 ? asInt32(m.inPins[2]) : 0);
            } else {
                m.outPins[sel] = floatValue(m.inPins.size() > 2 ? asFloat(m.inPins[2]) : 0.0f);
            }
            return;
        }
        case DIRIGO_BLOCK_ADVCOUNTER: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            auto in = [&m](size_t i) { return m.inPins.size() > i && asBool(m.inPins[i]); };
            auto param = [&m](size_t i, int64_t fallback) {
                return m.paramPins.size() > i ? asInt(m.paramPins[i]) : fallback;
            };
            const bool trigger = in(1), reset = in(2), preset = in(3), enableHigh = in(4), enableLow = in(5);
            const int64_t presetValue = param(0, 0), maximum = param(1, 0), minimum = param(2, 0), step = param(3, 1);
            const bool rising = trigger && !m.lastTr;
            m.lastTr = trigger;
            if (reset) m.total = 0;
            else if (preset) m.total = presetValue;
            else if (rising) m.total += step;
            if (enableHigh && m.total > maximum) m.total = maximum;
            if (enableLow && m.total < minimum) m.total = minimum;
            if (m.outPins.size() > 0) m.outPins[0] = int32Value(static_cast<int32_t>(m.total));
            if (m.outPins.size() > 1) m.outPins[1] = boolean(m.total >= maximum);
            if (m.outPins.size() > 2) m.outPins[2] = boolean(m.total <= minimum);
            return;
        }
        case DIRIGO_BLOCK_FILTER: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            const double x = static_cast<double>(m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0);
            const int64_t t = std::max<int64_t>(1, m.paramPins.empty() ? 10 : asInt(m.paramPins[0]));
            m.filterValue += (x - m.filterValue) / static_cast<double>(t);
            m.outPins[0] = int32Value(static_cast<int32_t>(std::round(m.filterValue)));
            return;
        }
        case DIRIGO_BLOCK_IAND:
        case DIRIGO_BLOCK_IOR:
        case DIRIGO_BLOCK_IXOR: {
            if (m.inPins.empty() || !asBool(m.inPins[0])) return;
            const int32_t a = m.inPins.size() > 1 ? asInt32(m.inPins[1]) : 0;
            const int32_t b = m.inPins.size() > 2 ? asInt32(m.inPins[2]) : 0;
            m.outPins[0] = int32Value(m.kind == DIRIGO_BLOCK_IAND ? (a & b) : m.kind == DIRIGO_BLOCK_IOR ? (a | b) : (a ^ b));
            return;
        }
        case DIRIGO_BLOCK_INOT: {
            if (m.inPins.empty() || !asBool(m.inPins[0])) return;
            m.outPins[0] = int32Value(~(m.inPins.size() > 1 ? asInt32(m.inPins[1]) : 0));
            return;
        }
        case DIRIGO_BLOCK_TRIGGER: {
            /* "Changed since the previous cycle", in either direction — and a change of *kind* counts. */
            if (m.inPins.empty() || !asBool(m.inPins[0])) return;
            const DirigoValue current = m.inPins.size() > 1 ? m.inPins[1] : boolean(false);
            if (!m.processedOnce) {
                m.processedOnce = true;
                m.lastValue = current;
                std::fill(m.outPins.begin(), m.outPins.end(), boolean(false));
                return;
            }
            const bool changed = !valuesEqual(current, m.lastValue);
            m.lastValue = current;
            if (!m.outPins.empty()) m.outPins[0] = boolean(changed);
            return;
        }
        case DIRIGO_BLOCK_CONSTOUT: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;      /* "not executed": hold */
            for (size_t i = 0; i < m.outPins.size(); ++i) {
                switch (m.variant) {
                    case 1: m.outPins[i] = boolean(false); break;
                    case 2: m.outPins[i] = floatValue(0); break;
                    case 3: m.outPins[i] = i == 0 ? boolean(false) : int32Value(0); break;
                    default: m.outPins[i] = int32Value(0); break;
                }
            }
            return;
        }
        case DIRIGO_BLOCK_DELAYFILTER: {
            /* `remaining` is optional in the Swift (`nil` until first armed): `processedOnce` says it is set. */
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            const bool input = m.inPins.size() > 1 && asBool(m.inPins[1]);
            const int64_t delay = std::max<int64_t>(0, m.paramPins.empty() ? 0 : asInt(m.paramPins[0]));
            if (!input) {
                m.remaining = delay; m.processedOnce = true;
                m.lastTr = false;
            } else if (!m.lastTr) {
                const int64_t current = m.processedOnce ? m.remaining : delay;
                const int64_t next = std::max<int64_t>(0, current - 1);
                m.remaining = next; m.processedOnce = true;
                if (next == 0) m.lastTr = true;
            }
            m.outPins[0] = int32Value(static_cast<int32_t>(m.processedOnce ? m.remaining : delay));
            if (m.outPins.size() > 1) m.outPins[1] = boolean(m.lastTr);
            return;
        }
        case DIRIGO_BLOCK_TIMER: {
            /* `elapsedTicks` is `total`, `lastIn` is `lastTr`. */
            if (m.inPins.empty() || !asBool(m.inPins[0])) return;
            const bool currentIn = m.inPins.size() > 1 && asBool(m.inPins[1]);
            const bool rst = m.inPins.size() > 2 && asBool(m.inPins[2]);
            const int64_t pt = m.paramPins.empty() ? 10 : std::max<int64_t>(1, asInt(m.paramPins[0]));
            auto setQ = [&m](bool q) { m.outPins[0] = boolean(q); };
            if (rst) {                                                  /* `reset()`, then remember In */
                m.total = 0;
                setQ(false);
                if (m.outPins.size() > 1) m.outPins[1] = int32Value(0);
                m.lastTr = currentIn;
                return;
            }
            switch (m.variant) {
                case 1:                                                 /* on-delay, continuous */
                    if (currentIn) { m.total += 1; setQ(m.total >= pt); } else setQ(false);
                    break;
                case 2: {                                               /* fixed pulse */
                    const bool rising = !m.lastTr && currentIn;
                    if (rising && m.total == 0) { m.total = 1; setQ(true); }
                    else if (m.total > 0) {
                        if (m.total < pt) { m.total += 1; setQ(true); }
                        else { setQ(false); if (!currentIn) m.total = 0; }
                    } else setQ(false);
                    break;
                }
                case 3: {                                               /* truncated pulse */
                    const bool rising = !m.lastTr && currentIn;
                    if (rising) { m.total = 1; setQ(true); }
                    else if (currentIn && m.total > 0 && m.total < pt) { m.total += 1; setQ(true); }
                    else { m.total = 0; setQ(false); }
                    break;
                }
                default:                                                /* on-delay */
                    if (currentIn) { if (m.total < pt) m.total += 1; setQ(m.total >= pt); }
                    else { m.total = 0; setQ(false); }
                    break;
            }
            m.lastTr = currentIn;
            if (m.outPins.size() > 1) m.outPins[1] = int32Value(static_cast<int32_t>(m.total));
            return;
        }
        case DIRIGO_BLOCK_RAMP: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            const int64_t x = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            const int64_t up = std::max<int64_t>(0, m.paramPins.size() > 0 ? asInt(m.paramPins[0]) : 0);
            const int64_t down = std::max<int64_t>(0, m.paramPins.size() > 1 ? asInt(m.paramPins[1]) : 0);
            if (x > m.total) m.total = std::min(x, m.total + up);
            else if (x < m.total) m.total = std::max(x, m.total - down);
            m.outPins[0] = int32Value(static_cast<int32_t>(m.total));
            return;
        }
        case DIRIGO_BLOCK_VALVE: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            const bool open = m.inPins.size() > 1 && asBool(m.inPins[1]);
            const bool close = m.inPins.size() > 2 && asBool(m.inPins[2]);
            const int64_t step = m.paramPins.size() > 0 ? asInt(m.paramPins[0]) : 1;
            const int64_t maximum = m.paramPins.size() > 1 ? asInt(m.paramPins[1]) : 0;
            const int64_t minimum = m.paramPins.size() > 2 ? asInt(m.paramPins[2]) : 0;
            if (open != close) m.total += open ? step : -step;
            if (m.total > maximum) m.total = maximum;
            if (m.total < minimum) m.total = minimum;
            m.outPins[0] = int32Value(static_cast<int32_t>(m.total));
            return;
        }
        case DIRIGO_BLOCK_WATERREG: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            const int64_t temperature = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            const int64_t required = m.paramPins.size() > 0 ? asInt(m.paramPins[0]) : 0;
            const int64_t band = m.paramPins.size() > 1 ? asInt(m.paramPins[1]) : 0;
            const int64_t half = m.paramPins.size() > 2 ? asInt(m.paramPins[2]) : 0;
            const bool cooling = m.paramPins.size() > 3 && asBool(m.paramPins[3]);
            const int64_t delta = temperature - required;
            if (delta > band + half) m.flagB = true;
            if (delta < band - half) m.flagB = false;
            if (delta < -band - half) m.flagA = true;
            if (delta > -band + half) m.flagA = false;
            m.outPins[0] = boolean(cooling ? m.flagB : m.flagA);
            if (m.outPins.size() > 1) m.outPins[1] = boolean(cooling ? m.flagA : m.flagB);
            return;
        }
        case DIRIGO_BLOCK_STEPDRV: {
            /* position, speed, target in `s`; `flagA` is "commanded". */
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            auto inInt = [&m](size_t i, int64_t fallback) { return m.inPins.size() > i ? asInt(m.inPins[i]) : fallback; };
            const bool start = m.inPins.size() > 1 && asBool(m.inPins[1]);
            const bool preset = m.inPins.size() > 2 && asBool(m.inPins[2]);
            const int64_t requested = inInt(3, 0), startSpeed = inInt(4, 32);
            const int64_t accel = std::max<int64_t>(1, inInt(5, 64));
            const int64_t posit = inInt(6, 0), prpos = inInt(7, 0);
            int64_t &position = m.s[0], &speed = m.s[1], &target = m.s[2];
            if (preset && speed == 0) position = prpos;
            if (start) { target = posit; m.flagA = true; }
            if (requested == 0) speed = std::max<int64_t>(0, speed - accel);
            else if (speed < requested) speed = speed >= startSpeed ? std::min(requested, speed + accel) : requested;
            else if (speed > requested) speed = std::max(requested, speed - accel);
            const int64_t distance = target - position;
            if (speed > 0 && distance != 0 && m.flagA) {
                const int64_t step = std::min(distance < 0 ? -distance : distance, speed);
                position += distance > 0 ? step : -step;
                if (position == target) m.flagA = false;
            }
            m.outPins[0] = boolean(speed > 0 && (target - position) != 0 && m.flagA);
            if (m.outPins.size() > 1) m.outPins[1] = int32Value(static_cast<int32_t>(speed));
            if (m.outPins.size() > 2) m.outPins[2] = int32Value(static_cast<int32_t>(position));
            return;
        }
        case DIRIGO_BLOCK_HYSTCOMP: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            const int64_t a = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            const int64_t b = m.inPins.size() > 2 ? asInt(m.inPins[2]) : 0;
            const int64_t half = std::max<int64_t>(0, m.paramPins.empty() ? 0 : asInt(m.paramPins[0]));
            if (a > b + half) { m.flagA = true; m.flagB = false; }
            else if (a < b - half) { m.flagB = true; m.flagA = false; }
            m.outPins[0] = boolean(m.flagA);
            if (m.outPins.size() > 1) m.outPins[1] = boolean(a >= b - half && a <= b + half);
            if (m.outPins.size() > 2) m.outPins[2] = boolean(m.flagB);
            return;
        }
        case DIRIGO_BLOCK_MCOMPARE: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            const int64_t x = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            int32_t ordinal = 0;
            for (size_t i = 0; i < m.paramPins.size(); ++i) {
                if (asInt(m.paramPins[i]) == x) { ordinal = static_cast<int32_t>(i + 1); break; }
            }
            m.outPins[0] = int32Value(ordinal);
            return;
        }
        case DIRIGO_BLOCK_IF:
            m.outPins[0] = m.inPins.empty() ? boolean(true) : m.inPins[0];
            return;
        case DIRIGO_BLOCK_ENDIF:
            m.outPins[0] = boolean(true);
            return;
        case DIRIGO_BLOCK_FLOATVAR:
            m.outPins[0] = floatValue(m.floatVar);
            return;
        case DIRIGO_BLOCK_CREATEARRAY: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            const int64_t id = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            const int64_t length = m.inPins.size() > 2 ? asInt(m.inPins[2]) : 16;
            /* `IntArrayStore.create`: Id 0...15, a positive length; the same length keeps the contents. */
            bool ok = false;
            if (id >= 0 && id <= 15 && length > 0) {
                auto existing = sim->arrays.find(id);
                if (existing == sim->arrays.end() || existing->second.size() != static_cast<size_t>(length)) {
                    sim->arrays[id] = std::vector<double>(static_cast<size_t>(length), 0.0);
                }
                ok = true;
            }
            m.outPins[0] = boolean(ok);
            return;
        }
        case DIRIGO_BLOCK_READARRAY:
        case DIRIGO_BLOCK_WRITEARRAY: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            const int64_t id = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            const int64_t index = m.inPins.size() > 2 ? asInt(m.inPins[2]) : 0;
            auto array = sim->arrays.find(id);
            const bool inRange = array != sim->arrays.end() && index >= 0
                && index < static_cast<int64_t>(array->second.size());
            /* An element read back: Float as itself, otherwise truncated through Int to Int32. */
            auto element = [&m](double stored) {
                if (m.variant == 1) return floatValue(static_cast<float>(stored));
                const double clamped = std::isfinite(stored)
                    ? std::max(-9.2e18, std::min(9.2e18, stored)) : 0.0;
                return int32Value(static_cast<int32_t>(static_cast<int64_t>(clamped)));
            };
            if (m.kind == DIRIGO_BLOCK_READARRAY) {
                /* "If the array Id or the Index is outside the permitted range, the value 0 is written." */
                m.outPins[0] = element(inRange ? array->second[static_cast<size_t>(index)] : 0.0);
                return;
            }
            const double stored = m.variant == 1
                ? static_cast<double>(m.inPins.size() > 3 ? asFloat(m.inPins[3]) : 0.0f)
                : static_cast<double>(m.inPins.size() > 3 ? asInt(m.inPins[3]) : 0);
            if (inRange) {                                             /* out of range: Y holds */
                array->second[static_cast<size_t>(index)] = stored;
                m.outPins[0] = element(stored);
            }
            return;
        }
        case DIRIGO_BLOCK_PASSIVE:
        case DIRIGO_BLOCK_MACRO_IO:
        case DIRIGO_BLOCK_ELSE:
        case DIRIGO_BLOCK_SWITCHCASE:
        case DIRIGO_BLOCK_CASE:
        case DIRIGO_BLOCK_DEFAULT:
        case DIRIGO_BLOCK_ENDSWITCH:
        case DIRIGO_BLOCK_SETIDX:
            /* Compute nothing here. A macro interface's pins are written by `propagateMacroCalls`; the
               construct markers act in the step loop, and `SetIdx` writes through there too. */
            return;
        default:
            return;                                                  /* unresolved: holds everything */
    }
}

/// The per-kind `reset()`, mirroring each Swift block's own. `NotBlock` really does reset high and
/// `EightDOBlock` really does keep its `En`, so these are quirks to copy rather than tidy.
void resetModule(Module &m) {
    m.cycleCounter = 0;
    m.pulseRemaining = 0;
    m.currentCount = 0;
    m.lastTr = false;
    m.remaining = 0;
    m.total = 0;
    m.filterValue = 0;
    m.history.clear();
    m.lastValue = undefinedValue();
    m.processedOnce = false;
    m.flagA = false;
    m.flagB = false;
    m.s[0] = m.s[1] = m.s[2] = 0;
    /* `m.floatVar`, like `intValue`, is the variable's data and survives a reset. */
    /* `m.intValue` is deliberately *not* cleared: `IntVar.reset` restores its stored value, because a
       variable is data, not transient state. */
    std::fill(m.inPins.begin(), m.inPins.end(), boolean(false));
    std::fill(m.paramPins.begin(), m.paramPins.end(), int32Value(0));
    switch (m.kind) {
        case DIRIGO_BLOCK_NOT:
            std::fill(m.outPins.begin(), m.outPins.end(), boolean(true));
            return;
        case DIRIGO_BLOCK_PULSEGEN:
            std::fill(m.outPins.begin(), m.outPins.end(), boolean(false));
            if (!m.outPins.empty()) m.outPins[0] = int32Value(0);
            return;
        case DIRIGO_BLOCK_COUNTER:
        case DIRIGO_BLOCK_COMPARATOR:
        case DIRIGO_BLOCK_INT2BITS:
        case DIRIGO_BLOCK_SWITCH:
            /* `ISwitchBlock.reset`: a zero of the switch's own element type. */
            if (!m.outPins.empty()) m.outPins[0] = m.variant == 1 ? floatValue(0) : int32Value(0);
            return;
        case DIRIGO_BLOCK_SYSTEMCMD:
        case DIRIGO_BLOCK_INRANGE:
            std::fill(m.outPins.begin(), m.outPins.end(), boolean(false));
            return;
        case DIRIGO_BLOCK_INTVAR:
            /* `IntVar.reset` restores its *stored* value, not zero — the variable keeps what it holds. */
            if (!m.outPins.empty()) m.outPins[0] = int32Value(m.intValue);
            return;
        case DIRIGO_BLOCK_DATETIME:
        case DIRIGO_BLOCK_BITS2INT:
        case DIRIGO_BLOCK_DIV:
        case DIRIGO_BLOCK_INTSUB:
        case DIRIGO_BLOCK_EQUITHERM:
        case DIRIGO_BLOCK_SHL:
        case DIRIGO_BLOCK_SAR:
        case DIRIGO_BLOCK_EXT:
        case DIRIGO_BLOCK_INS:
        case DIRIGO_BLOCK_PULSELEN:
        case DIRIGO_BLOCK_IABS:
        case DIRIGO_BLOCK_IINC:
        case DIRIGO_BLOCK_INEG:
        case DIRIGO_BLOCK_IADD:
        case DIRIGO_BLOCK_IMUL:
        case DIRIGO_BLOCK_LIMITER:
        case DIRIGO_BLOCK_CALIBTRANSF:
        case DIRIGO_BLOCK_MEAN:
        case DIRIGO_BLOCK_MOVE:
        case DIRIGO_BLOCK_ENCODEDATE:
        case DIRIGO_BLOCK_FILTER:
        case DIRIGO_BLOCK_IAND:
        case DIRIGO_BLOCK_IOR:
        case DIRIGO_BLOCK_IXOR:
        case DIRIGO_BLOCK_INOT:
            /* `WT` resets to an *int* zero, not the boolean default: the kind of a pin is part of the
               value, and the differential test compares the kinds. */
            if (!m.outPins.empty()) m.outPins[0] = int32Value(0);
            return;
        case DIRIGO_BLOCK_YES:
        case DIRIGO_BLOCK_LONGMATH:
        case DIRIGO_BLOCK_COPY:
        case DIRIGO_BLOCK_IDEMUX:
        case DIRIGO_BLOCK_DECODEDATE:
            std::fill(m.outPins.begin(), m.outPins.end(), int32Value(0));
            return;
        case DIRIGO_BLOCK_FLOATMATH:
        case DIRIGO_BLOCK_FLOATNUM:
        case DIRIGO_BLOCK_FDEMUX:
            std::fill(m.outPins.begin(), m.outPins.end(), floatValue(0));
            return;
        case DIRIGO_BLOCK_SINGLEPULSE:
            if (m.outPins.size() >= 2) { m.outPins[0] = int32Value(0); m.outPins[1] = boolean(false); }
            else std::fill(m.outPins.begin(), m.outPins.end(), boolean(false));
            return;
        case DIRIGO_BLOCK_ADVCOUNTER:
            std::fill(m.outPins.begin(), m.outPins.end(), boolean(false));
            if (!m.outPins.empty()) m.outPins[0] = int32Value(0);
            return;
        default:
            std::fill(m.outPins.begin(), m.outPins.end(), boolean(false));
            return;
    }
}

/// One module's outputs to whatever consumes them.
///
/// This is the rule that a first cut got wrong: pushing a block's outputs to its consumers the moment it
/// has run, so that a block later in the same pass sees the *fresh* value rather than the one from the
/// top of the pass. Propagating only at the start and end of a cycle gave a `Not` its input one step
/// late, which the differential test caught immediately.
///
/// The comment here used to claim the Swift engine did this too. It did not — `propagateWires(from:)`
/// had no call site — and the two engines disagreed on `Int2Bits1` and its `Segment1`/`8xDO1` cone until
/// `stepNode` started calling it. The claim is true now, but it was aspirational when written, which is
/// exactly how a port drifts: a comment describing intent reads like a description of behaviour.
void propagateFrom(DirigoSim *sim, size_t sourceIndex) {
    const Module &from = sim->modules[sourceIndex];
    auto found = sim->outgoingByModule.find(from.id);
    if (found == sim->outgoingByModule.end()) return;
    for (size_t connectionIndex : found->second) {
        const Connection &c = sim->connections[connectionIndex];
        auto dst = sim->indexById.find(c.inModule);
        if (dst == sim->indexById.end()) continue;
        Module &to = sim->modules[dst->second];
        if (c.outPin < 0 || static_cast<size_t>(c.outPin) >= from.outPins.size()) continue;
        DirigoValue value = from.outPins[c.outPin];
        if (c.inverted) value = boolean(!asBool(value));
        if (c.inPin < 0) continue;
        if (c.toParamPins) {
            if (static_cast<size_t>(c.inPin) < to.paramPins.size()) to.paramPins[c.inPin] = value;
        } else if (static_cast<size_t>(c.inPin) < to.inPins.size()) {
            to.inPins[c.inPin] = value;
        }
    }
}

/// `Set` / `SetIdx`: writes a value into the *producer* on the other end of a connection.
///
/// Mirrors the Swift `writeThrough` in `SimulationEngine.stepNode`. Nothing here applies `inverted`:
/// the Swift applies it when propagating a value *forward* to a consumer, not when writing back, and
/// this must agree with the Swift engine pin for pin rather than with what would be tidier.
void writeThroughConnection(DirigoSim *sim, const Connection &c, const DirigoValue &value) {
    auto source = sim->indexById.find(c.outModule);
    if (source == sim->indexById.end()) return;
    Module &producer = sim->modules[source->second];

    /* A variable stores state, so the write has to reach the *variable*, not only its output pin:
       writing the pin alone is undone the next time the variable runs. This mirrors the Swift
       `WritableVariable` path, and `IntVar` is the one such kind ported so far. */
    if (producer.kind == DIRIGO_BLOCK_INTVAR) {
        producer.intValue = static_cast<int32_t>(asInt(value));
        if (!producer.outPins.empty()) producer.outPins[0] = int32Value(producer.intValue);
        return;
    }
    /* The other `WritableVariable`: `FloatVarBlock.writeVariable` stores `value.asFloat`. */
    if (producer.kind == DIRIGO_BLOCK_FLOATVAR) {
        producer.floatVar = asFloat(value);
        if (!producer.outPins.empty()) producer.outPins[0] = floatValue(producer.floatVar);
        return;
    }

    /* Anything else recomputes its outputs anyway, so its output pin is all there is to write — the Swift
       `writeThrough` writes `source.block.outPins[outPinId]`, whatever the connection's destination kind. */
    if (c.outPin >= 0 && static_cast<size_t>(c.outPin) < producer.outPins.size()) {
        producer.outPins[c.outPin] = value;
    }
}

/// `TMSetPins`: "Set values of the pin X to the pins P1..Pn".
///
/// Unlike every other kind this computes no output, so it lives in the step loop where the connection
/// graph is in scope. It mirrors the Swift `SetBlock` branch exactly — including that the Swift walks
/// only the **in** connection map and so does *not* write back a producer reached through a param
/// connection. That is a difference from the block's own documentation, but the two engines have to
/// agree, and the corpus (`kostička.pcc`, where `ISwitch1` feeds `Set1`'s param pin) is the test.
void applySetWriteThrough(DirigoSim *sim, size_t index) {
    Module &self = sim->modules[index];
    if (self.inPins.size() < 2) return;
    const DirigoValue value = self.inPins[1];          /* `writeValue` */
    /* Walk the connections whose *destination* is this module: `inConnectionMap[module.id]`. */
    auto incoming = sim->incomingByModule.find(self.id);
    if (incoming == sim->incomingByModule.end()) return;
    for (size_t connectionIndex : incoming->second) {
        const Connection &c = sim->connections[connectionIndex];
        /* `inConnectionMap` holds in-pin connections only, so a param connection is never written back. */
        if (c.toParamPins || c.inPin < 2) continue;    /* `where conn.inPinId >= 2` */
        writeThroughConnection(sim, c, value);
    }
}

/// Mirrors `SimulationEngine.propagateMacroCalls`: moves values across the caller/subpage boundary.
///
/// This is why the step loop calls it at the top and the bottom, as the Swift engine does — a macro's
/// values cross *between* module lists rather than through a connection a single block could pull, so
/// no per-block push can carry them.
void propagateMacroCalls(DirigoSim *sim) {
    for (const DirigoMacroBridge &bridge : sim->macroBridges) {
        auto callerIt = sim->indexById.find(bridge.callerModule);
        auto ifaceIt = sim->indexById.find(bridge.interfaceModule);
        if (callerIt == sim->indexById.end() || ifaceIt == sim->indexById.end()) continue;
        Module &caller = sim->modules[callerIt->second];
        Module &iface = sim->modules[ifaceIt->second];

        if (bridge.kind == DIRIGO_MACRO_INPUTS) {
            /* Caller inPins -> subpage Inputs outPins. The interface module has no inPins of its own. */
            const size_t n = std::min(caller.inPins.size(), iface.outPins.size());
            for (size_t i = 0; i < n; ++i) iface.outPins[i] = caller.inPins[i];
        } else if (bridge.kind == DIRIGO_MACRO_PARAMS) {
            /* Caller paramPins -> subpage Params outPins. */
            const size_t n = std::min(caller.paramPins.size(), iface.outPins.size());
            for (size_t i = 0; i < n; ++i) iface.outPins[i] = caller.paramPins[i];
        } else if (bridge.kind == DIRIGO_MACRO_OUTPUTS) {
            /* Subpage Outputs inPins -> caller outPins. */
            const size_t n = std::min(iface.inPins.size(), caller.outPins.size());
            for (size_t i = 0; i < n; ++i) caller.outPins[i] = iface.inPins[i];
        }
    }
}

/// One connection's value into its consumer: the Swift `propagateWiresOnce` body for one wire.
void carry(DirigoSim *sim, const Connection &c) {
    auto src = sim->indexById.find(c.outModule);
    auto dst = sim->indexById.find(c.inModule);
    if (src == sim->indexById.end() || dst == sim->indexById.end()) return;
    const Module &from = sim->modules[src->second];
    Module &to = sim->modules[dst->second];
    if (c.outPin < 0 || static_cast<size_t>(c.outPin) >= from.outPins.size() || c.inPin < 0) return;
    DirigoValue value = from.outPins[c.outPin];
    if (c.toParamPins) {
        if (static_cast<size_t>(c.inPin) < to.paramPins.size()) to.paramPins[c.inPin] = value;
    } else if (static_cast<size_t>(c.inPin) < to.inPins.size()) {
        if (c.inverted) value = boolean(!asBool(value));
        to.inPins[c.inPin] = value;
    }
}

/// The whole-project sweep, wire by wire **in file order** — in-pin connections, then param connections —
/// as the Swift walks `runtime.inConnections` and then `runtime.paramConnections`. Walking module by module
/// instead gave a different answer whenever two wires fed one pin.
void propagate(DirigoSim *sim) {
    for (int32_t sweep = 0; sweep < sim->macroSweeps; ++sweep) {
        propagateMacroCalls(sim);
        for (const Connection &c : sim->connections) carry(sim, c);
        propagateMacroCalls(sim);
    }
}

/// `SimulationEngine.pullInputs`: refreshes a module's inputs from its producers' *current* outputs just
/// before it runs. Pushing alone is not equivalent: a `Set` that writes a producer's output mid-pass is
/// seen by every consumer that runs after it, because they pull.
void pullInputs(DirigoSim *sim, size_t index) {
    auto incoming = sim->incomingByModule.find(sim->modules[index].id);
    if (incoming == sim->incomingByModule.end()) return;
    for (size_t connectionIndex : incoming->second) carry(sim, sim->connections[connectionIndex]);
}

/// `SetIdx`: writes `X` through the one P pin its `Idx` input selects (`SetIdxBlock.targetPinIndex`).
void applySetIdxWriteThrough(DirigoSim *sim, size_t index) {
    Module &self = sim->modules[index];
    if (self.inPins.size() <= 3) return;
    const int64_t idx = asInt(self.inPins[1]);
    const int64_t selectable = static_cast<int64_t>(self.inPins.size()) - 3;
    if (idx < 0 || idx >= selectable) return;                  /* "no write takes place" */
    const int32_t target = static_cast<int32_t>(3 + idx);
    const DirigoValue value = self.inPins[2];
    auto incoming = sim->incomingByModule.find(self.id);
    if (incoming == sim->incomingByModule.end()) return;
    for (size_t connectionIndex : incoming->second) {
        const Connection &c = sim->connections[connectionIndex];
        if (!c.toParamPins && c.inPin == target) writeThroughConnection(sim, c, value);
    }
}

/// The construct bookkeeping the Swift `stepNode` does before its gate, for every module. It is never
/// gated itself: an `If` in a false branch still pushes its bit and an `EndIf` still pops, or the stack
/// would lose its balance and every later block would be skipped for the rest of the pass.
void constructBookkeeping(DirigoSim *sim, size_t index) {
    Module &m = sim->modules[index];
    const bool enabled = m.inPins.empty() ? true : asBool(m.inPins[0]);
    auto topIs = [sim](int32_t kind) {
        return !sim->constructStack.empty() && sim->modules[sim->constructStack.back()].kind == kind;
    };
    switch (m.kind) {
        case DIRIGO_BLOCK_IF:
        case DIRIGO_BLOCK_SWITCHCASE: {
            /* `b := (not InPinEnabled) xor Inverted`, pushed as the innermost condition. */
            const bool holds = (!enabled) != (m.variant == 1);
            sim->condStack = static_cast<int64_t>(static_cast<uint64_t>(sim->condStack) << 1) | (holds ? 1 : 0);
            sim->constructStack.push_back(index);
            if (m.kind == DIRIGO_BLOCK_SWITCHCASE) {
                sim->switchMatched[index] = false;
                /* The selector is captured only while the switch's own bit is clear. */
                const bool captured = (sim->condStack & 1) == 0 && m.inPins.size() > 1;
                sim->switchSelector[index] = {captured, captured ? asInt(m.inPins[1]) : 0};
            }
            return;
        }
        case DIRIGO_BLOCK_ELSE:
            if (topIs(DIRIGO_BLOCK_IF)) sim->condStack ^= 1;
            return;
        case DIRIGO_BLOCK_ENDIF:
        case DIRIGO_BLOCK_ENDSWITCH:
            if (topIs(m.kind == DIRIGO_BLOCK_ENDSWITCH ? DIRIGO_BLOCK_SWITCHCASE : DIRIGO_BLOCK_IF)) {
                sim->constructStack.pop_back();
                sim->condStack >>= 1;
            }
            return;
        case DIRIGO_BLOCK_CASE: {
            /* Bit 0 := "this case did not match". */
            if (topIs(DIRIGO_BLOCK_SWITCHCASE)) {
                const size_t top = sim->constructStack.back();
                const auto selector = sim->switchSelector[top];
                bool matched = false;
                if (selector.first) {
                    for (const auto &range : m.caseRanges) {
                        if (selector.second >= range.first && selector.second <= range.second) { matched = true; break; }
                    }
                }
                if (matched) sim->switchMatched[top] = true;
                sim->condStack |= 1;
                if (matched) sim->condStack &= ~static_cast<int64_t>(1);
            } else {
                sim->condStack |= 1;
            }
            return;
        }
        case DIRIGO_BLOCK_DEFAULT: {
            /* Runs only when the switch captured a selector and no case matched it. */
            if (topIs(DIRIGO_BLOCK_SWITCHCASE)) {
                const size_t top = sim->constructStack.back();
                const bool runs = sim->switchSelector[top].first && !sim->switchMatched[top];
                sim->condStack |= 1;
                if (runs) sim->condStack &= ~static_cast<int64_t>(1);
            } else {
                sim->condStack |= 1;
            }
            return;
        }
        default:
            return;
    }
}

}  // namespace

extern "C" {

DirigoSim *dirigo_sim_create(const DirigoModuleDesc *modules, int32_t count,
                             const DirigoConnection *connections, int32_t connectionCount,
                             double cycleDelayMs, int32_t profileScheduling) {
    DirigoSim *sim = new DirigoSim();
    sim->cycleDelayMs = cycleDelayMs > 0 ? cycleDelayMs : 1;
    sim->profileScheduling = profileScheduling != 0;

    for (int32_t i = 0; i < count; ++i) {
        const DirigoModuleDesc &d = modules[i];
        Module m;
        m.id = d.id;
        m.order = d.order;
        m.threadId = d.threadId;
        m.kind = d.kind;
        m.variant = d.variant;
        for (int c = 0; c < 4; ++c) m.config[c] = d.config[c];
        m.inPins.assign(static_cast<size_t>(std::max(0, d.inCount)), boolean(false));
        m.paramPins.assign(static_cast<size_t>(std::max(0, d.paramCount)), int32Value(0));
        m.outPins.assign(static_cast<size_t>(std::max(0, d.outCount)), boolean(false));
        for (int32_t p = 0; p < d.inCount && d.initialIn; ++p) m.inPins[p] = d.initialIn[p];
        for (int32_t p = 0; p < d.outCount && d.initialOut; ++p) m.outPins[p] = d.initialOut[p];
        /* A variable's value is its state, and the block was built holding its configured initial value
           in Y. Without this the state stayed 0 and the first pass overwrote the initial value. */
        if (m.kind == DIRIGO_BLOCK_INTVAR && !m.outPins.empty()) m.intValue = asInt32(m.outPins[0]);
        if (m.kind == DIRIGO_BLOCK_FLOATVAR && !m.outPins.empty()) m.floatVar = asFloat(m.outPins[0]);
        sim->indexById[m.id] = sim->modules.size();
        /* A module that has never run is due immediately, and the order within a thread is ORDER. */
        if (static_cast<int32_t>(sim->schedule.size()) <= m.threadId) {
            sim->schedule.resize(static_cast<size_t>(m.threadId) + 1);
        }
        sim->schedule[m.threadId].push_back(sim->modules.size());
        sim->modules.push_back(std::move(m));
    }

    for (size_t t = 0; t < sim->schedule.size(); ++t) {
        std::stable_sort(sim->schedule[t].begin(), sim->schedule[t].end(),
                         [sim](size_t a, size_t b) {
                             return sim->modules[a].order < sim->modules[b].order;
                         });
        if (!sim->schedule[t].empty()) sim->threadIds.push_back(static_cast<int32_t>(t));
    }

    for (int32_t i = 0; i < connectionCount; ++i) {
        const DirigoConnection &c = connections[i];
        Connection conn;
        conn.inModule = c.inModule;
        conn.inPin = c.inPin;
        conn.outModule = c.outModule;
        conn.outPin = c.outPin;
        conn.inverted = c.inverted != 0;
        conn.toParamPins = c.toParamPins != 0;
        sim->connections.push_back(conn);
        const size_t stored = sim->connections.size() - 1;
        sim->outgoingByModule[conn.outModule].push_back(stored);
        sim->incomingByModule[conn.inModule].push_back(stored);
    }
    return sim;
}

void dirigo_sim_set_macro_sweeps(DirigoSim *sim, int32_t sweeps) {
    if (sim) sim->macroSweeps = sweeps < 1 ? 1 : sweeps;
}

void dirigo_sim_set_macro_bridges(DirigoSim *sim, const DirigoMacroBridge *bridges, int32_t count) {
    if (!sim) return;
    sim->macroBridges.clear();
    for (int32_t i = 0; i < count; ++i) {
        /* Only keep bridges whose modules exist: a caller that guesses wrong should get no macro
           behaviour for that bridge rather than an out-of-range index at every step. */
        if (sim->indexById.find(bridges[i].callerModule) == sim->indexById.end()) continue;
        if (sim->indexById.find(bridges[i].interfaceModule) == sim->indexById.end()) continue;
        sim->macroBridges.push_back(bridges[i]);
    }

    /* Deterministic order, by caller then interface then kind.
     *
     * This matters when **several call sites share one subpage**: they all write the same interface
     * module, so the last one applied wins. `jk_master_slave.pcc` is exactly that — five `JK` call
     * sites, each wired to the next (`JK2.in[0] <- JK2.out[1]`, and so on), all pointing at one
     * `Inputs1`. The Swift engine iterates `nodes.values`, a `Dictionary`, so which of the five it
     * applies last is not defined by its source. *(Measured: it produced the same result on four
     * consecutive runs, so it is stable in practice — but that is hash order being stable for a fixed
     * process, not a guarantee, and it is not a definition this engine can port.)* Picking a fixed order
     * at least makes this engine reproducible, and the divergence is recorded rather than papered over.
     */
    std::sort(sim->macroBridges.begin(), sim->macroBridges.end(),
              [](const DirigoMacroBridge &a, const DirigoMacroBridge &b) {
                  if (a.callerModule != b.callerModule) return a.callerModule < b.callerModule;
                  if (a.interfaceModule != b.interfaceModule) return a.interfaceModule < b.interfaceModule;
                  return a.kind < b.kind;
              });
}

void dirigo_sim_set_wall_clock(DirigoSim *sim, DirigoWallClock clock) {
    if (!sim) return;
    sim->wallClock = clock;
}

void dirigo_sim_set_thread_interval(DirigoSim *sim, int32_t threadId, double intervalMs) {
    if (sim) sim->threadIntervalMs[threadId] = intervalMs;
}

void dirigo_sim_set_case_ranges(DirigoSim *sim, int32_t index, const int64_t *ranges, int32_t count) {
    if (!sim || index < 0 || static_cast<size_t>(index) >= sim->modules.size()) return;
    Module &m = sim->modules[index];
    m.caseRanges.clear();
    for (int32_t i = 0; i < count && ranges; ++i) m.caseRanges.emplace_back(ranges[2 * i], ranges[2 * i + 1]);
}

void dirigo_sim_destroy(DirigoSim *sim) { delete sim; }

void dirigo_sim_reset(DirigoSim *sim) {
    if (!sim) return;
    sim->tickCount = 0;
    sim->threadElapsedMs.clear();
    sim->threadRunCounts.clear();
    sim->arrays.clear();             /* the data area is the PLC's, and a reset clears it */
    for (Module &m : sim->modules) resetModule(m);
}

double dirigo_sim_next_due_ms(const DirigoSim *sim) {
    if (!sim || !sim->profileScheduling) return 0;
    const double stepMs = std::max(1.0, sim->cycleDelayMs);
    double soonest = std::numeric_limits<double>::max();
    for (int32_t tid : sim->threadIds) {
        const double interval = intervalMs(sim, tid);
        auto it = sim->threadElapsedMs.find(tid);
        const double elapsed = it == sim->threadElapsedMs.end() ? interval : it->second;
        soonest = std::min(soonest, std::max(0.0, interval - elapsed));
    }
    if (soonest == std::numeric_limits<double>::max()) return 0;
    return soonest <= stepMs ? 0 : soonest - stepMs;
}

double dirigo_sim_ms_until_run(const DirigoSim *sim) {
    if (!sim || !sim->profileScheduling) return 0;
    double soonest = std::numeric_limits<double>::max();
    for (int32_t tid : sim->threadIds) {
        const double interval = intervalMs(sim, tid);
        auto it = sim->threadElapsedMs.find(tid);
        const double elapsed = it == sim->threadElapsedMs.end() ? interval : it->second;
        soonest = std::min(soonest, std::max(0.0, interval - elapsed));
    }
    return soonest == std::numeric_limits<double>::max() ? 0 : soonest;
}

/// The step loop. `forceAll` runs every thread whatever its timer, and leaves the timers alone.
static int32_t stepImpl(DirigoSim *sim, double deltaMs, bool forceAll) {
    sim->tickCount += 1;
    sim->condStack = 0;
    sim->constructStack.clear();
    /* The caller's delta is taken as given, to a thousandth of a millisecond, so a slowed simulation is slowed. */
    const double stepMs = std::max(0.001, deltaMs);
    propagate(sim);
    bool ranAny = false;

    for (int32_t tid : sim->threadIds) {
        const double interval = intervalMs(sim, tid);
        bool isDue = true;
        if (sim->profileScheduling && !forceAll) {
            auto it = sim->threadElapsedMs.find(tid);
            const double elapsed = (it == sim->threadElapsedMs.end() ? interval : it->second) + stepMs;
            if (elapsed + 1e-9 < interval) {
                sim->threadElapsedMs[tid] = elapsed;
                isDue = false;
            } else {
                sim->threadElapsedMs[tid] = std::fmod(elapsed, interval);
            }
        }
        if (!isDue) continue;
        ranAny = true;
        sim->threadRunCounts[tid] += 1;
        Sample sample{sim->tickCount, interval};
        for (size_t index : sim->schedule[tid]) {
            /* `SimulationEngine.stepNode`, in its order: construct bookkeeping (never gated), then the gate,
               then pull, process, write-through and push. */
            constructBookkeeping(sim, index);
            /* The engine-level gate: a module inside a false branch, or whose first in pin reads 0, does
               not run and does not push, so all its outputs hold. That is not each block's own `En` rule —
               it applies even where pin 0 is an operand (`Int2Bits`'s `X`) — and it reads pin 0 *before*
               the pull, as the Swift does. */
            const Module &gated = sim->modules[index];
            if (sim->condStack != 0) continue;
            if (!gated.inPins.empty() && !asBool(gated.inPins[0])) continue;
            pullInputs(sim, index);
            processModule(sim, sim->modules[index], sample, sim->wallClock);
            const int32_t kind = sim->modules[index].kind;
            if (kind == DIRIGO_BLOCK_SETIDX) applySetIdxWriteThrough(sim, index);
            if (kind == DIRIGO_BLOCK_SET) applySetWriteThrough(sim, index);
            propagateFrom(sim, index);       /* the Swift engine pushes after every block */
        }
    }
    if (ranAny) propagate(sim);
    return ranAny ? 1 : 0;
}

int32_t dirigo_sim_step(DirigoSim *sim, double deltaMs) {
    if (!sim) return 0;
    return stepImpl(sim, deltaMs, false);
}

void dirigo_sim_evaluate_now(DirigoSim *sim) {
    if (sim) stepImpl(sim, sim->cycleDelayMs, true);
}

uint64_t dirigo_sim_tick_count(const DirigoSim *sim) { return sim ? sim->tickCount : 0; }

DirigoValue dirigo_sim_get_in(const DirigoSim *sim, int32_t index, int32_t pin) {
    if (!sim || index < 0 || static_cast<size_t>(index) >= sim->modules.size()) return undefinedValue();
    const Module &m = sim->modules[index];
    if (pin < 0 || static_cast<size_t>(pin) >= m.inPins.size()) return undefinedValue();
    return m.inPins[pin];
}

DirigoValue dirigo_sim_get_param(const DirigoSim *sim, int32_t index, int32_t pin) {
    if (!sim || index < 0 || static_cast<size_t>(index) >= sim->modules.size()) return undefinedValue();
    const Module &m = sim->modules[index];
    if (pin < 0 || static_cast<size_t>(pin) >= m.paramPins.size()) return undefinedValue();
    return m.paramPins[pin];
}

DirigoValue dirigo_sim_get_out(const DirigoSim *sim, int32_t index, int32_t pin) {
    if (!sim || index < 0 || static_cast<size_t>(index) >= sim->modules.size()) return undefinedValue();
    const Module &m = sim->modules[index];
    if (pin < 0 || static_cast<size_t>(pin) >= m.outPins.size()) return undefinedValue();
    return m.outPins[pin];
}

void dirigo_sim_set_in(DirigoSim *sim, int32_t index, int32_t pin, DirigoValue value) {
    if (!sim || index < 0 || static_cast<size_t>(index) >= sim->modules.size()) return;
    Module &m = sim->modules[index];
    if (pin < 0 || static_cast<size_t>(pin) >= m.inPins.size()) return;
    m.inPins[pin] = value;
}

void dirigo_sim_set_param(DirigoSim *sim, int32_t index, int32_t pin, DirigoValue value) {
    if (!sim || index < 0 || static_cast<size_t>(index) >= sim->modules.size()) return;
    Module &m = sim->modules[index];
    if (pin < 0 || static_cast<size_t>(pin) >= m.paramPins.size()) return;
    m.paramPins[pin] = value;
}

void dirigo_sim_set_out(DirigoSim *sim, int32_t index, int32_t pin, DirigoValue value) {
    if (!sim || index < 0 || static_cast<size_t>(index) >= sim->modules.size()) return;
    Module &m = sim->modules[index];
    if (pin < 0 || static_cast<size_t>(pin) >= m.outPins.size()) return;
    m.outPins[pin] = value;
    m.pulseRemaining = 0;                 /* `BoolVarBlock.setOutput` */
    /* A variable's value is its *state*, not its pin: writing the pin alone is undone the next time the
       variable runs, so a value set by hand has to reach `intValue` too. */
    if (m.kind == DIRIGO_BLOCK_INTVAR && pin == 0) m.intValue = static_cast<int32_t>(asInt(value));
    if (m.kind == DIRIGO_BLOCK_FLOATVAR && pin == 0) {
        m.floatVar = asFloat(value);
        m.outPins[0] = floatValue(m.floatVar);
    }
}

void dirigo_sim_pulse_out(DirigoSim *sim, int32_t index, int32_t pin, int32_t cycles) {
    if (!sim || index < 0 || static_cast<size_t>(index) >= sim->modules.size()) return;
    Module &m = sim->modules[index];
    if (pin < 0 || static_cast<size_t>(pin) >= m.outPins.size()) return;
    m.outPins[pin] = boolean(true);
    m.pulseRemaining = std::max(0, cycles);
}

void dirigo_sim_reset_module(DirigoSim *sim, int32_t index) {
    if (!sim || index < 0 || static_cast<size_t>(index) >= sim->modules.size()) return;
    Module &m = sim->modules[index];
    const std::vector<DirigoValue> ins = m.inPins, params = m.paramPins;
    resetModule(m);
    m.inPins = ins;
    m.paramPins = params;
}

void dirigo_sim_set_variant(DirigoSim *sim, int32_t index, int32_t variant) {
    if (!sim || index < 0 || static_cast<size_t>(index) >= sim->modules.size()) return;
    sim->modules[index].variant = variant;
}

void dirigo_sim_propagate(DirigoSim *sim) {
    if (sim) propagate(sim);
}

uint64_t dirigo_sim_thread_run_count(const DirigoSim *sim, int32_t threadId) {
    if (!sim) return 0;
    auto found = sim->threadRunCounts.find(threadId);
    return found == sim->threadRunCounts.end() ? 0 : found->second;
}

double dirigo_sim_thread_interval_ms(const DirigoSim *sim, int32_t threadId) {
    return sim ? intervalMs(sim, threadId) : 0;
}

uint64_t dirigo_sim_pins_digest(const DirigoSim *sim) {
    uint64_t digest = 0xcbf29ce484222325ULL;                    /* FNV-1a offset basis */
    if (!sim) return digest;
    auto mix = [&digest](uint64_t value) { digest = (digest ^ value) * 0x100000001b3ULL; };
    auto mixValue = [&mix](const DirigoValue &v) {
        mix(static_cast<uint64_t>(v.kind));
        switch (v.kind) {
            case DIRIGO_VALUE_INT64: mix(static_cast<uint64_t>(v.i64)); break;
            case DIRIGO_VALUE_FLOAT: { double f = v.f; uint64_t bits; std::memcpy(&bits, &f, sizeof bits); mix(bits); break; }
            case DIRIGO_VALUE_UNDEFINED: break;
            default: mix(static_cast<uint64_t>(static_cast<uint32_t>(v.i))); break;
        }
    };
    for (const Module &m : sim->modules) {
        mix(static_cast<uint64_t>(static_cast<uint32_t>(m.id)));
        for (const DirigoValue &v : m.inPins) mixValue(v);
        for (const DirigoValue &v : m.paramPins) mixValue(v);
        for (const DirigoValue &v : m.outPins) mixValue(v);
    }
    return digest;
}

int32_t dirigo_sim_portable_kind_count(void) { return DIRIGO_BLOCK_SETIDX; }

}  // extern "C"
