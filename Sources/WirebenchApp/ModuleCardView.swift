import SwiftUI
import WirebenchCore
import WirebenchLibrary
import WirebenchModel

/// A block on the sheet.
///
/// The card takes **plain values** rather than a live `RuntimeNode` plus a global
/// `simulationVersion`. Everything except the callbacks is `Equatable`, so SwiftUI can skip a
/// card on a simulation tick when none of its pin values changed. Previously every card
/// re-evaluated its body ~30 times a second whether or not it had changed, which made the canvas
/// by far the most expensive thing in the app (measured on a 57-module sheet: ~38% of a CPU core,
/// sustained, in a Debug build).
public struct ModuleCardView: View, Equatable {
    // Geometry lives in `CardGeometry`, which the model and the wire router use too; these are the names the views and
    // their tests already know it by.
    nonisolated public static var defaultWidth: CGFloat { CardGeometry.defaultWidth }
    nonisolated public static var controlHeight: CGFloat { CardGeometry.controlHeight }
    fileprivate typealias Metrics = CardGeometry.Metrics

    nonisolated public static func cardWidth(for module: PCCModule) -> CGFloat { CardGeometry.cardWidth(for: module) }
    nonisolated public static func cardHeight(for module: PCCModule) -> CGFloat { CardGeometry.cardHeight(for: module) }
    nonisolated static func isMacroCaller(_ module: PCCModule) -> Bool { CardGeometry.isMacroCaller(module) }
    nonisolated public static func inPinPoint(for module: PCCModule, pinIndex: Int) -> CGPoint {
        CardGeometry.inPinPoint(for: module, pinIndex: pinIndex)
    }
    nonisolated public static func outPinPoint(for module: PCCModule, pinIndex: Int) -> CGPoint {
        CardGeometry.outPinPoint(for: module, pinIndex: pinIndex)
    }
    nonisolated public static func renderScale(for zoom: CGFloat) -> CGFloat { CardGeometry.renderScale(for: zoom) }

    // MARK: - Inputs

    public let module: PCCModule
    public let inValues: [PinValue]
    public let paramValues: [PinValue]
    public let outValues: [PinValue]
    public let boolVarMode: BoolVarBlock.Mode?
    /// Set when the block matches the sidebar's search, so it is highlighted on the sheet.
    public let isSearchMatch: Bool
    /// True while this card's name is being edited in place.
    public let isRenaming: Bool
    public let segments: [Bool]
    public let isSelected: Bool
    public let renderScale: CGFloat

    private let onSelect: () -> Void
    private let onToggleInput: (Int) -> Void
    /// Sets the variable of an `IntVar` / `LongVar` from its slider.
    private let onSetValue: (Int) -> Void
    /// Reports a momentary control going down or up: `(pinIndex, isPressed)`.
    private let onPressInput: (Int, Bool) -> Void
    private let onOpenMacro: ((String) -> Void)?
    private let onConfigure: (() -> Void)?

    // Wiring. Declared with defaults so the memberwise initialiser does not have to change, and
    // deliberately excluded from `==` like the other callbacks.
    public var onPinDragBegan: ((PinReference) -> Void)?
    public var onPinDragMoved: ((CGPoint) -> Void)?
    public var onPinDragEnded: ((CGPoint, PinReference) -> Void)?

    // Renaming, declared the same way: defaulted, and excluded from `==`.
    public var onBeginRename: (() -> Void)?
    public var onRename: ((String) -> Void)?
    public var onCancelRename: (() -> Void)?
    public var onDelete: (() -> Void)?
    /// Copy, cut and paste from the menu. They act on the selection: a right-click on a block already in it keeps the whole group, and
    /// one outside it selects just that block first (see `CanvasView`).
    public var onCopy: (() -> Void)?
    public var onCut: (() -> Void)?
    public var onPaste: (() -> Void)?

    /// "Move into … / Take out of …" entries for the block's menu, when `If` / `Switch` containers are on the sheet.
    public struct ContainerAction: Identifiable {
        public let title: String
        public let run: () -> Void
        public var id: String { title }
        public init(title: String, run: @escaping () -> Void) { self.title = title; self.run = run }
    }
    /// Worked out when the menu opens, not with every redraw of the card: it scans the page for containers, and a
    /// card is redrawn at every tick that changes a value.
    public let containerActions: () -> [ContainerAction]

    @State private var isHeldLocally = false
    @State private var renameDraft: String = ""
    @FocusState private var isRenameFocused: Bool
    @State private var hoveredPinIndex: Int?
    @Environment(\.colorScheme) private var colorScheme

