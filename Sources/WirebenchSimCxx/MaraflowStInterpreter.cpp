//
//  MaraflowStInterpreter.cpp
//  Wirebench
//
//  C++17 port of cz.maramat.sim.StInterpreter (lexer, parser, evaluator, built-in
//  functions, emulated standard function blocks). See MaraflowStInterpreter.h for
//  the storage contract and the deliberate deviations from the Java original.
//

#include "MaraflowStInterpreter.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <limits>
#include <random>
#include <string>
#include <utility>

namespace wirebench {
namespace {

constexpr int kMaxLoopIterations = 1000;

struct SyntaxError {
    int line;
    std::string message;
};

struct RuntimeFault {};

std::string upperAscii(const std::string& text) {
    std::string out = text;
    for (char& c : out) {
        c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    }
    return out;
}

std::string lowerAscii(const std::string& text) {
    std::string out = text;
    for (char& c : out) {
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }
    return out;
}

bool equalsIgnoreCase(const std::string& a, const std::string& b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); ++i) {
        if (std::tolower(static_cast<unsigned char>(a[i])) !=
            std::tolower(static_cast<unsigned char>(b[i]))) {
            return false;
        }
    }
    return true;
}

bool isTruthy(double value) {
    return std::fabs(value) >= 0.5;
}

// DataType.convertValue: BOOL maps any non-zero value to 1, INT truncates
// toward zero (saturating as the Java narrowing conversion does), LONG
// truncates, FLOAT narrows to 32 bits.
int javaDoubleToInt(double value) {
    if (std::isnan(value)) return 0;
    if (value >= 2147483647.0) return std::numeric_limits<int>::max();
    if (value <= -2147483648.0) return std::numeric_limits<int>::min();
    return static_cast<int>(value);
}

long long javaDoubleToLong(double value) {
    if (std::isnan(value)) return 0;
    const double maxLong = 9223372036854775807.0;
    const double minLong = -9223372036854775808.0;
    if (value >= maxLong) return std::numeric_limits<long long>::max();
    if (value <= minLong) return std::numeric_limits<long long>::min();
    return static_cast<long long>(value);
}

double convertValue(double value, int type) {
    switch (type) {
        case 0: return (value != 0.0 && !std::isnan(value)) ? 1.0 : 0.0;
        case 1: return static_cast<double>(javaDoubleToInt(value));
        case 2: return static_cast<double>(javaDoubleToLong(value));
        case 3: return static_cast<double>(static_cast<float>(value));
        default: return value;
    }
}

int sanitizeType(int type) {
    return (type >= 0 && type <= 3) ? type : 1;
}

double javaRound(double value) {
    if (std::isnan(value)) return 0.0;
    return std::floor(value + 0.5);
}

long long javaRoundLong(double value) {
    return javaDoubleToLong(javaRound(value));
}

int digitValue(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'z') return c - 'a' + 10;
    if (c >= 'A' && c <= 'Z') return c - 'A' + 10;
    return -1;
}

double clampOrFault(double value, double low, double high) {
    // Java's Math.clamp throws when min > max; execute() suppresses the fault.
    if (low > high) throw RuntimeFault{};
    if (value < low) return low;
    if (value > high) return high;
    return value;
}

enum class TokType {
    Ident, Number,
    Assign,         // :=
    Arrow,          // =>
    Semi,           // ;
    Colon,          // :
    Comma,          // ,
    DotDot,         // ..
    LParen, RParen, // ( )
    Plus, Minus, Star, Slash, Power, // + - * / **
    Eq, Neq, Lt, Lte, Gt, Gte,       // = <> < <= > >=
    KwIf, KwThen, KwElsif, KwElse, KwEndIf,
    KwCase, KwOf, KwEndCase,
    KwFor, KwTo, KwBy, KwDo, KwEndFor,
    KwWhile, KwEndWhile,
    KwRepeat, KwUntil, KwEndRepeat,
    KwExit, KwReturn,
    KwAnd, KwOr, KwXor, KwNot, KwMod,
    KwTrue, KwFalse,
    Eof
};

struct Token {
    TokType type;
    std::string text;
    double numVal;
    int line;
};

bool isCallableKeyword(TokType type) {
    return type == TokType::KwAnd || type == TokType::KwOr || type == TokType::KwXor ||
           type == TokType::KwNot || type == TokType::KwMod;
}

double parseNumericLiteral(const std::string& raw, int line) {
    const size_t hash = raw.find('#');
    if (hash != std::string::npos && hash > 0) {
        int radix = 0;
        for (size_t i = 0; i < hash; ++i) {
            const int digit = digitValue(raw[i]);
            if (digit < 0 || digit >= 10) {
                throw SyntaxError{line, "Invalid number literal '" + raw + "'"};
            }
            radix = radix * 10 + digit;
        }
        if (radix < 2 || radix > 36 || hash + 1 >= raw.size()) {
            throw SyntaxError{line, "Invalid number literal '" + raw + "'"};
        }
        long long value = 0;
        for (size_t i = hash + 1; i < raw.size(); ++i) {
            const int digit = digitValue(raw[i]);
            if (digit < 0 || digit >= radix) {
                throw SyntaxError{line, "Invalid number literal '" + raw + "'"};
            }
            value = value * radix + digit;
        }
        return static_cast<double>(value);
    }

    std::string text = raw;
    if (!text.empty()) {
        const char last = text.back();
        // Double.parseDouble accepts the f/F/d/D suffix.
        if (last == 'f' || last == 'F' || last == 'd' || last == 'D') {
            text.pop_back();
        }
    }
    if (text.empty() || text.find('x') != std::string::npos ||
        text.find('X') != std::string::npos) {
        throw SyntaxError{line, "Invalid number literal '" + raw + "'"};
    }
    char* end = nullptr;
    const double value = std::strtod(text.c_str(), &end);
    if (end == text.c_str() || end == nullptr || *end != '\0') {
        throw SyntaxError{line, "Invalid number literal '" + raw + "'"};
    }
    return value;
}

