//
//  WirebenchSimCore.cpp
//  Wirebench
//
//  The simulation core, in C++.
//
//  The runtime that steps a project — schedule by thread and ORDER, per-thread periods, wire propagation,
//  the tick counter — and the block behaviours it drives. The Swift block classes in WirebenchLibrary no
//  longer run in the app; the tests keep them as the oracle (`BlockOracle`, `CxxBlockFuzzTests`) and compare
//  this core with them pin for pin, because "it compiles" is not evidence that a simulation agrees with the
//  one it replaced. Where a rule is subtle the comment below says which rule it implements.
//
//  A block type the core does not know is `UNRESOLVED`: present, holding its inputs, contributing nothing.
//

#include "WirebenchSimCxx.h"
#include "MaraflowVariants.h"
#include "MaraflowStInterpreter.h"
#include <sstream>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <deque>
#include <limits>
#include <random>
#include <map>
#include <unordered_map>
#include <vector>

namespace {

inline bool asBool(const WirebenchValue &v) {
    switch (v.kind) {
        case WIREBENCH_VALUE_BOOL:
        case WIREBENCH_VALUE_INT16:
        case WIREBENCH_VALUE_INT32: return v.i != 0;
        case WIREBENCH_VALUE_INT64: return v.i64 != 0;
        case WIREBENCH_VALUE_FLOAT: return v.f != 0.0;
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
inline int64_t asInt(const WirebenchValue &v) {
    switch (v.kind) {
        case WIREBENCH_VALUE_BOOL:
        case WIREBENCH_VALUE_INT16:
        case WIREBENCH_VALUE_INT32: return v.i;
        case WIREBENCH_VALUE_INT64: return v.i64;
        case WIREBENCH_VALUE_FLOAT: return saturatingInt32(v.f);
        default: return 0;
    }
}

/// `PinValue.asInt32`: an Int64 truncates, a float saturates.
inline int32_t asInt32(const WirebenchValue &v) {
    switch (v.kind) {
        case WIREBENCH_VALUE_BOOL:
        case WIREBENCH_VALUE_INT16:
        case WIREBENCH_VALUE_INT32: return v.i;
        case WIREBENCH_VALUE_INT64: return static_cast<int32_t>(v.i64);
        case WIREBENCH_VALUE_FLOAT: return saturatingInt32(v.f);
        default: return 0;
    }
}

/// `PinValue.asFloat`, which is a Swift `Float`: every result is rounded to single precision.
inline float asFloat(const WirebenchValue &v) {
    switch (v.kind) {
        case WIREBENCH_VALUE_BOOL:
        case WIREBENCH_VALUE_INT16:
        case WIREBENCH_VALUE_INT32: return static_cast<float>(v.i);
        case WIREBENCH_VALUE_INT64: return static_cast<float>(v.i64);
        case WIREBENCH_VALUE_FLOAT: return static_cast<float>(v.f);
        default: return 0.0f;
    }
}

/// `PinValue ==`: the kind is part of the value, so `.bool(true)` is not `.int32(1)`, and NaN is unequal.
inline bool valuesEqual(const WirebenchValue &a, const WirebenchValue &b) {
    if (a.kind != b.kind) return false;
    switch (a.kind) {
        case WIREBENCH_VALUE_BOOL:
        case WIREBENCH_VALUE_INT16:
        case WIREBENCH_VALUE_INT32: return a.i == b.i;
        case WIREBENCH_VALUE_INT64: return a.i64 == b.i64;
        case WIREBENCH_VALUE_FLOAT: return static_cast<float>(a.f) == static_cast<float>(b.f);
        default: return true;
    }
}

inline WirebenchValue boolean(bool value) {
    WirebenchValue v{};
    v.kind = WIREBENCH_VALUE_BOOL;
    v.i = value ? 1 : 0;
    return v;
}

inline WirebenchValue int32Value(int32_t value) {
    WirebenchValue v{};
    v.kind = WIREBENCH_VALUE_INT32;
    v.i = value;
    return v;
}

/// A float pin. Stored as a double for the C ABI, but always a value a Swift `Float` can hold.
inline WirebenchValue floatValue(double value) {
    WirebenchValue v{};
    v.kind = WIREBENCH_VALUE_FLOAT;
    v.f = static_cast<float>(value);
    return v;
}

inline WirebenchValue int64Value(int64_t value) {
    WirebenchValue v{};
    v.kind = WIREBENCH_VALUE_INT64;
    v.i64 = value;
    return v;
}

/// A numeric result written to a pin whose kind decides the conversion, mirroring `DataType.convertValue`.
inline WirebenchValue maraflowNumber(double value, const WirebenchValue &prototype) {
    switch (prototype.kind) {
        case WIREBENCH_VALUE_BOOL: return boolean(value != 0.0);
        case WIREBENCH_VALUE_INT16:
        case WIREBENCH_VALUE_INT32: return int32Value(static_cast<int32_t>(value));
        case WIREBENCH_VALUE_INT64: return int64Value(static_cast<int64_t>(value));
        case WIREBENCH_VALUE_FLOAT: return floatValue(value);
        default: return int32Value(static_cast<int32_t>(value));
    }
}

inline std::mt19937 &maraflowRng() {
    static thread_local std::mt19937 engine(std::random_device{}());
    return engine;
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

inline WirebenchValue undefinedValue() {
    WirebenchValue v{};
    v.kind = WIREBENCH_VALUE_UNDEFINED;
    return v;
}

struct Module;

struct LdElement {
    std::string kind;
    std::string operand;
    std::string source;
    bool previous = false;   /* per-element edge memory, like Maraflow's prevEdgeInput */
    /* Embedded ladder function block. The block keeps its own state between scans. */
    std::shared_ptr<Module> fbModule;
    std::vector<std::string> fbInputOperands;
    std::vector<std::string> fbOutputBindings;
};

struct LdBranch {
    int start = 0;
    int end = 0;
    std::vector<LdElement> elements;
    bool output = false;     /* branchEnergizedOut */
};

struct LdRung {
    int order = 0;
    std::vector<LdElement> main;
    std::vector<LdBranch> branches;
    std::vector<LdElement> coils;
};

struct LdProgram {
    std::vector<LdRung> rungs;
};

struct Module {
    int32_t id = 0;
    int32_t order = 0;
    int32_t threadId = 0;
    int32_t kind = WIREBENCH_BLOCK_UNRESOLVED;
    bool hasEnable = false;
    std::vector<WirebenchValue> inPins;
    std::vector<WirebenchValue> paramPins;
    std::vector<WirebenchValue> outPins;
    int32_t cycleCounter = 0;      /* PulseGen */
    int32_t pulseRemaining = 0;    /* BoolVar */
    int32_t currentCount = 0;      /* Counter */
    int32_t intValue = 0;          /* IntVar: the variable itself, not a pin */
    bool lastTr = false;           /* Counter: for the 0->1 edge */
    int32_t variant = 0;           /* WirebenchModuleDesc.variant */
    int64_t config[4] = {0, 0, 0, 0};
    int64_t remaining = 0;         /* SinglePulse */
    int64_t total = 0;             /* SinglePulse; PulseLen's active cycles; AdvCounter's value */
    double filterValue = 0;        /* Filter */
    std::deque<int64_t> history;   /* Mean */
    WirebenchValue lastValue{};       /* Trigger; `undefined` until it has run */
    bool processedOnce = false;    /* Trigger; DelayFilter's "armed" */
    bool flagA = false;            /* WaterRegulator's open latch, HystComparator's "greater", StepDriver's commanded */
    bool flagB = false;            /* WaterRegulator's close latch, HystComparator's "less" */
    int64_t s[3] = {0, 0, 0};      /* StepDriver: position, speed, target */
    double floatVar = 0;           /* FloatVar: the variable itself, not a pin */
    std::vector<std::pair<int64_t, int64_t>> caseRanges;   /* Case */
    std::map<std::string, std::string> strings;             /* native Maraflow string configuration */
    std::shared_ptr<wirebench::StInterpreter> stInterpreter;
    std::map<std::string, double> stVariables;
    bool stCompileTried = false;
    bool stCompiled = false;
    std::string stError;
    std::shared_ptr<LdProgram> ldProgram;
    /* Connection indices into `WirebenchSim::connections`, in file order. Resolved once when the
       simulation is created: the per-wire id lookups these replace were most of a step's cost. */
    std::vector<size_t> incoming;
    std::vector<size_t> outgoing;
};

constexpr size_t kNoModule = static_cast<size_t>(-1);

struct Connection {
    int32_t inModule = 0;
    int32_t inPin = 0;
    int32_t outModule = 0;
    int32_t outPin = 0;
    bool inverted = false;
    bool toParamPins = false;
    /* The endpoints as module positions, resolved in `wirebench_sim_create` through the same
       `indexById` the step loop used to consult on every wire. `kNoModule` is a wire to or from a
       module that is not there, which the old lookups skipped. */
    size_t from = kNoModule;
    size_t to = kNoModule;
};

struct Sample {
    uint64_t tickCount = 0;
    double deltaMs = 0;
};

}  // namespace

struct WirebenchSim {
    std::vector<Module> modules;
    std::unordered_map<int32_t, size_t> indexById;
    std::vector<Connection> connections;
    /// Macro interfaces, resolved from module attributes Swift-side. See `WirebenchMacroBridge`.
    std::vector<WirebenchMacroBridge> macroBridges;
    int32_t macroSweeps = 1;
    /// The step's wall clock, decomposed by Swift. See `wirebench_sim_set_wall_clock`.
    WirebenchWallClock wallClock{0, 0, 0, 0, 0};
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
    /// The Maraflow operand namespace: DI/DO/AI/AO/PWM channel registers and named registers.
    std::map<std::string, double> operands;
    bool maraflowEStopActive = false;

    /* Construct state (the Swift `condStack` and friends), reset at the start of every step. */
    int64_t condStack = 0;
    std::vector<size_t> constructStack;
    std::map<size_t, std::pair<bool, int64_t>> switchSelector;   /* captured?, value */
    std::map<size_t, bool> switchMatched;
};

namespace {

/// A thread's period: the profile's when it gives one, otherwise the project's cycle.
double intervalMs(const WirebenchSim *sim, int32_t threadId) {
    auto found = sim->threadIntervalMs.find(threadId);
    if (found != sim->threadIntervalMs.end() && found->second > 0) return found->second;
    return std::max(1.0, sim->cycleDelayMs);
}

void processModule(WirebenchSim *sim, Module &m, const Sample &sample, const WirebenchWallClock &clock);

inline std::string ldUpper(std::string value) {
    for (auto &c : value) c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    return value;
}

double ldOperand(WirebenchSim *sim, const std::string &raw) {
    if (!sim) return 0.0;
    std::string name = raw;
    while (!name.empty() && std::isspace(static_cast<unsigned char>(name.front()))) name.erase(name.begin());
    while (!name.empty() && std::isspace(static_cast<unsigned char>(name.back()))) name.pop_back();
    if (name.empty()) return 0.0;
    const auto dot = name.find('.');
    if (dot != std::string::npos) {
        const std::string blockName = ldUpper(name.substr(0, dot));
        const std::string pinName = ldUpper(name.substr(dot + 1));
        for (const Module &module : sim->modules) {
            auto moduleName = module.strings.find("Name");
            if (moduleName == module.strings.end() || ldUpper(moduleName->second) != blockName) continue;
            auto names = [&](const char *key, const std::vector<WirebenchValue> &pins,
                             double &value) -> bool {
                auto foundNames = module.strings.find(key);
                if (foundNames == module.strings.end()) return false;
                std::string current;
                size_t index = 0;
                for (size_t i = 0; i <= foundNames->second.size(); ++i) {
                    if (i == foundNames->second.size() || foundNames->second[i] == '|') {
                        if (ldUpper(current) == pinName && index < pins.size()) {
                            value = asFloat(pins[index]);
                            return true;
                        }
                        current.clear();
                        ++index;
                    } else {
                        current.push_back(foundNames->second[i]);
                    }
                }
                return false;
            };
            double value = 0.0;
            if (names("OutNames", module.outPins, value)) return value;
            if (names("InNames", module.inPins, value)) return value;
            return 0.0;
        }
        return 0.0;
    }
    auto found = sim->operands.find(name);
    if (found != sim->operands.end()) return found->second;
    found = sim->operands.find(ldUpper(name));
    if (found != sim->operands.end()) return found->second;
    if (ldUpper(name) == "TRUE") return 1.0;
    if (ldUpper(name) == "FALSE") return 0.0;
    char *end = nullptr;
    const double numeric = std::strtod(name.c_str(), &end);
    if (end && *end == '\0') return numeric;
    return 0.0;
}

void ldWrite(WirebenchSim *sim, const std::string &name, double value) {
    if (!sim || name.empty()) return;
    sim->operands[name] = value;
    sim->operands[ldUpper(name)] = value;
}

bool ldSeries(WirebenchSim *sim, LdElement &element, bool powerIn, const Sample &sample,
              const WirebenchWallClock &clock) {
    if (element.kind == "FUNCTION_BLOCK") {
        if (!element.fbModule) return false;
        Module &block = *element.fbModule;
        if (!block.inPins.empty()) block.inPins[0] = boolean(powerIn);
        for (size_t i = 1; i < block.inPins.size(); ++i) {
            const std::string operand = i < element.fbInputOperands.size() ? element.fbInputOperands[i] : "";
            block.inPins[i] = maraflowNumber(ldOperand(sim, operand), block.inPins[i]);
        }
        processModule(sim, block, sample, clock);
        for (size_t i = 0; i < block.outPins.size(); ++i) {
            const std::string binding = i < element.fbOutputBindings.size() ? element.fbOutputBindings[i] : "";
            if (!binding.empty() && binding != "0") ldWrite(sim, binding, asFloat(block.outPins[i]));
        }
        bool output = powerIn;
        if (!block.outPins.empty() && block.outPins[0].kind == WIREBENCH_VALUE_BOOL)
            output = powerIn && asBool(block.outPins[0]);
        return output;
    }
    const bool raw = ldOperand(sim, element.operand) != 0.0;
    const bool previous = element.previous;
    element.previous = raw;
    bool conducts = false;
    if (element.kind == "NO_CONTACT") conducts = raw;
    else if (element.kind == "NC_CONTACT") conducts = !raw;
    else if (element.kind == "POS_EDGE_CONTACT") conducts = raw && !previous;
    else if (element.kind == "NEG_EDGE_CONTACT") conducts = !raw && previous;
    return powerIn && conducts;
}

void ldApplyCoil(WirebenchSim *sim, LdElement &coil, bool power) {
    const bool previous = coil.previous;
    coil.previous = power;
    if (coil.kind == "NORMAL_COIL") {
        ldWrite(sim, coil.operand, power ? 1.0 : 0.0);
    } else if (coil.kind == "NEGATED_COIL") {
        ldWrite(sim, coil.operand, power ? 0.0 : 1.0);
    } else if (coil.kind == "SET_COIL") {
        if (power) ldWrite(sim, coil.operand, 1.0);
    } else if (coil.kind == "RESET_COIL") {
        if (power) ldWrite(sim, coil.operand, 0.0);
    } else if (coil.kind == "POS_EDGE_COIL") {
        ldWrite(sim, coil.operand, (power && !previous) ? 1.0 : 0.0);
    } else if (coil.kind == "NEG_EDGE_COIL") {
        ldWrite(sim, coil.operand, (!power && previous) ? 1.0 : 0.0);
    } else if (coil.kind == "ANALOG_COIL") {
        if (power) ldWrite(sim, coil.operand, ldOperand(sim, coil.source));
    }
}

std::shared_ptr<LdProgram> parseLadder(const std::string &text) {
    auto program = std::make_shared<LdProgram>();
    if (text.empty()) return program;
    std::istringstream stream(text);
    std::string line;
    LdElement *lastElement = nullptr;
    while (std::getline(stream, line)) {
        if (line.empty()) continue;
        std::vector<std::string> fields;
        std::string field;
        for (char c : line) {
            if (c == '\x1f') { fields.push_back(field); field.clear(); }
            else field.push_back(c);
        }
        fields.push_back(field);
        if (fields.size() < 2) continue;
        const std::string tag = fields[0];
        if (tag == "R") {
            lastElement = nullptr;
            program->rungs.push_back(LdRung{});
            if (fields.size() > 1) program->rungs.back().order = std::atoi(fields[1].c_str());
        } else if (!program->rungs.empty()) {
            LdRung &rung = program->rungs.back();
            auto element = [&fields]() {
                LdElement e;
                if (fields.size() > 1) e.kind = fields[1];
                if (fields.size() > 2) e.operand = fields[2];
                if (fields.size() > 3) e.source = fields[3];
                return e;
            };
            if (tag == "M") { rung.main.push_back(element()); lastElement = &rung.main.back(); }
            else if (tag == "B") {
                LdBranch branch;
                if (fields.size() > 1) branch.start = std::atoi(fields[1].c_str());
                if (fields.size() > 2) branch.end = std::atoi(fields[2].c_str());
                rung.branches.push_back(branch);
            } else if (tag == "E" && !rung.branches.empty()) {
                rung.branches.back().elements.push_back(element());
                lastElement = &rung.branches.back().elements.back();
            } else if (tag == "C") {
                rung.coils.push_back(element());
                lastElement = &rung.coils.back();
            } else if (tag == "F" && lastElement) {
                auto block = std::make_shared<Module>();
                block->kind = WIREBENCH_BLOCK_MARAFLOW;
                if (fields.size() > 1) block->variant = std::atoi(fields[1].c_str());
                const int inputs = fields.size() > 2 ? std::atoi(fields[2].c_str()) : 0;
                const int outputs = fields.size() > 3 ? std::atoi(fields[3].c_str()) : 0;
                block->hasEnable = fields.size() > 4 ? std::atoi(fields[4].c_str()) != 0 : true;
                block->inPins.assign(static_cast<size_t>(std::max(0, inputs)), boolean(false));
                block->outPins.assign(static_cast<size_t>(std::max(0, outputs)), boolean(false));
                lastElement->fbModule = block;
            } else if (tag == "I" && lastElement && lastElement->fbModule) {
                const int type = fields.size() > 1 ? std::atoi(fields[1].c_str()) : 0;
                const size_t index = lastElement->fbInputOperands.size();
                if (index < lastElement->fbModule->inPins.size()) {
                    WirebenchValue prototype{};
                    prototype.kind = type == 0 ? WIREBENCH_VALUE_BOOL : type == 2 ? WIREBENCH_VALUE_INT64
                        : type == 3 ? WIREBENCH_VALUE_FLOAT : WIREBENCH_VALUE_INT32;
                    lastElement->fbModule->inPins[index] = maraflowNumber(0, prototype);
                }
                lastElement->fbInputOperands.push_back(fields.size() > 2 ? fields[2] : "");
            } else if (tag == "O" && lastElement && lastElement->fbModule) {
                const int type = fields.size() > 1 ? std::atoi(fields[1].c_str()) : 0;
                const size_t index = lastElement->fbOutputBindings.size();
                if (index < lastElement->fbModule->outPins.size()) {
                    WirebenchValue prototype{};
                    prototype.kind = type == 0 ? WIREBENCH_VALUE_BOOL : type == 2 ? WIREBENCH_VALUE_INT64
                        : type == 3 ? WIREBENCH_VALUE_FLOAT : WIREBENCH_VALUE_INT32;
                    lastElement->fbModule->outPins[index] = maraflowNumber(0, prototype);
                }
                lastElement->fbOutputBindings.push_back(fields.size() > 2 ? fields[2] : "");
            }
        }
    }
    std::stable_sort(program->rungs.begin(), program->rungs.end(),
                     [](const LdRung &a, const LdRung &b) { return a.order < b.order; });
    return program;
}

void resetLadder(LdProgram &program) {
    for (auto &rung : program.rungs) {
        for (auto &element : rung.main) element.previous = false;
        for (auto &branch : rung.branches) {
            branch.output = false;
            for (auto &element : branch.elements) element.previous = false;
        }
        for (auto &coil : rung.coils) coil.previous = false;
        auto resetBlock = [](LdElement &element) {
            if (!element.fbModule) return;
            Module &block = *element.fbModule;
            block.flagA = false;
            block.flagB = false;
            block.s[0] = block.s[1] = block.s[2] = 0;
            std::fill(block.outPins.begin(), block.outPins.end(), boolean(false));
        };
        for (auto &element : rung.main) resetBlock(element);
        for (auto &branch : rung.branches) for (auto &element : branch.elements) resetBlock(element);
    }
}

void runLadder(WirebenchSim *sim, LdProgram &program, const Sample &sample,
               const WirebenchWallClock &clock) {
    for (auto &rung : program.rungs) {
        const int count = static_cast<int>(rung.main.size());
        std::vector<bool> power(static_cast<size_t>(count) + 1, false);
        if (!power.empty()) power[0] = true;
        for (int col = 0; col < count; ++col) {
            for (auto &branch : rung.branches) {
                if (branch.end == col - 1 && branch.start <= col - 1 && power[static_cast<size_t>(col)])
                    power[static_cast<size_t>(col)] = true;
                if (branch.end == col - 1 && branch.start <= col - 1)
                    power[static_cast<size_t>(col)] = power[static_cast<size_t>(col)] || branch.output;
            }
            for (auto &branch : rung.branches) {
                if (branch.start == col) {
                    bool branchPower = power[static_cast<size_t>(col)];
                    for (auto &element : branch.elements) branchPower = ldSeries(sim, element, branchPower, sample, clock);
                    branch.output = branchPower;
                }
            }
            power[static_cast<size_t>(col) + 1] = ldSeries(sim, rung.main[static_cast<size_t>(col)],
                                                          power[static_cast<size_t>(col)], sample, clock);
        }
        bool finalPower = power[static_cast<size_t>(count)];
        for (auto &branch : rung.branches) {
            if (branch.end >= count - 1) {
                if (count == 0) {
                    bool branchPower = true;
                    for (auto &element : branch.elements) branchPower = ldSeries(sim, element, branchPower, sample, clock);
                    branch.output = branchPower;
                }
                finalPower = finalPower || branch.output;
            }
        }
        for (auto &coil : rung.coils) ldApplyCoil(sim, coil, finalPower);
    }
}

/// One module, mirroring its Swift block's `process(sample:)` exactly — including the `En = 0` rule,
/// which holds the output rather than clearing it (docs/spec/blocks-datapath.md §0.5).
void processModule(WirebenchSim *sim, Module &m, const Sample &sample, const WirebenchWallClock &clock) {
    if (m.kind == WIREBENCH_BLOCK_MARAFLOW_LD) {
        if (!sim) return;
        if (!m.ldProgram) m.ldProgram = parseLadder(m.strings.count("LDRungs") ? m.strings["LDRungs"] : "");
        runLadder(sim, *m.ldProgram, sample, clock);
        return;
    }
    if (m.kind == WIREBENCH_BLOCK_MARAFLOW_ST) {
        if (!sim) return;
        if (!m.stCompileTried) {
            m.stCompileTried = true;
            m.stInterpreter = std::make_shared<wirebench::StInterpreter>();
            std::string error;
            int line = 0;
            m.stCompiled = m.stInterpreter->compile(m.strings.count("STCode") ? m.strings["STCode"] : "",
                                                    {}, error, line);
            if (!m.stCompiled) m.stError = (line > 0 ? "line " + std::to_string(line) + ": " : "") + error;
        }
        if (!m.stCompiled) return;
        auto read = [sim](const std::string &name) -> double { return ldOperand(sim, name); };
        auto write = [sim](const std::string &name, double value) { sim->operands[name] = value; };
        // ST macro: seed VAR_INPUT operands from the Inputs interface, then publish VAR_OUTPUT to Outputs.
        auto names = [](const std::string &text) {
            std::vector<std::string> result;
            std::string current;
            for (char c : text) {
                if (c == '|') { result.push_back(current); current.clear(); }
                else current.push_back(c);
            }
            if (!current.empty() || !text.empty()) result.push_back(current);
            return result;
        };
        auto moduleById = [sim](const std::string &raw) -> Module * {
            if (raw.empty()) return nullptr;
            auto found = sim->indexById.find(std::atoi(raw.c_str()));
            return found == sim->indexById.end() ? nullptr : &sim->modules[found->second];
        };
        if (m.strings.count("STInputModule") && m.strings.count("STInputs")) {
            if (Module *input = moduleById(m.strings["STInputModule"])) {
                const auto variables = names(m.strings["STInputs"]);
                for (size_t i = 0; i < variables.size() && i < input->outPins.size(); ++i)
                    sim->operands[variables[i]] = asFloat(input->outPins[i]);
            }
        }
        m.stInterpreter->execute(read, write, m.stVariables);
        if (m.strings.count("STOutputModule") && m.strings.count("STOutputs")) {
            if (Module *output = moduleById(m.strings["STOutputModule"])) {
                const auto variables = names(m.strings["STOutputs"]);
                for (size_t i = 0; i < variables.size() && i < output->inPins.size(); ++i)
                    output->inPins[i] = maraflowNumber(ldOperand(sim, variables[i]), output->inPins[i]);
            }
        }
        return;
    }
    /* Every kind below writes outputs and nothing else a reader can see (`Set` works in the step loop, not
       here), so a module without out pins has nothing to do — and the cases may then index `outPins[0]`. */
    if (m.outPins.empty()) return;
    switch (m.kind) {
        case WIREBENCH_BLOCK_NOT: {
            const bool enabled = m.inPins.empty() ? true : asBool(m.inPins[0]);
            if (!enabled) return;                                   /* holds */
            const bool value = m.inPins.size() > 1 ? asBool(m.inPins[1]) : false;
            if (!m.outPins.empty()) m.outPins[0] = boolean(!value);
            return;
        }
        case WIREBENCH_BLOCK_AND:
        case WIREBENCH_BLOCK_OR:
        case WIREBENCH_BLOCK_XOR: {
            if (m.inPins.empty()) return;
            if (!asBool(m.inPins[0])) return;                        /* holds */
            bool result = m.kind == WIREBENCH_BLOCK_AND;
            for (size_t i = 1; i < m.inPins.size(); ++i) {
                const bool bit = asBool(m.inPins[i]);
                if (m.kind == WIREBENCH_BLOCK_AND) {
                    result = result && bit;
                    if (!result) break;
                } else if (m.kind == WIREBENCH_BLOCK_OR) {
                    result = result || bit;
                    if (result) break;
                } else {
                    result = result != bit;
                }
            }
            if (!m.outPins.empty()) m.outPins[0] = boolean(result);
            return;
        }
        case WIREBENCH_BLOCK_BOOLVAR: {
            /* A held button owns its value; only an un-held single-shot pulse expires. */
            if (m.pulseRemaining > 0) {
                m.pulseRemaining -= 1;
                if (m.pulseRemaining == 0 && !m.outPins.empty()) m.outPins[0] = boolean(false);
            }
            return;
        }
        case WIREBENCH_BLOCK_PULSEGEN: {
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
        case WIREBENCH_BLOCK_COUNTER: {
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
        case WIREBENCH_BLOCK_COMPARATOR: {
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
        case WIREBENCH_BLOCK_INT2BITS: {
            const int64_t value = m.inPins.empty() ? 0 : asInt(m.inPins[0]);
            for (size_t i = 0; i < m.outPins.size(); ++i) {
                m.outPins[i] = boolean(i < 63 && (value & (static_cast<int64_t>(1) << i)) != 0);
            }
            return;
        }
        case WIREBENCH_BLOCK_SYSTEMCMD: {
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
            for (WirebenchValue &out : m.outPins) out = int32Value(static_cast<int32_t>(value));
            return;
        }
        case WIREBENCH_BLOCK_SWITCH: {
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
        case WIREBENCH_BLOCK_INRANGE: {
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
        case WIREBENCH_BLOCK_EQUITHERM: {
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
        case WIREBENCH_BLOCK_DATETIME: {
            /* The clock is handed in, never read here — see `WirebenchWallClock`. `En` holds, as usual.
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
        case WIREBENCH_BLOCK_BITS2INT: {
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
        case WIREBENCH_BLOCK_RS: {
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
        case WIREBENCH_BLOCK_INTVAR: {
            /* "Performs no operation; it only allocates space for a variable of type Int." The value is
               `m.intValue`, which survives this pass and is written by `Set`/`SetIdx`. */
            if (!m.outPins.empty()) m.outPins[0] = int32Value(m.intValue);
            return;
        }
        case WIREBENCH_BLOCK_DIV: {
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
        case WIREBENCH_BLOCK_INTSUB: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;      /* holds */
            const int64_t a = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            const int64_t b = m.inPins.size() > 2 ? asInt(m.inPins[2]) : 0;
            if (!m.outPins.empty()) m.outPins[0] = int32Value(static_cast<int32_t>(a - b));
            return;
        }
        case WIREBENCH_BLOCK_YES: {
            for (size_t i = 0; i < m.inPins.size() && i < m.outPins.size(); ++i) m.outPins[i] = m.inPins[i];
            return;
        }
        case WIREBENCH_BLOCK_SHL:
        case WIREBENCH_BLOCK_SAR: {
            if (m.inPins.empty() || !asBool(m.inPins[0])) return;
            const int64_t value = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            const int64_t shift = m.inPins.size() > 2
                ? std::max<int64_t>(0, std::min<int64_t>(31, asInt(m.inPins[2]))) : 0;
            const int64_t shifted = m.kind == WIREBENCH_BLOCK_SHL
                ? static_cast<int64_t>(static_cast<uint64_t>(value) << shift) : value >> shift;
            m.outPins[0] = int32Value(static_cast<int32_t>(shifted));
            return;
        }
        case WIREBENCH_BLOCK_EXT: {
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
        case WIREBENCH_BLOCK_INS: {
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
        case WIREBENCH_BLOCK_SINGLEPULSE: {
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
        case WIREBENCH_BLOCK_PULSELEN: {
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
        case WIREBENCH_BLOCK_IABS:
        case WIREBENCH_BLOCK_IINC:
        case WIREBENCH_BLOCK_INEG: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            const int64_t x = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            const int64_t y = m.kind == WIREBENCH_BLOCK_IABS ? (x < 0 ? -x : x)
                            : m.kind == WIREBENCH_BLOCK_IINC ? x + 1 : -x;
            m.outPins[0] = int32Value(static_cast<int32_t>(y));
            return;
        }
        case WIREBENCH_BLOCK_IADD:
        case WIREBENCH_BLOCK_IMUL: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            const int64_t a = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            const int64_t b = m.inPins.size() > 2 ? asInt(m.inPins[2]) : 0;
            m.outPins[0] = int32Value(static_cast<int32_t>(m.kind == WIREBENCH_BLOCK_IADD ? a + b : a * b));
            return;
        }
        case WIREBENCH_BLOCK_LIMITER: {
            /* No En on this block: pin 0 is X. */
            const int64_t x = m.inPins.empty() ? 0 : asInt(m.inPins[0]);
            const int64_t maximum = m.paramPins.size() > 0 ? asInt(m.paramPins[0]) : 0;
            const int64_t minimum = m.paramPins.size() > 1 ? asInt(m.paramPins[1]) : 0;
            m.outPins[0] = int32Value(static_cast<int32_t>(std::min(std::max(x, minimum), maximum)));
            return;
        }
        case WIREBENCH_BLOCK_CALIBTRANSF: {
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
        case WIREBENCH_BLOCK_MEAN: {
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
        case WIREBENCH_BLOCK_FLOATMATH: {
            /* The legacy block computes in `Float` throughout, so every step is single precision here. */
            const float a = m.inPins.size() > 0 ? asFloat(m.inPins[0]) : 0.0f;
            const float b = m.inPins.size() > 1 ? asFloat(m.inPins[1]) : 0.0f;
            float y = 0.0f;
            switch (m.variant) {
                case WIREBENCH_FMATH_SUB: y = a - b; break;
                case WIREBENCH_FMATH_MUL: y = a * b; break;
                case WIREBENCH_FMATH_DIV: y = b != 0.0f ? a / b : 0.0f; break;
                case WIREBENCH_FMATH_SQRT: y = a >= 0.0f ? std::sqrt(a) : 0.0f; break;
                case WIREBENCH_FMATH_SIN: y = std::sin(a); break;
                case WIREBENCH_FMATH_COS: y = std::cos(a); break;
                default: y = a + b; break;
            }
            m.outPins[0] = floatValue(y);
            return;
        }
        case WIREBENCH_BLOCK_LONGMATH: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            std::vector<int64_t> ops;
            for (size_t i = 1; i < m.inPins.size(); ++i) ops.push_back(asInt(m.inPins[i]));
            const int64_t first = ops.empty() ? 0 : ops[0];
            int64_t result = 0;
            switch (m.variant) {
                case WIREBENCH_LONG_ADD: for (int64_t v : ops) result += v; break;
                case WIREBENCH_LONG_SUB: result = first; for (size_t i = 1; i < ops.size(); ++i) result -= ops[i]; break;
                case WIREBENCH_LONG_ABS: result = first < 0 ? -first : first; break;
                case WIREBENCH_LONG_NEG: result = -first; break;
                case WIREBENCH_LONG_NOT: result = ~first; break;
                case WIREBENCH_LONG_INC: result = first + 1; break;
                case WIREBENCH_LONG_AND: result = first; for (size_t i = 1; i < ops.size(); ++i) result &= ops[i]; break;
                case WIREBENCH_LONG_OR: result = first; for (size_t i = 1; i < ops.size(); ++i) result |= ops[i]; break;
                case WIREBENCH_LONG_XOR: result = first; for (size_t i = 1; i < ops.size(); ++i) result ^= ops[i]; break;
            }
            for (WirebenchValue &out : m.outPins) out = int32Value(static_cast<int32_t>(result));
            return;
        }
        case WIREBENCH_BLOCK_FLOATNUM: {
            /* `FloatMathNumericBlock` widens each operand to Double, computes, and rounds back to Float. */
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            std::vector<double> ops;
            for (size_t i = 1; i < m.inPins.size(); ++i) ops.push_back(static_cast<double>(asFloat(m.inPins[i])));
            const double x = ops.empty() ? 0.0 : ops[0];
            const double k = ops.size() > 1 ? ops[1]
                           : (m.paramPins.empty() ? 1.0 : static_cast<double>(asFloat(m.paramPins[0])));
            double result = 0.0;
            switch (m.variant) {
                case WIREBENCH_FNUM_ADD: for (double v : ops) result += v; break;
                case WIREBENCH_FNUM_SUB: result = x; for (size_t i = 1; i < ops.size(); ++i) result -= ops[i]; break;
                case WIREBENCH_FNUM_MUL: result = 1.0; for (double v : ops) result *= v; break;
                case WIREBENCH_FNUM_DIV:
                    result = x;
                    for (size_t i = 1; i < ops.size(); ++i) if (ops[i] != 0.0) result /= ops[i];
                    break;
                case WIREBENCH_FNUM_ABS: result = std::fabs(x); break;
                case WIREBENCH_FNUM_NEG: result = -x; break;
                case WIREBENCH_FNUM_SQRT: result = x < 0 ? 0.0 : std::sqrt(x); break;
                case WIREBENCH_FNUM_MOD: result = ops.size() > 1 && ops[1] != 0.0 ? std::fmod(x, ops[1]) : 0.0; break;
                case WIREBENCH_FNUM_SIN: result = std::sin(x * k); break;
                case WIREBENCH_FNUM_COS: result = std::cos(x * k); break;
                case WIREBENCH_FNUM_ASIN: result = x < -1 || x > 1 ? 0.0 : std::asin(x) * k; break;
                case WIREBENCH_FNUM_ACOS: result = x < -1 || x > 1 ? 0.0 : std::acos(x) * k; break;
            }
            for (WirebenchValue &out : m.outPins) out = floatValue(result);
            return;
        }
        case WIREBENCH_BLOCK_MOVE: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            const bool trigger = m.inPins.size() > 1 && asBool(m.inPins[1]);
            const bool rising = trigger && !m.lastTr;
            m.lastTr = trigger;
            if (rising && m.inPins.size() > 2) m.outPins[0] = m.inPins[2];
            return;
        }
        case WIREBENCH_BLOCK_COPY: {
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
        case WIREBENCH_BLOCK_ENCODEDATE: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            const int64_t day = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 1;
            const int64_t month = m.inPins.size() > 2 ? asInt(m.inPins[2]) : 1;
            const int64_t year = m.inPins.size() > 3 ? asInt(m.inPins[3]) : 2000;
            if (day < 1 || day > 31 || month < 1 || month > 12 || year < 1980 || year > 2190) return;   /* hold */
            m.outPins[0] = int32Value(static_cast<int32_t>(daysSince1980(year, month, day)));
            return;
        }
        case WIREBENCH_BLOCK_DECODEDATE: {
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
        case WIREBENCH_BLOCK_IDEMUX:
        case WIREBENCH_BLOCK_FDEMUX: {
            /* "The values of the other Y outputs remain unchanged"; an out-of-range selector writes nothing. */
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            const int64_t sel = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            if (sel < 0 || sel >= static_cast<int64_t>(m.outPins.size())) return;
            if (m.kind == WIREBENCH_BLOCK_IDEMUX) {
                m.outPins[sel] = int32Value(m.inPins.size() > 2 ? asInt32(m.inPins[2]) : 0);
            } else {
                m.outPins[sel] = floatValue(m.inPins.size() > 2 ? asFloat(m.inPins[2]) : 0.0f);
            }
            return;
        }
        case WIREBENCH_BLOCK_ADVCOUNTER: {
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
        case WIREBENCH_BLOCK_FILTER: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            const double x = static_cast<double>(m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0);
            const int64_t t = std::max<int64_t>(1, m.paramPins.empty() ? 10 : asInt(m.paramPins[0]));
            m.filterValue += (x - m.filterValue) / static_cast<double>(t);
            m.outPins[0] = int32Value(static_cast<int32_t>(std::round(m.filterValue)));
            return;
        }
        case WIREBENCH_BLOCK_IAND:
        case WIREBENCH_BLOCK_IOR:
        case WIREBENCH_BLOCK_IXOR: {
            if (m.inPins.empty() || !asBool(m.inPins[0])) return;
            const int32_t a = m.inPins.size() > 1 ? asInt32(m.inPins[1]) : 0;
            const int32_t b = m.inPins.size() > 2 ? asInt32(m.inPins[2]) : 0;
            m.outPins[0] = int32Value(m.kind == WIREBENCH_BLOCK_IAND ? (a & b) : m.kind == WIREBENCH_BLOCK_IOR ? (a | b) : (a ^ b));
            return;
        }
        case WIREBENCH_BLOCK_INOT: {
            if (m.inPins.empty() || !asBool(m.inPins[0])) return;
            m.outPins[0] = int32Value(~(m.inPins.size() > 1 ? asInt32(m.inPins[1]) : 0));
            return;
        }
        case WIREBENCH_BLOCK_TRIGGER: {
            /* "Changed since the previous cycle", in either direction — and a change of *kind* counts. */
            if (m.inPins.empty() || !asBool(m.inPins[0])) return;
            const WirebenchValue current = m.inPins.size() > 1 ? m.inPins[1] : boolean(false);
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
        case WIREBENCH_BLOCK_CONSTOUT: {
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
        case WIREBENCH_BLOCK_DELAYFILTER: {
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
        case WIREBENCH_BLOCK_TIMER: {
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
        case WIREBENCH_BLOCK_RAMP: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            const int64_t x = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            const int64_t up = std::max<int64_t>(0, m.paramPins.size() > 0 ? asInt(m.paramPins[0]) : 0);
            const int64_t down = std::max<int64_t>(0, m.paramPins.size() > 1 ? asInt(m.paramPins[1]) : 0);
            if (x > m.total) m.total = std::min(x, m.total + up);
            else if (x < m.total) m.total = std::max(x, m.total - down);
            m.outPins[0] = int32Value(static_cast<int32_t>(m.total));
            return;
        }
        case WIREBENCH_BLOCK_VALVE: {
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
        case WIREBENCH_BLOCK_WATERREG: {
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
        case WIREBENCH_BLOCK_STEPDRV: {
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
        case WIREBENCH_BLOCK_HYSTCOMP: {
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
        case WIREBENCH_BLOCK_MCOMPARE: {
            if (!m.inPins.empty() && !asBool(m.inPins[0])) return;
            const int64_t x = m.inPins.size() > 1 ? asInt(m.inPins[1]) : 0;
            int32_t ordinal = 0;
            for (size_t i = 0; i < m.paramPins.size(); ++i) {
                if (asInt(m.paramPins[i]) == x) { ordinal = static_cast<int32_t>(i + 1); break; }
            }
            m.outPins[0] = int32Value(ordinal);
            return;
        }
        case WIREBENCH_BLOCK_MARAFLOW: {
            if (m.variant == MARAFLOW_Main_Execution_ReadReg || m.variant == MARAFLOW_Main_Execution_WriteReg) {
                const bool enabled = !m.inPins.empty() && asBool(m.inPins[0]);
                const bool rising = enabled && !m.flagB;
                m.flagB = enabled;
                const std::string mode = m.strings.count("TriggerMode") ? m.strings["TriggerMode"] : "";
                const bool risingMode = mode.rfind("Rising", 0) == 0;
                const bool shouldRun = risingMode ? rising : enabled;
                const std::string name = m.strings.count("RegisterName") ? m.strings["RegisterName"] : "REG_0";
                if (m.variant == MARAFLOW_Main_Execution_WriteReg) {
                    if (shouldRun && m.inPins.size() > 1) {
                        const double value = asFloat(m.inPins[1]);
                        sim->operands[name] = value;
                        if (!m.outPins.empty()) m.outPins[0] = maraflowNumber(value, m.outPins[0]);
                    } else if (!m.outPins.empty()) {
                        m.outPins[0] = maraflowNumber(sim->operands.count(name) ? sim->operands[name] : 0.0, m.outPins[0]);
                    }
                } else if (shouldRun && !m.outPins.empty()) {
                    m.outPins[0] = maraflowNumber(sim->operands.count(name) ? sim->operands[name] : 0.0, m.outPins[0]);
                }
                return;
            }
            if (m.hasEnable && !m.inPins.empty() && !asBool(m.inPins[0])) return;   /* En gate; outputs hold */
            switch (m.variant) {
                case MARAFLOW_Bool_And:
                case MARAFLOW_Bool_Nand:
                case MARAFLOW_Bool_Or:
                case MARAFLOW_Bool_Nor:
                case MARAFLOW_Bool_Xor:
                case MARAFLOW_Bool_Xnor: {
                    bool result = (m.variant == MARAFLOW_Bool_And || m.variant == MARAFLOW_Bool_Nand);
                    for (size_t i = 1; i < m.inPins.size(); ++i) {
                        const bool bit = asBool(m.inPins[i]);
                        if (m.variant == MARAFLOW_Bool_And || m.variant == MARAFLOW_Bool_Nand) result = result && bit;
                        else if (m.variant == MARAFLOW_Bool_Or || m.variant == MARAFLOW_Bool_Nor) result = result || bit;
                        else result = result != bit;
                    }
                    if (m.variant == MARAFLOW_Bool_Nand || m.variant == MARAFLOW_Bool_Nor
                        || m.variant == MARAFLOW_Bool_Xnor) result = !result;
                    if (!m.outPins.empty()) m.outPins[0] = boolean(result);
                    return;
                }
                case MARAFLOW_Bool_Not: {
                    const bool value = m.inPins.size() > 1 ? asBool(m.inPins[1]) : false;
                    if (!m.outPins.empty()) m.outPins[0] = boolean(!value);
                    return;
                }
                case MARAFLOW_Bool_RS:
                case MARAFLOW_Bool_SR: {
                    const bool set = m.inPins.size() > 1 && asBool(m.inPins[1]);
                    const bool reset = m.inPins.size() > 2 && asBool(m.inPins[2]);
                    if (m.variant == MARAFLOW_Bool_RS) {
                        if (reset) m.flagA = false;
                        else if (set) m.flagA = true;
                    } else {
                        if (set) m.flagA = true;
                        else if (reset) m.flagA = false;
                    }
                    if (!m.outPins.empty()) m.outPins[0] = boolean(m.flagA);
                    if (m.outPins.size() > 1) m.outPins[1] = boolean(!m.flagA);
                    return;
                }
                case MARAFLOW_IO_DI: {
                    const std::string channel = "DI" + std::to_string(m.config[0]);
                    if (!m.outPins.empty()) m.outPins[0] = boolean(sim->operands.count(channel) ? sim->operands[channel] != 0.0 : false);
                    return;
                }
                case MARAFLOW_IO_DO: {
                    const bool value = m.inPins.size() > 1 && asBool(m.inPins[1]);
                    if (sim) sim->operands["DO" + std::to_string(m.config[0])] = value ? 1.0 : 0.0;
                    if (!m.outPins.empty()) m.outPins[0] = boolean(value);
                    return;
                }
                case MARAFLOW_IO_AI: {
                    const std::string channel = "AI" + std::to_string(m.config[0]);
                    if (!m.outPins.empty()) m.outPins[0] = maraflowNumber(sim->operands.count(channel) ? sim->operands[channel] : 0.0, m.outPins[0]);
                    return;
                }
                case MARAFLOW_IO_AO: {
                    const double value = m.inPins.size() > 1 ? asFloat(m.inPins[1]) : 0.0;
                    if (sim) sim->operands["AO" + std::to_string(m.config[0])] = value;
                    if (!m.outPins.empty()) m.outPins[0] = boolean(true);
                    return;
                }
                case MARAFLOW_IO_PWM: {
                    const double duty = m.inPins.size() > 2 ? asFloat(m.inPins[2]) : 0.0;
                    if (sim) sim->operands["PWM" + std::to_string(m.config[0])] = duty;
                    if (!m.outPins.empty()) m.outPins[0] = boolean(duty > 0.0);
                    return;
                }
                case MARAFLOW_IO_8xDI: {
                    for (size_t i = 0; i < m.outPins.size(); ++i) {
                        const std::string channel = "DI" + std::to_string(i);
                        if (sim->operands.count(channel)) m.outPins[i] = boolean(sim->operands[channel] != 0.0);
                    }
                    return;
                }
                case MARAFLOW_IO_8xDO: {
                    for (size_t i = 1; i < m.inPins.size(); ++i) {
                        if (sim) sim->operands["DO" + std::to_string(i - 1)] = asBool(m.inPins[i]) ? 1.0 : 0.0;
                    }
                    return;
                }
                case MARAFLOW_Main_Timers_Timer: {
                    const bool input = m.inPins.size() > 1 && asBool(m.inPins[1]);
                    const double preset = std::max(0.0, m.inPins.size() > 2 ? static_cast<double>(asFloat(m.inPins[2])) : 0.0);
                    double elapsed = m.s[0];
                    elapsed = input ? std::min(preset, elapsed + sample.deltaMs) : 0.0;
                    m.s[0] = elapsed;
                    if (!m.outPins.empty()) m.outPins[0] = boolean(input && elapsed >= preset);
                    if (m.outPins.size() > 1) m.outPins[1] = maraflowNumber(static_cast<double>(static_cast<int64_t>(elapsed)), m.outPins[1]);
                    return;
                }
                case MARAFLOW_Main_Timers_PulseGen: {
                    const double high = std::max(1.0, m.inPins.size() > 1 ? static_cast<double>(asFloat(m.inPins[1])) : 500.0);
                    const double low = std::max(1.0, m.inPins.size() > 2 ? static_cast<double>(asFloat(m.inPins[2])) : 500.0);
                    const double cycle = high + low;
                    m.s[0] = std::fmod(m.s[0] + sample.deltaMs, cycle);
                    if (!m.outPins.empty()) m.outPins[0] = boolean(m.s[0] < high);
                    return;
                }
                case MARAFLOW_Main_Timers_PulseLen: {
                    const bool input = m.inPins.size() > 1 && asBool(m.inPins[1]);
                    const double length = std::max(0.0, m.inPins.size() > 2 ? static_cast<double>(asFloat(m.inPins[2])) : 0.0);
                    const bool previous = m.flagA;
                    m.flagA = input;
                    bool active = m.s[1] != 0.0;
                    if (!active && input && !previous) { active = true; m.s[0] = 0.0; }
                    if (active) {
                        m.s[0] += sample.deltaMs;
                        if (m.s[0] >= length) { active = false; m.s[0] = length; }
                    }
                    m.s[1] = active ? 1.0 : 0.0;
                    if (!m.outPins.empty()) m.outPins[0] = boolean(active);
                    return;
                }
                case MARAFLOW_Main_Timers_SinglePulse: {
                    const bool input = m.inPins.size() > 1 && asBool(m.inPins[1]);
                    const bool previous = m.flagA;
                    m.flagA = input;
                    if (!m.outPins.empty()) m.outPins[0] = boolean(input && !previous);
                    return;
                }
                case MARAFLOW_Main_Timers_Counter: {
                    const bool up = m.inPins.size() > 1 && asBool(m.inPins[1]);
                    const bool down = m.inPins.size() > 2 && asBool(m.inPins[2]);
                    const bool reset = m.inPins.size() > 3 && asBool(m.inPins[3]);
                    const double preset = m.inPins.size() > 4 ? static_cast<double>(asFloat(m.inPins[4])) : 0.0;
                    const bool previousUp = (static_cast<int>(m.s[1]) & 1) != 0;
                    const bool previousDown = (static_cast<int>(m.s[1]) & 2) != 0;
                    double value = m.s[0];
                    if (reset) value = 0.0;
                    else {
                        if (up && !previousUp) value += 1.0;
                        if (down && !previousDown && value > 0.0) value -= 1.0;
                    }
                    m.s[0] = value;
                    m.s[1] = (up ? 1 : 0) | (down ? 2 : 0);
                    if (!m.outPins.empty()) m.outPins[0] = boolean(value >= preset);
                    if (m.outPins.size() > 1) m.outPins[1] = maraflowNumber(value, m.outPins[1]);
                    return;
                }
                case MARAFLOW_Main_Timers_DateTime: {
                    if (!m.outPins.empty()) m.outPins[0] = maraflowNumber(clock.unixSeconds, m.outPins[0]);
                    return;
                }
                case MARAFLOW_Main_Timers_DecodeDate: {
                    const int64_t seconds = static_cast<int64_t>(m.inPins.size() > 1 ? asFloat(m.inPins[1]) : 0.0);
                    const int64_t days = static_cast<int64_t>(std::floor(static_cast<double>(seconds) / 86400.0));
                    const int64_t secondOfDay = seconds - days * 86400;
                    int64_t year = 1970, month = 1, day = 1;
                    civilFrom1980(days, year, month, day);
                    if (m.outPins.size() > 0) m.outPins[0] = maraflowNumber(static_cast<double>(year), m.outPins[0]);
                    if (m.outPins.size() > 1) m.outPins[1] = maraflowNumber(static_cast<double>(month), m.outPins[1]);
                    if (m.outPins.size() > 2) m.outPins[2] = maraflowNumber(static_cast<double>(day), m.outPins[2]);
                    if (m.outPins.size() > 3) m.outPins[3] = maraflowNumber(static_cast<double>(secondOfDay / 3600), m.outPins[3]);
                    if (m.outPins.size() > 4) m.outPins[4] = maraflowNumber(static_cast<double>((secondOfDay / 60) % 60), m.outPins[4]);
                    if (m.outPins.size() > 5) m.outPins[5] = maraflowNumber(static_cast<double>(secondOfDay % 60), m.outPins[5]);
                    return;
                }
                case MARAFLOW_Visual_Vars_BoolVar:
                case MARAFLOW_Visual_Vars_IntVar:
                case MARAFLOW_Visual_Vars_LongVar: {
                    int64_t bits = m.config[0];
                    double value = 0.0;
                    std::memcpy(&value, &bits, sizeof(double));
                    if (!m.outPins.empty()) m.outPins[0] = maraflowNumber(value, m.outPins[0]);
                    return;
                }
                case MARAFLOW_Main_Safety_EStop: {
                    const bool reset = m.inPins.size() > 1 && asBool(m.inPins[1]);
                    const bool previous = m.flagA;
                    m.flagA = reset;
                    if (reset && !previous && sim) sim->maraflowEStopActive = false;
                    if (sim == nullptr) return;
                    if (!m.outPins.empty()) m.outPins[0] = boolean(!sim->maraflowEStopActive);
                    if (m.outPins.size() > 1) m.outPins[1] = boolean(sim->maraflowEStopActive);
                    if (m.outPins.size() > 2) m.outPins[2] = int32Value(0);
                    return;
                }
                case MARAFLOW_Math_Add: {
                    double sum = 0.0;
                    for (size_t i = 1; i < m.inPins.size(); ++i) sum += asFloat(m.inPins[i]);
                    if (!m.outPins.empty()) m.outPins[0] = maraflowNumber(sum, m.outPins[0]);
                    return;
                }
                case MARAFLOW_Math_Sub: {
                    double result = m.inPins.size() > 1 ? asFloat(m.inPins[1]) : 0.0;
                    for (size_t i = 2; i < m.inPins.size(); ++i) result -= asFloat(m.inPins[i]);
                    if (!m.outPins.empty()) m.outPins[0] = maraflowNumber(result, m.outPins[0]);
                    return;
                }
                case MARAFLOW_Math_Mul: {
                    double product = 1.0;
                    for (size_t i = 1; i < m.inPins.size(); ++i) product *= asFloat(m.inPins[i]);
                    if (!m.outPins.empty()) m.outPins[0] = maraflowNumber(product, m.outPins[0]);
                    return;
                }
                case MARAFLOW_Math_Div: {
                    const double a = m.inPins.size() > 1 ? asFloat(m.inPins[1]) : 0.0;
                    const double b = m.inPins.size() > 2 ? asFloat(m.inPins[2]) : 0.0;
                    if (!m.outPins.empty()) m.outPins[0] = maraflowNumber(std::abs(b) < 1e-12 ? 0.0 : a / b, m.outPins[0]);
                    if (m.outPins.size() > 1) m.outPins[1] = boolean(std::abs(b) < 1e-12);
                    return;
                }
                case MARAFLOW_Math_Mod: {
                    const int64_t a = static_cast<int64_t>(m.inPins.size() > 1 ? asFloat(m.inPins[1]) : 0.0);
                    const int64_t b = static_cast<int64_t>(m.inPins.size() > 2 ? asFloat(m.inPins[2]) : 0.0);
                    if (!m.outPins.empty()) m.outPins[0] = maraflowNumber(b == 0 ? 0.0 : static_cast<double>(a % b), m.outPins[0]);
                    if (m.outPins.size() > 1) m.outPins[1] = boolean(b == 0);
                    return;
                }
                case MARAFLOW_Math_Min:
                case MARAFLOW_Math_Max: {
                    double value = m.inPins.size() > 1 ? asFloat(m.inPins[1]) : 0.0;
                    for (size_t i = 2; i < m.inPins.size(); ++i) {
                        const double operand = static_cast<double>(asFloat(m.inPins[i]));
                        value = m.variant == MARAFLOW_Math_Min ? std::min(value, operand)
                                                              : std::max(value, operand);
                    }
                    if (!m.outPins.empty()) m.outPins[0] = maraflowNumber(value, m.outPins[0]);
                    return;
                }
                case MARAFLOW_Math_Abs: {
                    if (!m.outPins.empty()) m.outPins[0] = maraflowNumber(std::abs(m.inPins.size() > 1 ? asFloat(m.inPins[1]) : 0.0), m.outPins[0]);
                    return;
                }
                case MARAFLOW_Math_Neg: {
                    if (!m.outPins.empty()) m.outPins[0] = maraflowNumber(-(m.inPins.size() > 1 ? asFloat(m.inPins[1]) : 0.0), m.outPins[0]);
                    return;
                }
                case MARAFLOW_Math_Sqrt: {
                    const double value = std::sqrt(std::max(0.0, m.inPins.size() > 1 ? asFloat(m.inPins[1]) : 0.0));
                    if (!m.outPins.empty()) m.outPins[0] = maraflowNumber(value, m.outPins[0]);
                    return;
                }
                case MARAFLOW_Math_Sin: {
                    if (!m.outPins.empty()) m.outPins[0] = maraflowNumber(std::sin(m.inPins.size() > 1 ? asFloat(m.inPins[1]) : 0.0), m.outPins[0]);
                    return;
                }
                case MARAFLOW_Math_Cos: {
                    if (!m.outPins.empty()) m.outPins[0] = maraflowNumber(std::cos(m.inPins.size() > 1 ? asFloat(m.inPins[1]) : 0.0), m.outPins[0]);
                    return;
                }
                case MARAFLOW_Math_Clamp: {
                    const double value = m.inPins.size() > 1 ? asFloat(m.inPins[1]) : 0.0;
                    const double lo = m.inPins.size() > 2 ? asFloat(m.inPins[2]) : 0.0;
                    const double hi = m.inPins.size() > 3 ? asFloat(m.inPins[3]) : 0.0;
                    const double clamped = std::clamp(value, std::min(lo, hi), std::max(lo, hi));
                    if (!m.outPins.empty()) m.outPins[0] = maraflowNumber(clamped, m.outPins[0]);
                    return;
                }
                case MARAFLOW_Math_Random: {
                    const bool trigger = m.inPins.size() > 1 && asBool(m.inPins[1]);
                    const bool rising = trigger && !m.flagA;
                    m.flagA = trigger;
                    const double lo = m.inPins.size() > 2 ? asFloat(m.inPins[2]) : 0.0;
                    const double hi = m.inPins.size() > 3 ? asFloat(m.inPins[3]) : 100.0;
                    if (rising || m.s[1] < 0.5) {
                        const double low = std::min(lo, hi);
                        const double high = std::max(lo, hi);
                        double sample;
                        if (m.outPins.empty() || m.outPins[0].kind != WIREBENCH_VALUE_FLOAT) {
                            const int64_t lowInt = static_cast<int64_t>(std::floor(low));
                            const int64_t highInt = static_cast<int64_t>(std::floor(high));
                            if (highInt <= lowInt) sample = static_cast<double>(lowInt);
                            else {
                                std::uniform_int_distribution<int64_t> distribution(lowInt, highInt);
                                sample = static_cast<double>(distribution(maraflowRng()));
                            }
                        } else {
                            std::uniform_real_distribution<double> distribution(low, high);
                            sample = distribution(maraflowRng());
                        }
                        m.s[0] = sample;
                        m.s[1] = 1;
                    }
                    if (!m.outPins.empty()) m.outPins[0] = maraflowNumber(m.s[0], m.outPins[0]);
                    return;
                }
                case MARAFLOW_Math_Scale: {
                    const double input = m.inPins.size() > 1 ? asFloat(m.inPins[1]) : 0.0;
                    const double inLow = m.inPins.size() > 2 ? asFloat(m.inPins[2]) : 0.0;
                    const double inHigh = m.inPins.size() > 3 ? asFloat(m.inPins[3]) : 100.0;
                    const double outLow = m.inPins.size() > 4 ? asFloat(m.inPins[4]) : 0.0;
                    const double outHigh = m.inPins.size() > 5 ? asFloat(m.inPins[5]) : 10.0;
                    const double span = inHigh - inLow;
                    const double scaled = std::abs(span) < 1e-12 ? outLow
                        : outLow + ((input - inLow) / span) * (outHigh - outLow);
                    if (!m.outPins.empty()) m.outPins[0] = maraflowNumber(scaled, m.outPins[0]);
                    return;
                }
                case MARAFLOW_Main_Comparators_EQ:
                case MARAFLOW_Main_Comparators_NE:
                case MARAFLOW_Main_Comparators_GT:
                case MARAFLOW_Main_Comparators_GE:
                case MARAFLOW_Main_Comparators_LT:
                case MARAFLOW_Main_Comparators_LE: {
                    const double a = m.inPins.size() > 1 ? asFloat(m.inPins[1]) : 0.0;
                    const double b = m.inPins.size() > 2 ? asFloat(m.inPins[2]) : 0.0;
                    bool result = false;
                    switch (m.variant) {
                        case MARAFLOW_Main_Comparators_EQ: result = std::abs(a - b) < 1e-6; break;
                        case MARAFLOW_Main_Comparators_NE: result = std::abs(a - b) >= 1e-6; break;
                        case MARAFLOW_Main_Comparators_GT: result = a > b; break;
                        case MARAFLOW_Main_Comparators_GE: result = a >= b; break;
                        case MARAFLOW_Main_Comparators_LT: result = a < b; break;
                        default: result = a <= b; break;
                    }
                    if (!m.outPins.empty()) m.outPins[0] = boolean(result);
                    return;
                }
                case MARAFLOW_Main_Conversion_PackBits: {
                    int64_t packed = 0;
                    for (size_t i = 1; i < m.inPins.size(); ++i) {
                        if (asBool(m.inPins[i])) packed |= (1LL << (i - 1));
                    }
                    if (!m.outPins.empty()) m.outPins[0] = maraflowNumber(static_cast<double>(packed), m.outPins[0]);
                    return;
                }
                case MARAFLOW_Main_Conversion_UnpackBits: {
                    const int64_t value = static_cast<int64_t>(m.inPins.size() > 1 ? asFloat(m.inPins[1]) : 0.0);
                    for (size_t i = 0; i < m.outPins.size(); ++i) {
                        m.outPins[i] = boolean(((value >> i) & 1LL) != 0);
                    }
                    return;
                }
                case MARAFLOW_Main_Switches_Sel: {
                    const bool gate = m.inPins.size() > 1 && asBool(m.inPins[1]);
                    const double value = gate
                        ? (m.inPins.size() > 3 ? asFloat(m.inPins[3]) : 0.0)
                        : (m.inPins.size() > 2 ? asFloat(m.inPins[2]) : 0.0);
                    if (!m.outPins.empty()) m.outPins[0] = maraflowNumber(value, m.outPins[0]);
                    return;
                }
                case MARAFLOW_Main_Switches_Mux: {
                    const int channelCount = static_cast<int>(m.inPins.size()) - 2;
                    if (channelCount > 0) {
                        const int address = static_cast<int>(m.inPins.size() > 1 ? asFloat(m.inPins[1]) : 0.0);
                        const int index = std::clamp(address, 0, channelCount - 1);
                        if (!m.outPins.empty()) m.outPins[0] = maraflowNumber(asFloat(m.inPins[2 + index]), m.outPins[0]);
                    }
                    return;
                }
                case MARAFLOW_Main_Execution_Interrupt: {
                    const std::string source = m.strings.count("InterruptSource") ? m.strings["InterruptSource"] : "TIM_IC1";
                    const std::string edgeMode = m.strings.count("TriggerEdge") ? m.strings["TriggerEdge"] : "RISING";
                    const std::string captureMode = m.strings.count("CaptureMode") ? m.strings["CaptureMode"] : "PULSE_WIDTH_US";
                    const std::string latchPolicy = m.strings.count("LatchPolicy") ? m.strings["LatchPolicy"] : "HOLD_FIRST_UNTIL_RST";
                    double simulated = 1160.0;
                    if (m.strings.count("SimPulseValue")) {
                        try { simulated = std::stod(m.strings["SimPulseValue"]); } catch (...) {}
                    }
                    bool event = false;
                    double captured = simulated;
                    if (source.rfind("EXTI_DI", 0) == 0) {
                        const std::string channel = source.substr(5);
                        const bool current = sim->operands.count(channel) ? sim->operands[channel] != 0.0 : false;
                        const bool previous = m.flagA;
                        m.flagA = current;
                        const bool rising = current && !previous;
                        const bool falling = !current && previous;
                        if ((edgeMode == "RISING" && rising) || (edgeMode == "FALLING" && falling)
                            || (edgeMode == "BOTH" && (rising || falling))) {
                            event = true;
                            if (captureMode.rfind("GPIO_STATE", 0) == 0) captured = current ? 1.0 : 0.0;
                        }
                    }
                    const bool latched = m.s[1] >= 0.5;
                    if (event) {
                        if (captureMode == "EDGE_COUNT") {
                            m.s[0] += 1.0;
                        } else if (!latched || latchPolicy == "OVERWRITE_LATEST") {
                            m.s[0] = captured;
                        }
                        m.s[1] = 1.0;
                    }
                    if (!m.outPins.empty()) m.outPins[0] = maraflowNumber(m.s[0], m.outPins[0]);
                    if (m.outPins.size() > 1) m.outPins[1] = boolean(m.s[1] >= 0.5);
                    const bool reset = m.inPins.size() > 1 && asBool(m.inPins[1]);
                    if (reset && m.s[1] >= 0.5) m.s[1] = 0.0;
                    return;
                }
                default:
                    return;   /* no-op, matching Maraflow's own evaluator */
            }
        }
        case WIREBENCH_BLOCK_IF:
            m.outPins[0] = m.inPins.empty() ? boolean(true) : m.inPins[0];
            return;
        case WIREBENCH_BLOCK_ENDIF:
            m.outPins[0] = boolean(true);
            return;
        case WIREBENCH_BLOCK_FLOATVAR:
            m.outPins[0] = floatValue(m.floatVar);
            return;
        case WIREBENCH_BLOCK_CREATEARRAY: {
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
        case WIREBENCH_BLOCK_READARRAY:
        case WIREBENCH_BLOCK_WRITEARRAY: {
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
            if (m.kind == WIREBENCH_BLOCK_READARRAY) {
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
        case WIREBENCH_BLOCK_PASSIVE:
        case WIREBENCH_BLOCK_MACRO_IO:
        case WIREBENCH_BLOCK_ELSE:
        case WIREBENCH_BLOCK_SWITCHCASE:
        case WIREBENCH_BLOCK_CASE:
        case WIREBENCH_BLOCK_DEFAULT:
        case WIREBENCH_BLOCK_ENDSWITCH:
        case WIREBENCH_BLOCK_SETIDX:
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
        case WIREBENCH_BLOCK_NOT:
            std::fill(m.outPins.begin(), m.outPins.end(), boolean(true));
            return;
        case WIREBENCH_BLOCK_PULSEGEN:
            std::fill(m.outPins.begin(), m.outPins.end(), boolean(false));
            if (!m.outPins.empty()) m.outPins[0] = int32Value(0);
            return;
        case WIREBENCH_BLOCK_COMPARATOR:
        case WIREBENCH_BLOCK_INT2BITS:
            // Every output is Boolean; clearing only outPins[0] left AGtB/ALtB and the upper bits stale.
            std::fill(m.outPins.begin(), m.outPins.end(), boolean(false));
            return;
        case WIREBENCH_BLOCK_COUNTER:
        case WIREBENCH_BLOCK_SWITCH:
            /* `ISwitchBlock.reset`: a zero of the switch's own element type. */
            if (!m.outPins.empty()) m.outPins[0] = m.variant == 1 ? floatValue(0) : int32Value(0);
            return;
        case WIREBENCH_BLOCK_MARAFLOW_LD:
            if (m.ldProgram) resetLadder(*m.ldProgram);
            return;
        case WIREBENCH_BLOCK_MARAFLOW_ST:
            if (m.stInterpreter) m.stInterpreter->reset();
            m.stVariables.clear();
            return;
        case WIREBENCH_BLOCK_MARAFLOW:
            m.flagA = false;
            m.s[0] = m.s[1] = m.s[2] = 0;
            std::fill(m.outPins.begin(), m.outPins.end(), boolean(false));
            return;
        case WIREBENCH_BLOCK_SYSTEMCMD:
        case WIREBENCH_BLOCK_INRANGE:
            std::fill(m.outPins.begin(), m.outPins.end(), boolean(false));
            return;
        case WIREBENCH_BLOCK_INTVAR:
            /* `IntVar.reset` restores its *stored* value, not zero — the variable keeps what it holds. */
            if (!m.outPins.empty()) m.outPins[0] = int32Value(m.intValue);
            return;
        case WIREBENCH_BLOCK_DATETIME:
        case WIREBENCH_BLOCK_BITS2INT:
        case WIREBENCH_BLOCK_DIV:
        case WIREBENCH_BLOCK_INTSUB:
        case WIREBENCH_BLOCK_EQUITHERM:
        case WIREBENCH_BLOCK_SHL:
        case WIREBENCH_BLOCK_SAR:
        case WIREBENCH_BLOCK_EXT:
        case WIREBENCH_BLOCK_INS:
        case WIREBENCH_BLOCK_PULSELEN:
        case WIREBENCH_BLOCK_IABS:
        case WIREBENCH_BLOCK_IINC:
        case WIREBENCH_BLOCK_INEG:
        case WIREBENCH_BLOCK_IADD:
        case WIREBENCH_BLOCK_IMUL:
        case WIREBENCH_BLOCK_LIMITER:
        case WIREBENCH_BLOCK_CALIBTRANSF:
        case WIREBENCH_BLOCK_MEAN:
        case WIREBENCH_BLOCK_MOVE:
        case WIREBENCH_BLOCK_ENCODEDATE:
        case WIREBENCH_BLOCK_FILTER:
        case WIREBENCH_BLOCK_IAND:
        case WIREBENCH_BLOCK_IOR:
        case WIREBENCH_BLOCK_IXOR:
        case WIREBENCH_BLOCK_INOT:
            /* `WT` resets to an *int* zero, not the boolean default: the kind of a pin is part of the
               value, and the differential test compares the kinds. */
            if (!m.outPins.empty()) m.outPins[0] = int32Value(0);
            return;
        case WIREBENCH_BLOCK_YES:
        case WIREBENCH_BLOCK_LONGMATH:
        case WIREBENCH_BLOCK_COPY:
        case WIREBENCH_BLOCK_IDEMUX:
        case WIREBENCH_BLOCK_DECODEDATE:
            std::fill(m.outPins.begin(), m.outPins.end(), int32Value(0));
            return;
        case WIREBENCH_BLOCK_FLOATMATH:
        case WIREBENCH_BLOCK_FLOATNUM:
        case WIREBENCH_BLOCK_FDEMUX:
            std::fill(m.outPins.begin(), m.outPins.end(), floatValue(0));
            return;
        case WIREBENCH_BLOCK_SINGLEPULSE:
            if (m.outPins.size() >= 2) { m.outPins[0] = int32Value(0); m.outPins[1] = boolean(false); }
            else std::fill(m.outPins.begin(), m.outPins.end(), boolean(false));
            return;
        case WIREBENCH_BLOCK_ADVCOUNTER:
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
void propagateFrom(WirebenchSim *sim, size_t sourceIndex) {
    const Module &from = sim->modules[sourceIndex];
    for (size_t connectionIndex : from.outgoing) {
        const Connection &c = sim->connections[connectionIndex];
        if (c.to == kNoModule) continue;
        Module &to = sim->modules[c.to];
        if (c.outPin < 0 || static_cast<size_t>(c.outPin) >= from.outPins.size()) continue;
        WirebenchValue value = from.outPins[c.outPin];
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
/// Nothing here applies `inverted`: that happens when a value is propagated *forward* to a consumer, not
/// when it is written back. The Swift blocks the tests compare this with do the same, and agreeing with
/// them pin for pin matters more than what would be tidier.
void writeThroughConnection(WirebenchSim *sim, const Connection &c, const WirebenchValue &value) {
    if (c.from == kNoModule) return;
    Module &producer = sim->modules[c.from];

    /* A variable stores state, so the write has to reach the *variable*, not only its output pin:
       writing the pin alone is undone the next time the variable runs. This mirrors the Swift
       `WritableVariable` path, and `IntVar` is the one such kind ported so far. */
    if (producer.kind == WIREBENCH_BLOCK_INTVAR) {
        producer.intValue = static_cast<int32_t>(asInt(value));
        if (!producer.outPins.empty()) producer.outPins[0] = int32Value(producer.intValue);
        return;
    }
    /* The other `WritableVariable`: `FloatVarBlock.writeVariable` stores `value.asFloat`. */
    if (producer.kind == WIREBENCH_BLOCK_FLOATVAR) {
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
void applySetWriteThrough(WirebenchSim *sim, size_t index) {
    Module &self = sim->modules[index];
    if (self.inPins.size() < 2) return;
    const WirebenchValue value = self.inPins[1];          /* `writeValue` */
    /* Walk the connections whose *destination* is this module: `inConnectionMap[module.id]`. */
    for (size_t connectionIndex : self.incoming) {
        const Connection &c = sim->connections[connectionIndex];
        /* A `Set` writes its value back to the variable wired to P1…Pn, and those are parameter pins; the
           in-pin rule (`where conn.inPinId >= 2`) must not skip them. */
        if (!c.toParamPins && c.inPin < 2) continue;
        writeThroughConnection(sim, c, value);
    }
}

/// Moves values across the caller/subpage boundary.
///
/// This is why the step loop calls it at the top and the bottom — a macro's
/// values cross *between* module lists rather than through a connection a single block could pull, so
/// no per-block push can carry them.
void propagateMacroCalls(WirebenchSim *sim) {
    for (const WirebenchMacroBridge &bridge : sim->macroBridges) {
        auto callerIt = sim->indexById.find(bridge.callerModule);
        auto ifaceIt = sim->indexById.find(bridge.interfaceModule);
        if (callerIt == sim->indexById.end() || ifaceIt == sim->indexById.end()) continue;
        Module &caller = sim->modules[callerIt->second];
        Module &iface = sim->modules[ifaceIt->second];

        if (bridge.kind == WIREBENCH_MACRO_INPUTS) {
            /* Caller inPins -> subpage Inputs outPins. The interface module has no inPins of its own. */
            const size_t n = std::min(caller.inPins.size(), iface.outPins.size());
            for (size_t i = 0; i < n; ++i) iface.outPins[i] = caller.inPins[i];
        } else if (bridge.kind == WIREBENCH_MACRO_PARAMS) {
            /* Caller paramPins -> subpage Params outPins. */
            const size_t n = std::min(caller.paramPins.size(), iface.outPins.size());
            for (size_t i = 0; i < n; ++i) iface.outPins[i] = caller.paramPins[i];
        } else if (bridge.kind == WIREBENCH_MACRO_OUTPUTS) {
            /* Subpage Outputs inPins -> caller outPins. */
            const size_t n = std::min(iface.inPins.size(), caller.outPins.size());
            for (size_t i = 0; i < n; ++i) caller.outPins[i] = iface.inPins[i];
        }
    }
}

/// One connection's value into its consumer: the Swift `propagateWiresOnce` body for one wire.
void carry(WirebenchSim *sim, const Connection &c) {
    if (c.from == kNoModule || c.to == kNoModule) return;
    const Module &from = sim->modules[c.from];
    Module &to = sim->modules[c.to];
    if (c.outPin < 0 || static_cast<size_t>(c.outPin) >= from.outPins.size() || c.inPin < 0) return;
    WirebenchValue value = from.outPins[c.outPin];
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
void propagate(WirebenchSim *sim) {
    for (int32_t sweep = 0; sweep < sim->macroSweeps; ++sweep) {
        propagateMacroCalls(sim);
        for (const Connection &c : sim->connections) carry(sim, c);
        propagateMacroCalls(sim);
    }
}

/// Refreshes a module's inputs from its producers' *current* outputs just
/// before it runs. Pushing alone is not equivalent: a `Set` that writes a producer's output mid-pass is
/// seen by every consumer that runs after it, because they pull.
void pullInputs(WirebenchSim *sim, size_t index) {
    for (size_t connectionIndex : sim->modules[index].incoming) {
        carry(sim, sim->connections[connectionIndex]);
    }
}

/// `SetIdx`: writes `X` through the one P pin its `Idx` input selects (`SetIdxBlock.targetPinIndex`).
void applySetIdxWriteThrough(WirebenchSim *sim, size_t index) {
    Module &self = sim->modules[index];
    if (self.inPins.size() <= 3) return;
    const int64_t idx = asInt(self.inPins[1]);
    const int64_t selectable = static_cast<int64_t>(self.inPins.size()) - 3;
    if (idx < 0 || idx >= selectable) return;                  /* "no write takes place" */
    const int32_t target = static_cast<int32_t>(3 + idx);
    const WirebenchValue value = self.inPins[2];
    for (size_t connectionIndex : self.incoming) {
        const Connection &c = sim->connections[connectionIndex];
        if (!c.toParamPins && c.inPin == target) writeThroughConnection(sim, c, value);
    }
}

/// The construct bookkeeping the Swift `stepNode` does before its gate, for every module. It is never
/// gated itself: an `If` in a false branch still pushes its bit and an `EndIf` still pops, or the stack
/// would lose its balance and every later block would be skipped for the rest of the pass.
void constructBookkeeping(WirebenchSim *sim, size_t index) {
    Module &m = sim->modules[index];
    const bool enabled = m.inPins.empty() ? true : asBool(m.inPins[0]);
    auto topIs = [sim](int32_t kind) {
        return !sim->constructStack.empty() && sim->modules[sim->constructStack.back()].kind == kind;
    };
    switch (m.kind) {
        case WIREBENCH_BLOCK_IF:
        case WIREBENCH_BLOCK_SWITCHCASE: {
            /* `b := (not InPinEnabled) xor Inverted`, pushed as the innermost condition. */
            const bool holds = (!enabled) != (m.variant == 1);
            sim->condStack = static_cast<int64_t>(static_cast<uint64_t>(sim->condStack) << 1) | (holds ? 1 : 0);
            sim->constructStack.push_back(index);
            if (m.kind == WIREBENCH_BLOCK_SWITCHCASE) {
                sim->switchMatched[index] = false;
                /* The selector is captured only while the switch's own bit is clear. */
                const bool captured = (sim->condStack & 1) == 0 && m.inPins.size() > 1;
                sim->switchSelector[index] = {captured, captured ? asInt(m.inPins[1]) : 0};
            }
            return;
        }
        case WIREBENCH_BLOCK_ELSE:
            if (topIs(WIREBENCH_BLOCK_IF)) sim->condStack ^= 1;
            return;
        case WIREBENCH_BLOCK_ENDIF:
        case WIREBENCH_BLOCK_ENDSWITCH:
            if (topIs(m.kind == WIREBENCH_BLOCK_ENDSWITCH ? WIREBENCH_BLOCK_SWITCHCASE : WIREBENCH_BLOCK_IF)) {
                sim->constructStack.pop_back();
                sim->condStack >>= 1;
            }
            return;
        case WIREBENCH_BLOCK_CASE: {
            /* Bit 0 := "this case did not match". */
            if (topIs(WIREBENCH_BLOCK_SWITCHCASE)) {
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
        case WIREBENCH_BLOCK_DEFAULT: {
            /* Runs only when the switch captured a selector and no case matched it. */
            if (topIs(WIREBENCH_BLOCK_SWITCHCASE)) {
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

WirebenchSim *wirebench_sim_create(const WirebenchModuleDesc *modules, int32_t count,
                             const DirigoConnection *connections, int32_t connectionCount,
                             double cycleDelayMs, int32_t profileScheduling) {
    WirebenchSim *sim = new WirebenchSim();
    sim->cycleDelayMs = cycleDelayMs > 0 ? cycleDelayMs : 1;
    sim->profileScheduling = profileScheduling != 0;

    for (int32_t i = 0; i < count; ++i) {
        const WirebenchModuleDesc &d = modules[i];
        Module m;
        m.id = d.id;
        m.order = d.order;
        m.threadId = d.threadId;
        m.kind = d.kind;
        m.variant = d.variant;
        m.hasEnable = d.hasEnable != 0;
        for (int c = 0; c < 4; ++c) m.config[c] = d.config[c];
        m.inPins.assign(static_cast<size_t>(std::max(0, d.inCount)), boolean(false));
        m.paramPins.assign(static_cast<size_t>(std::max(0, d.paramCount)), int32Value(0));
        m.outPins.assign(static_cast<size_t>(std::max(0, d.outCount)), boolean(false));
        for (int32_t p = 0; p < d.inCount && d.initialIn; ++p) m.inPins[p] = d.initialIn[p];
        for (int32_t p = 0; p < d.outCount && d.initialOut; ++p) m.outPins[p] = d.initialOut[p];
        /* A variable's value is its state, and the block was built holding its configured initial value
           in Y. Without this the state stayed 0 and the first pass overwrote the initial value. */
        if (m.kind == WIREBENCH_BLOCK_INTVAR && !m.outPins.empty()) m.intValue = asInt32(m.outPins[0]);
        if (m.kind == WIREBENCH_BLOCK_FLOATVAR && !m.outPins.empty()) m.floatVar = asFloat(m.outPins[0]);
        sim->indexById[m.id] = sim->modules.size();
        /* A module that has never run is due immediately, and the order within a thread is ORDER.
         *
         * `THREAD_ID` comes straight from the file and may be negative or absurd — a hand-edited or corrupt project is
         * still a project someone opens. Indexing `schedule` with it wrote out of bounds (a negative id became a huge
         * `size_t`), and a large one would have tried to allocate a vector per thread id. A module outside the
         * threads this simulator can hold is not scheduled at all: it keeps its pins and its state, and simply never
         * runs, which is what a block on no thread is. `kMaxThreads` is far past any hardware profile (the largest
         * has eight). */
        constexpr int32_t kMaxThreads = 64;
        if (m.threadId >= 0 && m.threadId < kMaxThreads) {
            if (static_cast<size_t>(sim->schedule.size()) <= static_cast<size_t>(m.threadId)) {
                sim->schedule.resize(static_cast<size_t>(m.threadId) + 1);
            }
            sim->schedule[static_cast<size_t>(m.threadId)].push_back(sim->modules.size());
        }
        sim->modules.push_back(std::move(m));
    }

    for (size_t t = 0; t < sim->schedule.size(); ++t) {
        std::sort(sim->schedule[t].begin(), sim->schedule[t].end(),
                  [sim](size_t a, size_t b) {
                      const Module &left = sim->modules[a];
                      const Module &right = sim->modules[b];
                      if (left.order != right.order) return left.order < right.order;
                      // The hardware compiler breaks ORDER ties by descending module id; agree with it.
                      return left.id > right.id;
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
    }
    /* Resolve every wire to module positions once, and file it under the modules it joins. */
    for (size_t i = 0; i < sim->connections.size(); ++i) {
        Connection &conn = sim->connections[i];
        auto from = sim->indexById.find(conn.outModule);
        auto to = sim->indexById.find(conn.inModule);
        conn.from = from == sim->indexById.end() ? kNoModule : from->second;
        conn.to = to == sim->indexById.end() ? kNoModule : to->second;
        if (conn.from != kNoModule) sim->modules[conn.from].outgoing.push_back(i);
        if (conn.to != kNoModule) sim->modules[conn.to].incoming.push_back(i);
    }
    return sim;
}

void wirebench_sim_set_macro_sweeps(WirebenchSim *sim, int32_t sweeps) {
    if (sim) sim->macroSweeps = sweeps < 1 ? 1 : sweeps;
}

void wirebench_sim_set_macro_bridges(WirebenchSim *sim, const WirebenchMacroBridge *bridges, int32_t count) {
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
              [](const WirebenchMacroBridge &a, const WirebenchMacroBridge &b) {
                  if (a.callerModule != b.callerModule) return a.callerModule < b.callerModule;
                  if (a.interfaceModule != b.interfaceModule) return a.interfaceModule < b.interfaceModule;
                  return a.kind < b.kind;
              });
}

void wirebench_sim_set_wall_clock(WirebenchSim *sim, WirebenchWallClock clock) {
    if (!sim) return;
    sim->wallClock = clock;
}

void wirebench_sim_set_thread_interval(WirebenchSim *sim, int32_t threadId, double intervalMs) {
    if (sim) sim->threadIntervalMs[threadId] = intervalMs;
}

void wirebench_sim_set_case_ranges(WirebenchSim *sim, int32_t index, const int64_t *ranges, int32_t count) {
    if (!sim || index < 0 || static_cast<size_t>(index) >= sim->modules.size()) return;
    Module &m = sim->modules[index];
    m.caseRanges.clear();
    for (int32_t i = 0; i < count && ranges; ++i) m.caseRanges.emplace_back(ranges[2 * i], ranges[2 * i + 1]);
}

void wirebench_sim_destroy(WirebenchSim *sim) { delete sim; }

void wirebench_sim_reset(WirebenchSim *sim) {
    if (!sim) return;
    sim->tickCount = 0;
    sim->threadElapsedMs.clear();
    sim->threadRunCounts.clear();
    sim->arrays.clear();             /* the data area is the PLC's, and a reset clears it */
    for (Module &m : sim->modules) {
        // A reset clears state, not configuration: the pins keep the values the project gave them, as the
        // per-module reset already does.
        const std::vector<WirebenchValue> ins = m.inPins, params = m.paramPins;
        resetModule(m);
        m.inPins = ins;
        m.paramPins = params;
    }
}

double wirebench_sim_ms_until_run(const WirebenchSim *sim) {
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
static int32_t stepImpl(WirebenchSim *sim, double deltaMs, bool forceAll) {
    sim->tickCount += 1;
    sim->condStack = 0;
    sim->constructStack.clear();
    /* The caller's delta is taken as given, to a thousandth of a millisecond, so a slowed simulation is slowed. */
    const double stepMs = std::max(0.001, deltaMs);
    /* The two whole-project sweeps are macro plumbing (`propagate`), and a project with no macro bridge has
       nothing for them to carry that the per-block push and pull do not. With none, skipping them is invisible:
       the corpus recordings and the block-against-core torture sweep both compare every pin of every step. */
    const bool sweeps = !sim->macroBridges.empty();
    if (sweeps) propagate(sim);
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
            /* One module, in this order: construct bookkeeping (never gated), then the gate,
               then pull, process, write-through and push. */
            constructBookkeeping(sim, index);
            /* The engine-level gate: a module inside a false branch, or whose first in pin reads 0, does
               not run and does not push, so all its outputs hold. That is not each block's own `En` rule —
               it applies even where pin 0 is an operand (`Int2Bits`'s `X`) — and it reads pin 0 *before*
               the pull, as the Swift does. */
            const Module &gated = sim->modules[index];
            if (sim->condStack != 0) continue;
            if (gated.hasEnable && !gated.inPins.empty() && !asBool(gated.inPins[0])) continue;
            pullInputs(sim, index);
            processModule(sim, sim->modules[index], sample, sim->wallClock);
            const int32_t kind = sim->modules[index].kind;
            if (kind == WIREBENCH_BLOCK_SETIDX) applySetIdxWriteThrough(sim, index);
            if (kind == WIREBENCH_BLOCK_SET) applySetWriteThrough(sim, index);
            propagateFrom(sim, index);       /* the Swift engine pushes after every block */
        }
    }
    if (ranAny && sweeps) propagate(sim);
    return ranAny ? 1 : 0;
}

int32_t wirebench_sim_step(WirebenchSim *sim, double deltaMs) {
    if (!sim) return 0;
    return stepImpl(sim, deltaMs, false);
}

void wirebench_sim_evaluate_now(WirebenchSim *sim) {
    if (sim) stepImpl(sim, sim->cycleDelayMs, true);
}

uint64_t wirebench_sim_tick_count(const WirebenchSim *sim) { return sim ? sim->tickCount : 0; }

WirebenchValue wirebench_sim_get_in(const WirebenchSim *sim, int32_t index, int32_t pin) {
    if (!sim || index < 0 || static_cast<size_t>(index) >= sim->modules.size()) return undefinedValue();
    const Module &m = sim->modules[index];
    if (pin < 0 || static_cast<size_t>(pin) >= m.inPins.size()) return undefinedValue();
    return m.inPins[pin];
}

WirebenchValue wirebench_sim_get_param(const WirebenchSim *sim, int32_t index, int32_t pin) {
    if (!sim || index < 0 || static_cast<size_t>(index) >= sim->modules.size()) return undefinedValue();
    const Module &m = sim->modules[index];
    if (pin < 0 || static_cast<size_t>(pin) >= m.paramPins.size()) return undefinedValue();
    return m.paramPins[pin];
}

WirebenchValue wirebench_sim_get_out(const WirebenchSim *sim, int32_t index, int32_t pin) {
    if (!sim || index < 0 || static_cast<size_t>(index) >= sim->modules.size()) return undefinedValue();
    const Module &m = sim->modules[index];
    if (pin < 0 || static_cast<size_t>(pin) >= m.outPins.size()) return undefinedValue();
    return m.outPins[pin];
}

void wirebench_sim_set_in(WirebenchSim *sim, int32_t index, int32_t pin, WirebenchValue value) {
    if (!sim || index < 0 || static_cast<size_t>(index) >= sim->modules.size()) return;
    Module &m = sim->modules[index];
    if (pin < 0 || static_cast<size_t>(pin) >= m.inPins.size()) return;
    m.inPins[pin] = value;
}

void wirebench_sim_set_param(WirebenchSim *sim, int32_t index, int32_t pin, WirebenchValue value) {
    if (!sim || index < 0 || static_cast<size_t>(index) >= sim->modules.size()) return;
    Module &m = sim->modules[index];
    if (pin < 0 || static_cast<size_t>(pin) >= m.paramPins.size()) return;
    m.paramPins[pin] = value;
}

void wirebench_sim_set_out(WirebenchSim *sim, int32_t index, int32_t pin, WirebenchValue value) {
    if (!sim || index < 0 || static_cast<size_t>(index) >= sim->modules.size()) return;
    Module &m = sim->modules[index];
    if (pin < 0 || static_cast<size_t>(pin) >= m.outPins.size()) return;
    m.outPins[pin] = value;
    m.pulseRemaining = 0;                 /* `BoolVarBlock.setOutput` */
    /* A variable's value is its *state*, not its pin: writing the pin alone is undone the next time the
       variable runs, so a value set by hand has to reach `intValue` too. */
    if (m.kind == WIREBENCH_BLOCK_INTVAR && pin == 0) m.intValue = static_cast<int32_t>(asInt(value));
    if (m.kind == WIREBENCH_BLOCK_FLOATVAR && pin == 0) {
        m.floatVar = asFloat(value);
        m.outPins[0] = floatValue(m.floatVar);
    }
}

void wirebench_sim_pulse_out(WirebenchSim *sim, int32_t index, int32_t pin, int32_t cycles) {
    if (!sim || index < 0 || static_cast<size_t>(index) >= sim->modules.size()) return;
    Module &m = sim->modules[index];
    if (pin < 0 || static_cast<size_t>(pin) >= m.outPins.size()) return;
    m.outPins[pin] = boolean(true);
    m.pulseRemaining = std::max(0, cycles);
}

void wirebench_sim_reset_module(WirebenchSim *sim, int32_t index) {
    if (!sim || index < 0 || static_cast<size_t>(index) >= sim->modules.size()) return;
    Module &m = sim->modules[index];
    const std::vector<WirebenchValue> ins = m.inPins, params = m.paramPins;
    resetModule(m);
    m.inPins = ins;
    m.paramPins = params;
}

void wirebench_sim_set_variant(WirebenchSim *sim, int32_t index, int32_t variant) {
    if (!sim || index < 0 || static_cast<size_t>(index) >= sim->modules.size()) return;
    sim->modules[index].variant = variant;
}

const char *wirebench_sim_maraflow_st_error(WirebenchSim *sim, int32_t index) {
    if (!sim || index < 0 || static_cast<size_t>(index) >= sim->modules.size()) return nullptr;
    const Module &module = sim->modules[static_cast<size_t>(index)];
    return module.stError.empty() ? nullptr : module.stError.c_str();
}

void wirebench_sim_set_string(WirebenchSim *sim, int32_t index, const char *key, const char *value) {
    if (!sim || !key || !value || index < 0 || static_cast<size_t>(index) >= sim->modules.size()) return;
    sim->modules[index].strings[key] = value;
}

void wirebench_sim_propagate(WirebenchSim *sim) {
    if (sim) propagate(sim);
}

uint64_t wirebench_sim_thread_run_count(const WirebenchSim *sim, int32_t threadId) {
    if (!sim) return 0;
    auto found = sim->threadRunCounts.find(threadId);
    return found == sim->threadRunCounts.end() ? 0 : found->second;
}

double wirebench_sim_thread_interval_ms(const WirebenchSim *sim, int32_t threadId) {
    return sim ? intervalMs(sim, threadId) : 0;
}

uint64_t wirebench_sim_pins_digest(const WirebenchSim *sim) {
    uint64_t digest = 0xcbf29ce484222325ULL;                    /* FNV-1a offset basis */
    if (!sim) return digest;
    auto mix = [&digest](uint64_t value) { digest = (digest ^ value) * 0x100000001b3ULL; };
    auto mixValue = [&mix](const WirebenchValue &v) {
        mix(static_cast<uint64_t>(v.kind));
        switch (v.kind) {
            case WIREBENCH_VALUE_INT64: mix(static_cast<uint64_t>(v.i64)); break;
            case WIREBENCH_VALUE_FLOAT: { double f = v.f; uint64_t bits; std::memcpy(&bits, &f, sizeof bits); mix(bits); break; }
            case WIREBENCH_VALUE_UNDEFINED: break;
            default: mix(static_cast<uint64_t>(static_cast<uint32_t>(v.i))); break;
        }
    };
    for (const Module &m : sim->modules) {
        mix(static_cast<uint64_t>(static_cast<uint32_t>(m.id)));
        for (const WirebenchValue &v : m.inPins) mixValue(v);
        for (const WirebenchValue &v : m.paramPins) mixValue(v);
        for (const WirebenchValue &v : m.outPins) mixValue(v);
    }
    return digest;
}

int32_t wirebench_sim_portable_kind_count(void) { return WIREBENCH_BLOCK_SETIDX; }

}  // extern "C"