    public init(
        module: PCCModule,
        inValues: [PinValue],
        paramValues: [PinValue],
        outValues: [PinValue],
        boolVarMode: BoolVarBlock.Mode? = nil,
        isSearchMatch: Bool = false,
        isRenaming: Bool = false,
        segments: [Bool] = [],
        isSelected: Bool,
        renderScale: CGFloat = 1.0,
        onSelect: @escaping () -> Void,
        onToggleInput: @escaping (Int) -> Void,
        onSetValue: @escaping (Int) -> Void = { _ in },
        onPressInput: @escaping (Int, Bool) -> Void = { _, _ in },
        onOpenMacro: ((String) -> Void)? = nil,
        onConfigure: (() -> Void)? = nil,
        onPinDragBegan: ((PinReference) -> Void)? = nil,
        onPinDragMoved: ((CGPoint) -> Void)? = nil,
        onPinDragEnded: ((CGPoint, PinReference) -> Void)? = nil,
        onBeginRename: (() -> Void)? = nil,
        onRename: ((String) -> Void)? = nil,
        onCancelRename: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil,
        onCopy: (() -> Void)? = nil,
        onCut: (() -> Void)? = nil,
        onPaste: (() -> Void)? = nil,
        containerActions: @escaping () -> [ContainerAction] = { [] }
    ) {
        self.module = module
        self.inValues = inValues
        self.paramValues = paramValues
        self.outValues = outValues
        self.boolVarMode = boolVarMode
        self.isSearchMatch = isSearchMatch
        self.isRenaming = isRenaming
        self.segments = segments
        self.isSelected = isSelected
        self.renderScale = renderScale
        self.onSelect = onSelect
        self.onToggleInput = onToggleInput
        self.onSetValue = onSetValue
        self.onPressInput = onPressInput
        self.onOpenMacro = onOpenMacro
        self.onConfigure = onConfigure
        self.onPinDragBegan = onPinDragBegan
        self.onPinDragMoved = onPinDragMoved
        self.onPinDragEnded = onPinDragEnded
        self.onBeginRename = onBeginRename
        self.onRename = onRename
        self.onCancelRename = onCancelRename
        self.onDelete = onDelete
        self.onCopy = onCopy
        self.onCut = onCut
        self.onPaste = onPaste
        self.containerActions = containerActions
    }