std::vector<Token> tokenize(const std::string& source) {
    std::vector<Token> out;
    const size_t n = source.size();
    size_t i = 0;
    int line = 1;

    while (i < n) {
        const char c = source[i];
        if (c == '\n') {
            ++line;
            ++i;
            continue;
        }
        if (std::isspace(static_cast<unsigned char>(c))) {
            ++i;
            continue;
        }
        if (c == '/' && i + 1 < n && source[i + 1] == '/') {
            i += 2;
            while (i < n && source[i] != '\n') ++i;
            continue;
        }
        if (c == '(' && i + 1 < n && source[i + 1] == '*') {
            i += 2;
            while (i + 1 < n && !(source[i] == '*' && source[i + 1] == ')')) {
                if (source[i] == '\n') ++line;
                ++i;
            }
            i = std::min(n, i + 2);
            continue;
        }
        if (c == '/' && i + 1 < n && source[i + 1] == '*') {
            i += 2;
            while (i + 1 < n && !(source[i] == '*' && source[i + 1] == '/')) {
                if (source[i] == '\n') ++line;
                ++i;
            }
            i = std::min(n, i + 2);
            continue;
        }

        if (c == ':' && i + 1 < n && source[i + 1] == '=') {
            out.push_back(Token{TokType::Assign, ":=", 0.0, line});
            i += 2;
            continue;
        }
        if (c == '=' && i + 1 < n && source[i + 1] == '>') {
            out.push_back(Token{TokType::Arrow, "=>", 0.0, line});
            i += 2;
            continue;
        }
        if (c == '.' && i + 1 < n && source[i + 1] == '.') {
            out.push_back(Token{TokType::DotDot, "..", 0.0, line});
            i += 2;
            continue;
        }
        if (c == '<' && i + 1 < n && source[i + 1] == '>') {
            out.push_back(Token{TokType::Neq, "<>", 0.0, line});
            i += 2;
            continue;
        }
        if (c == '!' && i + 1 < n && source[i + 1] == '=') {
            out.push_back(Token{TokType::Neq, "!=", 0.0, line});
            i += 2;
            continue;
        }
        if (c == '<' && i + 1 < n && source[i + 1] == '=') {
            out.push_back(Token{TokType::Lte, "<=", 0.0, line});
            i += 2;
            continue;
        }
        if (c == '>' && i + 1 < n && source[i + 1] == '=') {
            out.push_back(Token{TokType::Gte, ">=", 0.0, line});
            i += 2;
            continue;
        }
        if (c == '*' && i + 1 < n && source[i + 1] == '*') {
            out.push_back(Token{TokType::Power, "**", 0.0, line});
            i += 2;
            continue;
        }

        switch (c) {
            case ';': out.push_back(Token{TokType::Semi, ";", 0.0, line}); ++i; continue;
            case ':': out.push_back(Token{TokType::Colon, ":", 0.0, line}); ++i; continue;
            case ',': out.push_back(Token{TokType::Comma, ",", 0.0, line}); ++i; continue;
            case '(': out.push_back(Token{TokType::LParen, "(", 0.0, line}); ++i; continue;
            case ')': out.push_back(Token{TokType::RParen, ")", 0.0, line}); ++i; continue;
            case '+': out.push_back(Token{TokType::Plus, "+", 0.0, line}); ++i; continue;
            case '-': out.push_back(Token{TokType::Minus, "-", 0.0, line}); ++i; continue;
            case '*': out.push_back(Token{TokType::Star, "*", 0.0, line}); ++i; continue;
            case '/': out.push_back(Token{TokType::Slash, "/", 0.0, line}); ++i; continue;
            case '=': out.push_back(Token{TokType::Eq, "=", 0.0, line}); ++i; continue;
            case '<': out.push_back(Token{TokType::Lt, "<", 0.0, line}); ++i; continue;
            case '>': out.push_back(Token{TokType::Gt, ">", 0.0, line}); ++i; continue;
            default: break;
        }

        if (std::isdigit(static_cast<unsigned char>(c))) {
            const size_t start = i;
            while (i < n && (std::isalnum(static_cast<unsigned char>(source[i])) ||
                             source[i] == '_' || source[i] == '#')) {
                ++i;
            }
            if (i < n && source[i] == '.' && (i + 1 >= n || source[i + 1] != '.')) {
                ++i;
                while (i < n && (std::isdigit(static_cast<unsigned char>(source[i])) ||
                                 source[i] == '_')) {
                    ++i;
                }
            }
            std::string raw = source.substr(start, i - start);
            raw.erase(std::remove(raw.begin(), raw.end(), '_'), raw.end());
            const double value = parseNumericLiteral(raw, line);
            out.push_back(Token{TokType::Number, raw, value, line});
            continue;
        }

        if (std::isalpha(static_cast<unsigned char>(c)) || c == '_') {
            const size_t start = i;
            while (i < n && (std::isalnum(static_cast<unsigned char>(source[i])) ||
                             source[i] == '_' || source[i] == '.')) {
                ++i;
            }
            const std::string ident = source.substr(start, i - start);
            const std::string upper = upperAscii(ident);
            TokType type = TokType::Ident;
            if (upper == "IF") type = TokType::KwIf;
            else if (upper == "THEN") type = TokType::KwThen;
            else if (upper == "ELSIF" || upper == "ELSEIF") type = TokType::KwElsif;
            else if (upper == "ELSE") type = TokType::KwElse;
            else if (upper == "END_IF" || upper == "ENDIF") type = TokType::KwEndIf;
            else if (upper == "CASE") type = TokType::KwCase;
            else if (upper == "OF") type = TokType::KwOf;
            else if (upper == "END_CASE" || upper == "ENDCASE") type = TokType::KwEndCase;
            else if (upper == "FOR") type = TokType::KwFor;
            else if (upper == "TO") type = TokType::KwTo;
            else if (upper == "BY") type = TokType::KwBy;
            else if (upper == "DO") type = TokType::KwDo;
            else if (upper == "END_FOR" || upper == "ENDFOR") type = TokType::KwEndFor;
            else if (upper == "WHILE") type = TokType::KwWhile;
            else if (upper == "END_WHILE" || upper == "ENDWHILE") type = TokType::KwEndWhile;
            else if (upper == "REPEAT") type = TokType::KwRepeat;
            else if (upper == "UNTIL") type = TokType::KwUntil;
            else if (upper == "END_REPEAT" || upper == "ENDREPEAT") type = TokType::KwEndRepeat;
            else if (upper == "EXIT") type = TokType::KwExit;
            else if (upper == "RETURN") type = TokType::KwReturn;
            else if (upper == "AND") type = TokType::KwAnd;
            else if (upper == "OR") type = TokType::KwOr;
            else if (upper == "XOR") type = TokType::KwXor;
            else if (upper == "NOT") type = TokType::KwNot;
            else if (upper == "MOD") type = TokType::KwMod;
            else if (upper == "TRUE") type = TokType::KwTrue;
            else if (upper == "FALSE") type = TokType::KwFalse;
            out.push_back(Token{type, ident, type == TokType::KwTrue ? 1.0 : 0.0, line});
            continue;
        }

        throw SyntaxError{line, std::string("Unexpected character '") + c + "'"};
    }

    out.push_back(Token{TokType::Eof, "", 0.0, line});
    return out;
}

} // namespace

// =============================================================================
// Interpreter implementation
// =============================================================================

struct StInterpreter::Impl {
    struct EvalContext;
    struct Expr;
    using ExprPtr = std::shared_ptr<Expr>;
    using Stmt = std::function<void(EvalContext&)>;

    struct Expr {
        int line = 0;
        std::function<double(EvalContext&)> eval;
    };

    struct EvalContext {
        Impl* impl = nullptr;
        std::map<std::string, double>* vars = nullptr;
        const std::function<double(const std::string&)>* readCb = nullptr;
        const std::function<void(const std::string&, double)>* writeCb = nullptr;
        bool exitFlag = false;
        bool returnFlag = false;

        double read(const std::string& name);
        void write(const std::string& name, double value);
    };

    struct CallArg {
        std::string paramName;
        ExprPtr expr;
        std::string outputVarName;
        bool isOutput = false;
    };

    struct Branch {
        ExprPtr cond;
        std::vector<Stmt> body;
    };

    struct CaseArm {
        std::vector<std::pair<int, int>> ranges;
        std::vector<Stmt> body;
    };

    struct DeclVar {
        std::string name;
        int scope = 0;
        int type = 1;
        double initial = 0.0;
    };

    enum {
        kScopeVar = 0,
        kScopeInput = 1,
        kScopeOutput = 2,
        kScopeTemp = 3
    };

    struct Parser {
        Impl* impl = nullptr;
        std::vector<Token> tokens;
        size_t pos = 0;

        Parser(Impl* owner, std::vector<Token> toks)
            : impl(owner), tokens(std::move(toks)) {}

        const Token& peek() const { return tokens[pos]; }

        const Token& lookahead() const {
            return (pos + 1 < tokens.size()) ? tokens[pos + 1] : tokens.back();
        }

        Token next() {
            Token token = tokens[pos];
            if (token.type != TokType::Eof) ++pos;
            return token;
        }

        bool match(TokType type) {
            if (peek().type == type) {
                next();
                return true;
            }
            return false;
        }

        Token expect(TokType type, const std::string& message) {
            if (peek().type == type) return next();
            throw SyntaxError{peek().line,
                              message + " (found '" +
                                  (peek().text.empty() ? std::string("EOF") : peek().text) +
                                  "')"};
        }

        static bool isStopToken(TokType type, const std::vector<TokType>& stops) {
            for (TokType stop : stops) {
                if (type == stop) return true;
            }
            return false;
        }

        std::vector<Stmt> parseStatementList(const std::vector<TokType>& stops) {
            std::vector<Stmt> list;
            while (peek().type != TokType::Eof && !isStopToken(peek().type, stops)) {
                if (match(TokType::Semi)) continue;
                list.push_back(parseStatement());
                match(TokType::Semi);
            }
            return list;
        }

        std::vector<CallArg> parseCallArgs() {
            std::vector<CallArg> list;
            if (peek().type == TokType::RParen) return list;
            do {
                if ((peek().type == TokType::Ident || isCallableKeyword(peek().type)) &&
                    (lookahead().type == TokType::Assign ||
                     lookahead().type == TokType::Arrow)) {
                    Token nameTok = next();
                    if (match(TokType::Arrow)) {
                        Token outVar =
                            expect(TokType::Ident, "Expected output variable name after '=>'");
                        CallArg arg;
                        arg.paramName = nameTok.text;
                        arg.outputVarName = outVar.text;
                        arg.isOutput = true;
                        list.push_back(std::move(arg));
                    } else {
                        expect(TokType::Assign,
                               "Expected ':=' after parameter name '" + nameTok.text + "'");
                        CallArg arg;
                        arg.paramName = nameTok.text;
                        arg.expr = parseExpr();
                        list.push_back(std::move(arg));
                    }
                } else {
                    CallArg arg;
                    arg.expr = parseExpr();
                    list.push_back(std::move(arg));
                }
            } while (match(TokType::Comma));
            return list;
        }

        Stmt parseStatement() {
            const Token token = peek();
            if (token.type == TokType::Ident) {
                Token id = next();
                if (match(TokType::LParen)) {
                    std::vector<CallArg> args = parseCallArgs();
                    expect(TokType::RParen, "Expected ')' after invocation arguments");
                    const std::string name = id.text;
                    return [name, args](EvalContext& ctx) { ctx.impl->execCall(ctx, name, args); };
                }
                expect(TokType::Assign, "Expected ':=' in assignment to '" + id.text + "'");
                ExprPtr rhs = parseExpr();
                const std::string target = id.text;
                return [target, rhs](EvalContext& ctx) { ctx.write(target, rhs->eval(ctx)); };
            }
            if (isCallableKeyword(token.type) && lookahead().type == TokType::LParen) {
                Token id = next();
                next(); // consume '('
                std::vector<CallArg> args = parseCallArgs();
                expect(TokType::RParen, "Expected ')' after invocation arguments");
                const std::string name = id.text;
                return [name, args](EvalContext& ctx) { ctx.impl->execCall(ctx, name, args); };
            }
            switch (token.type) {
                case TokType::KwIf: return parseIf();
                case TokType::KwCase: return parseCase();
                case TokType::KwFor: return parseFor();
                case TokType::KwWhile: return parseWhile();
                case TokType::KwRepeat: return parseRepeat();
                case TokType::KwExit:
                    next();
                    return [](EvalContext& ctx) { ctx.exitFlag = true; };
                case TokType::KwReturn:
                    next();
                    return [](EvalContext& ctx) { ctx.returnFlag = true; };
                default:
                    throw SyntaxError{
                        token.line,
                        "Unexpected token '" +
                            (token.text.empty() ? std::string("EOF") : token.text) +
                            "' at start of statement"};
            }
        }

