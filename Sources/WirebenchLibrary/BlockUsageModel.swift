import Foundation

/// Predicts which block the user will add next, from what they have added before.
///
/// Three things say what comes next, and the prediction is a mixture of the three:
///
/// * **Popularity** — how often each block is added, with older additions counting for less
///   (`halfLife`). Before anything has been added this is the *default order*, a general-purpose list of the
///   blocks nearly every project starts from; it stands in for `priorWeight` additions, so a few real ones
///   do not throw it away and many of them replace it.
/// * **Sequence** — what has been added after the block the user is working from (the selected block's type,
///   or the last one added). Someone who adds a `Comparator` after every `Counter` gets one offered the next
///   time a `Counter` is selected.
/// * **Page** — what has been added to pages that already held a given block type. A page with a `Counter` and a
///   `Timer` on it brings up whatever tended to join those.
///
/// Sequence and page evidence is *smoothed towards popularity* (`backoff`): a block type seen once in some
/// context moves the ranking a little, and the third time it moves it a lot. A context never seen before changes
/// nothing, so it falls back to plain popularity rather than to chance.
///
/// "Time" is the number of additions, not the clock, so the model behaves the same however slowly someone works,
/// and a test can age it by adding blocks.
///
/// A value, `Codable`, and small: each context keeps at most `rowLimit` entries.
public struct BlockUsageModel: Codable, Equatable, Sendable {
    /// What the prediction is made in.
    public struct Context: Equatable, Sendable {
        /// The block type being worked from: the selected block's, otherwise the last one added.
        public var anchor: UUID?
        /// The types of the blocks already on the page.
        public var page: Set<UUID>

        public init(anchor: UUID? = nil, page: Set<UUID> = []) {
            self.anchor = anchor
            self.page = page
        }
    }

    // MARK: - Tuning

    /// After this many additions, an earlier one counts for half.
    static let halfLife: Double = 150
    /// How many additions the default order is worth. Large enough that one stray click cannot reorder the list,
    /// small enough that three or four of the same block do.
    static let priorWeight: Double = 30
    /// How many observations a context needs before it counts for as much as popularity does.
    static let backoff: Double = 3
    /// How the three signals are mixed. They are probabilities that each sum to one, and so does the mix.
    static let popularityShare = 0.5
    static let sequenceShare = 0.3
    static let pageShare = 0.2
    /// The most entries one context remembers, and the least a remembered one may weigh.
    static let rowLimit = 16
    static let smallestWeight = 0.01

    /// The blocks nearly every project starts from, most likely first: inputs, the gates, counting and timing,
    /// comparing, selecting, the I/O blocks, a little arithmetic. Anything not listed follows alphabetically.
    ///
    /// Names are the catalogue's `blockName`s; a test checks every one resolves.
    public static let defaultOrder: [String] = [
        "BoolVar", "And", "Or", "Not", "Counter", "Timer", "PulseGen", "Comparator", "Value", "IntVar",
        "ISwitch", "8xDI", "8xDO", "RS", "Xor", "IAdd", "ISub", "IMul", "Trigger", "SinglePulse", "Yes",
        "Segment", "Int2Bits", "Bits2Int", "Filter", "Ramp", "Mean", "Div", "Set", "FloatVar", "Copy", "Move",
    ]

    // MARK: - What it knows

    /// A count that fades: `weight` as of addition number `at`.
    private struct Weighted: Codable, Equatable, Sendable {
        var weight: Double
        var at: Int

        func value(at now: Int) -> Double { weight * pow(0.5, Double(now - at) / BlockUsageModel.halfLife) }
        func adding(at now: Int) -> Weighted { Weighted(weight: value(at: now) + 1, at: now) }
    }

    /// Additions recorded so far, which is the model's clock.
    private var additions = 0
    private var uses: [UUID: Weighted] = [:]
    /// What was added after a block type: anchor → block.
    private var following: [UUID: [UUID: Weighted]] = [:]
    /// What was added to a page that held a block type: type on the page → block.
    private var alongside: [UUID: [UUID: Weighted]] = [:]

    public init() {}

    /// How many block-to-block relations are remembered, for a test of the bound.
    var trackedRelations: Int {
        following.values.reduce(0) { $0 + $1.count } + alongside.values.reduce(0) { $0 + $1.count }
    }

    // MARK: - Learning

