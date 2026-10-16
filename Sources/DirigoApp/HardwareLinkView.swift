import SwiftUI
import AppKit

/// The sidebar's *Hardware Link* block, top to bottom in the order the work happens:
///
///     ● Connected                       [Disconnect]      ← the link
///     cu.usbserial-110 ⌃⌄                       ⟳
///     [          Compile Project          ]               ← the one big action
///     ──────────────────────────────────────
///     ✓ Upload complete · 100%                            ← what the last upload did
///     ▸ Log                                    24 lines
///
/// One control per job: the link is a small button beside its status (a second full-width bar for it
/// competed with Compile), the port is named once, and the upload's outcome is one line with an icon
/// rather than a status sentence, a headline and a bar that all said the same thing.
struct HardwareLinkSection: View {
    @Bindable var model: AppModel
    @State private var showingLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            linkRow
            portRow
            compileButton
            Divider().padding(.vertical, 2)
            uploadStatus
        }
        .padding(.vertical, 6)
        // `refreshPorts` is the only thing that fills `availablePorts`; re-reading on appear also picks up
        // an adapter plugged in after launch.
        .onAppear { model.refreshPorts() }
    }

    // MARK: - The link

    /// Status on the left, the one action that changes it on the right. Connect is the call to action until
    /// there is a link, and Disconnect is deliberately quiet once there is.
    private var linkRow: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(model.isHardwareConnected ? Theme.signalHigh : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
                .shadow(color: model.isHardwareConnected ? Theme.signalHigh.opacity(0.8) : .clear, radius: 3)
            Text(model.isHardwareConnected ? "Connected" : "Disconnected")
                .font(.callout.weight(.medium))
                .foregroundStyle(model.isHardwareConnected ? Theme.signalHigh : .secondary)
            Spacer(minLength: 4)
            if model.isHardwareConnected {
                Button("Disconnect") { model.disconnectHardware() }
                    .buttonStyle(.bordered)
            } else {
                Button("Connect") { model.connectHardware() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.availablePorts.isEmpty)
            }
        }
        .controlSize(.small)
    }

    /// The port, named once. With no adapter there is nothing to pick, so say so — and the rescan stays,
    /// because plugging one in does not need the sidebar to be toggled to be seen.
    private var portRow: some View {
        HStack(spacing: 6) {
            if model.availablePorts.isEmpty {
                Text("No serial ports found.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Picker("Serial Port", selection: $model.selectedPortPath) {
                    ForEach(model.availablePorts) { port in
                        Text(port.name).tag(port.path)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .disabled(model.isHardwareConnected)
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

    /// Blue once there is a link to upload over: compiling is then the next step. The report it opens has
    /// Upload to PLC and the exports. A ternary cannot pick between two button styles, so both are spelled out.
    @ViewBuilder
    private var compileButton: some View {
        if model.isHardwareConnected {
            Button { model.buildAndShowReport() } label: { compileLabel }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.project == nil)
        } else {
            Button { model.buildAndShowReport() } label: { compileLabel }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(model.project == nil)
        }
    }

    private var compileLabel: some View {
        Label("Compile Project", systemImage: "hammer")
            .frame(maxWidth: .infinity)
    }

    // MARK: - The upload

    private enum Outcome { case idle, running, done, failed }

    private var outcome: Outcome {
        if model.isUploading { return .running }
        if model.uploadPhase.hasPrefix("Upload failed") { return .failed }
        if model.uploadPhase.hasPrefix("Upload complete") { return .done }
        return .idle
    }

    /// One line for the outcome, a bar only while it is running, and the log behind a toggle.
    private var uploadStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                outcomeIcon
                Text(headline)
                    .font(.caption)
                    .foregroundStyle(outcome == .failed ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if outcome == .running, let progress = model.uploadProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
            logToggle
            if showingLog { logBody }
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
            Image(systemName: "arrow.up.circle.fill").foregroundStyle(Color.accentColor)
        case .idle:
            Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
        }
    }

    /// What is happening, or what the last upload did; before any upload, what to do first. The message the
    /// model keeps for errors that happen before an upload starts (no serial link) is shown when there is no
    /// phase to report.
    private var headline: String {
        if !model.uploadPhase.isEmpty { return model.uploadPhase }
        if !model.uploadStatus.isEmpty { return model.uploadStatus }
        return model.isHardwareConnected ? "Ready — compile, then upload from the report."
                                         : "Connect to a serial port to upload."
    }

    private var logToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { showingLog.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(showingLog ? 90 : 0))
                    .frame(width: 10)
                Text("Log")
                Spacer(minLength: 0)
                if !model.uploadLog.isEmpty {
                    Text("\(model.uploadLog.count) lines").foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    private func color(for kind: AppModel.UploadLogEntry.Kind) -> Color {
        switch kind {
        case .stage: return .primary
        case .reply: return Theme.signalHigh
        case .error: return .red
        case .request, .info: return .secondary
        }
    }
}