        Stmt parseIf() {
            expect(TokType::KwIf, "Expected IF");
            ExprPtr cond = parseExpr();
            expect(TokType::KwThen, "Expected THEN after IF condition");
            std::vector<Branch> branches;
            branches.push_back(Branch{
                cond, parseStatementList({TokType::KwElsif, TokType::KwElse, TokType::KwEndIf})});
            while (match(TokType::KwElsif)) {
                ExprPtr elsifCond = parseExpr();
                expect(TokType::KwThen, "Expected THEN after ELSIF condition");
                branches.push_back(Branch{
                    elsifCond,
                    parseStatementList({TokType::KwElsif, TokType::KwElse, TokType::KwEndIf})});
            }
            std::vector<Stmt> elseBody;
            if (match(TokType::KwElse)) {
                elseBody = parseStatementList({TokType::KwEndIf});
            }
            expect(TokType::KwEndIf, "Expected END_IF");
            return [branches = std::move(branches), elseBody = std::move(elseBody)](
                       EvalContext& ctx) {
                for (const Branch& branch : branches) {
                    if (isTruthy(branch.cond->eval(ctx))) {
                        Impl::execBody(branch.body, ctx);
                        return;
                    }
                }
                Impl::execBody(elseBody, ctx);
            };
        }

        bool isCaseLabelStart() const {
            size_t p = pos;
            if (p < tokens.size() &&
                (tokens[p].type == TokType::Minus || tokens[p].type == TokType::Plus)) {
                ++p;
            }
            if (p < tokens.size() && tokens[p].type == TokType::Number) {
                ++p;
                if (p < tokens.size() &&
                    (tokens[p].type == TokType::Colon || tokens[p].type == TokType::Comma ||
                     tokens[p].type == TokType::DotDot)) {
                    return true;
                }
            }
            return false;
        }

        int parseCaseInt() {
            bool neg = match(TokType::Minus);
            if (!neg) match(TokType::Plus);
            Token num = expect(TokType::Number, "Expected integer constant in CASE label");
            int value = javaDoubleToInt(javaRound(num.numVal));
            return neg ? -value : value;
        }

        Stmt parseCase() {
            expect(TokType::KwCase, "Expected CASE");
            ExprPtr selector = parseExpr();
            expect(TokType::KwOf, "Expected OF after CASE selector");
            std::vector<CaseArm> arms;
            std::vector<Stmt> elseBody;
            bool hasElse = false;

            while (peek().type != TokType::Eof && peek().type != TokType::KwEndCase) {
                if (match(TokType::KwElse)) {
                    hasElse = true;
                    elseBody = parseStatementList({TokType::KwEndCase});
                    break;
                }
                std::vector<std::pair<int, int>> ranges;
                do {
                    int low = parseCaseInt();
                    int high = low;
                    if (match(TokType::DotDot)) high = parseCaseInt();
                    ranges.emplace_back(low, high);
                } while (match(TokType::Comma));
                expect(TokType::Colon, "Expected ':' after CASE label");

                CaseArm arm;
                arm.ranges = std::move(ranges);
                while (peek().type != TokType::Eof && peek().type != TokType::KwEndCase &&
                       peek().type != TokType::KwElse && !isCaseLabelStart()) {
                    if (match(TokType::Semi)) continue;
                    arm.body.push_back(parseStatement());
                    match(TokType::Semi);
                }
                arms.push_back(std::move(arm));
            }
            expect(TokType::KwEndCase, "Expected END_CASE");
            return [selector, arms = std::move(arms), elseBody = std::move(elseBody), hasElse](
                       EvalContext& ctx) {
                const int selected = javaDoubleToInt(javaRound(selector->eval(ctx)));
                for (const CaseArm& arm : arms) {
                    for (const std::pair<int, int>& range : arm.ranges) {
                        if (selected >= range.first && selected <= range.second) {
                            Impl::execBody(arm.body, ctx);
                            return;
                        }
                    }
                }
                if (hasElse) Impl::execBody(elseBody, ctx);
            };
        }

        Stmt parseFor() {
            expect(TokType::KwFor, "Expected FOR");
            Token varTok = expect(TokType::Ident, "Expected loop variable identifier after FOR");
            expect(TokType::Assign, "Expected ':=' after FOR variable");
            ExprPtr start = parseExpr();
            expect(TokType::KwTo, "Expected TO in FOR loop");
            ExprPtr end = parseExpr();
            ExprPtr step;
            if (match(TokType::KwBy)) {
                step = parseExpr();
            }
            expect(TokType::KwDo, "Expected DO in FOR loop");
            std::vector<Stmt> body = parseStatementList({TokType::KwEndFor});
            expect(TokType::KwEndFor, "Expected END_FOR");
            const std::string varName = varTok.text;
            return [varName, start, end, step, body](EvalContext& ctx) {
                double current = javaRound(start->eval(ctx));
                const double limit = javaRound(end->eval(ctx));
                double increment = step ? javaRound(step->eval(ctx)) : 1.0;
                if (increment == 0.0) increment = 1.0;

                int guards = 0;
                ctx.write(varName, current);
                while ((increment > 0.0 ? current <= limit : current >= limit) &&
                       guards++ < kMaxLoopIterations) {
                    bool stop = false;
                    for (const Stmt& statement : body) {
                        statement(ctx);
                        if (ctx.returnFlag) return;
                        if (ctx.exitFlag) {
                            ctx.exitFlag = false;
                            stop = true;
                            break;
                        }
                    }
                    if (stop) return;
                    current = ctx.read(varName) + increment;
                    ctx.write(varName, current);
                }
            };
        }

        Stmt parseWhile() {
            expect(TokType::KwWhile, "Expected WHILE");
            ExprPtr cond = parseExpr();
            expect(TokType::KwDo, "Expected DO after WHILE condition");
            std::vector<Stmt> body = parseStatementList({TokType::KwEndWhile});
            expect(TokType::KwEndWhile, "Expected END_WHILE");
            return [cond, body](EvalContext& ctx) {
                int guards = 0;
                while (isTruthy(cond->eval(ctx)) && guards++ < kMaxLoopIterations) {
                    bool stop = false;
                    for (const Stmt& statement : body) {
                        statement(ctx);
                        if (ctx.returnFlag) return;
                        if (ctx.exitFlag) {
                            ctx.exitFlag = false;
                            stop = true;
                            break;
                        }
                    }
                    if (stop) return;
                }
            };
        }

        Stmt parseRepeat() {
            expect(TokType::KwRepeat, "Expected REPEAT");
            std::vector<Stmt> body = parseStatementList({TokType::KwUntil});
            expect(TokType::KwUntil, "Expected UNTIL in REPEAT loop");
            ExprPtr cond = parseExpr();
            match(TokType::Semi);
            expect(TokType::KwEndRepeat, "Expected END_REPEAT");
            return [body, cond](EvalContext& ctx) {
                int guards = 0;
                do {
                    bool stop = false;
                    for (const Stmt& statement : body) {
                        statement(ctx);
                        if (ctx.returnFlag) return;
                        if (ctx.exitFlag) {
                            ctx.exitFlag = false;
                            stop = true;
                            break;
                        }
                    }
                    if (stop) return;
                } while (!isTruthy(cond->eval(ctx)) && ++guards < kMaxLoopIterations);
            };
        }

        // Expression grammar, lowest precedence first:
        // OR -> XOR -> AND -> comparison -> add/sub -> mul/div/mod -> power -> unary
        ExprPtr parseExpr() { return parseOr(); }

        ExprPtr parseOr() {
            ExprPtr left = parseXor();
            while (match(TokType::KwOr)) {
                ExprPtr right = parseXor();
                ExprPtr lhs = left;
                left = impl->makeExpr(peek().line, [lhs, right](EvalContext& ctx) -> double {
                    if (isTruthy(lhs->eval(ctx))) return 1.0;
                    return isTruthy(right->eval(ctx)) ? 1.0 : 0.0;
                });
            }
            return left;
        }

        ExprPtr parseXor() {
            ExprPtr left = parseAnd();
            while (match(TokType::KwXor)) {
                ExprPtr right = parseAnd();
                ExprPtr lhs = left;
                left = impl->makeExpr(peek().line, [lhs, right](EvalContext& ctx) -> double {
                    const bool a = isTruthy(lhs->eval(ctx));
                    const bool b = isTruthy(right->eval(ctx));
                    return (a != b) ? 1.0 : 0.0;
                });
            }
            return left;
        }

        ExprPtr parseAnd() {
            ExprPtr left = parseComparison();
            while (match(TokType::KwAnd)) {
                ExprPtr right = parseComparison();
                ExprPtr lhs = left;
                left = impl->makeExpr(peek().line, [lhs, right](EvalContext& ctx) -> double {
                    if (!isTruthy(lhs->eval(ctx))) return 0.0;
                    return isTruthy(right->eval(ctx)) ? 1.0 : 0.0;
                });
            }
            return left;
        }

        ExprPtr parseComparison() {
            ExprPtr left = parseAddSub();
            const TokType type = peek().type;
            if (type == TokType::Eq || type == TokType::Neq || type == TokType::Lt ||
                type == TokType::Lte || type == TokType::Gt || type == TokType::Gte) {
                const int line = peek().line;
                next();
                ExprPtr right = parseAddSub();
                ExprPtr lhs = left;
                return impl->makeExpr(line, [type, lhs, right](EvalContext& ctx) -> double {
                    const double a = lhs->eval(ctx);
                    const double b = right->eval(ctx);
                    switch (type) {
                        case TokType::Eq: return std::fabs(a - b) < 1e-6 ? 1.0 : 0.0;
                        case TokType::Neq: return std::fabs(a - b) >= 1e-6 ? 1.0 : 0.0;
                        case TokType::Lt: return a < b ? 1.0 : 0.0;
                        case TokType::Lte: return a <= b ? 1.0 : 0.0;
                        case TokType::Gt: return a > b ? 1.0 : 0.0;
                        case TokType::Gte: return a >= b ? 1.0 : 0.0;
                        default: return 1.0;
                    }
                });
            }
            return left;
        }

