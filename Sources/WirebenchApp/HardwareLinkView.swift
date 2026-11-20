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
            GlassSegmentedPicker(selection: $model.hardwareFamily,
                                 options: HardwareFamily.allCases,
                                 title: { $0.shortTitle },
                                 accessibilityLabel: "PLC family")
                .help("The PLC family the build and upload actions target")
            if model.hardwareFamily == .duinoS {
                GlassSegmentedPicker(selection: $model.duinoTransport,
                                     options: DuinoTransport.allCases,
                                     title: { $0.title },
                                     accessibilityLabel: "Duino-S transport")
                    .help("USB CDC virtual COM port, or the Duino-S Ethernet TCP server on port 5020")
            }
            statusRow
            if (model.hardwareFamily != .duinoS || model.duinoTransport == .usbCDC),
               !model.availablePorts.isEmpty {
                portPicker
            }
            if model.hardwareFamily == .duinoS, model.duinoTransport == .ethernet {
                ethernetFields
            }
            if model.hardwareFamily == .duinoS, model.isDuinoLinkConfigured {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Button("Identify") { Task { await model.identifyDuino() } }
                            .glassButtonStyle()
                            .controlSize(.small)
                            .disabled(model.isDiscoveringDuino || model.isIdentifyingDuino
                                      || model.isWatchingDuino || model.isUploading)
                            .help("Connect to the selected endpoint, ping the Duino-S, and read its model and firmware")
                        if model.isIdentifyingDuino { ProgressView().controlSize(.small) }
                        if model.duinoTransport == .usbCDC {
                            Button("Find") { Task { await model.discoverDuinoDevices() } }
                                .glassButtonStyle()
                                .controlSize(.small)
                                .disabled(model.isDiscoveringDuino || model.isWatchingDuino)
                                .help("Probe the serial ports and use the one that identifies as a Duino-S")
                        }
                        Spacer(minLength: 4)
                        if let info = model.duinoInfo {
                            Text("\(info.modelName) · 0x\(String(format: "%04X", info.modelId))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    if !model.duinoDiscoveryStatus.isEmpty {
                        Text(model.duinoDiscoveryStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if model.duinoDiscoveredDevices.count > 1 {
                        Menu("Found \(model.duinoDiscoveredDevices.count) devices") {
                            ForEach(model.duinoDiscoveredDevices) { device in
                                Button(device.displayName) { model.selectDuinoDevice(device) }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .controlSize(.small)
                    }
                }
            }
            actions
            watchPanel
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
        .onAppear {
            model.refreshPorts()
            if model.hardwareFamily == .duinoS, model.duinoDiscoveredDevices.isEmpty {
                Task { await model.discoverDuinoDevices() }
            }
        }
        .onChange(of: model.hardwareFamily) { _, family in
            if family == .duinoS, model.duinoDiscoveredDevices.isEmpty {
                Task { await model.discoverDuinoDevices() }
            }
        }
        .onChange(of: model.duinoTransport) { _, _ in
            if model.hardwareFamily == .duinoS {
                Task { await model.discoverDuinoDevices() }
            }
        }
    }

    // MARK: - The link

    private var statusText: String {
        // The link is opened by an upload and closed after it, so "connected" is only what an upload in progress looks like.
        if model.isHardwareConnected { return "Connected" }
        if model.hardwareFamily == .duinoS {
            if model.duinoTransport == .ethernet {
                let host = model.duinoHost.trimmingCharacters(in: .whitespaces)
                return host.isEmpty ? "No Ethernet host" : "TCP \(host):\(model.duinoTCPPort)"
            }
            if let info = model.duinoInfo { return "Ready · \(info.modelName)" }
            return model.availablePorts.isEmpty ? "No serial port" : "Duino-S ready"
        }
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
            if model.hardwareFamily != .duinoS || model.duinoTransport == .usbCDC {
                Button {
                    model.refreshPorts()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(model.hardwareFamily == .duinoS
                      ? "Rescan for the Duino-S USB CDC port"
                      : "Rescan for serial adapters")
                .accessibilityLabel("Rescan serial ports")
            }
        }
    }

    private var ethernetFields: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("IP").foregroundStyle(.secondary)
                TextField("192.168.1.50", text: $model.duinoHost)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .disabled(model.isWatchingDuino || model.isUploading)
                Text("Port").foregroundStyle(.secondary)
                TextField("5020", value: $model.duinoTCPPort, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 62)
                    .disabled(model.isWatchingDuino || model.isUploading)
            }
            .font(.caption)
            HStack(spacing: 6) {
                Button {
                    Task { await model.discoverDuinoDevices() }
                } label: {
                    Label(model.isDiscoveringDuino ? "Scanning…" : "Find Duino-S",
                          systemImage: "antenna.radiowaves.left.and.right")
                }
                .glassButtonStyle()
                .controlSize(.small)
                .disabled(model.isDiscoveringDuino || model.isWatchingDuino || model.isUploading)
                if model.isDiscoveringDuino { ProgressView().controlSize(.small) }
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
        .disabled(model.isHardwareConnected || model.isWatchingDuino)
    }

    /// The section's main action, full width. The frame is on the label, not the button: a frame around
    /// a macOS button only pads it, while a wide label stretches the bezel itself.
    private var actions: some View {
        VStack(spacing: 6) {
            Button {
                model.buildAndShowReport()
            } label: {
                // Named as in the Build menu, so the same action reads the same everywhere.
                Text("Build Project")
                    .frame(maxWidth: .infinity)
            }
            .glassButtonStyle(prominent: true)
            // The system popover, like the block picker's, with its arrow on the button it belongs to.
            .popover(isPresented: Binding(get: { model.isBuildReportVisible },
                                          set: { model.isShowingBuildReport = $0 }),
                     arrowEdge: .trailing) { report() }
            .controlSize(.regular)
            .disabled(model.project == nil)
            .padding(.top, 6)
            .help(model.hardwareFamily == .duinoS
                  ? "Build the FBD project and show the Duino-S image report, with Upload to Duino-S (⌘B)"
                  : "Build the project and show the report, with Upload to PLC (⌘B)")

            if model.hardwareFamily == .duinoS {
                if model.isWatchingDuino {
                    Button("Stop Watch") { model.stopDuinoWatch() }
                        .glassButtonStyle()
                        .controlSize(.regular)
                        .frame(maxWidth: .infinity)
                } else {
                    Button("Watch") { model.startDuinoWatch() }
                        .glassButtonStyle()
                        .controlSize(.regular)
                        .frame(maxWidth: .infinity)
                        .disabled(model.project == nil || !model.isDuinoLinkConfigured || model.isUploading)
                        .help("Poll the Duino-S VM and show the selected slots live")
                }
            }
        }
    }

    @ViewBuilder
    private var watchPanel: some View {
        if model.isWatchingDuino || !model.duinoWatchStatus.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: model.isWatchingDuino ? "eye.fill" : "eye")
                    Text(model.duinoWatchStatus)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(model.isWatchingDuino ? Color.secondary : Color.secondary)
                if !model.duinoWatchSlotNames.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(model.duinoWatchSlotNames.keys.sorted(), id: \.self) { slot in
                                HStack(spacing: 6) {
                                    Text(model.duinoWatchSlotNames[slot] ?? "slot \(slot)")
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 2)
                                    Text(watchValue(slot))
                                        .monospacedDigit()
                                        .foregroundStyle(.primary)
                                }
                                .font(.caption)
                            }
                        }
                    }
                    .frame(maxHeight: 170)
                }
            }
            .padding(.top, 2)
        }
    }

    private func watchValue(_ slot: UInt16) -> String {
        guard let value = model.duinoWatchValues[slot] else { return "—" }
        switch model.duinoWatchSlotTypes[slot] ?? .bool {
        case .bool: return value == 0 ? "0" : "1"
        case .int, .long: return String(Int64(value))
        case .float: return String(format: "%.3f", value)
        }
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
