import SwiftUI
import WirebenchCore
import WirebenchLibrary
import WirebenchModel

/// *Build ▸ PLC Configuration*: the commands the PLC is sent when the program runs, with what each is and presets for its parameters.
///
/// In Dirigo these are `SystemCmd` blocks on a sheet; here they are a list in the project (`PLCConfiguration`), and *Export Legacy .PCC* writes them
/// back as blocks. A command in the circuit — one wired to something — is still a block and is not listed here.
struct PLCConfigurationView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.plcCommands.isEmpty {
                        Text("No commands. A new project sends the PLC none; add one to set up its pins, for example.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(Array(model.plcCommands.indices), id: \.self) { index in
                        CommandCard(model: model, index: index)
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Button { model.addPLCCommand() } label: { Label("Add Command", systemImage: "plus") }
                    .glassButtonStyle()
                    .disabled(model.systemCommandCatalogue.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .glassButtonStyle(prominent: true)
            }
            .padding(14)
        }
        .frame(width: 600, height: 640)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PLC Configuration").font(.title2.weight(.semibold))
            Text("Commands sent to the PLC's firmware. They are part of the program, run before the circuit, and are written to Dirigo as "
                 + "SystemCmd blocks when you export a legacy .pcc.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.plcProfileNames.isEmpty {
                HStack {
                    Text("Hardware").foregroundStyle(.secondary)
                    Picker("Hardware", selection: Binding(get: { model.plcProfileName }, set: { model.setPLCProfile($0) })) {
                        ForEach(model.plcProfileNames, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    Spacer()
                }
                .padding(.top, 4)
                Text("The commands on offer depend on the hardware.").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(20)
    }
}

/// One command: which it is, and its two parameters.
struct CommandCard: View {
    let model: AppModel
    let index: Int

    private var entry: PCCModule? { model.plcCommands.indices.contains(index) ? model.plcCommands[index] : nil }

    var body: some View {
        if let entry {
            let guide = model.plcGuide(of: entry)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    commandPicker(for: entry, guide: guide)
                    Spacer()
                    Text(String(format: "0x%04X", entry.plcCommandWord)).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                    Button(role: .destructive) { model.removePLCCommand(at: index) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Remove this command")
                }
                if let guide {
                    Text(guide.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(0..<2, id: \.self) { slot in
                        ParameterView(model: model, index: index, which: slot + 1, value: entry.plcParameter(slot + 1), parameter: guide.parameters[slot])
                    }
                } else {
                    Text("This hardware profile does not list command " + String(format: "0x%04X", entry.plcCommandWord) + ". It is kept as it is; pick a command to describe it.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(0..<2, id: \.self) { slot in
                        ParameterView(model: model, index: index, which: slot + 1, value: entry.plcParameter(slot + 1), parameter: .unlisted(slot + 1))
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.10)))
        }
    }

    private func commandPicker(for entry: PCCModule, guide: PLCCommandGuide?) -> some View {
        let catalogue = model.systemCommandCatalogue
        let current = model.plcCommandInfo(of: entry)
        return Menu {
            ForEach(catalogue, id: \.selectionTag) { (info: SystemCommandInfo) in
                let word = String(format: "0x%04X", Int(info.command))
                let label: String = info.title + "  ·  " + word
                Button(label) { model.setPLCCommand(at: index, to: info) }
            }
        } label: {
            Text(current?.title ?? guide?.title ?? "Command").font(.headline)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// One parameter: its name and type, a field, presets, what it is, and for a row of pins a grid of them.
struct ParameterView: View {
    let model: AppModel
    let index: Int
    let which: Int
    let value: Int
    let parameter: PLCCommandGuide.Parameter

    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Par\(which)").font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                Text("\(parameter.name) (\(parameter.dataType))").font(.subheadline.weight(.medium))
                Spacer()
                if parameter.isUsed {
                    TextField("", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .focused($editing)
                        .onSubmit(commit)
                        .onChange(of: editing) { _, focused in if !focused { commit() } }
                    Text(String(format: "0x%X", value)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                    if !parameter.presets.isEmpty {
                        Menu {
                            ForEach(parameter.presets, id: \.label) { preset in
                                Button("\(preset.label)  (\(preset.value))") { model.setPLCParameter(at: index, which, value: preset.value) }
                            }
                        } label: { Text("Presets") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }
            Text(parameter.meaning)
                .font(.callout).foregroundStyle(parameter.isUsed ? .secondary : .tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 42)
            if parameter.isUsed, let bits = parameter.bits {
                PinGrid(bits: bits, value: value) { model.setPLCParameter(at: index, which, value: $0) }
                    .padding(.leading, 42)
            }
        }
        .onAppear { text = String(value) }
        .onChange(of: value) { _, new in if !editing { text = String(new) } }
    }

    /// Takes what was typed, as a decimal, `0x…` or `$…`; anything else puts the value back.
    private func commit() {
        if case .int32(let parsed) = PinValue.parse(text.trimmingCharacters(in: .whitespaces)) {
            model.setPLCParameter(at: index, which, value: Int(parsed))
        }
        text = String(model.plcCommands.indices.contains(index) ? model.plcCommands[index].plcParameter(which) : value)
    }
}

/// A row of pins, highest first as in Dirigo's tutorial, each an input or an output; the pins that cannot change are shown and not clickable.
struct PinGrid: View {
    let bits: PLCCommandGuide.Bits
    let value: Int
    let set: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ForEach((0..<bits.names.count).reversed(), id: \.self) { bit in
                    let fixed = bits.fixed.contains(bit)
                    let isOn = value & (1 << bit) != 0
                    Button {
                        set(value ^ (1 << bit))
                    } label: {
                        VStack(spacing: 2) {
                            Text(String(bit)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                            Text(fixed ? (bit == 0 ? "Tx" : "Rx") : (isOn ? "In" : "Out"))
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 26, height: 20)
                                .background(fixed ? Color.primary.opacity(0.04) : (isOn ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.10)),
                                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(fixed)
                    .help(fixed ? "\(bits.names[bit]) is the serial link and cannot be changed" : "\(bits.names[bit]): \(isOn ? bits.onLabel : bits.offLabel). Click to change.")
                }
            }
            Text("Pin numbers are I/O n. Click a pin to make it an input or an output.").font(.caption).foregroundStyle(.tertiary)
        }
    }
}
