import SwiftUI
import AppKit

/// The sidebar's *Hardware Link* block: the connection and its port, the compile button, and the upload log.
struct HardwareLinkSection: View {
    @Bindable var model: AppModel
    @State private var showingLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            statusRow
            portRow
            // Connect is the call to action until there is a link; once there is, compiling is the next step.
            fullWidthButton(model.isHardwareConnected ? "Disconnect" : "Connect",
                            prominent: !model.isHardwareConnected) {
                if model.isHardwareConnected { model.disconnectHardware() } else { model.connectHardware() }
            }
            .disabled(model.availablePorts.isEmpty)

            // The report this opens has Upload to PLC and the exports, so compile → upload is two clicks.
            fullWidthButton("Compile Project", prominent: model.isHardwareConnected) {
                model.buildAndShowReport()
            }
            .disabled(model.project == nil)

            if !model.uploadStatus.isEmpty {
                Text(model.uploadStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            uploadLog
        }
        .padding(.vertical, 6)
        // `refreshPorts` is the only thing that fills `availablePorts`; re-reading on appear also picks up
        // an adapter plugged in after launch.
        .onAppear { model.refreshPorts() }
    }

    // MARK: - Connection

    private var statusRow: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(model.isHardwareConnected ? Theme.signalHigh : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
                .shadow(color: model.isHardwareConnected ? Theme.signalHigh.opacity(0.8) : .clear, radius: 3)
            Text(model.isHardwareConnected ? "Connected" : "Disconnected")
                .font(.caption.weight(.semibold))
                .foregroundStyle(model.isHardwareConnected ? Theme.signalHigh : .secondary)
            Spacer(minLength: 4)
            if let port = model.availablePorts.first(where: { $0.path == model.selectedPortPath }) {
                Text(port.name)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    /// An empty picker is a dead control; say what is wrong instead — and offer a rescan.
    private var portRow: some View {
        HStack(spacing: 6) {
            if model.availablePorts.isEmpty {
                Text("No serial ports found.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Serial Port", selection: $model.selectedPortPath) {
                    ForEach(model.availablePorts) { port in
                        Text(port.name).tag(port.path)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }
            Spacer(minLength: 2)
            Button {
                model.refreshPorts()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Rescan for serial adapters")
        }
    }

    /// A standard macOS push button. A ternary cannot pick between two button styles, so the two are spelled out.
    @ViewBuilder
    private func fullWidthButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        if prominent {
            Button(action: action) { Text(title).frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        } else {
            Button(action: action) { Text(title).frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
                .controlSize(.regular)
        }
    }

    // MARK: - Upload log

    /// Status and log. The header and status line are always visible — what the upload is doing, and how far —
    /// and the frames and stages open underneath.
    private var uploadLog: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showingLog.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(showingLog ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text("Upload Log").font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    if !model.uploadLog.isEmpty {
                        Text("\(model.uploadLog.count) lines")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(headline)
                .font(.caption2)
                .foregroundStyle(model.uploadPhase.hasPrefix("Upload failed") ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let progress = model.uploadProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }

            if showingLog { logBody }
        }
    }

    @ViewBuilder
    private var logBody: some View {
        if model.uploadLog.isEmpty {
            Text("Nothing has been uploaded yet.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.uploadLog) { entry in
                            Text(entry.text)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(color(for: entry.kind))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                }
                .frame(maxHeight: 200)
                .onChange(of: model.uploadLog.count) {
                    if let last = model.uploadLog.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            HStack(spacing: 10) {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.uploadLogText, forType: .string)
                }
                Button("Clear") { model.clearUploadLog() }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .font(.caption2)
        }
    }

    /// One line in words: the phase and its percentage, or what to do first.
    private var headline: String {
        if !model.uploadPhase.isEmpty { return model.uploadPhase }
        return model.isHardwareConnected ? "Ready — compile, then upload from the report."
                                         : "Not connected — connect to a serial port first."
    }

    private func color(for kind: AppModel.UploadLogEntry.Kind) -> Color {
        switch kind {
        case .stage: return .primary
        case .reply: return Theme.signalHigh
        case .error: return .red
        case .request, .info: return .secondary
        }
    }
}
