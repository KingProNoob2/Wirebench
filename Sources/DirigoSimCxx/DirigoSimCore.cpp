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

inline int64_t asInt(const DirigoValue &v) {
    switch (v.kind) {
        case DIRIGO_VALUE_BOOL:
        case DIRIGO_VALUE_INT16:
        case DIRIGO_VALUE_INT32: return v.i;
        case DIRIGO_VALUE_INT64: return v.i64;
        case DIRIGO_VALUE_FLOAT: return static_cast<int64_t>(v.f);
        default: return 0;
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

inline DirigoValue floatValue(double value) {
    DirigoValue v{};
    v.kind = DIRIGO_VALUE_FLOAT;
    v.f = value;
    return v;
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
    uint64_t tickCount = 0;
    double cycleDelayMs = 1;
    bool profileScheduling = false;
};

namespace {

double intervalMs(const DirigoSim *sim, int32_t threadId) {
    (void)threadId;                       /* no profile is loaded here; the project's cycle governs */
    return std::max(1.0, sim->cycleDelayMs);
}

/// One module, mirroring its Swift block's `process(sample:)` exactly — including the `En = 0` rule,
/// which holds the output rather than clearing it (docs/spec/blocks-datapath.md §0.5).
void processModule(Module &m, const Sample &sample, const DirigoWallClock &clock) {
    (void)sample;
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
                m.outPins[0] = m.outPins[0].kind == DIRIGO_VALUE_FLOAT ? floatValue(0) : int32Value(0);
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
            const int32_t values[6] = {
                clock.days, clock.hour, clock.minute, clock.second, clock.dayOfWeek,
                clock.hour * 3600 + clock.minute * 60 + clock.second,
            };
            for (size_t i = 0; i < m.outPins.size() && i < 6; ++i) m.outPins[i] = int32Value(values[i]);
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
            /* A latch: `En = 0` holds. Reset priority, which is the block's default; a module that
               overrides it is not read from the file yet (see the note in `dirigo_sim_create`). */
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;      /* holds */
            const bool setIn = m.inPins.size() > 1 ? asBool(m.inPins[1]) : false;
            const bool resetIn = m.inPins.size() > 2 ? asBool(m.inPins[2]) : false;
            if (resetIn) m.lastTr = false;          /* reuse of the 1-bit state field, as Counter does */
            else if (setIn) m.lastTr = true;
            if (!m.outPins.empty()) m.outPins[0] = boolean(m.lastTr);
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
        case DIRIGO_BLOCK_PASSIVE:
        case DIRIGO_BLOCK_MACRO_IO:
            /* Both compute nothing. A macro interface's pins are written by `propagateMacroCalls`. */
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
        case DIRIGO_BLOCK_SYSTEMCMD:
        case DIRIGO_BLOCK_SWITCH:
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
            /* `WT` resets to an *int* zero, not the boolean default: the kind of a pin is part of the
               value, and the differential test compares the kinds. */
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

    /* The Swift writes through `WritableVariable` when the producer conforms to it — which only
       `IntVar` and `FloatVar` do (`BoolVar` deliberately does not, so a written pin is simply not
       undone because `BoolVar.process` never overwrites its output). Neither of those two kinds is
       ported here yet, so there is nothing to add for this case; when one is ported it needs a branch
       here, or a written value would be discarded the moment the producer next ran. */
    if (c.toParamPins) {
        if (c.inPin >= 0 && static_cast<size_t>(c.inPin) < producer.paramPins.size()) {
            producer.paramPins[c.inPin] = value;
        }
        return;
    }
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
        if (c.inPin < 2) continue;                      /* `where conn.inPinId >= 2` */
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
        } else if (bridge.kind == DIRIGO_MACRO_OUTPUTS) {
            /* Subpage Outputs inPins -> caller outPins. */
            const size_t n = std::min(iface.inPins.size(), caller.outPins.size());
            for (size_t i = 0; i < n; ++i) caller.outPins[i] = iface.inPins[i];
        }
    }
}

void propagate(DirigoSim *sim) {
    for (int32_t sweep = 0; sweep < sim->macroSweeps; ++sweep) {
        propagateMacroCalls(sim);
        for (size_t i = 0; i < sim->modules.size(); ++i) propagateFrom(sim, i);
        propagateMacroCalls(sim);
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
        m.inPins.assign(static_cast<size_t>(std::max(0, d.inCount)), boolean(false));
        m.paramPins.assign(static_cast<size_t>(std::max(0, d.paramCount)), int32Value(0));
        m.outPins.assign(static_cast<size_t>(std::max(0, d.outCount)), boolean(false));
        for (int32_t p = 0; p < d.inCount && d.initialIn; ++p) m.inPins[p] = d.initialIn[p];
        for (int32_t p = 0; p < d.outCount && d.initialOut; ++p) m.outPins[p] = d.initialOut[p];
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

void dirigo_sim_destroy(DirigoSim *sim) { delete sim; }

void dirigo_sim_reset(DirigoSim *sim) {
    if (!sim) return;
    sim->tickCount = 0;
    sim->threadElapsedMs.clear();
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

int32_t dirigo_sim_step(DirigoSim *sim, double deltaMs) {
    if (!sim) return 0;
    sim->tickCount += 1;
    /* The caller's delta is taken as given, to a thousandth of a millisecond, so a slowed simulation is slowed. */
    const double stepMs = std::max(0.001, deltaMs);
    propagate(sim);
    bool ranAny = false;

    for (int32_t tid : sim->threadIds) {
        const double interval = intervalMs(sim, tid);
        bool isDue = true;
        if (sim->profileScheduling) {
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
        Sample sample{sim->tickCount, interval};
        for (size_t index : sim->schedule[tid]) {
            processModule(sim->modules[index], sample, sim->wallClock);
            propagateFrom(sim, index);       /* the Swift engine pushes after every block */
            if (sim->modules[index].kind == DIRIGO_BLOCK_SET) {
                applySetWriteThrough(sim, index);
            }
        }
    }
    if (ranAny) propagate(sim);
    return ranAny ? 1 : 0;
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
}

int32_t dirigo_sim_portable_kind_count(void) { return 12; }

}  // extern "C"
