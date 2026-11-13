import WirebenchModel
import SwiftUI
import WirebenchCore
import WirebenchLibrary
import WirebenchEngine

/// The inspector sidebar: what the selected block is, what its pins are doing, and how to configure it.
///
/// The sections are separate views rather than computed properties, because the signal rows change at the
/// simulation rate while the header does not: with the header in its own `Equatable` view, a tick
/// invalidates the rows whose values moved and leaves the rest — including the whole hero — alone.
public struct InspectorView: View {
    @Bindable var model: AppModel
    @AppStorage("inspector.showDetails") private var showDetails = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        if let modId = model.selectedModuleId,
           let mod = model.project?.modules.first(where: { $0.id == modId }) {
            let node = model.getNode(id: modId)
            let blockTypeName = BlockRegistry.shared.resolvedTypeName(for: mod) ?? mod.name
            let info = BlockTypeCatalog.info(forGuid: mod.guid)

            InspectorStack {
                InspectorCard {
                    InspectorHero(
                        name: mod.name,
                        blockName: info?.blockName ?? blockTypeName,
                        category: info?.category ?? "",
                        summary: info?.summary ?? "",
                        symbol: Self.iconForBlockType(blockTypeName),
                        tint: Theme.tint(forCategory: info?.category ?? ""),
                        isSimulated: CxxSimulationCore.kind(forGUID: mod.guid) != nil,
                        onToggleFirstInput: { model.toggleModuleInput(moduleId: mod.id, pinIndex: 0) },
                        onReset: { model.resetModuleState(id: mod.id) },
                        onConfigure: { model.openConfigureModule(id: mod.id) })
                        .equatable()
                }

                // Inputs and outputs are separate cards rather than one list: a sheet may name a pin
                // on each side the same thing (a macro's `PN` does), and in one list that reads as a
                // duplicated row rather than as two pins.
                if mod.inPins.isEmpty && mod.outPins.isEmpty {
                    InspectorCard(title: "Signals") {
                        Text("No signals connected")
                            .foregroundStyle(.secondary)
                    }
                }

                if !mod.inPins.isEmpty {
                    InspectorCard(title: "Inputs") {
                        InspectorRows(count: mod.inPins.count) { idx in
                            let val = node?.block.inPins.indices.contains(idx) == true
                                ? node!.block.inPins[idx] : mod.inPins[idx].value
                            // An input can be driven by hand: clicking its name clears a set pin and sets
                            // a clear one, and an integer pin's value can be typed over. That is how a
                            // `Switch`'s selector or its `X3` values are poked without a wire.
                            SignalRow(name: ModulePinCatalog.inputPinFullName(for: mod, index: idx),
                                      value: PinDisplay.inputText(val, index: idx, guid: mod.guid),
                                      isHigh: val.asBool,
                                      onToggle: { model.toggleModuleInput(moduleId: mod.id, pinIndex: idx) },
                                      number: Self.editableNumber(model: model, module: mod, index: idx, value: val),
                                      isInput: true, owner: mod.id, pin: idx)
                                .equatable()
                                .id("\(mod.id).in.\(idx)")
                        }
                    }
                }

                if !mod.outPins.isEmpty {
                    InspectorCard(title: "Outputs") {
                        InspectorRows(count: mod.outPins.count) { idx in
                            let val = node?.block.outPins.indices.contains(idx) == true
                                ? node!.block.outPins[idx] : .bool(false)
                            // An `IntVar`'s output *is* the variable, so it can be typed over like an input.
                            SignalRow(name: ModulePinCatalog.outputPinFullName(for: mod, index: idx),
                                      value: val.description,
                                      isHigh: val.asBool,
                                      number: Self.editableVariable(model: model, module: mod, value: val),
                                      owner: mod.id, pin: idx)
                                .equatable()
                                .id("\(mod.id).out.\(idx)")
                        }
                    }
                }

                if !mod.paramPins.isEmpty {
                    InspectorCard(title: "Parameters") {
                        InspectorRows(count: mod.paramPins.count) { idx in
                            let pVal = node?.block.paramPins.indices.contains(idx) == true
                                ? node!.block.paramPins[idx] : mod.paramPins[idx].value
                            LabeledContent(ModulePinCatalog.paramPinFullName(for: mod, index: idx)) {
                                ParamValueField(model: model, moduleId: mod.id, index: idx, current: pVal.description)
                                    .id("\(mod.id).par.\(idx)")
                            }
                        }
                    }
                }

                // Advanced, so collapsed until asked for; the choice is remembered across blocks and launches.
                InspectorCard(title: "Details", isExpanded: $showDetails) {
                    // The implementation row is there only when it differs from the class.
                    let hasImplementation = info?.delphiClass != nil && info?.delphiClass != blockTypeName
                    InspectorRows(count: hasImplementation ? 7 : 6) { position in
                        let row = (!hasImplementation && position >= 1) ? position + 1 : position
                        switch row {
                        case 0:
                            // The class that implements the block. Selectable, because it is what gets pasted
                            // into a bug report or a note about the port.
                            LabeledContent("Dirigo Class") {
                                Text(info?.delphiClass ?? blockTypeName)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        case 1:
                            LabeledContent("Implementation") {
                                Text(blockTypeName)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        case 2: LabeledContent("Module ID", value: "\(mod.id)")
                        // Both are document data that drive the engine's schedule, so they are edited
                        // here rather than in a second set of fields elsewhere in the inspector.
                        case 3: LabeledContent("Execution Order") { Self.field(orderBinding(mod)) }
                        case 4: LabeledContent("Thread ID") { Self.field(threadBinding(mod)) }
                        case 5: LabeledContent("Page", value: mod.page)
                        default: LabeledContent("Position", value: "(\(Int(mod.x)), \(Int(mod.y)))")
                        }
                    }
                }
            }
        } else if let entry = selectedAnnotation {
            AnnotationInspector(model: model, index: entry.index)
        } else if let extras = model.project?.maraflow {
            MaraflowExtrasInspector(extras: extras)
        } else {
            ContentUnavailableView {
                Label("No Selection", systemImage: "cursorarrow.click.2")
            } description: {
                Text("Select a block, a shape or a text object to see what it is.")
            }
        }
    }

    /// The selected drawn object, when it is on the page being shown.
    ///
    /// Shapes and text share one array, so one index names either; the page check is what stops a
    /// selection made on one page from being inspected — and edited — while another is on screen.
    private var selectedAnnotation: (index: Int, graphic: ProjectGraphic)? {
        guard let index = model.selectedAnnotationIndex,
              let graphics = model.project?.graphics,
              graphics.indices.contains(index) else { return nil }
        let graphic = graphics[index]
        guard graphic.page == model.selectedPage else { return nil }
        return (index, graphic)
    }

    /// A typed-in value for an `IntVar`'s output: the variable itself, which nothing else can change by hand.
    static func editableVariable(model: AppModel, module: PCCModule, value: PinValue) -> Binding<Int>? {
        guard BlockRole.isIntVariable(module) else { return nil }
        return Binding(
            get: {
                // The variable's value is its output: the core keeps the two together.
                model.getNode(id: module.id)?.block.outPins.first?.asInt ?? value.asInt
            },
            set: { model.setVariableValue(moduleId: module.id, value: $0) })
    }

    /// A typed-in value for an input pin that holds an integer.
    ///
    /// Boolean and Float pins are shown rather than edited: a click already toggles those, and a text
    /// field over a Float would be a different control with different rules.
    static func editableNumber(model: AppModel, module: PCCModule, index: Int,
                               value: PinValue) -> Binding<Int>? {
        func kind(_ int: Int) -> PinValue {
            switch value {
            case .int16: return .int16(Int16(truncatingIfNeeded: int))
            case .int64: return .int64(Int64(int))
            default: return .int32(Int32(truncatingIfNeeded: int))
            }
        }
        switch value {
        case .int16, .int32, .int64:
            return Binding(
                get: {
                    guard let node = model.getNode(id: module.id),
                          node.block.inPins.indices.contains(index) else { return value.asInt }
                    return node.block.inPins[index].asInt
                },
                set: { model.setModuleInput(moduleId: module.id, pinIndex: index, value: kind($0)) })
        default:
            return nil
        }
    }

    /// A small typed field. Both edits go through the model, which clamps the value and rebuilds
    /// the runtime — the schedule is keyed by thread and sorted by order.
    fileprivate static func field(_ value: Binding<Int>) -> some View {
        TextField("", value: value, format: .number)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .font(.system(.body, design: .monospaced))
            // A fixed width, not a minimum: `LabeledContent` hands its content the whole trailing
            // space, so a minimum let the field stretch across the row.
            .frame(width: 72, alignment: .trailing)
            .controlSize(.small)
    }

    /// The same field for a canvas coordinate, which is not whole.
    fileprivate static func field(_ value: Binding<Double>) -> some View {
        TextField("", value: value, format: .number.precision(.fractionLength(0...1)))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .font(.system(.body, design: .monospaced))
            .frame(width: 72, alignment: .trailing)
            .controlSize(.small)
    }

    private func orderBinding(_ mod: PCCModule) -> Binding<Int> {
        Binding(get: { model.module(id: mod.id)?.order ?? mod.order },
                set: { model.updateModuleOrder(id: mod.id, order: $0) })
    }

    private func threadBinding(_ mod: PCCModule) -> Binding<Int> {
        Binding(get: { model.module(id: mod.id)?.threadId ?? mod.threadId },
                set: { model.updateModuleThread(id: mod.id, threadId: $0) })
    }

    /// The glyph for a block type. One `switch` for the whole app: the palette, the cards and the
    /// inspector all ask for the same symbols, so a type never wears two different icons.
    static func iconForBlockType(_ typeName: String) -> String {
        switch typeName.uppercased() {
        case "AND", "OR", "XOR", "NOT", "NAND", "NOR":
            return "point.filled.topleft.down.curvedto.point.bottomright.up"
        case "COUNTER", "COUNTERDOWN", "UPDOWNCOUNTER":
            return "number.circle"
        case "PULSEGEN", "SINGLEPULSE":
            return "waveform.path.ecg"
        case "BOOLVAR", "REALVAR", "INTVAR":
            return "switch.2"
        case "ADD", "SUB", "MUL", "DIV":
            return "plus.forwardslash.minus"
        case "COMPARE", "GREATER", "LESS", "EQUAL":
            return "equal.circle"
        case "TIMERTON", "TIMERTOF", "TIMERTP":
            return "timer"
        case "DISPLAY", "SEGMENTDISPLAY":
            return "gauge.with.needle"
        default:
            return "cpu"
        }
    }
}

// MARK: - Glass cards

/// The inspector's column: cards of glass on a scrolling stack, in place of the system's grouped form.
struct InspectorStack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .labeledContentStyle(TrailingValueStyle())
        }
    }
}