    /// Closures are deliberately excluded: they are recreated on every pass but capture only the
    /// module id and the model, so two cards differing only in closure identity draw identically.
    nonisolated public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.module == rhs.module
            && lhs.inValues == rhs.inValues
            && lhs.paramValues == rhs.paramValues
            && lhs.outValues == rhs.outValues
            && lhs.boolVarMode == rhs.boolVarMode
            && lhs.segments == rhs.segments
            && lhs.isSelected == rhs.isSelected
            && lhs.isSearchMatch == rhs.isSearchMatch
            && lhs.isRenaming == rhs.isRenaming
            && lhs.renderScale == rhs.renderScale
    }

    /// Whether `LiveValuesLayer` draws this block's pin rows, so that its card is static. A `Segment` has its display beside the pins and keeps
    /// its row views.
    static func drawsRowsInLayer(_ module: PCCModule) -> Bool {
        BlockTypeCatalog.info(forGuid: module.guid)?.blockName != "Segment"
    }

    /// Whether the card needs the block's live values for anything it draws itself: the control of a `BoolVar` or `IntVar`, a seven-segment
    /// display, or the pin rows where the layer does not draw them. Any other card is given none, and so never changes on a tick.
    static func readsLiveValues(_ module: PCCModule) -> Bool {
        if !drawsRowsInLayer(module) { return true }
        let interaction = BlockInteraction.classify(module)
        return interaction == .control || interaction == .slider
    }

    /// What a card is given of its block's live values: all of them where it draws them, and otherwise only what it draws itself — a
    /// `BoolVar`'s mode — so that a pin changing does not change the card. The parameters are pins, drawn by the layer with the other rows.
    static func cardSnapshot(_ snapshot: BlockSnapshot, of module: PCCModule) -> BlockSnapshot {
        guard !readsLiveValues(module) else { return snapshot }
        var trimmed = snapshot
        trimmed.inValues = []
        trimmed.outValues = []
        trimmed.paramValues = []
        return trimmed
    }

    // MARK: - Derived

    private var s: CGFloat { renderScale }
    private var cardWidth: CGFloat { Self.cardWidth(for: module) }
    private var cardHeight: CGFloat { Self.cardHeight(for: module) }
    private var info: BlockTypeInfo? { BlockTypeCatalog.info(forGuid: module.guid) }
    private var tint: Color { Theme.tint(forBlockNamed: module.name, guid: module.guid) }
    private var interaction: BlockInteraction { BlockInteraction.classify(module) }

    private var isMacroCaller: Bool { Self.isMacroCaller(module) }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.cardRadius * s, style: .continuous)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            VStack(spacing: Metrics.pinRowSpacing * s) {
                pinArea
                controlArea
                macroButton
            }

            Spacer(minLength: 0)
        }
        .frame(width: cardWidth * s, height: cardHeight * s)
        // The header carries a tinted fill; without this clip it squares off the card's corners.
        .clipShape(cardShape)
        .cardSurface(
            cornerRadius: Theme.cardRadius * s,
            tint: isSelected ? tint : nil,
            tintOpacity: isSelected ? 0.22 : 0.10,
            shadowColor: Theme.cardShadow(for: colorScheme, isSelected: isSelected),
            shadowRadius: (isSelected ? 9 : 4) * s,
            shadowY: (isSelected ? 4 : 2) * s
        )
        .overlay {
            if isSelected {
                cardShape.strokeBorder(tint.opacity(0.95), lineWidth: 1.8 * s)
            }
        }
        .overlay {
            // Search highlight. Drawn with its own glow so it reads even on a card that is also
            // selected, whose border is the block's tint.
            if isSearchMatch {
                cardShape
                    .strokeBorder(Theme.searchHighlight, lineWidth: 2.2 * s)
                    .shadow(color: Theme.searchHighlight.opacity(0.6), radius: 5 * s)
            }
        }
        .scaleEffect(1.0 / s)
        .frame(width: cardWidth, height: cardHeight)
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
        .contextMenu { contextMenuContent }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 4 * s) {
            if isMacroCaller {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 8 * s, weight: .semibold))
                    .foregroundStyle(colorScheme == .dark ? tint : Color.primary.opacity(0.78))
            }
            if isRenaming {
                TextField("", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 9.5 * s, weight: .semibold))
                    .focused($isRenameFocused)
                    .onSubmit { onRename?(renameDraft) }
                    .onExitCommand { onCancelRename?() }
                    .onAppear {
                        renameDraft = module.name
                        isRenameFocused = true
                    }
            } else {
                SteadyText.make(module.name, size: 9.5, weight: .semibold, scale: s)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    // Dirigo instance names can be long (`PrepinacRezim`); shrink slightly rather
                    // than truncating mid-word on a 110 pt card.
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 2 * s)
            Text("#\(module.order)")
                .font(.system(size: 7.5 * s, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.pinSecondaryText(for: colorScheme))
        }
        .padding(.horizontal, 8 * s)
        .frame(height: Metrics.headerHeight * s)
        .background(tint.opacity(colorScheme == .dark ? 0.30 : 0.24))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.16))
                .frame(height: max(0.5, 0.75 * s))
        }
        .contentShape(Rectangle())
        // Simultaneous, not an `onTapGesture(count: 2)` / `onTapGesture` pair: that pair makes the single tap
        // wait out the system double-click interval (~0.5 s) to be sure no second click is coming, which is
        // the delay between clicking a block and it being selected.
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                if let macroName = MacroCalls.target(of: module) {
                    onOpenMacro?("*" + macroName)
                } else {
                    onBeginRename?()
                }
            }
        )
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
    }

    // MARK: - Pins

    @ViewBuilder
    private var pinArea: some View {
        if info?.blockName == "Segment" {
            pinAreaViews
        } else {
            pinAreaHits
        }
    }

    /// The pin rows' space and clicks, with the rows themselves drawn by `LiveValuesLayer`: nothing here depends on a pin's value, so the
    /// card does not change when one moves.
    private var pinAreaHits: some View {
        PinHitArea(inputLabels: (0..<module.inPins.count).map { ModulePinCatalog.inputPinLabel(for: module, index: $0) },
                   outputLabels: (0..<module.outPins.count).map { ModulePinCatalog.outputPinLabel(for: module, index: $0) },
                   parameterRows: module.paramPins.count,
                   scale: s, clickableOutputs: interaction == .pinToggles, onToggle: { onToggleInput($0) })
            .equatable()
            .padding(.horizontal, 6 * s)
            .padding(.top, Metrics.bodyTopPadding * s)
    }

    private var pinAreaViews: some View {
        HStack(alignment: .top, spacing: 4 * s) {
            VStack(alignment: .leading, spacing: Metrics.pinRowSpacing * s) {
                ForEach(0..<module.inPins.count, id: \.self) { idx in
                    inputRow(idx)
                }
            }

            Spacer(minLength: 2 * s)

            VStack(alignment: .trailing, spacing: Metrics.pinRowSpacing * s) {
                ForEach(0..<module.outPins.count, id: \.self) { idx in
                    outputRow(idx)
                }
            }
        }
        .padding(.horizontal, 6 * s)
        .padding(.top, Metrics.bodyTopPadding * s)
        // A Segment's display fills the body beside the pins, where `CardGeometry.segmentWindow` puts it (measured from the card's top, which
        // is where this area starts less the header).
        .overlay(alignment: .topLeading) {
            if let window = CardGeometry.segmentWindow(for: module) {
                segmentDisplay(window.size)
                    .offset(x: window.minX * s, y: (window.minY - Metrics.headerHeight) * s)
            }
        }
    }


    private func value(_ values: [PinValue], _ index: Int) -> PinValue {
        values.indices.contains(index) ? values[index] : .undefined
    }

    /// `PinValue.undefined` means "no value yet"; printing the word is noise on a block face.
    private func text(for value: PinValue) -> String {
        if case .undefined = value { return "\u{2013}" }
        return value.description
    }

    private func inputRow(_ idx: Int) -> some View {
        let current = value(inValues, idx)
        let isHigh = current.asBool
        let label = ModulePinCatalog.inputPinLabel(for: module, index: idx)

        return HStack(spacing: 3 * s) {
            PinBead(isHigh: isHigh, scale: s)
            Text(label)
                .font(.system(size: 7.5 * s, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(text(for: current))
                .font(.system(size: 7.5 * s, weight: isHigh ? .bold : .regular, design: .monospaced))
                .foregroundStyle(isHigh ? Theme.signalHigh : Theme.pinSecondaryText(for: colorScheme))
                .lineLimit(1)
        }
        .frame(height: Metrics.pinRowHeight * s)
        .contentShape(Rectangle())
        .onTapGesture { onToggleInput(idx) }
    }

    private func outputRow(_ idx: Int) -> some View {
        let current = value(outValues, idx)
        let isHigh = current.asBool
        let label = ModulePinCatalog.outputPinLabel(for: module, index: idx)
        let clickable = interaction == .pinToggles
        let isHovered = hoveredPinIndex == idx

        return HStack(spacing: 3 * s) {
            Text(text(for: current))
                .font(.system(size: 7.5 * s, weight: isHigh ? .bold : .regular, design: .monospaced))
                .foregroundStyle(isHigh ? Theme.signalHigh : Theme.pinSecondaryText(for: colorScheme))
                .lineLimit(1)
            Text(label)
                .font(.system(size: 7.5 * s, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
            PinBead(isHigh: isHigh, scale: s)
        }
        .padding(.horizontal, clickable ? 3 * s : 0)
        .frame(height: Metrics.pinRowHeight * s)
        .background {
            if clickable {
                RoundedRectangle(cornerRadius: 4 * s, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.12 : 0.001))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            guard clickable else { return }
            hoveredPinIndex = hovering ? idx : (hoveredPinIndex == idx ? nil : hoveredPinIndex)
        }
        .onTapGesture {
            guard clickable else { return }
            onToggleInput(idx)
        }
        .help(clickable ? "Click to toggle this input" : "")
    }

    // MARK: - Controls

    @ViewBuilder
    private var controlArea: some View {
        switch interaction {
        case .control:
            // A push button is momentary and needs press and release; a latch is a tap.
            let isHigh = outValues.first?.asBool ?? inValues.first?.asBool ?? false
            chip(isHigh: isHigh, momentary: boolVarMode == .pushButton)
        case .slider:
            sliderControl(value: outValues.first?.asInt ?? 0)
        case .none, .pinToggles:
            EmptyView()
        }
    }

    /// An `IntVar`'s slider: a thumb on a track from 0 to the block's maximum (set in its configuration), with the
    /// variable following the thumb. A value past either end — typed into the inspector, say — sits at that end.
    private func sliderControl(value: Int) -> some View {
        let maximum = BlockRole.sliderMax(of: module)
        return Slider(value: Binding(get: { Double(min(max(value, 0), maximum)) },
                                     set: { position in
                                         let next = Int(position.rounded())
                                         // Only a step to another value is a change; the same one is not.
                                         guard next != value else { return }
                                         onSetValue(next)
                                     }),
                      in: 0...Double(maximum), step: 1)
            .controlSize(.mini)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6 * s)
            .padding(.vertical, 1 * s)
            .help("\(value)  (0 – \(maximum))")
    }

    /// The control chip. Shared by the push button and the latch so neither can end up without a control —
    /// an `else if` that did not cover every case left the latch with no button at all.
    private func chip(isHigh: Bool, momentary: Bool) -> some View {
        let face = HStack(spacing: 4 * s) {
            PinBead(isHigh: isHigh, scale: s)
            SteadyText.make(controlLabel(isHigh: isHigh), size: 8, weight: .semibold, scale: s)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        // Fill the slot the card reserves (less this chip's own 2pt vertical padding), so the button
        // is a properly sized target and no dead space is left beneath it.
        .frame(height: (Self.controlHeight - 4) * s)
        .contentShape(Rectangle())

        return Group {
            if momentary {
                // `DragGesture(minimumDistance: 0)` is how SwiftUI exposes both edges of a click; a
                // `Button` only ever reports the tap, which cannot express "held down".
                face.gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !isHeldLocally else { return }
                            isHeldLocally = true
                            onSelect()
                            onPressInput(0, true)
                        }
                        .onEnded { _ in
                            guard isHeldLocally else { return }
                            isHeldLocally = false
                            onPressInput(0, false)
                        }
                )
            } else {
                Button {
                    onToggleInput(0)
                } label: {
                    face
                }
                .buttonStyle(.plain)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: Theme.chipRadius * s, style: .continuous)
                .fill(isHigh
                    ? Theme.signalHigh.opacity(colorScheme == .dark ? 0.34 : 0.24)
                    : (colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.chipRadius * s, style: .continuous)
                .strokeBorder(
                    isHigh
                        ? Theme.signalHigh.opacity(0.80)
                        : (colorScheme == .dark ? Color.white.opacity(0.28) : Color.black.opacity(0.26)),
                    lineWidth: 0.75 * s
                )
        }
        .padding(.horizontal, 4 * s)
        .padding(.vertical, 2 * s)
    }

    private func controlLabel(isHigh: Bool) -> String {
        switch boolVarMode {
        case .pushButton: return "Pulse"
        case .toggleSwitch: return isHigh ? "LATCHED" : "OFF"
        case nil: return isHigh ? "ON" : "OFF"
        }
    }

    @ViewBuilder
    private var macroButton: some View {
        if let macroName = MacroCalls.target(of: module) {
            Button {
                onOpenMacro?("*" + macroName)
            } label: {
                HStack(spacing: 3 * s) {
                    Image(systemName: "arrow.up.right.square.fill")
                        .font(.system(size: 7 * s, weight: .semibold))
                    SteadyText.make("*\(macroName)", size: 7.5, weight: .semibold, scale: s)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2.5 * s)
            }
            .buttonStyle(.plain)
            .foregroundStyle(colorScheme == .dark ? tint : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: Theme.chipRadius * s, style: .continuous)
                    .fill(tint.opacity(colorScheme == .dark ? 0.20 : 0.18))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.chipRadius * s, style: .continuous)
                    .strokeBorder(tint.opacity(colorScheme == .dark ? 0.48 : 0.55), lineWidth: 0.75 * s)
            }
            .padding(.horizontal, 4 * s)
            .padding(.vertical, 2 * s)
        }
    }

    private func segmentDisplay(_ window: CGSize) -> some View {
        SegmentDisplayView(segments: segments, window: window)
            .scaleEffect(s)
            .frame(width: window.width * s, height: window.height * s)
    }

    // MARK: - Context menu

    @ViewBuilder
    private var contextMenuContent: some View {
        Button {
            onConfigure?()
        } label: {
            Label("Configure...", systemImage: "slider.horizontal.3")
        }

        Button {
            onBeginRename?()
        } label: {
            Label("Rename...", systemImage: "pencil")
        }

        Divider()

        Button { onCopy?() } label: { Label("Copy", systemImage: "doc.on.doc") }
        Button { onCut?() } label: { Label("Cut", systemImage: "scissors") }
        Button { onPaste?() } label: { Label("Paste", systemImage: "doc.on.clipboard") }

        Divider()

        if let macroName = MacroCalls.target(of: module) {
            Button {
                onOpenMacro?("*" + macroName)
            } label: {
                Label("Open Macro (*\(macroName))", systemImage: "arrow.up.right.square")
            }
        }

        let containerActions = self.containerActions()
        if !containerActions.isEmpty {
            Divider()
            ForEach(containerActions) { action in
                Button(action.title, action: action.run)
            }
        }

        Button {
            NotificationCenter.default.post(name: .showHelp, object: nil, userInfo: ["block": HelpModel.blockName(of: module)])
        } label: {
            Label("Help for \(HelpModel.blockName(of: module))", systemImage: "questionmark.circle")
        }

        Button {
            onSelect()
            // The pane is hidden by default; asking to inspect a block is what opens it.
            NotificationCenter.default.post(name: .showInspector, object: nil)
        } label: {
            Label("Inspect Block", systemImage: "info.circle")
        }

        Divider()

        Button(role: .destructive) {
            onDelete?()
        } label: {
            Label("Delete", systemImage: "trash")
        }

        if let currentInfo = info {
            Divider()
            Text("\(currentInfo.blockName) — \(currentInfo.delphiClass)")
        }
    }
}