        ExprPtr parseAddSub() {
            ExprPtr left = parseMulDiv();
            while (peek().type == TokType::Plus || peek().type == TokType::Minus) {
                const TokType op = next().type;
                ExprPtr right = parseMulDiv();
                ExprPtr lhs = left;
                left = impl->makeExpr(peek().line, [op, lhs, right](EvalContext& ctx) -> double {
                    const double a = lhs->eval(ctx);
                    const double b = right->eval(ctx);
                    return op == TokType::Plus ? a + b : a - b;
                });
            }
            return left;
        }

        ExprPtr parseMulDiv() {
            ExprPtr left = parsePower();
            while (peek().type == TokType::Star || peek().type == TokType::Slash ||
                   peek().type == TokType::KwMod) {
                const TokType op = next().type;
                ExprPtr right = parsePower();
                ExprPtr lhs = left;
                if (op == TokType::Star) {
                    left = impl->makeExpr(peek().line, [lhs, right](EvalContext& ctx) -> double {
                        const double a = lhs->eval(ctx);
                        const double b = right->eval(ctx);
                        return a * b;
                    });
                } else if (op == TokType::Slash) {
                    left = impl->makeExpr(peek().line, [lhs, right](EvalContext& ctx) -> double {
                        const double divisor = right->eval(ctx);
                        if (std::fabs(divisor) < 1e-12) return 0.0;
                        return lhs->eval(ctx) / divisor;
                    });
                } else {
                    left = impl->makeExpr(peek().line, [lhs, right](EvalContext& ctx) -> double {
                        const long long divisor = javaRoundLong(right->eval(ctx));
                        if (divisor == 0) return 0.0;
                        return static_cast<double>(javaRoundLong(lhs->eval(ctx)) % divisor);
                    });
                }
            }
            return left;
        }

        ExprPtr parsePower() {
            ExprPtr left = parseUnary();
            if (match(TokType::Power)) {
                const int line = peek().line;
                ExprPtr right = parseUnary();
                ExprPtr lhs = left;
                return impl->makeExpr(line, [lhs, right](EvalContext& ctx) -> double {
                    const double base = lhs->eval(ctx);
                    const double exponent = right->eval(ctx);
                    return std::pow(base, exponent);
                });
            }
            return left;
        }

        ExprPtr parseUnary() {
            const int line = peek().line;
            if (match(TokType::Minus)) {
                ExprPtr operand = parseUnary();
                return impl->makeExpr(line, [operand](EvalContext& ctx) -> double {
                    return -operand->eval(ctx);
                });
            }
            if (match(TokType::Plus)) {
                return parseUnary();
            }
            if (peek().type == TokType::KwNot && lookahead().type != TokType::LParen) {
                next();
                ExprPtr operand = parseUnary();
                return impl->makeExpr(line, [operand](EvalContext& ctx) -> double {
                    return isTruthy(operand->eval(ctx)) ? 0.0 : 1.0;
                });
            }
            return parsePrimary();
        }

        ExprPtr parsePrimary() {
            const Token token = peek();
            if (token.type == TokType::Number || token.type == TokType::KwTrue ||
                token.type == TokType::KwFalse) {
                next();
                const double value = token.numVal;
                return impl->makeExpr(token.line, [value](EvalContext&) -> double { return value; });
            }
            if (match(TokType::LParen)) {
                ExprPtr inner = parseExpr();
                expect(TokType::RParen, "Expected ')'");
                return inner;
            }
            if (token.type == TokType::Ident ||
                (isCallableKeyword(token.type) && lookahead().type == TokType::LParen)) {
                Token fnTok = next();
                const std::string name = fnTok.text;
                if (match(TokType::LParen)) {
                    std::vector<CallArg> args = parseCallArgs();
                    expect(TokType::RParen, "Expected ')' after function arguments");
                    return buildFunctionCall(name, args, fnTok.line);
                }
                if (fnTok.type == TokType::Ident) {
                    return impl->makeExpr(fnTok.line, [name](EvalContext& ctx) -> double {
                        return ctx.read(name);
                    });
                }
            }
            throw SyntaxError{token.line,
                              "Expected expression (found '" +
                                  (token.text.empty() ? std::string("EOF") : token.text) + "')"};
        }

        void requireArgs(const std::string& function, const std::vector<ExprPtr>& args,
                         size_t expected, int line) {
            if (args.size() != expected) {
                throw SyntaxError{line,
                                  "Function " + function + " expects " + std::to_string(expected) +
                                      " argument(s), got " + std::to_string(args.size())};
            }
        }

