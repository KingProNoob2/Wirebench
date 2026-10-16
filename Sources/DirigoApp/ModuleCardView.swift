import SwiftUI
import DirigoCore
import DirigoLibrary

/// A block on the sheet.
///
/// The card takes **plain values** rather than a live `RuntimeNode` plus a global
/// `simulationVersion`. Everything except the callbacks is `Equatable`, so SwiftUI can skip a
/// card on a simulation tick when none of its pin values changed. Previously every card
/// re-evaluated its body ~30 times a second whether or not it had changed, which made the canvas
/// by far the most expensive thing in the app (measured on a 57-module sheet: ~38% of a CPU core,
/// sustained, in a Debug build).
public struct ModuleCardView: View, Equatable {
    nonisolated public static let defaultWidth: CGFloat = 110.0

    /// The vertical space a control card gives its chip (a `BoolVar`'s `Pulse`/`LATCHED`, and the
    /// macro button). Shared with `cardHeight` so the reserved space and the drawn chip cannot
    /// drift: they had, by about 7pt, which showed up as dead space under the button.
    nonisolated public static let controlHeight: CGFloat = 28.0

    /// A `Segment` card carries its display *beside* the pin list, so it needs room for both: the
    /// pin column (measured at about 31 pt), the display (74 pt), the card's padding, and a little
    /// air either side of the display so it is neither jammed against the labels nor orphaned.
    ///
    /// The display is centred in whatever is left after the pins, so the two gaps are equal by
    /// construction. Sizes were measured by rendering the card and finding the display's edges,
    /// not guessed: 144 left 21 pt of dead space, 136 left 17, and this leaves about 5 either side.
    nonisolated public static let segmentWidth: CGFloat = 128.0


    /// Layout constants. These are load-bearing: `inPinPoint`/`outPinPoint` and the wire router
    /// derive pin positions from them, so any change here must be mirrored there.
    private enum Metrics {
        static let headerHeight: CGFloat = 23
        static let bodyTopPadding: CGFloat = 4
        static let pinRowHeight: CGFloat = 12
        static let pinRowSpacing: CGFloat = 4
        /// Distance from the card's top edge to the centre of the first pin row.
        static var firstPinCentre: CGFloat { headerHeight + bodyTopPadding + pinRowHeight / 2 }
    }

    // MARK: - Geometry (also used by the wire router)

    nonisolated public static func cardWidth(for module: PCCModule) -> CGFloat {
        BlockTypeCatalog.info(forGuid: module.guid)?.blockName == "Segment" ? segmentWidth : defaultWidth
    }

    nonisolated public static func cardHeight(for module: PCCModule) -> CGFloat {
        let pinCount = max(module.inPins.count, module.outPins.count)
        let pinsHeight: CGFloat = CGFloat(max(1, pinCount)) * 16.0 + 8.0
        let paramsHeight: CGFloat = module.paramPins.isEmpty ? 0.0 : 18.0
        let isSegment = BlockTypeCatalog.info(forGuid: module.guid)?.blockName == "Segment"
        // The display sits *beside* the pins, so the body must fit the taller of the two, not their
        // sum. The size comes from the view itself so the two cannot drift apart.
        let bodyHeight: CGFloat = isSegment
            ? max(pinsHeight, SegmentDisplayView.displaySize.height)
            : pinsHeight
        let hasControl = BlockInteraction.classify(module) == .control
        let controlSpace: CGFloat = (isMacroCaller(module) || hasControl) ? controlHeight : 0.0
        let calculated = Metrics.headerHeight + bodyHeight + paramsHeight + controlSpace
        return hasControl ? max(76.0, calculated) : calculated
    }

    /// A macro's call site, on a main page or — nested macros — on another macro's sheet. The `Inputs`, `Outputs`
    /// and `Params` interfaces inside a sheet carry a `MACRO_NAME` too and are not calls.
    nonisolated static func isMacroCaller(_ module: PCCModule) -> Bool {
        MacroCalls.target(of: module) != nil
    }