// MARK: - Text that does not move with the render scale

/// Text of the system font, set at `size × scale` and as wide as it is at `size`.
///
/// A card is laid out at the render scale and scaled back down (`ModuleCardView.renderScale`). The system font spaces its letters by point size,
/// so a name set at 12 pt, 19 pt and 24 pt and scaled back to the same size came out up to 5% narrower with every step of the scale —
/// and as the scale follows a zoom, the titles shifted at each step. This adds the tracking that makes up the difference. Monospaced text
/// has no such spacing and is not run through it.
@MainActor
enum SteadyText {
    private static var tracking: [String: CGFloat] = [:]

    static func make(_ string: String, size: CGFloat, weight: Font.Weight, scale: CGFloat) -> Text {
        let text = Text(string).font(.system(size: size * scale, weight: weight))
        guard scale != 1, string.count > 0 else { return text }
        return text.tracking(extra(string, size: size, weight: weight, scale: scale))
    }

    /// Per letter, in points at layout size.
    private static func extra(_ string: String, size: CGFloat, weight: Font.Weight, scale: CGFloat) -> CGFloat {
        let key = "\(string)|\(size)|\(scale)|\(weight)"
        if let known = tracking[key] { return known }
        func width(_ points: CGFloat) -> CGFloat {
            (string as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: points, weight: nsWeight(weight))]).width
        }
        let value = (width(size) * scale - width(size * scale)) / CGFloat(string.count)
        if tracking.count > 4000 { tracking.removeAll() }
        tracking[key] = value
        return value
    }

    private static func nsWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        default: return .regular
        }
    }
}