        ExprPtr buildFunctionCall(const std::string& fnName,
                                  const std::vector<CallArg>& rawArgs, int line) {
            const std::string up = upperAscii(fnName);

            std::vector<ExprPtr> inputExprs;
            for (const CallArg& arg : rawArgs) {
                if (!arg.isOutput && arg.expr) inputExprs.push_back(arg.expr);
            }
            const CallArg* enArg = nullptr;
            for (const CallArg& arg : rawArgs) {
                if (!arg.paramName.empty() && equalsIgnoreCase(arg.paramName, "EN")) {
                    enArg = &arg;
                    break;
                }
            }
            std::vector<ExprPtr> operandExprs;
            if (enArg != nullptr) {
                for (const CallArg& arg : rawArgs) {
                    if (arg.isOutput || !arg.expr) continue;
                    if (!arg.paramName.empty() && equalsIgnoreCase(arg.paramName, "EN")) continue;
                    operandExprs.push_back(arg.expr);
                }
            } else {
                operandExprs = inputExprs;
            }
            ExprPtr en = enArg != nullptr ? enArg->expr : nullptr;

            if (up == "AND" || up == "NAND" || up == "OR" || up == "NOR" || up == "XOR" ||
                up == "XNOR") {
                if (inputExprs.empty()) {
                    throw SyntaxError{line, up + "() requires at least one argument"};
                }
                const std::vector<ExprPtr> use = (up == "XNOR" || enArg != nullptr)
                                                     ? operandExprs
                                                     : inputExprs;
                if (up == "AND") {
                    return impl->makeExpr(line, [en, use](EvalContext& ctx) -> double {
                        if (en && !isTruthy(en->eval(ctx))) return 0.0;
                        for (const ExprPtr& operand : use) {
                            if (!isTruthy(operand->eval(ctx))) return 0.0;
                        }
                        return 1.0;
                    });
                }
                if (up == "NAND") {
                    return impl->makeExpr(line, [en, use](EvalContext& ctx) -> double {
                        if (en && !isTruthy(en->eval(ctx))) return 0.0;
                        for (const ExprPtr& operand : use) {
                            if (!isTruthy(operand->eval(ctx))) return 1.0;
                        }
                        return 0.0;
                    });
                }
                if (up == "OR") {
                    return impl->makeExpr(line, [en, use](EvalContext& ctx) -> double {
                        if (en && !isTruthy(en->eval(ctx))) return 0.0;
                        for (const ExprPtr& operand : use) {
                            if (isTruthy(operand->eval(ctx))) return 1.0;
                        }
                        return 0.0;
                    });
                }
                if (up == "NOR") {
                    return impl->makeExpr(line, [en, use](EvalContext& ctx) -> double {
                        if (en && !isTruthy(en->eval(ctx))) return 0.0;
                        for (const ExprPtr& operand : use) {
                            if (isTruthy(operand->eval(ctx))) return 0.0;
                        }
                        return 1.0;
                    });
                }
                if (up == "XOR") {
                    return impl->makeExpr(line, [en, use](EvalContext& ctx) -> double {
                        if (en && !isTruthy(en->eval(ctx))) return 0.0;
                        bool result = false;
                        for (const ExprPtr& operand : use) {
                            result = (result != isTruthy(operand->eval(ctx)));
                        }
                        return result ? 1.0 : 0.0;
                    });
                }
                return impl->makeExpr(line, [use](EvalContext& ctx) -> double {
                    bool result = false;
                    for (const ExprPtr& operand : use) {
                        result = (result != isTruthy(operand->eval(ctx)));
                    }
                    return result ? 0.0 : 1.0;
                });
            }

            if (up == "NOT") {
                requireArgs(up, operandExprs, 1, line);
                ExprPtr operand = operandExprs[0];
                return impl->makeExpr(line, [en, operand](EvalContext& ctx) -> double {
                    if (en && !isTruthy(en->eval(ctx))) return 0.0;
                    return isTruthy(operand->eval(ctx)) ? 0.0 : 1.0;
                });
            }

            if (up == "ADD") {
                if (inputExprs.empty()) {
                    throw SyntaxError{line, "ADD() requires arguments"};
                }
                return impl->makeExpr(line, [inputExprs](EvalContext& ctx) -> double {
                    double sum = 0.0;
                    for (const ExprPtr& operand : inputExprs) sum += operand->eval(ctx);
                    return sum;
                });
            }
            if (up == "SUB") {
                requireArgs(up, inputExprs, 2, line);
                ExprPtr a = inputExprs[0];
                ExprPtr b = inputExprs[1];
                return impl->makeExpr(line, [a, b](EvalContext& ctx) -> double {
                    const double leftValue = a->eval(ctx);
                    const double rightValue = b->eval(ctx);
                    return leftValue - rightValue;
                });
            }
            if (up == "MUL") {
                if (inputExprs.empty()) {
                    throw SyntaxError{line, "MUL() requires arguments"};
                }
                return impl->makeExpr(line, [inputExprs](EvalContext& ctx) -> double {
                    double product = 1.0;
                    for (const ExprPtr& operand : inputExprs) product *= operand->eval(ctx);
                    return product;
                });
            }
            if (up == "DIV") {
                requireArgs(up, inputExprs, 2, line);
                ExprPtr a = inputExprs[0];
                ExprPtr b = inputExprs[1];
                return impl->makeExpr(line, [a, b](EvalContext& ctx) -> double {
                    const double divisor = b->eval(ctx);
                    if (std::fabs(divisor) < 1e-12) return 0.0;
                    return a->eval(ctx) / divisor;
                });
            }
            if (up == "MOD") {
                requireArgs(up, inputExprs, 2, line);
                ExprPtr a = inputExprs[0];
                ExprPtr b = inputExprs[1];
                return impl->makeExpr(line, [a, b](EvalContext& ctx) -> double {
                    const long long divisor = javaRoundLong(b->eval(ctx));
                    if (divisor == 0) return 0.0;
                    return static_cast<double>(javaRoundLong(a->eval(ctx)) % divisor);
                });
            }

            if (up == "EQ" || up == "NE" || up == "LT" || up == "LE" || up == "GT" ||
                up == "GE") {
                requireArgs(up, inputExprs, 2, line);
                ExprPtr a = inputExprs[0];
                ExprPtr b = inputExprs[1];
                return impl->makeExpr(line, [up, a, b](EvalContext& ctx) -> double {
                    const double leftValue = a->eval(ctx);
                    const double rightValue = b->eval(ctx);
                    if (up == "EQ") return std::fabs(leftValue - rightValue) < 1e-6 ? 1.0 : 0.0;
                    if (up == "NE") return std::fabs(leftValue - rightValue) >= 1e-6 ? 1.0 : 0.0;
                    if (up == "LT") return leftValue < rightValue ? 1.0 : 0.0;
                    if (up == "LE") return leftValue <= rightValue ? 1.0 : 0.0;
                    if (up == "GT") return leftValue > rightValue ? 1.0 : 0.0;
                    return leftValue >= rightValue ? 1.0 : 0.0;
                });
            }

            auto unaryFn = [&](std::function<double(double)> fn) -> ExprPtr {
                requireArgs(up, inputExprs, 1, line);
                ExprPtr operand = inputExprs[0];
                return impl->makeExpr(
                    line, [fn = std::move(fn), operand](EvalContext& ctx) -> double {
                        return fn(operand->eval(ctx));
                    });
            };
            auto binaryFn = [&](std::function<double(double, double)> fn) -> ExprPtr {
                requireArgs(up, inputExprs, 2, line);
                ExprPtr a = inputExprs[0];
                ExprPtr b = inputExprs[1];
                return impl->makeExpr(
                    line, [fn = std::move(fn), a, b](EvalContext& ctx) -> double {
                        const double leftValue = a->eval(ctx);
                        const double rightValue = b->eval(ctx);
                        return fn(leftValue, rightValue);
                    });
            };

            if (up == "ABS") return unaryFn([](double v) { return std::fabs(v); });
            if (up == "SQRT") {
                return unaryFn([](double v) { return std::sqrt(std::max(0.0, v)); });
            }
            if (up == "LN") {
                return unaryFn([](double v) { return std::log(std::max(1e-12, v)); });
            }
            if (up == "LOG") {
                return unaryFn([](double v) { return std::log10(std::max(1e-12, v)); });
            }
            if (up == "EXP") return unaryFn([](double v) { return std::exp(v); });
            if (up == "SIN") return unaryFn([](double v) { return std::sin(v); });
            if (up == "COS") return unaryFn([](double v) { return std::cos(v); });
            if (up == "TAN") return unaryFn([](double v) { return std::tan(v); });
            if (up == "ASIN") {
                return unaryFn([](double v) { return std::asin(std::max(-1.0, std::min(1.0, v))); });
            }
            if (up == "ACOS") {
                return unaryFn([](double v) { return std::acos(std::max(-1.0, std::min(1.0, v))); });
            }
            if (up == "ATAN") return unaryFn([](double v) { return std::atan(v); });
            if (up == "TRUNC" || up == "FLOAT_TO_INT" || up == "REAL_TO_INT" ||
                up == "DINT_TO_INT") {
                return unaryFn(
                    [](double v) { return static_cast<double>(javaDoubleToLong(v)); });
            }
            if (up == "ROUND") {
                return unaryFn([](double v) { return static_cast<double>(javaRoundLong(v)); });
            }
            if (up == "INT_TO_FLOAT" || up == "INT_TO_REAL" || up == "BOOL_TO_INT") {
                return unaryFn([](double v) { return v; });
            }
            if (up == "INT_TO_BOOL") {
                return unaryFn([](double v) { return isTruthy(v) ? 1.0 : 0.0; });
            }
            if (up == "MIN") return binaryFn([](double a, double b) { return std::min(a, b); });
            if (up == "MAX") return binaryFn([](double a, double b) { return std::max(a, b); });
            if (up == "LIMIT") {
                requireArgs(up, inputExprs, 3, line);
                ExprPtr valueExpr = inputExprs[1];
                ExprPtr lowExpr = inputExprs[0];
                ExprPtr highExpr = inputExprs[2];
                return impl->makeExpr(line, [valueExpr, lowExpr,
                                             highExpr](EvalContext& ctx) -> double {
                    const double value = valueExpr->eval(ctx);
                    const double low = lowExpr->eval(ctx);
                    const double high = highExpr->eval(ctx);
                    return clampOrFault(value, low, high);
                });
            }
            if (up == "CLAMP") {
                requireArgs(up, inputExprs, 3, line);
                ExprPtr valueExpr = inputExprs[0];
                ExprPtr lowExpr = inputExprs[1];
                ExprPtr highExpr = inputExprs[2];
                return impl->makeExpr(line, [valueExpr, lowExpr,
                                             highExpr](EvalContext& ctx) -> double {
                    const double value = valueExpr->eval(ctx);
                    const double low = lowExpr->eval(ctx);
                    const double high = highExpr->eval(ctx);
                    return clampOrFault(value, low, high);
                });
            }
            if (up == "SEL") {
                requireArgs(up, inputExprs, 3, line);
                ExprPtr cond = inputExprs[0];
                ExprPtr whenFalse = inputExprs[1];
                ExprPtr whenTrue = inputExprs[2];
                return impl->makeExpr(
                    line, [cond, whenFalse, whenTrue](EvalContext& ctx) -> double {
                        if (isTruthy(cond->eval(ctx))) return whenTrue->eval(ctx);
                        return whenFalse->eval(ctx);
                    });
            }
            if (up == "MUX") {
                if (inputExprs.size() < 2) {
                    throw SyntaxError{line, "MUX() requires at least 2 arguments"};
                }
                return impl->makeExpr(line, [inputExprs](EvalContext& ctx) -> double {
                    const int selected =
                        javaDoubleToInt(javaRound(inputExprs[0]->eval(ctx)));
                    const size_t target = static_cast<size_t>(selected + 1);
                    if (selected >= 0 && target < inputExprs.size()) {
                        return inputExprs[target]->eval(ctx);
                    }
                    return 0.0;
                });
            }

            if (up == "RANDOM" || up == "RND") {
                ExprPtr trigArg;
                ExprPtr minArg;
                ExprPtr maxArg;
                std::vector<ExprPtr> positional;
                for (const CallArg& arg : rawArgs) {
                    if (arg.isOutput || !arg.expr) continue;
                    if (!arg.paramName.empty()) {
                        const std::string pUp = upperAscii(arg.paramName);
                        if (pUp == "EN") continue;
                        if (pUp == "TRIG" || pUp == "CLK") trigArg = arg.expr;
                        else if (pUp == "MIN" || pUp == "LO") minArg = arg.expr;
                        else if (pUp == "MAX" || pUp == "HI") maxArg = arg.expr;
                        else {
                            throw SyntaxError{line, "Unknown parameter '" + arg.paramName +
                                                        "' for function " + fnName};
                        }
                    } else {
                        positional.push_back(arg.expr);
                    }
                }
                if (!positional.empty()) {
                    if (positional.size() == 1) {
                        if (!maxArg) maxArg = positional[0];
                        else if (!minArg) minArg = positional[0];
                    } else if (positional.size() == 2) {
                        if (!minArg) minArg = positional[0];
                        if (!maxArg) maxArg = positional[1];
                    } else if (positional.size() == 3) {
                        if (!trigArg) trigArg = positional[0];
                        if (!minArg) minArg = positional[1];
                        if (!maxArg) maxArg = positional[2];
                    } else {
                        throw SyntaxError{line,
                                          fnName +
                                              "() accepts at most 3 positional arguments ([Trig, "
                                              "]Min, Max)"};
                    }
                }
                const bool explicitBounds = (minArg != nullptr || maxArg != nullptr);
                const int stateId = impl->nextBuiltinId++;
                const std::string base = "__rnd_" + std::to_string(stateId);
                return impl->makeExpr(
                    line,
                    [en, trigArg, minArg, maxArg, explicitBounds,
                     base](EvalContext& ctx) -> double {
                        if (en && !isTruthy(en->eval(ctx))) return 0.0;
                        const double low = minArg ? minArg->eval(ctx) : 0.0;
                        const double high =
                            maxArg ? maxArg->eval(ctx) : (explicitBounds ? 100.0 : 1.0);
                        const double minVal = std::min(low, high);
                        const double maxVal = std::max(low, high);
                        if (trigArg) {
                            const bool trig = isTruthy(trigArg->eval(ctx));
                            const bool previous =
                                isTruthy(Impl::stateOf(ctx.impl->builtinState, base + "_prev", 0.0));
                            const bool sampled =
                                isTruthy(Impl::stateOf(ctx.impl->builtinState, base + "_init", 0.0));
                            double current =
                                Impl::stateOf(ctx.impl->builtinState, base + "_val", minVal);
                            const bool shouldSample = (trig && !previous) || !sampled;
                            if (shouldSample) {
                                current = ctx.impl->sampleRandom(minVal, maxVal, explicitBounds);
                                ctx.impl->builtinState[base + "_val"] = current;
                                ctx.impl->builtinState[base + "_init"] = 1.0;
                            }
                            ctx.impl->builtinState[base + "_prev"] = trig ? 1.0 : 0.0;
                            return current;
                        }
                        return ctx.impl->sampleRandom(minVal, maxVal, explicitBounds);
                    });
            }

            if (up == "SINGLEPULSE" || up == "ONESHOT") {
                ExprPtr inExpr;
                for (const CallArg& arg : rawArgs) {
                    if (arg.isOutput || !arg.expr) continue;
                    if (arg.paramName.empty() || equalsIgnoreCase(arg.paramName, "IN") ||
                        equalsIgnoreCase(arg.paramName, "CLK")) {
                        inExpr = arg.expr;
                    }
                }
                if (!inExpr && !inputExprs.empty()) inExpr = inputExprs.front();
                if (!inExpr) {
                    throw SyntaxError{line, fnName + "() requires an input argument"};
                }
                const int stateId = impl->nextBuiltinId++;
                const std::string base = "__pulse_" + std::to_string(stateId);
                return impl->makeExpr(line, [en, inExpr, base](EvalContext& ctx) -> double {
                    if (en && !isTruthy(en->eval(ctx))) {
                        ctx.impl->builtinState[base + "_prev"] = 0.0;
                        return 0.0;
                    }
                    const bool input = isTruthy(inExpr->eval(ctx));
                    const bool previous =
                        isTruthy(Impl::stateOf(ctx.impl->builtinState, base + "_prev", 0.0));
                    ctx.impl->builtinState[base + "_prev"] = input ? 1.0 : 0.0;
                    return (input && !previous) ? 1.0 : 0.0;
                });
            }

            throw SyntaxError{line, "Unknown ST function '" + fnName + "'"};
        }
    };