/// A label on the left and its value on the right, as a grouped form lays out a `LabeledContent`; outside a form the system sets the
/// value right beside the label.
private struct TrailingValueStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.label
            Spacer(minLength: 8)
            configuration.content
        }
    }
}

/// One card of the inspector: its title *inside* it, then its rows. With `isExpanded` the title is a button that folds the card.
struct InspectorCard<Content: View>: View {
    var title: String?
    var isExpanded: Binding<Bool>?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                if let isExpanded {
                    Button {
                        withAnimation(.smooth(duration: 0.2)) { isExpanded.wrappedValue.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                            Text(title)
                            Spacer(minLength: 0)
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(isExpanded.wrappedValue ? "expanded" : "collapsed")
                } else {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            if isExpanded?.wrappedValue ?? true {
                content
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 18)
    }
}

/// A card's `count` rows with a hairline between them. Every index must draw something: a card with an optional row counts only the rows it has.
struct InspectorRows<Row: View>: View {
    let count: Int
    @ViewBuilder let row: (Int) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                row(index)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if index < count - 1 { Divider().opacity(0.6) }
            }
        }
    }
}

// MARK: - The block header

/// The block's identity, its one-line description, and the actions that act on it.
///
/// `Equatable` over the data alone — the two closures are excluded, as `ModuleCardView` does — so a
/// simulation tick, which changes the pin values below it, does not re-render the header.
///
/// It draws no background: it sits in an `InspectorCard`, which is the container. Internal rather than private so a
/// snapshot render can draw it on its own.
struct InspectorHero: View, Equatable {
    let name: String
    let blockName: String
    let category: String
    let summary: String
    let symbol: String
    let tint: Color
    let isSimulated: Bool
    let onToggleFirstInput: () -> Void
    let onReset: () -> Void
    var onConfigure: () -> Void = {}

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name
            && lhs.blockName == rhs.blockName
            && lhs.category == rhs.category
            && lhs.summary == rhs.summary
            && lhs.symbol == rhs.symbol
            && lhs.tint == rhs.tint
            && lhs.isSimulated == rhs.isSimulated
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                BlockGlyph(symbol: symbol, tint: tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // Type and category on one quiet line. The category is plain text: it labels the
                    // block, so it does not need to look like something to click.
                    Text(category.isEmpty ? blockName : "\(blockName) · \(category)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }

            if !summary.isEmpty {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !isSimulated {
                Label("Not simulated — no implementation for this block type yet.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GlassGroup(spacing: 6) {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        Button(action: onConfigure) { Text("Configure…").frame(maxWidth: .infinity) }
                            .help("Opens the module's settings.")
                        Button {
                            NotificationCenter.default.post(name: .showHelp, object: nil, userInfo: ["block": blockName])
                        } label: { Text("Help").frame(maxWidth: .infinity) }
                            .help("Opens this block type's page in the block reference.")
                    }
                    GridRow {
                        Button(action: onToggleFirstInput) { Text("Toggle In 0").frame(maxWidth: .infinity) }
                            .help("Flips the block's first input pin, so a triggered block can be stepped by hand.")
                        Button(action: onReset) { Text("Reset").frame(maxWidth: .infinity) }
                            .help("Resets the block's internal state to its initial value.")
                    }
                }
                .glassButtonStyle()
                .controlSize(.small)
            }
            .padding(.top, 2)
        }
        // No container of its own: the card it sits in is the container.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The block's icon: a flat tinted tile with a white glyph and a hairline edge.
///
/// The earlier version put the tile through `glassPanel` with a shadow, which read as an app icon — a
/// glossy, raised square. This is the sidebar-badge treatment instead: flat fill, one hairline, no
/// shadow, so it sits on the card rather than above it.
struct BlockGlyph: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - One signal

/// A pin's name and its live value.
///
/// Its own `Equatable` view because the value is the only thing a tick changes: the inspector sits open
/// during simulation, and this keeps a tick from re-rendering every other row on the panel.
struct SignalRow: View, Equatable {
    let name: String
    let value: String
    let isHigh: Bool
    /// Present for an input pin: clicking the name clears it, clicking again sets it.
    var onToggle: (() -> Void)?
    /// Present for an integer input pin: its value can be typed over.
    var number: Binding<Int>?
    /// Whether this is an input row. A plain `Bool`, because this is what `==` compares: the closure above
    /// is main-actor isolated and cannot be read from a nonisolated comparison.
    var isInput: Bool = false
    /// The module this row belongs to, and its pin. Part of what `==` compares: without it, selecting another block
    /// whose row reads the same (`X`, `0`) was "equal", so SwiftUI kept the old row — its closures pointing at the
    /// *previous* block — and a number typed there was written to the wrong module, or looked as if it had not been.
    var owner: Int = 0
    var pin: Int = 0

    /// Whether the value is currently a field rather than text. Purely local: the row rests as text so
    /// it is laid out like every other row, and becomes a field for as long as it is being edited.
    @State private var isEditing = false
    /// What has been typed so far. The field edits this text, not the value: `TextField(value:format:)` commits
    /// only on Return or on losing focus, and this row removes the field the moment either happens — so the
    /// typed number could be discarded before the commit and the value fell back to what it was.
    @State private var draft = ""
    @State private var isHovering = false
    @FocusState private var isEditingFocused: Bool

    /// Writes what was typed, if it is a whole number, and closes the field. Anything else is dropped and the
    /// row shows the value it had.
    private func commit() {
        guard isEditing else { return }
        isEditing = false
        // A whole number, in decimal or as `0x…` / `$…` (which is how a `SystemCmd`'s command word is shown).
        let text = draft.trimmingCharacters(in: .whitespaces)
        if let typed = Int(text) {
            number?.wrappedValue = typed
        } else if case .int32(let word) = PinValue.parse(text) {
            number?.wrappedValue = Int(word)
        }
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.owner == rhs.owner && lhs.pin == rhs.pin
            && lhs.name == rhs.name && lhs.value == rhs.value && lhs.isHigh == rhs.isHigh
            && lhs.isInput == rhs.isInput
            && (lhs.number == nil) == (rhs.number == nil)
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Circle()
                    .fill(isHigh ? Theme.signalHigh : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
                if number != nil {
                    // One chip, resting or editing. The resting text sizes it; while editing, the field is laid *over*
                    // that text, which is hidden but still there to give the chip its size. Swapping a `TextField` in
                    // for the text changed the row's width and height — a `TextField` in a `Form` reserves the
                    // standard control height — and moved everything beside it.
                    Text(value)
                        .font(.system(.body, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(isHigh ? .primary : .secondary)
                        .opacity(isEditing ? 0 : 1)
                        .frame(minWidth: valueChipWidth(for: value), alignment: .trailing)
                        .padding(.horizontal, 4)
                        .background(Color.primary.opacity(isEditing || isHovering ? 0.16 : 0.08),
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay {
                            if isEditing {
                                TextField("", text: $draft)
                                    .textFieldStyle(.plain)
                                    .multilineTextAlignment(.trailing)
                                    .font(.system(.body, design: .monospaced))
                                    .monospacedDigit()
                                    .focused($isEditingFocused)
                                    .padding(.horizontal, 4)
                                    .onSubmit { commit() }
                                    // Focus after the field exists rather than in the same update that creates it,
                                    // which is what makes the caret land in it reliably.
                                    .task { isEditingFocused = true }
                                    .onChange(of: isEditingFocused) { _, focused in
                                        if !focused { commit() }
                                    }
                            }
                        }
                        .contentShape(Rectangle())
                        .onHover { isHovering = $0 }
                        .onTapGesture {
                            guard !isEditing else { return }
                            draft = value
                            isEditing = true
                        }
                        .help(isInput ? "Click to edit this input." : "Click to set this variable.")
                } else {
                    Text(value)
                        .font(.system(.body, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(isHigh ? .primary : .secondary)
                        .textSelection(.enabled)
                }
            }
        } label: {
            if let onToggle {
                // A tap gesture rather than a `Button`: a button brings its own metrics, which pushed the
                // label off the value's baseline. This keeps the row laid out exactly like a read-only one
                // while still being clickable.
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onToggle)
                    .help("Click to set this input to 0, and again to 1.")
            } else {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

/// A parameter's value, typed over. The number is written to the block as it is typed — a half-typed `-` waits —
/// so there is no Return to forget and no OK to press.
struct ParamValueField: View {
    @Bindable var model: AppModel
    let moduleId: Int
    let index: Int
    let current: String
    @State private var draft: String?

    var body: some View {
        // The same chip as a signal row's value: its text sizes it and the field lies over that, so typing does not
        // change the row's width or height (a bordered `TextField` in a `Form` is taller than the text beside it).
        Text(current)
            .font(.system(.body, design: .monospaced))
            .monospacedDigit()
            .opacity(0)
            .frame(minWidth: valueChipWidth(for: current), alignment: .trailing)
            .padding(.horizontal, 4)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                TextField("", text: Binding(
                    get: { draft ?? current },
                    set: { text in
                        draft = text
                        if let number = Int32(text.trimmingCharacters(in: .whitespaces)) {
                            model.updateModuleParam(id: moduleId, paramIndex: index, value: .int32(number))
                        }
                    }))
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 4)
                    .onSubmit { draft = nil }
            }
            // What was typed has been written; from then on the field shows the block's own value, so a change from
            // the simulation or from another editor is not hidden behind the old text.
            .onChange(of: current) { _, _ in
                if let typed = draft, Int32(typed.trimmingCharacters(in: .whitespaces)) != nil { draft = nil }
            }
    }
}

/// The width a value chip reserves for `text`, in the monospaced body font: wide enough that a value changing by a
/// digit does not make the row jump, and never narrower than a short one needs to be a click target.
private func valueChipWidth(for text: String) -> CGFloat {
    max(30, CGFloat(text.count) * 8.5 + 12)
}

// MARK: - The drawn-object inspector

/// The inspector for what the sheet draws that is not a block: a rectangle, a circle or a text chip.
///
/// A block's inspector is signals and parameters, because that is what a block *does*. These have no
/// signals; what they have is the document's own description of them — where they are, how they are
/// drawn, and for text what they say — so that is what is shown, and every row of it is editable,
/// because all of it is ordinary `.pcc` data rather than runtime state.
struct AnnotationInspector: View {
    @Bindable var model: AppModel
    let index: Int

    @State private var textDraft: String?

    /// The live object, re-read on every render so a drag on the canvas shows up here as it happens.
    private var graphic: ProjectGraphic? {
        guard let project = model.project, project.graphics.indices.contains(index) else { return nil }
        return project.graphics[index]
    }

    var body: some View {
        if let graphic {
            InspectorStack {
                InspectorCard {
                    HStack {
                        Label(title(of: graphic), systemImage: icon(of: graphic))
                            .font(.headline)
                        Spacer()
                        Text(graphic.page)
                            .foregroundStyle(.secondary)
                    }
                }

                if graphic.isShape, graphic.boundingBox != nil {
                    InspectorCard(title: "Geometry") {
                        InspectorRows(count: 4) { row in
                            switch row {
                            case 0: LabeledContent("X") { InspectorView.field(boxComponent(\.x)) }
                            case 1: LabeledContent("Y") { InspectorView.field(boxComponent(\.y)) }
                            case 2: LabeledContent("Width") { InspectorView.field(boxComponent(\.width)) }
                            default: LabeledContent("Height") { InspectorView.field(boxComponent(\.height)) }
                            }
                        }
                    }

                    InspectorCard(title: "Pen") {
                        InspectorRows(count: 2) { row in
                            if row == 0 {
                                LabeledContent("Colour") {
                                    ColorPicker("", selection: penColor, supportsOpacity: false).labelsHidden()
                                }
                            } else {
                                LabeledContent("Width") { InspectorView.field(penWidth) }
                            }
                        }
                    }

                    InspectorCard(title: "Brush") {
                        // A clear brush has no colour to pick, so then there is only the one row.
                        InspectorRows(count: graphic.brushStyle != 1 ? 2 : 1) { row in
                            if row == 0 {
                                Picker("Fill", selection: brushStyle) {
                                    Text("None").tag(1)
                                    Text("Solid").tag(0)
                                }
                            } else {
                                // A clear brush has no colour to pick; showing one would edit bytes the file
                                // draws nothing from.
                                LabeledContent("Colour") {
                                    ColorPicker("", selection: brushColor, supportsOpacity: false).labelsHidden()
                                }
                            }
                        }
                    }
                }

                if graphic.objectKind != .text {
                    InspectorCard(title: "Output binding") {
                        Picker("Module", selection: bindingModule) {
                            Text("None").tag(Int?.none)
                            ForEach(pageModules, id: \.id) { module in
                                Text(module.name).tag(Optional(module.id))
                            }
                        }
                        Picker("Output pin", selection: bindingPin) {
                            Text("None").tag(Int?.none)
                            if let module = boundModule {
                                ForEach(module.outPins.indices, id: \.self) { pin in
                                    Text(ModulePinCatalog.outputPinLabel(for: module, index: pin))
                                        .tag(Optional(pin))
                                }
                            }
                        }
                        .disabled(boundModule == nil)
                        if boundModule != nil {
                            Toggle("Custom threshold", isOn: customHigh)
                            if graphic.highValue != nil {
                                LabeledContent("Active at") {
                                    TextField("High", value: highValue, format: .number)
                                        .frame(width: 70)
                                }
                            }
                            LabeledContent("Active pen") {
                                ColorPicker("", selection: activePenColor, supportsOpacity: false).labelsHidden()
                            }
                            LabeledContent("Active brush") {
                                ColorPicker("", selection: activeBrushColor, supportsOpacity: false).labelsHidden()
                            }
                            Button("Clear Connection", role: .destructive) {
                                model.updateGraphic(at: index) {
                                    $0.inputModuleId = nil
                                    $0.inputPinId = nil
                                }
                            }
                            Text("The object paints with the active colours while the connected output is above the threshold.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Connect an output to make this object a live indicator.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if graphic.text != nil {
                    InspectorCard(title: "Text") {
                        InspectorRows(count: 5) { row in
                            switch row {
                            case 0:
                                TextField("Text", text: Binding(get: { textDraft ?? graphic.text ?? "" },
                                                                set: { textDraft = $0 }),
                                          axis: .vertical)
                                    .onSubmit(commitText)
                            case 1: LabeledContent("Size") { InspectorView.field(fontSize) }
                            case 2: Toggle("Bold", isOn: fontFlag(\.fontBold))
                            case 3: Toggle("Italic", isOn: fontFlag(\.fontItalic))
                            default:
                                LabeledContent("Colour") {
                                    ColorPicker("", selection: fontColor, supportsOpacity: false).labelsHidden()
                                }
                            }
                        }
                    }
                }

                InspectorCard(title: "Details") {
                    InspectorRows(count: 2) { row in
                        if row == 0 { LabeledContent("Index", value: "\(index)") }
                        else { LabeledContent("Type", value: "\(graphic.type)") }
                    }
                }
            }
            // A fresh draft per object: text typed for one must not appear in the next.
            .id(index)
            .onAppear { textDraft = nil }
        }
    }

    /// Writes the text field back. An empty string is refused by the model — the object would still be
    /// in the document but draw nothing — so the draft is dropped and the stored text reappears.
    /// Modules on the object's page that could own the output it displays.
    private var pageModules: [PCCModule] {
        guard let project = model.project, let graphic else { return [] }
        return project.modules.filter { $0.page == graphic.page && !BlockRole.isMaraflowPageRuntime($0) }
    }

    private var boundModule: PCCModule? {
        guard let id = graphic?.inputModuleId else { return nil }
        return pageModules.first { $0.id == id }
    }

    private var bindingModule: Binding<Int?> {
        Binding(get: { graphic?.inputModuleId }, set: { newValue in
            model.updateGraphic(at: index) { g in
                g.inputModuleId = newValue
                if let newValue, let module = model.project?.modules.first(where: { $0.id == newValue }),
                   !module.outPins.isEmpty {
                    g.inputPinId = 0
                } else {
                    g.inputPinId = nil
                }
            }
        })
    }

    private var bindingPin: Binding<Int?> {
        Binding(get: { graphic?.inputPinId }, set: { newValue in
            model.updateGraphic(at: index) { $0.inputPinId = newValue }
        })
    }

    private var customHigh: Binding<Bool> {
        Binding(get: { graphic?.highValue != nil }, set: { on in
            model.updateGraphic(at: index) { $0.highValue = on ? 1 : nil }
        })
    }

    private var highValue: Binding<Double> {
        Binding(get: { graphic?.highValue ?? 1 }, set: { value in
            model.updateGraphic(at: index) { $0.highValue = value }
        })
    }

    private var activePenColor: Binding<Color> {
        Binding(get: { graphic.map { GraphicColor.activePen(of: $0) } ?? .primary },
                set: { color in model.updateGraphic(at: index) { $0.activePenColor = GraphicColor.encode(color) } })
    }

    private var activeBrushColor: Binding<Color> {
        Binding(get: { graphic.map { GraphicColor.activeBrush(of: $0) } ?? .red },
                set: { color in model.updateGraphic(at: index) { $0.activeBrushColor = GraphicColor.encode(color) } })
    }

    private func commitText() {
        guard let draft = textDraft else { return }
        model.updateAnnotationText(at: index, text: draft)
        textDraft = nil
    }

    private func title(of graphic: ProjectGraphic) -> String {
        switch graphic.objectKind {
        case .rectangle: return "Rectangle"
        case .ellipse: return "Circle"
        case .line: return "Line"
        case .text: return "Text"
        default: return "Object"
        }
    }

    private func icon(of graphic: ProjectGraphic) -> String {
        switch graphic.objectKind {
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .text: return "textformat"
        default: return "square.dashed"
        }
    }

    /// One corner of the stored box. Edits go through `updateShape`, the same door the canvas's drag
    /// and resize use, so a typed position is clamped to the sheet and snapped like a dragged one.
    private func boxComponent(_ keyPath: WritableKeyPath<GraphicBox, Double>) -> Binding<Double> {
        Binding(get: {
            graphic?.boundingBox?[keyPath: keyPath] ?? 0
        }, set: { newValue in
            guard let current = graphic?.boundingBox else { return }
            var box = current
            box[keyPath: keyPath] = newValue
            model.updateShape(at: index, to: box)
        })
    }

    private var penColor: Binding<Color> {
        Binding(get: { graphic.flatMap { GraphicColor.decode($0.penColor) }?.color ?? .primary },
                set: { color in model.updateGraphic(at: index) { $0.penColor = GraphicColor.encode(color) } })
    }

    private var penWidth: Binding<Int> {
        Binding(get: { graphic?.penWidth ?? 1 },
                set: { width in model.updateGraphic(at: index) { $0.penWidth = max(1, width) } })
    }

    private var brushStyle: Binding<Int> {
        Binding(get: { graphic?.brushStyle ?? 1 },
                set: { style in model.updateGraphic(at: index) { $0.brushStyle = style } })
    }

    private var brushColor: Binding<Color> {
        Binding(get: { graphic.flatMap { GraphicColor.decode($0.brushColor) }?.color ?? .clear },
                set: { color in model.updateGraphic(at: index) { $0.brushColor = GraphicColor.encode(color) } })
    }

    private var fontSize: Binding<Int> {
        Binding(get: { graphic?.fontSize ?? 11 },
                set: { size in model.updateGraphic(at: index) { $0.fontSize = max(4, size) } })
    }

    private var fontColor: Binding<Color> {
        Binding(get: { graphic.flatMap { GraphicColor.decode($0.fontColor) }?.color ?? .primary },
                set: { color in model.updateGraphic(at: index) { $0.fontColor = GraphicColor.encode(color) } })
    }

    private func fontFlag(_ keyPath: WritableKeyPath<ProjectGraphic, Bool?>) -> Binding<Bool> {
        Binding(get: { graphic?[keyPath: keyPath] ?? false },
                set: { on in model.updateGraphic(at: index) { $0[keyPath: keyPath] = on } })
    }
}