// MARK: - Pin rows in canvases

/// How a block's pin rows are drawn by `LiveValuesLayer`: inputs down the left (bead, name, value), outputs down the right (value, name, bead).
/// The geometry is the row views' (`CardGeometry.Metrics`), so the rows sit where the card's pins are.
enum PinRows {
    struct Row: Equatable, Sendable {
        let label: String
        let valueText: String
        let isHigh: Bool
        /// A parameter pin (`PV`, `Max`…), drawn on a shaded cell as in Dirigo.
        var isParam = false
    }

    private static var rowHeight: CGFloat { CardGeometry.Metrics.pinRowHeight }
    private static var rowSpacing: CGFloat { CardGeometry.Metrics.pinRowSpacing }

    @MainActor
    private static var resolvedCache: [TextCacheKey: CachedText] = [:]

    private struct TextCacheKey: Hashable {
        let label: String
        let value: String
        let scale: CGFloat
        let isHigh: Bool
        let isInput: Bool
        let isDark: Bool
    }

    private struct CachedText {
        let resolved: GraphicsContext.ResolvedText
        var measuredWidth: CGFloat?
    }

    @MainActor
    private static func cachedText(
        label: String,
        value: String,
        scale s: CGFloat,
        isHigh: Bool,
        isInput: Bool,
        colorScheme: ColorScheme,
        context: GraphicsContext,
        measureWidth: Bool = false
    ) -> (resolved: GraphicsContext.ResolvedText, width: CGFloat) {
        let key = TextCacheKey(label: label, value: value, scale: s, isHigh: isHigh, isInput: isInput, isDark: colorScheme == .dark)
        if var hit = resolvedCache[key] {
            if measureWidth && hit.measuredWidth == nil {
                let w = hit.resolved.measure(in: CGSize(width: 1000, height: 100)).width
                hit.measuredWidth = w
                resolvedCache[key] = hit
                return (hit.resolved, w)
            }
            return (hit.resolved, hit.measuredWidth ?? 0)
        }
        let labelText = Text(label)
            .font(.system(size: 7.5 * s, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.pinPrimaryText(for: colorScheme))
        let spacerText = Text(" ")
            .font(.system(size: 5 * s, design: .monospaced))
        let valueText = Text(value)
            .font(.system(size: 7.5 * s, weight: isHigh ? .bold : .regular, design: .monospaced))
            .foregroundStyle(isHigh ? Theme.signalHigh : Theme.pinSecondaryText(for: colorScheme))
        let combined = isInput
            ? (labelText + spacerText + valueText)
            : (valueText + spacerText + labelText)
        let resolved = context.resolve(combined)
        let w = measureWidth ? resolved.measure(in: CGSize(width: 1000, height: 100)).width : nil
        if resolvedCache.count > 2048 {
            resolvedCache.removeAll(keepingCapacity: true)
        }
        resolvedCache[key] = CachedText(resolved: resolved, measuredWidth: w)
        return (resolved, w ?? 0)
    }

    /// The rows' height at `scale`: the taller of the two columns.
    static func height(inputs: Int, outputs: Int, scale: CGFloat) -> CGFloat {
        let count = max(inputs, outputs)
        return count == 0 ? 0 : (CGFloat(count) * rowHeight + CGFloat(count - 1) * rowSpacing) * scale
    }

    /// `inputOf` is the block's type for a row of its inputs, which can write a value its own way (`PinDisplay`).
    static func row(_ values: [PinValue], _ index: Int, label: String, inputOf guid: UUID? = nil) -> Row {
        let current = values.indices.contains(index) ? values[index] : .undefined
        // `.undefined` means "no value yet"; printing the word is noise on a block face.
        let text: String
        if case .undefined = current { text = "\u{2013}" }
        else if let guid { text = PinDisplay.inputText(current, index: index, guid: guid) }
        else { text = current.description }
        return Row(label: label, valueText: text, isHigh: current.asBool)
    }

    private static func valueString(_ current: PinValue, index: Int, inputOf guid: UUID? = nil) -> (text: String, isHigh: Bool) {
        if case .undefined = current { return ("\u{2013}", false) }
        let text = guid.map { PinDisplay.inputText(current, index: index, guid: $0) } ?? current.description
        return (text, current.asBool)
    }

    private static func bead(_ context: inout GraphicsContext, centreX: CGFloat, centreY: CGFloat, isHigh: Bool, _ s: CGFloat, colorScheme: ColorScheme) {
        let rect = CGRect(x: centreX - 3 * s, y: centreY - 3 * s, width: 6 * s, height: 6 * s)
        context.fill(Path(ellipseIn: rect), with: .color(isHigh ? Theme.signalHigh : Theme.pinBeadIdleFill(for: colorScheme)))
        context.stroke(Path(ellipseIn: rect.insetBy(dx: 0.25 * s, dy: 0.25 * s)),
                       with: .color(isHigh ? Theme.pinBeadHighStroke(for: colorScheme) : Theme.pinBeadIdleStroke(for: colorScheme)), lineWidth: 0.5 * s)
    }

    /// Draws the rows with their top-left corner at the context's origin, `width` wide.
    @MainActor
    static func draw(in context: inout GraphicsContext, width: CGFloat, inputs: [Row], outputs: [Row], scale s: CGFloat, clickableOutputs: Bool, colorScheme: ColorScheme = .dark) {
        let pitch = (rowHeight + rowSpacing) * s
        let labelX = 14 * s
        let right = width - (clickableOutputs ? 3 * s : 0)
        let labelRight = right - 14 * s
        for (index, row) in inputs.enumerated() {
            let centreY = CGFloat(index) * pitch + rowHeight * s / 2
            let entry = cachedText(label: row.label, value: row.valueText, scale: s, isHigh: row.isHigh,
                                   isInput: true, colorScheme: colorScheme, context: context, measureWidth: row.isParam)
            if row.isParam {
                // The shaded cell Dirigo gives a parameter pin, as wide as the row's content.
                let cell = CGRect(x: 0, y: centreY - rowHeight * s / 2, width: labelX + entry.width + 5 * s, height: rowHeight * s)
                let paramFill = colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.09)
                context.fill(Path(roundedRect: cell, cornerRadius: 3 * s, style: .continuous), with: .color(paramFill))
            }
            bead(&context, centreX: 5.5 * s, centreY: centreY, isHigh: row.isHigh, s, colorScheme: colorScheme)
            context.draw(entry.resolved, at: CGPoint(x: labelX, y: centreY), anchor: .leading)
        }
        for (index, row) in outputs.enumerated() {
            let centreY = CGFloat(index) * pitch + rowHeight * s / 2
            bead(&context, centreX: right - 5.5 * s, centreY: centreY, isHigh: row.isHigh, s, colorScheme: colorScheme)
            let entry = cachedText(label: row.label, value: row.valueText, scale: s, isHigh: row.isHigh,
                                   isInput: false, colorScheme: colorScheme, context: context)
            context.draw(entry.resolved, at: CGPoint(x: labelRight, y: centreY), anchor: .trailing)
        }
    }