    std::vector<DeclVar> declarations;
    std::map<std::string, int> declIndex;
    std::vector<Stmt> statements;
    std::map<std::string, double> fbState;
    std::map<std::string, double> builtinState;
    std::map<std::string, double> instancePins;
    std::mt19937 rng;
    int nextBuiltinId = 0;

    Impl();

    ExprPtr makeExpr(int line, std::function<double(EvalContext&)> fn) {
        auto expr = std::make_shared<Expr>();
        expr->line = line;
        expr->eval = std::move(fn);
        return expr;
    }

    static void execBody(const std::vector<Stmt>& body, EvalContext& ctx) {
        for (const Stmt& statement : body) {
            statement(ctx);
            if (ctx.exitFlag || ctx.returnFlag) return;
        }
    }

    int findDecl(const std::string& name) const {
        const auto it = declIndex.find(lowerAscii(name));
        return it == declIndex.end() ? -1 : it->second;
    }

    void addDecl(const std::string& name, int scope, int type, double initial) {
        const int idx = findDecl(name);
        const int normalizedType = sanitizeType(type);
        const double normalizedInitial = convertValue(initial, normalizedType);
        if (idx >= 0) {
            declarations[idx].name = name;
            declarations[idx].scope = scope;
            declarations[idx].type = normalizedType;
            declarations[idx].initial = normalizedInitial;
            return;
        }
        declIndex[lowerAscii(name)] = static_cast<int>(declarations.size());
        declarations.push_back(DeclVar{name, scope, normalizedType, normalizedInitial});
    }

    void updateDecl(const std::string& name, int type, double initial) {
        const int idx = findDecl(name);
        if (idx < 0) return;
        const int normalizedType = sanitizeType(type);
        declarations[idx].name = name;
        declarations[idx].type = normalizedType;
        declarations[idx].initial = convertValue(initial, normalizedType);
    }

    void resetRuntime() {
        fbState.clear();
        builtinState.clear();
        instancePins.clear();
    }

    bool compile(const std::string& code, const std::vector<StVariable>& variables,
                 std::string& error, int& errorLine);

    void execute(const std::function<double(const std::string&)>& read,
                 const std::function<void(const std::string&, double)>& write,
                 std::map<std::string, double>& variables);

    void execCall(EvalContext& ctx, const std::string& targetName,
                  const std::vector<CallArg>& args);

    std::map<std::string, double> runFunctionBlock(
        const std::string& fbType, const std::string& instName,
        const std::map<std::string, double>& inVals, EvalContext& ctx);

    double sampleRandom(double minVal, double maxVal, bool explicitBounds);

    static double stateOf(const std::map<std::string, double>& state, const std::string& key,
                          double fallback) {
        const auto it = state.find(key);
        return it == state.end() ? fallback : it->second;
    }

    void splitDeclarations(const std::vector<Token>& tokens, std::vector<Token>& body);

    void parseDeclBlock(const std::vector<Token>& tokens, size_t begin, size_t end, int scope);
};

// -----------------------------------------------------------------------------
// EvalContext
// -----------------------------------------------------------------------------

double StInterpreter::Impl::EvalContext::read(const std::string& name) {
    auto it = vars->find(name);
    if (it == vars->end()) {
        for (auto i = vars->begin(); i != vars->end(); ++i) {
            if (equalsIgnoreCase(i->first, name)) {
                it = i;
                break;
            }
        }
    }
    if (it != vars->end()) return it->second;

    const int decl = impl->findDecl(name);
    if (decl >= 0) return impl->declarations[decl].initial;

    const auto pin = impl->instancePins.find(lowerAscii(name));
    if (pin != impl->instancePins.end()) return pin->second;

    if (readCb != nullptr && static_cast<bool>(*readCb)) {
        return (*readCb)(name);
    }
    return 0.0;
}

void StInterpreter::Impl::EvalContext::write(const std::string& name, double value) {
    auto it = vars->find(name);
    if (it == vars->end()) {
        for (auto i = vars->begin(); i != vars->end(); ++i) {
            if (equalsIgnoreCase(i->first, name)) {
                it = i;
                break;
            }
        }
    }
    if (it != vars->end()) {
        it->second = value;
        return;
    }

    const std::string lowered = lowerAscii(name);
    if (lowered.find('.') != std::string::npos) {
        const auto pin = impl->instancePins.find(lowered);
        if (pin != impl->instancePins.end()) {
            pin->second = value;
            return;
        }
    }

    const int decl = impl->findDecl(name);
    if (decl >= 0) {
        (*vars)[impl->declarations[decl].name] = value;
        return;
    }

    if (writeCb != nullptr && static_cast<bool>(*writeCb)) {
        (*writeCb)(name, value);
        return;
    }
    (*vars)[name] = value;
}

// -----------------------------------------------------------------------------
// Impl lifecycle / compile
// -----------------------------------------------------------------------------

StInterpreter::Impl::Impl() {
    std::random_device device;
    rng.seed(device());
}

bool StInterpreter::Impl::compile(const std::string& code,
                                  const std::vector<StVariable>& variables,
                                  std::string& error, int& errorLine) {
    error.clear();
    errorLine = 0;
    declarations.clear();
    declIndex.clear();
    statements.clear();
    nextBuiltinId = 0;
    resetRuntime();

    try {
        std::vector<Token> tokens = tokenize(code);
        std::vector<Token> body;
        splitDeclarations(tokens, body);

        for (const StVariable& variable : variables) {
            const int type = sanitizeType(variable.type);
            const int idx = findDecl(variable.name);
            if (idx >= 0) {
                updateDecl(variable.name, type, variable.initial);
            } else {
                addDecl(variable.name, kScopeVar, type, variable.initial);
            }
        }

        Parser parser(this, std::move(body));
        statements = parser.parseStatementList({TokType::Eof});
        return true;
    } catch (const SyntaxError& ex) {
        error = ex.message;
        errorLine = ex.line;
        declarations.clear();
        declIndex.clear();
        statements.clear();
        nextBuiltinId = 0;
        resetRuntime();
        return false;
    }
}

// -----------------------------------------------------------------------------
// Declarations
// -----------------------------------------------------------------------------

void StInterpreter::Impl::splitDeclarations(const std::vector<Token>& tokens,
                                            std::vector<Token>& body) {
    size_t i = 0;
    while (i < tokens.size()) {
        const Token& token = tokens[i];
        if (token.type == TokType::Eof) {
            body.push_back(token);
            break;
        }
        if (token.type == TokType::Ident) {
            const std::string upper = upperAscii(token.text);
            if (upper == "VAR" || upper == "VAR_INPUT" || upper == "VAR_OUTPUT" ||
                upper == "VAR_TEMP") {
                size_t end = tokens.size();
                bool found = false;
                for (size_t j = i + 1; j < tokens.size(); ++j) {
                    if (tokens[j].type == TokType::Eof) break;
                    if (tokens[j].type == TokType::Ident &&
                        upperAscii(tokens[j].text) == "END_VAR") {
                        end = j;
                        found = true;
                        break;
                    }
                }
                if (found) {
                    int scope = kScopeVar;
                    if (upper == "VAR_INPUT") scope = kScopeInput;
                    else if (upper == "VAR_OUTPUT") scope = kScopeOutput;
                    else if (upper == "VAR_TEMP") scope = kScopeTemp;
                    parseDeclBlock(tokens, i + 1, end, scope);
                    i = end + 1;
                    continue;
                }
            }
        }
        body.push_back(token);
        ++i;
    }
}

