import SwiftUI
import DirigoCore
import DirigoLibrary
import DirigoEngine

/// The inspector sidebar: what the selected block is, what its pins are doing, and how to configure it.
///
/// The sections are separate views rather than computed properties, because the signal rows change at the
/// simulation rate while the header does not: with the header in its own `Equatable` view, a tick
/// invalidates the rows whose values moved and leaves the rest — including the whole hero — alone.
public struct InspectorView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        if let modId = model.selectedModuleId,
           let mod = model.project?.modules.first(where: { $0.id == modId }) {
            let node = model.getNode(id: modId)
            let blockTypeName = node != nil ? type(of: node!.block).typeName : mod.name
            let info = BlockTypeCatalog.info(forGuid: mod.guid)

            Form {
                Section {
                    InspectorHero(
                        name: mod.name,
                        blockName: info?.blockName ?? blockTypeName,
                        category: info?.category ?? "",
                        summary: info?.summary ?? "",
                        symbol: Self.iconForBlockType(blockTypeName),
                        tint: Theme.tint(forCategory: info?.category ?? ""),
                        isSimulated: !(node?.block is UnresolvedBlock),
                        onToggleFirstInput: { model.toggleModuleInput(moduleId: mod.id, pinIndex: 0) },
                        onReset: {
                            node?.block.reset()
                            model.simulationDidChange()
                        })
                        .equatable()
                }

                // Inputs and outputs are separate sections rather than one list: a sheet may name a pin
                // on each side the same thing (a macro's `PN` does), and in one list that reads as a
                // duplicated row rather than as two pins.
                if mod.inPins.isEmpty && mod.outPins.isEmpty {
                    Section("Signals") {
                        Text("No signals connected")
                            .foregroundStyle(.secondary)
                    }
                }

                if !mod.inPins.isEmpty {
                    Section("Inputs") {
                        ForEach(0..<mod.inPins.count, id: \.self) { idx in
                            let val = node?.block.inPins.indices.contains(idx) == true
                                ? node!.block.inPins[idx] : mod.inPins[idx].value
                            // An input can be driven by hand: clicking its name clears a set pin and sets
                            // a clear one, and an integer pin's value can be typed over. That is how a
                            // `Switch`'s selector or its `X3` values are poked without a wire.
                            SignalRow(name: ModulePinCatalog.inputPinFullName(for: mod, index: idx),
                                      value: val.description,
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
                    Section("Outputs") {
                        ForEach(0..<mod.outPins.count, id: \.self) { idx in
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
                    Section("Parameters") {
                        ForEach(0..<mod.paramPins.count, id: \.self) { idx in
                            let pVal = node?.block.paramPins.indices.contains(idx) == true
                                ? node!.block.paramPins[idx] : mod.paramPins[idx].value
                            LabeledContent(ModulePinCatalog.paramPinFullName(for: mod, index: idx)) {
                                ParamValueField(model: model, moduleId: mod.id, index: idx, current: pVal.description)
                                    .id("\(mod.id).par.\(idx)")
                            }
                        }
                    }
                }

                Section("Details") {
                    // The class that implements the block. Selectable, because it is what gets pasted
                    // into a bug report or a note about the port.
                    LabeledContent("Dirigo Class") {
                        Text(info?.delphiClass ?? blockTypeName)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if info?.delphiClass != nil, info?.delphiClass != blockTypeName {
                        LabeledContent("Implementation") {
                            Text(blockTypeName)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }

                    LabeledContent("Module ID", value: "\(mod.id)")
                    // Both are document data that drive the engine's schedule, so they are edited
                    // here rather than in a second set of fields elsewhere in the inspector.
                    LabeledContent("Execution Order") { field(orderBinding(mod)) }
                    LabeledContent("Thread ID") { field(threadBinding(mod)) }
                    LabeledContent("Page", value: mod.page)
                    LabeledContent("Position", value: "(\(Int(mod.x)), \(Int(mod.y)))")

                    Button {
                        model.openConfigureModule(id: mod.id)
                    } label: {
                        Label("Configure Module…", systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView {
                Label("No Selection", systemImage: "cursorarrow.click.2")
            } description: {
                Text("Select a function block on the canvas to inspect its signals and parameters.")
            }
        }
    }

    /// A typed-in value for an `IntVar`'s output: the variable itself, which nothing else can change by hand.
    static func editableVariable(model: AppModel, module: PCCModule, value: PinValue) -> Binding<Int>? {
        guard model.getNode(id: module.id)?.block is IntVarBlock else { return nil }
        return Binding(
            get: {
                (model.getNode(id: module.id)?.block as? IntVarBlock).map { Int($0.currentValue) } ?? value.asInt
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
    private func field(_ value: Binding<Int>) -> some View {
        TextField("", value: value, format: .number)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .font(.system(.body, design: .monospaced))
            // A fixed width, not a minimum: `LabeledContent` hands its content the whole trailing
            // space, so a minimum let the field stretch across the row.
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

// MARK: - The block header

/// The block's identity, its one-line description, and the two actions that poke it.
///
/// `Equatable` over the data alone — the two closures are excluded, as `ModuleCardView` does — so a
/// simulation tick, which changes the pin values below it, does not re-render the header.
///
/// It draws no background: it is the grouped form's first row, which is the container. Internal rather
/// than private so a snapshot render can draw it on its own — a grouped `Form` has no layout without a
/// window.
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 11) {
                BlockGlyph(symbol: symbol, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(blockName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        CategoryChip(category: category, tint: tint)
                    }
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

            HStack(spacing: 8) {
                Button(action: onToggleFirstInput) {
                    Label("Toggle In 0", systemImage: "bolt.fill")
                }
                .help("Flips the block's first input pin, so a triggered block can be stepped by hand.")
                Button(action: onReset) {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .help("Resets the block's internal state to its initial value.")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        // No container of its own: the header is the first row of the grouped form, so it lines up with
        // the sections below it instead of floating above them in a panel of its own.
        .padding(.vertical, 10)
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

/// The block's category, as a chip rather than a coloured word: the tint marks the chip's text, and the
/// fill stays neutral so a row of chips reads as labels instead of decoration.
struct CategoryChip: View {
    let category: String
    let tint: Color

    var body: some View {
        if !category.isEmpty {
            Text(category)
                .font(.caption2.weight(.medium))
                .foregroundStyle(tint)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
                .accessibilityLabel("Category: \(category)")
        }
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
        if let typed = Int(draft.trimmingCharacters(in: .whitespaces)) { number?.wrappedValue = typed }
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