    /// Zero-allocation path used by `LiveValuesLayer`: draws a module's pins directly from its snapshot and
    /// accumulates non-clipped beads into shared paths so all beads stroke/fill in a handful of draw calls.
    @MainActor
    static func drawModule(
        _ module: PCCModule,
        snapshot: BlockSnapshot?,
        origin: CGPoint,
        width: CGFloat,
        clickableOutputs: Bool,
        colorScheme: ColorScheme,
        in context: inout GraphicsContext,
        highBeads: inout Path,
        idleBeadsFill: inout Path,
        idleBeadsStroke: inout Path
    ) {
        let pitch = rowHeight + rowSpacing
        let labelX = origin.x + 14
        let right = origin.x + width - (clickableOutputs ? 3 : 0)
        let labelRight = right - 14
        let inCount = module.inPins.count
        let snapIn = snapshot?.inValues
        let snapParam = snapshot?.paramValues
        let snapOut = snapshot?.outValues

        for index in 0..<inCount {
            let centreY = origin.y + CGFloat(index) * pitch + rowHeight / 2
            let val: PinValue
            if let snapIn {
                val = index < snapIn.count ? snapIn[index] : .undefined
            } else {
                val = module.inPins[index].value
            }
            let (valueText, isHigh) = valueString(val, index: index, inputOf: module.guid)
            let label = ModulePinCatalog.inputPinLabel(for: module, index: index)
            let rect = CGRect(x: origin.x + 2.5, y: centreY - 3, width: 6, height: 6)
            if isHigh {
                highBeads.addEllipse(in: rect)
            } else {
                idleBeadsFill.addEllipse(in: rect)
                idleBeadsStroke.addEllipse(in: rect.insetBy(dx: 0.25, dy: 0.25))
            }
            let entry = cachedText(label: label, value: valueText, scale: 1, isHigh: isHigh,
                                   isInput: true, colorScheme: colorScheme, context: context)
            context.draw(entry.resolved, at: CGPoint(x: labelX, y: centreY), anchor: .leading)
        }

        let paramCount = module.paramPins.count
        if paramCount > 0 {
            let paramFill = colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.09)
            for pIndex in 0..<paramCount {
                let rowIndex = inCount + pIndex
                let centreY = origin.y + CGFloat(rowIndex) * pitch + rowHeight / 2
                let val: PinValue
                if let snapParam {
                    val = pIndex < snapParam.count ? snapParam[pIndex] : .undefined
                } else {
                    val = module.paramPins[pIndex].value
                }
                let (valueText, _) = valueString(val, index: pIndex)
                let label = ModulePinCatalog.paramPinLabel(for: module, index: pIndex)
                let entry = cachedText(label: label, value: valueText, scale: 1, isHigh: false,
                                       isInput: true, colorScheme: colorScheme, context: context, measureWidth: true)
                let cell = CGRect(x: origin.x, y: centreY - rowHeight / 2, width: 14 + entry.width + 5, height: rowHeight)
                context.fill(Path(roundedRect: cell, cornerRadius: 3, style: .continuous), with: .color(paramFill))
                let rect = CGRect(x: origin.x + 2.5, y: centreY - 3, width: 6, height: 6)
                idleBeadsFill.addEllipse(in: rect)
                idleBeadsStroke.addEllipse(in: rect.insetBy(dx: 0.25, dy: 0.25))
                context.draw(entry.resolved, at: CGPoint(x: labelX, y: centreY), anchor: .leading)
            }
        }