    /// Notes that `block` was added in `context`.
    public mutating func recordAddition(of block: UUID, in context: Context) {
        additions += 1
        let now = additions
        uses[block] = (uses[block] ?? Weighted(weight: 0, at: now)).adding(at: now)
        if let anchor = context.anchor {
            Self.note(block, in: &following[anchor, default: [:]], at: now)
        }
        for type in context.page {
            Self.note(block, in: &alongside[type, default: [:]], at: now)
        }
    }

    private static func note(_ block: UUID, in row: inout [UUID: Weighted], at now: Int) {
        row[block] = (row[block] ?? Weighted(weight: 0, at: now)).adding(at: now)
        // A row is a handful of the likeliest follow-ups, not a history: drop what has faded, then keep the best.
        for (key, entry) in row where entry.value(at: now) < smallestWeight { row[key] = nil }
        if row.count > rowLimit {
            let keep = row.sorted { $0.value.value(at: now) > $1.value.value(at: now) }.prefix(rowLimit)
            row = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    // MARK: - Predicting

    /// The chance of each of `blocks` being the next one added, in `context`. The values sum to one.
    public func probabilities(for blocks: [BlockTypeInfo], in context: Context) -> [UUID: Double] {
        guard !blocks.isEmpty else { return [:] }
        let now = additions

        // Popularity: the default order, as a distribution, worth `priorWeight` additions, plus real additions.
        let rawPrior = blocks.map { Self.priorWeightOf($0) }
        let priorTotal = rawPrior.reduce(0, +)
        let used = blocks.map { uses[$0.guid]?.value(at: now) ?? 0 }
        let usedTotal = used.reduce(0, +)
        let popularity = zip(rawPrior, used).map { (Self.priorWeight * $0 / priorTotal + $1) / (Self.priorWeight + usedTotal) }

        /// A context's follow-ups as a distribution, smoothed towards popularity; `nil` when it has none.
        func conditional(_ row: [UUID: Weighted]?) -> [Double]? {
            guard let row, !row.isEmpty else { return nil }
            let seen = blocks.map { row[$0.guid]?.value(at: now) ?? 0 }
            let total = seen.reduce(0, +)
            guard total > 0 else { return nil }
            return zip(popularity, seen).map { (Self.backoff * $0 + $1) / (Self.backoff + total) }
        }

        let sequence = conditional(context.anchor.flatMap { following[$0] }) ?? popularity
        let pages = context.page.compactMap { conditional(alongside[$0]) }
        let page = pages.isEmpty
            ? popularity
            : popularity.indices.map { index in pages.reduce(0) { $0 + $1[index] } / Double(pages.count) }

        var result: [UUID: Double] = [:]
        for (index, block) in blocks.enumerated() {
            result[block.guid] = Self.popularityShare * popularity[index]
                + Self.sequenceShare * sequence[index] + Self.pageShare * page[index]
        }
        return result
    }

    /// `blocks`, likeliest first. Equal chances — the blocks nobody has used and the default order does not list —
    /// stay alphabetical.
    public func ranked(_ blocks: [BlockTypeInfo], in context: Context) -> [BlockTypeInfo] {
        let chance = probabilities(for: blocks, in: context)
        return blocks.sorted { a, b in
            let (x, y) = (chance[a.guid] ?? 0, chance[b.guid] ?? 0)
            if x != y { return x > y }
            return a.blockName.localizedCaseInsensitiveCompare(b.blockName) == .orderedAscending
        }
    }

    /// The block most likely to be added next.
    public func prediction(among blocks: [BlockTypeInfo], in context: Context) -> BlockTypeInfo? {
        ranked(blocks, in: context).first
    }

    /// How much a block counts in the default order: a falling curve down the list, and a small equal share for
    /// everything the list does not name, so those stay level with each other.
    private static func priorWeightOf(_ block: BlockTypeInfo) -> Double {
        if let rank = defaultRank[block.blockName] { return 1 / pow(Double(rank) + 3, 0.7) }
        return 1 / Double(defaultOrder.count + 40)
    }

    private static let defaultRank: [String: Int] = Dictionary(
        uniqueKeysWithValues: defaultOrder.enumerated().map { ($0.element, $0.offset) })

    // MARK: - Keeping it

    /// Where the app keeps the learned model.
    public static let defaultsKey = "blockUsage.v1"

    /// The model saved in `defaults`, or a fresh one — also when what is saved cannot be read.
    public static func load(from defaults: UserDefaults = .standard) -> BlockUsageModel {
        guard let data = defaults.data(forKey: defaultsKey),
              let model = try? JSONDecoder().decode(BlockUsageModel.self, from: data) else { return BlockUsageModel() }
        return model
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    /// Forgets everything learned, including what is saved.
    public static func forget(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