void StInterpreter::Impl::parseDeclBlock(const std::vector<Token>& tokens, size_t begin,
                                         size_t end, int scope) {
    size_t j = begin;
    while (j < end && tokens[j].type == TokType::Ident &&
           (upperAscii(tokens[j].text) == "CONSTANT" ||
            upperAscii(tokens[j].text) == "RETAIN")) {
        ++j;
    }

    while (j < end) {
        while (j < end && tokens[j].type == TokType::Semi) ++j;
        if (j >= end) break;

        std::vector<std::string> names;
        bool ok = true;
        while (true) {
            if (j >= end || tokens[j].type != TokType::Ident) {
                ok = false;
                break;
            }
            names.push_back(tokens[j].text);
            ++j;
            if (j < end && tokens[j].type == TokType::Comma) {
                ++j;
                continue;
            }
            break;
        }
        if (!ok || j >= end || tokens[j].type != TokType::Colon) {
            while (j < end && tokens[j].type != TokType::Semi) ++j;
            if (j < end) ++j;
            continue;
        }
        ++j; // ':'

        int type = 1;
        if (j < end && tokens[j].type == TokType::Ident) {
            const std::string typeName = upperAscii(tokens[j].text);
            if (typeName == "BOOL") type = 0;
            else if (typeName == "LONG" || typeName == "LINT" || typeName == "DINT") type = 2;
            else if (typeName == "FLOAT" || typeName == "REAL" || typeName == "LREAL") type = 3;
            else type = 1;
            ++j;
        }

        double initial = 0.0;
        if (j < end && tokens[j].type == TokType::Assign) {
            ++j;
            bool negative = false;
            if (j < end && (tokens[j].type == TokType::Minus ||
                            tokens[j].type == TokType::Plus)) {
                negative = (tokens[j].type == TokType::Minus);
                ++j;
            }
            bool simpleConstant = false;
            double constant = 0.0;
            if (j < end && tokens[j].type == TokType::Number) {
                constant = tokens[j].numVal;
                if (negative) constant = -constant;
                simpleConstant = true;
                ++j;
            } else if (j < end && tokens[j].type == TokType::Ident) {
                const std::string valueName = upperAscii(tokens[j].text);
                if (valueName == "TRUE") {
                    constant = 1.0;
                    simpleConstant = true;
                } else if (valueName == "FALSE") {
                    constant = 0.0;
                    simpleConstant = true;
                }
                ++j;
            }
            // Maraflow treats the initial value as free text and data-type
            // parsing failure yields 0.0; only a single literal is accepted here.
            if (simpleConstant && (j >= end || tokens[j].type == TokType::Semi)) {
                initial = constant;
            }
            while (j < end && tokens[j].type != TokType::Semi) ++j;
        }
        if (j < end && tokens[j].type == TokType::Semi) ++j;

        for (const std::string& name : names) {
            addDecl(name, scope, type, initial);
        }
    }
}

// -----------------------------------------------------------------------------
// execute
// -----------------------------------------------------------------------------

void StInterpreter::Impl::execute(
    const std::function<double(const std::string&)>& read,
    const std::function<void(const std::string&, double)>& write,
    std::map<std::string, double>& variables) {
    instancePins.clear();

    EvalContext ctx;
    ctx.impl = this;
    ctx.vars = &variables;
    ctx.readCb = &read;
    ctx.writeCb = &write;

    for (const DeclVar& decl : declarations) {
        if (decl.scope == kScopeInput) {
            if (read) {
                variables[decl.name] = read(decl.name);
            } else {
                auto it = variables.find(decl.name);
                if (it == variables.end()) {
                    for (auto i = variables.begin(); i != variables.end(); ++i) {
                        if (equalsIgnoreCase(i->first, decl.name)) {
                            it = i;
                            break;
                        }
                    }
                }
                if (it == variables.end()) variables[decl.name] = decl.initial;
            }
        } else if (decl.scope == kScopeTemp) {
            variables[decl.name] = decl.initial;
        } else {
            auto it = variables.find(decl.name);
            if (it == variables.end()) {
                for (auto i = variables.begin(); i != variables.end(); ++i) {
                    if (equalsIgnoreCase(i->first, decl.name)) {
                        it = i;
                        break;
                    }
                }
            }
            if (it == variables.end()) variables[decl.name] = decl.initial;
        }
    }

    try {
        for (const Stmt& statement : statements) {
            statement(ctx);
            if (ctx.returnFlag || ctx.exitFlag) break;
        }
    } catch (const RuntimeFault&) {
        // Runtime faults are suppressed to keep the scan deterministic, as in
        // the Java interpreter.
    } catch (...) {
        // Same policy for any other evaluator fault.
    }

    for (const DeclVar& decl : declarations) {
        auto it = variables.find(decl.name);
        if (it == variables.end()) {
            for (auto i = variables.begin(); i != variables.end(); ++i) {
                if (equalsIgnoreCase(i->first, decl.name)) {
                    it = i;
                    break;
                }
            }
        }
        if (it == variables.end()) {
            variables[decl.name] = convertValue(decl.initial, decl.type);
        } else {
            it->second = convertValue(it->second, decl.type);
        }
    }

    if (write) {
        for (const DeclVar& decl : declarations) {
            if (decl.scope != kScopeOutput) continue;
            auto it = variables.find(decl.name);
            if (it == variables.end()) {
                for (auto i = variables.begin(); i != variables.end(); ++i) {
                    if (equalsIgnoreCase(i->first, decl.name)) {
                        it = i;
                        break;
                    }
                }
            }
            write(decl.name, it == variables.end() ? decl.initial : it->second);
        }
    }
}

// -----------------------------------------------------------------------------
// Function-block calls
// -----------------------------------------------------------------------------

namespace {

std::vector<std::string> positionalParamsFor(const std::string& fbType) {
    if (fbType == "SR" || fbType == "RS") return {"S", "R"};
    if (fbType == "TON" || fbType == "TOF" || fbType == "TP" || fbType == "TIMER") {
        return {"IN", "PT"};
    }
    if (fbType == "CTU") return {"CU", "RESET", "PV"};
    if (fbType == "CTD") return {"CD", "LOAD", "PV"};
    if (fbType == "CTUD" || fbType == "COUNTER" || fbType == "CNTR") {
        return {"CU", "CD", "RESET", "LOAD", "PV"};
    }
    if (fbType == "R_TRIG" || fbType == "F_TRIG" || fbType == "SINGLEPULSE" ||
        fbType == "ONESHOT") {
        return {"CLK"};
    }
    if (fbType == "RANDOM" || fbType == "RND") return {"TRIG", "MIN", "MAX"};
    return {};
}

bool endsWith(const std::string& text, const std::string& suffix) {
    return text.size() >= suffix.size() &&
           text.compare(text.size() - suffix.size(), suffix.size(), suffix) == 0;
}

} // namespace

void StInterpreter::Impl::execCall(EvalContext& ctx, const std::string& targetName,
                                   const std::vector<CallArg>& args) {
    std::map<std::string, double> inVals;
    std::vector<const CallArg*> outArgs;

    std::string fbType = upperAscii(targetName);
    const size_t dot = fbType.rfind('.');
    if (dot != std::string::npos) fbType = fbType.substr(dot + 1);
    if (fbType.rfind("INST_", 0) == 0) {
        fbType = fbType.substr(5);
    } else {
        static const char* const known[] = {
            "SR", "RS", "TON", "TOF", "TP", "CTU", "CTD", "CTUD",
            "R_TRIG", "F_TRIG", "RANDOM", "RND", "SINGLEPULSE", "ONESHOT",
            "COUNTER", "CNTR"};
        for (const char* candidate : known) {
            const std::string name(candidate);
            if (fbType == name || endsWith(fbType, "_" + name)) {
                fbType = name;
                break;
            }
        }
    }

    const std::vector<std::string> positionalParams = positionalParamsFor(fbType);
    size_t positionalIndex = 0;

    for (const CallArg& arg : args) {
        if (arg.isOutput) {
            outArgs.push_back(&arg);
        } else if (arg.expr) {
            const double value = arg.expr->eval(ctx);
            std::string paramName = arg.paramName;
            if (paramName.empty() && positionalIndex < positionalParams.size()) {
                paramName = positionalParams[positionalIndex++];
            }
            if (!paramName.empty()) {
                const std::string upperName = upperAscii(paramName);
                inVals[upperName] = value;
                instancePins[lowerAscii(targetName) + "." + lowerAscii(paramName)] = value;
            }
        }
    }

    const std::map<std::string, double> outVals = runFunctionBlock(fbType, targetName, inVals, ctx);
    for (const auto& entry : outVals) {
        instancePins[lowerAscii(targetName) + "." + lowerAscii(entry.first)] = entry.second;
    }
    for (const CallArg* outArg : outArgs) {
        if (!outArg->outputVarName.empty() && !outArg->paramName.empty()) {
            const auto it = outVals.find(upperAscii(outArg->paramName));
            if (it != outVals.end()) {
                ctx.write(outArg->outputVarName, it->second);
            }
        }
    }
}