        for index in 0..<module.outPins.count {
            let centreY = origin.y + CGFloat(index) * pitch + rowHeight / 2
            let val: PinValue
            if let snapOut {
                val = index < snapOut.count ? snapOut[index] : .undefined
            } else {
                val = module.outPins[index].value
            }
            let (valueText, isHigh) = valueString(val, index: index)
            let label = ModulePinCatalog.outputPinLabel(for: module, index: index)
            let rect = CGRect(x: right - 8.5, y: centreY - 3, width: 6, height: 6)
            if isHigh {
                highBeads.addEllipse(in: rect)
            } else {
                idleBeadsFill.addEllipse(in: rect)
                idleBeadsStroke.addEllipse(in: rect.insetBy(dx: 0.25, dy: 0.25))
            }
            let entry = cachedText(label: label, value: valueText, scale: 1, isHigh: isHigh,
                                   isInput: false, colorScheme: colorScheme, context: context)
            context.draw(entry.resolved, at: CGPoint(x: labelRight, y: centreY), anchor: .trailing)
        }
    }
}

/// A card's pin rows that draw nothing: the space they take, and the clicks on them. The rows themselves are drawn by `LiveValuesLayer`, which
/// is what lets a card stay unchanged while its values move. Clicking an input row toggles it; so does clicking an output row of a block whose
/// outputs are driven by hand.
struct PinHitArea: View, Equatable {
    let inputLabels: [String]
    let outputLabels: [String]
    /// Rows under the inputs that are parameter pins: they take room, and are not clicked.
    let parameterRows: Int
    let scale: CGFloat
    let clickableOutputs: Bool
    let onToggle: (Int) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.inputLabels == rhs.inputLabels && lhs.outputLabels == rhs.outputLabels && lhs.parameterRows == rhs.parameterRows
            && lhs.scale == rhs.scale && lhs.clickableOutputs == rhs.clickableOutputs
    }

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: PinRows.height(inputs: inputLabels.count + parameterRows, outputs: outputLabels.count, scale: scale))
            .modifier(PinTaps(inputLabels: inputLabels, outputLabels: outputLabels, scale: scale, clickableOutputs: clickableOutputs, onToggle: onToggle))
    }
}