    nonisolated public static func inPinPoint(for module: PCCModule, pinIndex: Int) -> CGPoint {
        CGPoint(x: module.x, y: module.y + Metrics.firstPinCentre + Double(pinIndex) * 16.0)
    }

    nonisolated public static func outPinPoint(for module: PCCModule, pinIndex: Int) -> CGPoint {
        let w = cardWidth(for: module)
        return CGPoint(
            x: module.x + Double(w),
            y: module.y + Metrics.firstPinCentre + Double(pinIndex) * 16.0
        )
    }

    /// Rendering magnification for a given canvas zoom, capped at 2x.
    ///
    /// The card lays out at `renderScale` and is then scaled back down by `1/renderScale`, so this
    /// controls rasterisation sharpness only — the on-screen size always comes from the canvas
    /// transform. It is only consulted for a *settled* zoom (see `AppModel.isZoomSettled`), so it
    /// can be a smooth function of zoom without cost: it is evaluated once, when the gesture ends.
    nonisolated public static func renderScale(for zoom: CGFloat) -> CGFloat {
        max(1.0, min(2.0, zoom))
    }

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

    @State private var isHeldLocally = false
    @State private var renameDraft: String = ""
    @FocusState private var isRenameFocused: Bool
    @State private var hoveredPinIndex: Int?

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
        onPressInput: @escaping (Int, Bool) -> Void = { _, _ in },
        onOpenMacro: ((String) -> Void)? = nil,
        onConfigure: (() -> Void)? = nil,
        onPinDragBegan: ((PinReference) -> Void)? = nil,
        onPinDragMoved: ((CGPoint) -> Void)? = nil,
        onPinDragEnded: ((CGPoint, PinReference) -> Void)? = nil,
        onBeginRename: (() -> Void)? = nil,
        onRename: ((String) -> Void)? = nil,
        onCancelRename: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil
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