std::map<std::string, double> StInterpreter::Impl::runFunctionBlock(
    const std::string& fbType, const std::string& instName,
    const std::map<std::string, double>& inVals, EvalContext& ctx) {
    (void)ctx;
    std::map<std::string, double> out;

    const auto getIn = [&inVals](const std::string& name, double fallback) -> double {
        const auto it = inVals.find(name);
        return it == inVals.end() ? fallback : it->second;
    };
    const std::string base = lowerAscii(instName);

    const bool en = getIn("EN", 1.0) != 0.0;
    if (!en) return out;

    if (fbType == "SR") {
        const bool s = getIn("S", 0.0) != 0.0;
        const bool r = getIn("R", 0.0) != 0.0;
        bool q = stateOf(fbState, base + "._q", 0.0) != 0.0;
        if (s) q = true;
        else if (r) q = false;
        fbState[base + "._q"] = q ? 1.0 : 0.0;
        out["Q"] = q ? 1.0 : 0.0;
        out["NQ"] = q ? 0.0 : 1.0;
        return out;
    }
    if (fbType == "RS") {
        const bool s = getIn("S", 0.0) != 0.0;
        const bool r = getIn("R", 0.0) != 0.0;
        bool q = stateOf(fbState, base + "._q", 0.0) != 0.0;
        if (r) q = false;
        else if (s) q = true;
        fbState[base + "._q"] = q ? 1.0 : 0.0;
        out["Q"] = q ? 1.0 : 0.0;
        out["NQ"] = q ? 0.0 : 1.0;
        return out;
    }
    if (fbType == "R_TRIG" || fbType == "SINGLEPULSE" || fbType == "ONESHOT") {
        const bool clk = getIn("CLK", getIn("IN", 0.0)) != 0.0;
        const bool previous = stateOf(fbState, base + "._prevClk", 0.0) != 0.0;
        const bool q = clk && !previous;
        fbState[base + "._prevClk"] = clk ? 1.0 : 0.0;
        out["Q"] = q ? 1.0 : 0.0;
        return out;
    }
    if (fbType == "F_TRIG") {
        const bool clk = getIn("CLK", getIn("IN", 0.0)) != 0.0;
        const bool previous = stateOf(fbState, base + "._prevClk", 0.0) != 0.0;
        const bool q = !clk && previous;
        fbState[base + "._prevClk"] = clk ? 1.0 : 0.0;
        out["Q"] = q ? 1.0 : 0.0;
        return out;
    }
    if (fbType == "TON" || fbType == "TIMER") {
        const bool input = getIn("IN", 0.0) != 0.0;
        const double pt = getIn("PT", 0.0);
        double et = stateOf(fbState, base + "._et", 0.0);
        if (input) et = std::min(pt, et + 10.0);
        else et = 0.0;
        fbState[base + "._et"] = et;
        out["Q"] = (input && et >= pt) ? 1.0 : 0.0;
        out["ET"] = et;
        return out;
    }
    if (fbType == "TOF") {
        const bool input = getIn("IN", 0.0) != 0.0;
        const double pt = getIn("PT", 0.0);
        double et = stateOf(fbState, base + "._et", 0.0);
        if (input) et = 0.0;
        else if (et < pt) et = std::min(pt, et + 10.0);
        fbState[base + "._et"] = et;
        out["Q"] = (input || et < pt) ? 1.0 : 0.0;
        out["ET"] = et;
        return out;
    }
    if (fbType == "TP") {
        const bool input = getIn("IN", 0.0) != 0.0;
        const double pt = getIn("PT", 0.0);
        const bool previousIn = stateOf(fbState, base + "._prevIn", 0.0) != 0.0;
        double et = stateOf(fbState, base + "._et", 0.0);
        bool active = stateOf(fbState, base + "._active", 0.0) != 0.0;
        if (!active && input && !previousIn) {
            active = true;
            et = 0.0;
        }
        if (active) {
            et += 10.0;
            if (et >= pt) {
                active = false;
                et = pt;
            }
        }
        fbState[base + "._prevIn"] = input ? 1.0 : 0.0;
        fbState[base + "._active"] = active ? 1.0 : 0.0;
        fbState[base + "._et"] = et;
        out["Q"] = active ? 1.0 : 0.0;
        out["ET"] = et;
        return out;
    }
    if (fbType == "CTU") {
        const bool cu = getIn("CU", 0.0) != 0.0;
        const bool reset = getIn("RESET", getIn("R", 0.0)) != 0.0;
        const double pv = getIn("PV", 0.0);
        double cv = stateOf(fbState, base + "._cv", 0.0);
        const bool previousCu = stateOf(fbState, base + "._prevCu", 0.0) != 0.0;
        if (reset) cv = 0.0;
        else if (cu && !previousCu && cv < pv) cv += 1.0;
        fbState[base + "._prevCu"] = cu ? 1.0 : 0.0;
        fbState[base + "._cv"] = cv;
        out["Q"] = cv >= pv ? 1.0 : 0.0;
        out["CV"] = cv;
        return out;
    }
    if (fbType == "CTD") {
        const bool cd = getIn("CD", 0.0) != 0.0;
        const bool load = getIn("LOAD", getIn("LD", 0.0)) != 0.0;
        const double pv = getIn("PV", 0.0);
        double cv = stateOf(fbState, base + "._cv", pv);
        const bool previousCd = stateOf(fbState, base + "._prevCd", 0.0) != 0.0;
        if (load) cv = pv;
        else if (cd && !previousCd && cv > 0.0) cv -= 1.0;
        fbState[base + "._prevCd"] = cd ? 1.0 : 0.0;
        fbState[base + "._cv"] = cv;
        out["Q"] = cv <= 0.0 ? 1.0 : 0.0;
        out["CV"] = cv;
        return out;
    }
    if (fbType == "CTUD" || fbType == "COUNTER" || fbType == "CNTR") {
        const bool cu = getIn("CU", 0.0) != 0.0;
        const bool cd = getIn("CD", 0.0) != 0.0;
        const bool reset = getIn("RESET", getIn("R", 0.0)) != 0.0;
        const bool load = getIn("LOAD", getIn("LD", 0.0)) != 0.0;
        const double pv = getIn("PV", 10.0);
        double cv = stateOf(fbState, base + "._cv", 0.0);
        const bool previousCu = stateOf(fbState, base + "._prevCu", 0.0) != 0.0;
        const bool previousCd = stateOf(fbState, base + "._prevCd", 0.0) != 0.0;
        if (reset) {
            cv = 0.0;
        } else if (load) {
            cv = pv;
        } else {
            if (cu && !previousCu) cv += 1.0;
            if (cd && !previousCd && cv > 0.0) cv -= 1.0;
        }
        fbState[base + "._prevCu"] = cu ? 1.0 : 0.0;
        fbState[base + "._prevCd"] = cd ? 1.0 : 0.0;
        fbState[base + "._cv"] = cv;
        out["Q"] = cv >= pv ? 1.0 : 0.0;
        out["QU"] = cv >= pv ? 1.0 : 0.0;
        out["QD"] = cv <= 0.0 ? 1.0 : 0.0;
        out["CV"] = cv;
        return out;
    }
    if (fbType == "RANDOM" || fbType == "RND") {
        const double minValue = getIn("MIN", 0.0);
        const double maxValue = getIn("MAX", 100.0);
        const double low = std::min(minValue, maxValue);
        const double high = std::max(minValue, maxValue);
        const bool trig = getIn("TRIG", 1.0) != 0.0;
        const bool previousTrig = stateOf(fbState, base + "._prevTrig", 0.0) != 0.0;
        const bool sampled = stateOf(fbState, base + "._sampled", 0.0) != 0.0;
        double currentVal = stateOf(fbState, base + "._val", low);
        const bool shouldSample = (trig && !previousTrig) || !sampled;
        if (shouldSample) {
            currentVal = sampleRandom(low, high, true);
            fbState[base + "._val"] = currentVal;
            fbState[base + "._sampled"] = 1.0;
        }
        fbState[base + "._prevTrig"] = trig ? 1.0 : 0.0;
        out["Y"] = currentVal;
        return out;
    }

    return out;
}

double StInterpreter::Impl::sampleRandom(double minVal, double maxVal, bool explicitBounds) {
    std::uniform_real_distribution<double> distribution(0.0, 1.0);
    const double pick = distribution(rng);
    if (!explicitBounds) return pick;
    if (minVal == std::floor(minVal) && maxVal == std::floor(maxVal)) {
        const long long minInt = javaDoubleToLong(minVal);
        const long long maxInt = javaDoubleToLong(maxVal);
        if (maxInt <= minInt) return static_cast<double>(minInt);
        const long long span = maxInt - minInt + 1;
        long long value = minInt + static_cast<long long>(pick * static_cast<double>(span));
        if (value > maxInt) value = maxInt;
        if (value < minInt) value = minInt;
        return static_cast<double>(value);
    }
    return minVal + pick * (maxVal - minVal);
}

// =============================================================================
// Public API
// =============================================================================

StInterpreter::StInterpreter() : impl_(std::make_shared<Impl>()) {}

bool StInterpreter::compile(const std::string& code,
                            const std::vector<StVariable>& variables, std::string& error,
                            int& errorLine) {
    return impl_->compile(code, variables, error, errorLine);
}

void StInterpreter::execute(const ReadOperand& read, const WriteOperand& write,
                            std::map<std::string, double>& variables) {
    impl_->execute(read, write, variables);
}

void StInterpreter::reset() {
    impl_->resetRuntime();
}

} // namespace wirebench