/// The clicks and the hover of a block's pin rows, found from where the pointer is. The hover highlight is drawn here, behind whatever draws the
/// rows' text (the layer is above the card).
private struct PinTaps: ViewModifier {
    let inputLabels: [String]
    let outputLabels: [String]
    let scale: CGFloat
    let clickableOutputs: Bool
    let onToggle: (Int) -> Void

    @State private var hoveredOutput: Int?

    private var pitch: CGFloat { (CardGeometry.Metrics.pinRowHeight + CardGeometry.Metrics.pinRowSpacing) * scale }
    private var rowHeight: CGFloat { CardGeometry.Metrics.pinRowHeight * scale }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if let row = hoveredOutput, outputLabels.indices.contains(row) {
                    // Wide as the row it sits behind: bead, name and a two-character value, with the padding the row gets.
                    let width = (CGFloat(outputLabels[row].count + 2) * 4.5 + 11 + 3 + 3 + 6) * scale
                    RoundedRectangle(cornerRadius: 4 * scale, style: .continuous)
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: width, height: rowHeight)
                        .offset(y: CGFloat(row) * pitch)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 1, coordinateSpace: .local) { location in tap(at: location) }
            .modifier(ClickableOutputHover(
                enabled: clickableOutputs,
                outputRowAt: outputRow(at:),
                hoveredOutput: $hoveredOutput
            ))
    }

    /// The row at height `y`, if it is on a row and not in the gap between two.
    private func row(at y: CGFloat) -> Int? {
        guard y >= 0 else { return nil }
        let index = Int(y / pitch)
        return y - CGFloat(index) * pitch <= rowHeight ? index : nil
    }

    private func inputRow(at point: CGPoint) -> Int? {
        guard let index = row(at: point.y), index < inputLabels.count else { return nil }
        // A monospaced glyph is about 0.6 em wide; a row is its bead, then the name and a value of a few characters.
        return point.x <= (14 + CGFloat(inputLabels[index].count + 3) * 4.5 + 3) * scale ? index : nil
    }

    private func outputRow(at point: CGPoint) -> Int? {
        guard clickableOutputs, let index = row(at: point.y), index < outputLabels.count else { return nil }
        return index
    }

    private func tap(at location: CGPoint) {
        if let index = inputRow(at: location) { onToggle(index); return }
        if let index = outputRow(at: location) { onToggle(index) }
    }
}

private struct ClickableOutputHover: ViewModifier {
    let enabled: Bool
    let outputRowAt: (CGPoint) -> Int?
    @Binding var hoveredOutput: Int?

    func body(content: Content) -> some View {
        if enabled {
            content
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hoveredOutput = outputRowAt(point)
                    case .ended: hoveredOutput = nil
                    }
                }
                .help("Click to toggle this input")
        } else {
            content
        }
    }
}
