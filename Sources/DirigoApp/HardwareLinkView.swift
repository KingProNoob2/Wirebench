import SwiftUI
import AppKit

/// The sidebar's *Hardware Link* block:
///
///     ● Not connected              ⟳  [Connect]      ← the link, a rescan, and its button
///     [ cu.usbserial-110 ⌄ ]                          ← only when there is a port to pick
///     [          Build Project           ]            ← the section's main action
///     ✓ Upload complete · 100%                        ← only once something has happened
///     › Log                                 24        ← only once there is a log
///
/// Nothing is shown that has nothing to say: an idle upload line and an empty log were two rows of
/// placeholder text under every project.
struct HardwareLinkSection: View {
    @Bindable var model: AppModel
    /// Remembered, so the log is where it was left.
    @AppStorage("hardware.showLog") private var showingLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusRow
            if !model.availablePorts.isEmpty { portPicker }
            actions
            if outcome != .idle { uploadStatus }
            if !model.uploadLog.isEmpty { log }
        }
        .controlSize(.small)
        // `refreshPorts` is the only thing that fills `availablePorts`; re-reading on appear also picks up
        // an adapter plugged in after launch.
        .onAppear { model.refreshPorts() }
    }

    // MARK: - The link

    private var statusText: String {
        if model.isHardwareConnected { return "Connected" }
        return model.availablePorts.isEmpty ? "No serial port" : "Not connected"
    }

    /// Status, rescan, and the link's own small button — the link is a setting, not the main action.
    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isHardwareConnected ? Theme.signalHigh : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.callout)
                .foregroundStyle(model.isHardwareConnected ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                model.refreshPorts()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Rescan for serial adapters")
            .accessibilityLabel("Rescan serial ports")
            if model.isHardwareConnected {
                Button("Disconnect") { model.disconnectHardware() }
            } else {
                Button("Connect") { model.connectHardware() }
                    .disabled(model.availablePorts.isEmpty)
            }
        }
    }

    private var portPicker: some View {
        Picker("Serial Port", selection: $model.selectedPortPath) {
            ForEach(model.availablePorts) { port in
                Text(port.name).tag(port.path)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(model.isHardwareConnected)
    }

    /// The section's main action, full width. The frame is on the label, not the button: a frame around
    /// a macOS button only pads it, while a wide label stretches the bezel itself.
    private var actions: some View {
        Button {
            model.buildAndShowReport()
        } label: {
            // Named as in the Build menu, so the same action reads the same everywhere.
            Text("Build Project")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(model.project == nil)
        .padding(.top, 6)
        // The report it opens has Upload to PLC and the exports.
        .help("Build the project and show the report, with Upload to PLC (⌘B)")
    }

    // MARK: - The upload

    private enum Outcome { case idle, info, running, done, failed }

    private var outcome: Outcome {
        if model.isUploading { return .running }
        if model.uploadPhase.hasPrefix("Upload failed") { return .failed }
        if model.uploadPhase.hasPrefix("Upload complete") { return .done }
        // A message from before an upload started (no serial link, a file being read) is still worth a line.
        if !model.uploadPhase.isEmpty || !model.uploadStatus.isEmpty { return .info }
        return .idle
    }

    private var headline: String {
        model.uploadPhase.isEmpty ? model.uploadStatus : model.uploadPhase
    }

    private var uploadStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                outcomeIcon
                // Selectable, so an error can be copied into a report.
                Text(headline)
                    .foregroundStyle(outcome == .failed ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .font(.caption)
            if outcome == .running, let progress = model.uploadProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }
        }
    }

    @ViewBuilder
    private var outcomeIcon: some View {
        switch outcome {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.signalHigh)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .running:
            ProgressView().controlSize(.mini)
        case .idle, .info:
            EmptyView()
        }
    }

    // MARK: - The log

    /// The system disclosure triangle, named for what it reveals.
    private var log: some View {
        DisclosureGroup(isExpanded: $showingLog) {
            logBody
                .padding(.top, 4)
        } label: {
            HStack {
                Text("Upload Log")
                Spacer(minLength: 0)
                Text("\(model.uploadLog.count)")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var logBody: some View {
        VStack(alignment: .leading, spacing: 4) {
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
                    .padding(6)
                }
                .frame(maxHeight: 200)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
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
            .font(.caption)
        }
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
