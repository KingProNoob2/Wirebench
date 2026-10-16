import Foundation

/// Makes the program the PLC runs shorter and quicker to settle, without changing what any module computes.
///
/// The PLC walks the records of a thread in table order once per cycle. A module that sits *before* the module
/// feeding it reads that module's value from the **previous** cycle, so a chain of such modules — a ripple-carry
/// adder written in the wrong order is the usual one — needs one cycle per link before its answer is true, and each
/// cycle of a slow thread is 100 ms or more. Dirigo keeps the order the author gave (`ORDER`), and so does a build
/// without this pass; here the records are put in dataflow order instead, so a value reaches everything that reads it
/// in the cycle it is made.
///
/// Two passes:
///
/// 1. **Dead records.** A pure module — a gate, a conversion — whose outputs lead nowhere that is read is dropped
///    from the table. Anything with an effect or something watching it (a counter, an output, a variable, a
///    display, a block this pass does not know) keeps everything that feeds it.
/// 2. **Order.** Within each thread, records are sorted so that every module comes after the modules that feed it,
///    keeping the original order wherever nothing says otherwise. A loop has no such order, so a loop is left as
///    it was written: its first module in the original order goes first.
///
/// Allocation does not change: the symbol table, the `.csv` and every address are what an unoptimised build
/// produces, so a monitor and a mixed program still agree about where values live.
public enum PLCProgramOptimizer {
    public struct Result: Equatable, Sendable {
        /// The modules to compile, in the order their records are written.
        public var modules: [PLCProjectCompiler.Module]
        /// The modules whose records were dropped.
        public var removed: [String]
        /// Cycles a value needs to cross the longest chain of modules, before and after.
        public var cyclesBefore: Int
        public var cyclesAfter: Int
        /// How many modules changed place.
        public var moved: Int
        public var isChange: Bool { !removed.isEmpty || moved > 0 }
    }

    /// Classes with no effect of their own: their records matter only through what reads their outputs.
    static let pure: Set<String> = [
        "TMAnd", "TMOr", "TMNot", "TMXor", "TMYes", "TMComparator", "TMBits2Int", "TMInt2Bits",
        "TMIntAnd", "TMIntOr", "TMIntXor", "TMIntNot", "TMIntAdd", "TMIntSub", "TMIntMul", "TMIntNeg", "TMIntAbs",
    ]

    /// - Parameters:
    ///   - ordered: `PLCProjectCompiler.recordOrder`'s modules — expansion order, grouped by thread.
    ///   - wires: the project's wires with macro interfaces resolved (`resolvingMacroInterfaces`).
    ///   - allModules: every module of the project, so a reader that is not in the program (a display) still counts
    ///     as someone reading an output.
    ///   - classForGUID: normalised GUID to class name.
    public static func optimize(_ ordered: [PLCProjectCompiler.Module],
                                wires: [PLCProjectCompiler.Wire],
                                allModules: [PLCProjectCompiler.Module],
                                classForGUID: [String: String]) -> Result {
        func cls(_ m: PLCProjectCompiler.Module) -> String? { classForGUID[PLCProjectCompiler.normaliseGUID(m.guid)] }

        // Who reads whom, by module id (ids are unique once macros are instanced).
        var readers: [UInt8: [UInt8]] = [:]
        for wire in wires where wire.outModule != wire.inModule {
            readers[wire.outModule, default: []].append(wire.inModule)
        }
        let byId = Dictionary(allModules.map { ($0.umisteni, $0) }, uniquingKeysWith: { first, _ in first })
        let inProgram = Set(ordered.map(\.umisteni))

        // 1. Backward from everything that is not a pure module in the program: it is kept, and so is what feeds it.
        var live = Set<UInt8>()
        for module in allModules {
            let isPureInProgram = inProgram.contains(module.umisteni) && cls(module).map(pure.contains) == true
            if !isPureInProgram { live.insert(module.umisteni) }
        }
        var changed = true
        while changed {
            changed = false
            for module in ordered where !live.contains(module.umisteni) {
                if (readers[module.umisteni] ?? []).contains(where: { live.contains($0) && byId[$0] != nil }) {
                    live.insert(module.umisteni)
                    changed = true
                }
            }
        }
        let kept = ordered.filter { live.contains($0.umisteni) }
        let removed = ordered.filter { !live.contains($0.umisteni) }.map(\.name)

        // 2. Dataflow order, thread by thread.
        var result: [PLCProjectCompiler.Module] = []
        var start = 0
        while start < kept.count {
            var end = start
            while end < kept.count, kept[end].threadId == kept[start].threadId { end += 1 }
            result += sorted(Array(kept[start..<end]), readers: readers)
            start = end
        }

        let moved = zip(kept, result).filter { $0.umisteni != $1.umisteni }.count
        return Result(modules: result, removed: removed,
                      cyclesBefore: cycles(of: ordered, readers: readers),
                      cyclesAfter: cycles(of: result, readers: readers),
                      moved: moved)
    }

    /// Kahn's algorithm that always takes the earliest-written module that is ready.
    private static func sorted(_ group: [PLCProjectCompiler.Module], readers: [UInt8: [UInt8]]) -> [PLCProjectCompiler.Module] {
        let index = Dictionary(group.enumerated().map { ($1.umisteni, $0) }, uniquingKeysWith: { first, _ in first })
        var feeders = Array(repeating: 0, count: group.count)
        for (i, module) in group.enumerated() {
            for reader in Set(readers[module.umisteni] ?? []) {
                if let j = index[reader], j != i { feeders[j] += 1 }
            }
        }
        var done = Array(repeating: false, count: group.count)
        var out: [PLCProjectCompiler.Module] = []
        while out.count < group.count {
            // The earliest module nothing unwritten feeds; in a loop, the earliest module left.
            let next = (0..<group.count).first { !done[$0] && feeders[$0] == 0 }
                ?? (0..<group.count).first { !done[$0] }!
            done[next] = true
            out.append(group[next])
            for reader in Set(readers[group[next].umisteni] ?? []) {
                if let j = index[reader], j != next, !done[j], feeders[j] > 0 { feeders[j] -= 1 }
            }
        }
        return out
    }

    /// How many cycles the slowest value takes to cross the program: a link costs one cycle when the module that
    /// reads comes before the module that makes (in the same thread), nothing otherwise. A loop counts once.
    static func cycles(of modules: [PLCProjectCompiler.Module], readers: [UInt8: [UInt8]]) -> Int {
        var position: [UInt8: (thread: Int, place: Int)] = [:]
        for (place, module) in modules.enumerated() { position[module.umisteni] = (module.threadId, place) }
        var feeders: [UInt8: [UInt8]] = [:]
        for module in modules {
            for reader in readers[module.umisteni] ?? [] where reader != module.umisteni { feeders[reader, default: []].append(module.umisteni) }
        }
        // Longest path to a module, by memoised depth-first search. A link back into the path being walked is a loop,
        // which has no settling time of its own, so it is not followed.
        var memo: [UInt8: Int] = [:]
        var onPath = Set<UInt8>()
        func depth(_ id: UInt8) -> Int {
            if let known = memo[id] { return known }
            guard let here = position[id] else { return 0 }
            onPath.insert(id)
            var best = 0
            for feeder in feeders[id] ?? [] where !onPath.contains(feeder) {
                guard let from = position[feeder], from.thread == here.thread else { continue }
                best = max(best, depth(feeder) + (here.place < from.place ? 1 : 0))
            }
            onPath.remove(id)
            memo[id] = best
            return best
        }
        return (modules.map { depth($0.umisteni) }.max() ?? 0) + 1
    }
}
