import WirebenchModel
import SwiftUI
import AppKit

/// The sidebar's *Hardware Link* block:
///
///     ● Ready                      ⟳                 ← the serial port, and a rescan
///     [ cu.usbserial-110 ⌄ ]                          ← only when there is a port to pick
///     [          Build Project           ]            ← the section's main action
///     ✓ Upload complete · 100%                        ← only once something has happened
///     › Log                                 24        ← only once there is a log
///
/// Nothing is shown that has nothing to say: an idle upload line and an empty log were two rows of
/// placeholder text under every project.
struct HardwareLinkSection<Report: View>: View {
    @Bindable var model: AppModel
    /// The build report, shown as a popover on the Build button.
    @ViewBuilder let report: () -> Report
    /// Remembered, so the log is where it was left.
    @AppStorage("hardware.showLog") private var showingLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The title is part of the card, not a chip above it.
            Text("Hardware Link")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 3)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            statusRow
            if !model.availablePorts.isEmpty { portPicker }
            actions
            if outcome != .idle { uploadStatus }
            if !model.uploadLog.isEmpty { log }
        }
        .controlSize(.small)
        // One card of glass for the whole block, so the link, the port and the build button read as one control group.
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 18)
        // `refreshPorts` is the only thing that fills `availablePorts`; re-reading on appear also picks up
        // an adapter plugged in after launch.
        .onAppear { model.refreshPorts() }
    }

    // MARK: - The link

    private var statusText: String {
        // The link is opened by an upload and closed after it, so "connected" is only what an upload in progress looks like.
        if model.isHardwareConnected { return "Connected" }
        return model.availablePorts.isEmpty ? "No serial port" : "Ready to upload"
    }

    /// Whether there is a port to upload to, and a rescan.
    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isHardwareConnected ? Theme.signalHigh : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.callout)
                .foregroundStyle(model.isHardwareConnected ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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
        .glassButtonStyle(prominent: true)
        // The system popover, like the block picker's, with its arrow on the button it belongs to.
        .popover(isPresented: Binding(get: { model.isBuildReportVisible }, set: { model.isShowingBuildReport = $0 }),
                 arrowEdge: .trailing) { report() }
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

    /// A disclosure of our own: the whole title row is the button. The system disclosure group only takes a click on its small triangle
    /// once it is outside a `List`, which left the log looking unclickable.
    private var log: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.smooth(duration: 0.2)) { showingLog.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(showingLog ? 90 : 0))
                    Text("Upload Log")
                    Spacer(minLength: 0)
                    Text("\(model.uploadLog.count)")
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(showingLog ? "expanded" : "collapsed")
            if showingLog {
                logBody
                    .padding(.top, 4)
            }
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