            parameterStrip
        }
        .frame(width: cardWidth * s, height: cardHeight * s)
        // The header carries a tinted fill; without this clip it squares off the card's corners.
        .clipShape(cardShape)
        .cardSurface(
            cornerRadius: Theme.cardRadius * s,
            tint: isSelected ? tint : nil,
            tintOpacity: isSelected ? 0.22 : 0.10
        )
        .overlay {
            cardShape.strokeBorder(
                isSelected ? tint.opacity(0.95) : Color.clear,
                lineWidth: 1.8 * s
            )
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
        .shadow(color: Theme.softShadow, radius: (isSelected ? 9 : 4) * s, x: 0, y: (isSelected ? 4 : 2) * s)
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
                    .foregroundStyle(tint)
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
                Text(module.name)
                    .font(.system(size: 9.5 * s, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    // Dirigo instance names can be long (`PrepinacRezim`); shrink slightly rather
                    // than truncating mid-word on a 110 pt card.
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 2 * s)
            Text("#\(module.order)")
                .font(.system(size: 7.5 * s, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8 * s)
        .frame(height: Metrics.headerHeight * s)
        .background(tint.opacity(0.22))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 0.5 * s)
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

    private var pinArea: some View {
        HStack(alignment: .top, spacing: 4 * s) {
            VStack(alignment: .leading, spacing: Metrics.pinRowSpacing * s) {
                ForEach(0..<module.inPins.count, id: \.self) { idx in
                    inputRow(idx)
                }
            }

            // A Segment block drives its display from inputs and has no outputs, so the right half
            // of this row is free — which is where the display belongs, beside the pins. Equal
            // spacers on both sides centre it in that space, rather than leaving all the slack on
            // the right of the card.
            if info?.blockName == "Segment" {
                // `maxWidth` claims the space the empty output column would have taken and centres
                // the display inside it. Two `Spacer`s do *not* do this — measured, they left the
                // display jammed against the pin labels with all the slack still on the right.
                segmentDisplay
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                Spacer(minLength: 2 * s)
            }

            VStack(alignment: .trailing, spacing: Metrics.pinRowSpacing * s) {
                ForEach(0..<module.outPins.count, id: \.self) { idx in
                    outputRow(idx)
                }
            }
        }
        .padding(.horizontal, 6 * s)
        .padding(.top, Metrics.bodyTopPadding * s)
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
                .foregroundStyle(isHigh ? Theme.signalHigh : Color.secondary)
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
                .foregroundStyle(isHigh ? Theme.signalHigh : Color.secondary)
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
        if interaction == .control {
            let isHigh = outValues.first?.asBool ?? inValues.first?.asBool ?? false
            if boolVarMode == .slider {
                sliderControl(isHigh: isHigh)
            } else {
                // Every other BoolVar gets a chip. A push button is momentary and needs press and
                // release; a latch (and an unknown mode) is a tap.
                chip(isHigh: isHigh, momentary: boolVarMode == .pushButton)
            }
        }
    }

    private func sliderControl(isHigh: Bool) -> some View {
        Toggle(isOn: Binding(get: { isHigh }, set: { _ in onToggleInput(0) })) {
            Text(isHigh ? "ON" : "OFF")
                .font(.system(size: 8 * s, weight: .bold))
                .foregroundStyle(isHigh ? Theme.signalHigh : Color.secondary)
        }
        .toggleStyle(.switch)
        .scaleEffect(0.62 * s)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 1 * s)
    }

    /// The control chip. Shared by both non-slider modes so neither can end up without a control —
    /// an `else if` that did not cover every case left the latch with no button at all.
    private func chip(isHigh: Bool, momentary: Bool) -> some View {
        let face = HStack(spacing: 4 * s) {
            PinBead(isHigh: isHigh, scale: s)
            Text(controlLabel(isHigh: isHigh))
                .font(.system(size: 8 * s, weight: .semibold))
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
                .fill(isHigh ? Theme.signalHigh.opacity(0.30) : Color.primary.opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.chipRadius * s, style: .continuous)
                .strokeBorder(
                    isHigh ? Theme.signalHigh.opacity(0.65) : Color.white.opacity(0.18),
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
        case .slider: return isHigh ? "ON" : "OFF"
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
                    Text("*\(macroName)")
                        .font(.system(size: 7.5 * s, weight: .semibold))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2.5 * s)
            }
            .buttonStyle(.plain)
            .foregroundStyle(tint)
            .background {
                RoundedRectangle(cornerRadius: Theme.chipRadius * s, style: .continuous)
                    .fill(tint.opacity(0.16))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.chipRadius * s, style: .continuous)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 0.75 * s)
            }
            .padding(.horizontal, 4 * s)
            .padding(.vertical, 2 * s)
        }
    }

    @ViewBuilder
    private var segmentDisplay: some View {
        if info?.blockName == "Segment" {
            SegmentDisplayView(segments: segments)
                .scaleEffect(s)
                .frame(width: SegmentDisplayView.displaySize.width * s,
                       height: SegmentDisplayView.displaySize.height * s)
        }
    }

    // MARK: - Parameters

    @ViewBuilder
    private var parameterStrip: some View {
        if !module.paramPins.isEmpty {
            HStack(spacing: 6 * s) {
                ForEach(0..<module.paramPins.count, id: \.self) { idx in
                    let current = value(paramValues, idx)
                    let name = ModulePinCatalog.paramPinLabel(for: module, index: idx)
                    Text("\(name) \(text(for: current))")
                        .font(.system(size: 7 * s, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8 * s)
            .frame(height: 16 * s)
            .background(tint.opacity(0.10))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 0.5 * s)
            }
        }
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

        if let macroName = MacroCalls.target(of: module) {
            Button {
                onOpenMacro?("*" + macroName)
            } label: {
                Label("Open Macro (*\(macroName))", systemImage: "arrow.up.right.square")
            }
        }

        Button {
            onSelect()
        } label: {
            Label("Inspect Module", systemImage: "info.circle")
        }

        Divider()

        Button(role: .destructive) {
            onDelete?()
        } label: {
            Label("Delete Block", systemImage: "trash")
        }

        if let currentInfo = info {
            Divider()
            Text("\(currentInfo.blockName) — \(currentInfo.delphiClass)")
        }
    }
}
