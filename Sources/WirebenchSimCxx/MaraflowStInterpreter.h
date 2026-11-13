//
//  MaraflowStInterpreter.h
//  Wirebench
//
//  Standalone C++17 port of Maraflow's Structured Text interpreter
//  (cz.maramat.sim.StInterpreter). Lexer, recursive-descent parser, AST and
//  bounded-iteration evaluator for one Maraflow ST page scan, plus the built-in
//  function library and the standard function blocks the interpreter emulates.
//
//  The Java interpreter re-parses the page on every scan and stores its function
//  block state in the per-scan variable map (so latches, timers, counters, edges
//  and RANDOM lose their state in the running simulator). This port compiles once
//  and keeps that state in the interpreter, per instance / per call site, as the
//  task requires. Everything else follows the Java grammar and evaluation rules,
//  including the Java precedence table (NOT binds tighter than comparison, ** is
//  a single application) and the 1000-iteration loop cap.
//
//  Storage contract:
//    * The supplied std::map is the page's persistent storage. VAR and VAR_OUTPUT
//      values live there between scans; VAR_TEMP is re-initialised at the start of
//      every scan.
//    * A VAR_INPUT is re-read from the ReadOperand callback at the start of every
//      scan when a callback is supplied; otherwise the map / declared initial
//      value is used.
//    * At the end of the scan every declared variable is converted with the
//      declared type's DataType.convertValue rules, and each VAR_OUTPUT is then
//      reported through the WriteOperand callback.
//    * Reads resolve in this order: persistent map (case-insensitive), declared
//      variable initial value, per-instance FB pins written by this scan, the
//      ReadOperand callback, 0.0 for an unknown identifier.
//    * Writes resolve in this order: existing map entry (case-insensitive),
//      declared variable (created on demand), per-instance FB pin, the
//      WriteOperand callback, a new map entry.
//
//  Scopes are not part of StVariable (the public table shape only carries name,
//  type and initial value), so scopes are taken from any VAR / VAR_INPUT /
//  VAR_OUTPUT / VAR_TEMP ... END_VAR declaration blocks present in `code`, exactly
//  as Maraflow's StDeclarationSync treats them. The `variables` table overrides
//  the type and initial value (and spelling) of matching declarations; variables
//  that exist only in the table are page-local VARs. Code with no declaration
//  blocks is accepted; all table variables then behave as VAR.
//
#pragma once

#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace wirebench {

struct StVariable {
    std::string name;
    int type;       // 0 BOOL, 1 INT, 2 LONG, 3 FLOAT
    double initial;
};

class StInterpreter {
public:
    using ReadOperand = std::function<double(const std::string&)>;
    using WriteOperand = std::function<void(const std::string&, double)>;

    StInterpreter();

    // Compiles code and declarations. Returns false and fills error (line +
    // message) on a syntax error. On failure the previous program is discarded.
    bool compile(const std::string& code, const std::vector<StVariable>& variables,
                 std::string& error, int& errorLine);

    // Runs one scan. variableState is the page's persistent VAR storage (name ->
    // typed double value); inputs from VAR_INPUT come from the caller map, outputs
    // are written back through writeOperand.
    void execute(const ReadOperand& read, const WriteOperand& write,
                 std::map<std::string, double>& variables);

    // Clears the persistent function-block / edge / RANDOM state. The compiled
    // program and the caller's variable storage are left untouched.
    void reset();

private:
    struct Impl;
    std::shared_ptr<Impl> impl_;
};

} // namespace wirebench
