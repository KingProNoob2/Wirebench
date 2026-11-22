import SwiftUI
import AppKit
import RealityKit
import WirebenchHardware
import WirebenchModel

/// The Duino-S simulator window: the KiCad boards in 3D (RealityKit), driven live by the
/// simulator session.
///
/// The models are exported from the KiCad projects (`tools/sim3d/export-board.sh`: kicad-cli glb →
/// Blender usdc → usdzip). macOS's RealityView has no orbit-camera API at this deployment target,
/// so the board itself is the manipulable object: drag rotates it, option-drag or scrolling pans,
/// and pinch zooms. LEDs mirror DO/PWM state and the CH455G mesh mirrors the display. Component
/// taps and the hardware drawer write through the same session to the emulator's virtual pins.
private final class DisplaySegmentStore {
    var entities: [ModelEntity] = []
}

struct DuinoSimView: View {
    var sharedSession: DuinoSimSession?

    @State private var session: DuinoSimSession?
    @State private var startError: String?
    /// Trackball orientation and distance of the board from the default camera.
    @State private var rotation = simd_quatf(angle: .pi / 2.6, axis: [1, 0, 0])
    @State private var yaw: Float = 0.5
    /// Zoom is the root's scale, not a camera distance: the macOS RealityView camera is an
    /// opaque token (~1.7 m out) that cannot be moved, so the board is parked at a fixed offset
    /// and brought close by scaling.
    @State private var zoom: Float = 18
    @State private var pan = SIMD2<Float>(0, 0)
    @State private var ledChannels: [String: Int] = [:]
    @State private var shieldLedChannels: [String: Int] = [:]
    @State private var buttonControls: [String: (board: String, node: String, channel: Int, activeLow: Bool)] = [:]
    @State private var analogControls: [String: (channel: Int, kind: String)] = [:]
    @State private var selectedControl: String?
    @State private var heldButton: (channel: Int, activeLow: Bool)?
    @State private var heldButtonStarted = Date()
    @State private var showControls = true
    @State private var root: Entity?
    @State private var boardModel: Entity?
    @State private var shieldModel: Entity?
    @State private var boardSize: SIMD3<Float>?

    init(sharedSession: DuinoSimSession? = nil) {
        self.sharedSession = sharedSession
    }
    @State private var lastLEDStates: [String: Bool] = [:]
    @State private var lastDisplaySignature: [UInt8] = []
    @State private var displaySegmentStore = DisplaySegmentStore()

    var body: some View {
        ZStack(alignment: .bottom) {
            if let session {
                RealityView { content in
                    await buildScene(into: content)
                } update: { content in
                    applyLEDs(content: content)
                    applyDisplay()
                    // Drive the captured root, never `content.entities.first`: the content does
                    // not guarantee insertion order, and writing the transform to the wrong
                    // entity made zoom and rotation do nothing.
                    root?.transform.rotation = rotation * simd_quatf(angle: yaw, axis: [0, 1, 0])
                    root?.transform.scale = SIMD3<Float>(repeating: zoom)
                    root?.position = [pan.x, pan.y, -1.45]
                }
                .highPriorityGesture(buttonHold)
                .gesture(dragRotation)
                .simultaneousGesture(hardwareTap)
                .simultaneousGesture(dragPan)
                .gesture(magnify)
                .overlay(alignment: .top) {
                    hud(session: session)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.top, 8)
                }
                .overlay(alignment: .trailing) {
                    if showControls {
                        DuinoHardwarePane(session: session, selectedControl: $selectedControl)
                            .frame(width: 308)
                            .frame(maxHeight: .infinity)
                            .background(.regularMaterial)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    Button(showControls ? "Hide Hardware" : "Hardware") {
                        withAnimation { showControls.toggle() }
                    }
                    .buttonStyle(.bordered)
                    .padding(12)
                }
            } else if let startError {
                ContentUnavailableView("The simulator could not start",
                                       systemImage: "xmark.octagon",
                                       description: Text(startError))
            } else {
                ProgressView("Starting the Duino-S simulator…")
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { installScrollPan() }
        .onDisappear {
            releaseHeldButton()
            removeScrollPan()
        }
        .task {
            if let sharedSession {
                session = sharedSession
            } else if session == nil {
                do { session = try DuinoSimSession() }
                catch { startError = error.localizedDescription }
            }
        }
    }

    @State private var lastMagnify: Float = 1
    @State private var scrollMonitor: Any?

    /// SwiftUI has no scroll-wheel gesture; pan with the wheel through a local event monitor.
    private func installScrollPan() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [self] event in
            guard event.window?.title == "Duino-S Simulator" else { return event }
            let k: Float = 0.0005 / zoom
            pan.x += Float(event.scrollingDeltaX) * k
            pan.y += Float(event.scrollingDeltaY) * k
            return event
        }
    }

    private func removeScrollPan() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    @State private var lastDrag = CGSize.zero
    @State private var lastPanDrag = CGSize.zero

    /// Orbit the board with a drag; component meshes reserve their targeted gestures for hardware taps.
    private var dragRotation: some Gesture {
        DragGesture()
            .onChanged { value in
                let delta = CGSize(width: value.translation.width - lastDrag.width,
                                   height: value.translation.height - lastDrag.height)
                yaw += Float(delta.width) * 0.012
                let pitch = Float(delta.height) * 0.012
                rotation = simd_quatf(angle: pitch, axis: [1, 0, 0]) * rotation
                lastDrag = value.translation
            }
            .onEnded { _ in lastDrag = .zero }
    }

    private var dragPan: some Gesture {
        DragGesture().modifiers(.option)
            .onChanged { value in
                let delta = CGSize(width: value.translation.width - lastPanDrag.width,
                                   height: value.translation.height - lastPanDrag.height)
                let scale = 0.0005 / zoom
                pan.x += Float(delta.width) * scale
                pan.y -= Float(delta.height) * scale
                lastPanDrag = value.translation
            }
            .onEnded { _ in lastPanDrag = .zero }
    }

    private var buttonHold: some Gesture {
        DragGesture(minimumDistance: 0).targetedToAnyEntity()
            .onChanged { value in
                guard heldButton == nil, let control = buttonControl(for: value.entity) else { return }
                heldButton = (control.channel, control.activeLow)
                heldButtonStarted = Date()
                session?.setDigitalInput(control.channel, !control.activeLow)
            }
            .onEnded { _ in releaseHeldButton() }
    }

    private func releaseHeldButton() {
        guard let heldButton else { return }
        if Date().timeIntervalSince(heldButtonStarted) < 0.18 {
            session?.pulseButton(channel: heldButton.channel, activeLow: heldButton.activeLow)
        } else {
            session?.setDigitalInput(heldButton.channel, heldButton.activeLow)
        }
        self.heldButton = nil
    }

    private func buttonControl(for entity: Entity) -> (board: String, node: String, channel: Int, activeLow: Bool)? {
        let onShield = isDescendant(entity, of: shieldModel)
        var current: Entity? = entity
        while let node = current {
            for (_, control) in buttonControls where control.node == node.name
                && (control.board == "shield") == onShield {
                return control
            }
            current = node.parent
        }
        return nil
    }

    private var hardwareTap: some Gesture {
        TapGesture().targetedToAnyEntity()
            .onEnded { value in handleHardwareTap(value.entity) }
    }

    private func handleHardwareTap(_ entity: Entity) {
        guard let session else { return }
        let onShield = isDescendant(entity, of: shieldModel)
        var current: Entity? = entity
        while let node = current {
            if !onShield && node.name == "J7" {
                session.setPowered(!session.isPowered)
                return
            }
            if onShield && node.name == "SW3" {
                session.setAI3UsesLDR(!session.ai3UsesLDR)
                selectedControl = "SW3"
                return
            }
            if onShield, let control = analogControls[node.name] {
                selectedControl = control.kind == "ldr" ? "R24" : node.name
                return
            }
            current = node.parent
        }
    }

    private func isDescendant(_ entity: Entity, of ancestor: Entity?) -> Bool {
        guard let ancestor else { return false }
        var current: Entity? = entity
        while let node = current {
            if node === ancestor { return true }
            current = node.parent
        }
        return false
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let factor = Float(value.magnification) / lastMagnify
                zoom = min(80, max(1, zoom * factor))
                lastMagnify = Float(value.magnification)
            }
            .onEnded { _ in lastMagnify = 1 }
    }

    // MARK: - Scene

    private func buildScene(into content: RealityViewCameraContent) async {
        if let manifest = loadManifest() {
            ledChannels = manifest["leds"] as? [String: Int] ?? [:]
            shieldLedChannels = manifest["shieldLeds"] as? [String: Int] ?? [:]
            if let buttons = manifest["buttons"] as? [String: [String: Any]] {
                for (key, value) in buttons {
                    guard let board = value["board"] as? String,
                          let node = value["node"] as? String,
                          let channel = value["channel"] as? Int else { continue }
                    buttonControls[key] = (board, node, channel, value["activeLow"] as? Bool ?? false)
                }
            }
            if let inputs = manifest["analogInputs"] as? [String: [String: Any]] {
                for (key, value) in inputs {
                    guard let channel = value["channel"] as? Int,
                          let kind = value["kind"] as? String else { continue }
                    analogControls[key] = (channel, kind)
                }
            }
        }
        guard let boardURL = Bundle.main.url(forResource: "board", withExtension: "usdz"),
              let shieldURL = Bundle.main.url(forResource: "shield", withExtension: "usdz"),
              let board = try? await Entity(contentsOf: boardURL),
              let shield = try? await Entity(contentsOf: shieldURL)
        else { return }
        boardModel = board
        shieldModel = shield
        lastLEDStates = [:]
        lastDisplaySignature = []
        let boardBounds = board.visualBounds(relativeTo: nil)
        let shieldBounds = shield.visualBounds(relativeTo: nil)
        boardSize = boardBounds.extents
        if let boardHeader = board.findEntity(named: "J1"),
           let shieldHeader = shield.findEntity(named: "J1") {
            // Measure before moving either USD root; these world-space anchors include its translation.
            let boardAnchor = boardHeader.position(relativeTo: nil)
            let shieldAnchor = shieldHeader.position(relativeTo: nil)
            board.position = -boardBounds.center
            shield.position = board.position + boardAnchor - shieldAnchor + SIMD3<Float>(0, 0.008, 0)
        } else {
            board.position = -boardBounds.center
            shield.position = SIMD3<Float>(
                -shieldBounds.center.x,
                boardBounds.extents.y / 2 + 0.008 + shieldBounds.extents.y / 2 - shieldBounds.center.y,
                -shieldBounds.center.z)
        }
        let root = Entity()
        self.root = root
        root.addChild(board)
        root.addChild(shield)
        for model in [board, shield] {
            for ref in ["J7", "SW1", "SW2", "SW3", "SW4", "R9", "R16", "R18", "R22", "R24"] {
                guard let control = model.findEntity(named: ref) else { continue }
                control.generateCollisionShapes(recursive: true)
                enableInput(on: control)
            }
        }
        makeDisplay(on: root, shield: shield)
        content.add(root)

        let sun = Entity()
        sun.components.set(DirectionalLightComponent(color: .white, intensity: 1400))
        sun.position = [0.4, 0.8, 0.5]
        sun.look(at: .zero, from: sun.position, relativeTo: nil)
        content.add(sun)
    }

    private func enableInput(on entity: Entity) {
        if entity.components[CollisionComponent.self] != nil {
            entity.components.set(InputTargetComponent())
        }
        for child in entity.children { enableInput(on: child) }
    }

    private func loadManifest() -> [String: Any]? {
        guard let url = Bundle.main.url(forResource: "board-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private func applyLEDs(content: RealityViewCameraContent) {
        guard let session, let root else { return }
        let pwmByDIO = [4: 0, 5: 1, 6: 2, 7: 3, 9: 4, 10: 5, 11: 6, 12: 7]
        func active(_ channel: Int) -> Bool {
            guard session.isPowered else { return false }
            if session.digitalOutputs[channel] { return true }
            if let pwm = pwmByDIO[channel], pwm < session.pwmDuties.count { return session.pwmDuties[pwm] > 0 }
            return false
        }
        for (ref, channel) in ledChannels where channel < session.digitalOutputs.count {
            let key = "board.\(ref)"
            let on = active(channel)
            if lastLEDStates[key] == on { continue }
            guard let node = root.findEntity(named: ref),
                  let model = node.components[ModelComponent.self] else { continue }
            var updated = model
            updated.materials = Array(repeating: UnlitMaterial(color: on ? .green : .darkGray),
                                      count: max(1, model.materials.count))
            node.components.set(updated)
            lastLEDStates[key] = on
        }
        for (ref, channel) in shieldLedChannels where channel < session.digitalOutputs.count {
            let key = "shield.\(ref)"
            let on = active(channel)
            if lastLEDStates[key] == on { continue }
            guard let node = shieldModel?.findEntity(named: ref),
                  let model = node.components[ModelComponent.self] else { continue }
            var updated = model
            updated.materials = Array(repeating: UnlitMaterial(color: on ? .red : .darkGray),
                                      count: max(1, model.materials.count))
            node.components.set(updated)
            lastLEDStates[key] = on
        }
    }

    private func makeDisplay(on root: Entity, shield: Entity) {
        guard let display = shield.findEntity(named: "LED1") else { return }
        let bounds = display.visualBounds(relativeTo: root)
        display.isEnabled = false
        let housing = ModelEntity(mesh: .generateBox(size: bounds.extents),
                                  materials: [UnlitMaterial(color: NSColor(calibratedWhite: 0.018, alpha: 1))])
        housing.name = "WBDisplayHousing"
        housing.position = bounds.center
        root.addChild(housing)
        let container = Entity()
        container.name = "WBDisplay"
        container.position = [bounds.center.x, bounds.center.y + bounds.extents.y / 2 + 0.00035, bounds.center.z]
        root.addChild(container)

        var generated: [ModelEntity] = []
        let width: Float = 0.0042
        let height: Float = 0.0074
        let stroke: Float = 0.00050
        let depth: Float = 0.00012
        for digit in 0..<3 {
            let digitX = (Float(digit) - 1) * 0.0064
            for segment in 0..<8 {
                var size = SIMD3<Float>(width - 0.00065, depth, stroke)
                var position = SIMD3<Float>(digitX, 0, -height / 2)
                switch segment {
                case 1:
                    size = [stroke, depth, height / 2 - 0.00055]
                    position = [digitX + width / 2, 0, -height / 4]
                case 2:
                    size = [stroke, depth, height / 2 - 0.00055]
                    position = [digitX + width / 2, 0, height / 4]
                case 3:
                    position = [digitX, 0, height / 2]
                case 4:
                    size = [stroke, depth, height / 2 - 0.00055]
                    position = [digitX - width / 2, 0, height / 4]
                case 5:
                    size = [stroke, depth, height / 2 - 0.00055]
                    position = [digitX - width / 2, 0, -height / 4]
                case 6:
                    position = [digitX, 0, 0]
                case 7:
                    size = [0.00055, depth, 0.00055]
                    position = [digitX + width / 2 + 0.00045, 0, height / 2]
                default:
                    break
                }
                let entity = ModelEntity(mesh: .generateBox(size: size),
                                         materials: [UnlitMaterial(color: NSColor(calibratedRed: 0.12,
                                                                                 green: 0.012, blue: 0.008, alpha: 1))])
                entity.name = "WBDisplay_\(digit)_\(segment)"
                entity.position = position
                container.addChild(entity)
                generated.append(entity)
            }
        }
        displaySegmentStore.entities = generated
    }

    static func displaySegmentMasks(_ display: DuinoSim.Display) -> [UInt8] {
        if display.raw {
            return (0..<3).map { index in index < display.segments.count ? display.segments[index] : 0 }
        }
        let glyphs: [Character: UInt8] = [
            "0": 0x3F, "1": 0x06, "2": 0x5B, "3": 0x4F, "4": 0x66,
            "5": 0x6D, "6": 0x7D, "7": 0x07, "8": 0x7F, "9": 0x6F,
            "-": 0x40, " ": 0
        ]
        var digits: [(Character, Bool)] = []
        for character in display.text {
            if character == ".", !digits.isEmpty {
                digits[digits.count - 1].1 = true
            } else {
                digits.append((character, false))
            }
        }
        let visible = Array(digits.suffix(3))
        let padded = Array(repeating: (Character(" "), false), count: 3 - visible.count) + visible
        return (0..<3).map { index in
            let (character, decimal) = padded[index]
            return (glyphs[character] ?? 0) | (decimal ? 0x80 : 0)
        }
    }

    private func applyDisplay() {
        guard let session, displaySegmentStore.entities.count == 24 else { return }
        let masks = Self.displaySegmentMasks(session.display)
        let brightness = max(1, min(8, session.display.brightness))
        let active = session.display.valid && session.display.enabled
        let signature = masks + [UInt8(brightness), active ? 1 : 0]
        if signature == lastDisplaySignature { return }
        lastDisplaySignature = signature
        let red = active ? 0.25 + 0.75 * Float(brightness) / 8 : 0.42
        let onColor = NSColor(calibratedRed: CGFloat(red), green: active ? 0.025 : 0.008, blue: 0.015, alpha: 1)
        let offColor = NSColor(calibratedRed: 0.12, green: 0.012, blue: 0.008, alpha: 1)
        for digit in 0..<3 {
            for segment in 0..<8 {
                let entity = displaySegmentStore.entities[digit * 8 + segment]
                let on = (masks[digit] & (1 << segment)) != 0
                guard var model = entity.components[ModelComponent.self] else { continue }
                model.materials = [UnlitMaterial(color: on ? onColor : offColor)]
                entity.components.set(model)
            }
        }
    }

    // MARK: - HUD

    @ViewBuilder
    private func hud(session: DuinoSimSession) -> some View {
        HStack(spacing: 18) {
            Text("build 22n")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
            if let size = boardSize {
                Text(String(format: "board %.0f×%.0f mm", size.x * 1000, size.z * 1000))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Button {
                session.setPowered(!session.isPowered)
            } label: {
                Label(session.isPowered ? "DC connected" : "DC disconnected",
                      systemImage: session.isPowered ? "powerplug.fill" : "powerplug")
            }
            .buttonStyle(.borderedProminent)
            .tint(session.isPowered ? .green : .gray)
            .help(session.isPowered ? "Unplug J7 and power-cycle the emulator" : "Plug in J7 and boot the emulator")
            Label(session.isPowered ? "127.0.0.1:\(session.port)" : "No power",
                  systemImage: "cable.connector")
                .font(.callout.monospaced())
            Text(session.display.valid && !session.display.enabled
                 ? "Display: IDLE" : "Display: \(session.display.text.trimmingCharacters(in: .whitespaces))")
                .font(.callout.monospaced())
                .foregroundStyle(session.display.enabled ? .primary : .secondary)
            Text("VM " + String(describing: session.vmState))
                .font(.callout.monospaced())
                .foregroundStyle(session.vmState == .running ? .green : .secondary)
        }
        .controlSize(.small)
    }
}
struct DuinoSimWindowView: View {
    let model: AppModel

    var body: some View {
        Group {
            if let session = model.duinoSimSession {
                DuinoSimView(sharedSession: session)
            } else if !model.duinoSimError.isEmpty {
                ContentUnavailableView("The simulator could not start",
                                       systemImage: "xmark.octagon",
                                       description: Text(model.duinoSimError))
            } else {
                ProgressView("Starting the Duino-S simulator…")
            }
        }
        .onAppear { model.startDuinoSimulator() }
    }
}


private struct MomentaryPinControl: View {
    let title: String
    let channel: Int
    var activeLow = false
    let session: DuinoSimSession

    var body: some View {
        let pressed = session.digitalInputs[channel] != activeLow
        Text(title)
            .font(.caption.monospacedDigit())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(pressed ? Color.accentColor : Color.secondary.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(pressed ? .white : .primary)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in session.setDigitalInput(channel, !activeLow) }
                .onEnded { _ in session.setDigitalInput(channel, activeLow) })
            .accessibilityAddTraits(.isButton)
    }
}


private enum DuinoHardwareTab: String, CaseIterable {
    case controls = "Controls"
    case analog = "Analog"
    case pins = "Pins"
}

private struct DuinoHardwarePane: View {
    let session: DuinoSimSession
    @Binding var selectedControl: String?
    @State private var tab: DuinoHardwareTab = .controls

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Label("Duino-S", systemImage: "cpu").font(.headline)
                    Spacer()
                    Circle()
                        .fill(session.isPowered ? .green : .gray)
                        .frame(width: 7, height: 7)
                    Text(String(describing: session.vmState))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Button { session.setPowered(!session.isPowered) } label: {
                        Image(systemName: session.isPowered ? "powerplug.fill" : "powerplug")
                    }
                    .help(session.isPowered ? "Disconnect J7" : "Connect J7")
                }
                HStack(spacing: 6) {
                    Button { session.controlVM(1) } label: { Label("Run", systemImage: "play.fill") }
                        .tint(.green)
                    Button { session.controlVM(2) } label: { Label("Pause", systemImage: "pause.fill") }
                    Button { session.controlVM(0) } label: { Label("Stop", systemImage: "stop.fill") }
                        .tint(.red)
                }
                .buttonStyle(.bordered)
                .disabled(!session.isPowered)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            Picker("Hardware section", selection: $tab) {
                ForEach(DuinoHardwareTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)

            ScrollView {
                Group {
                    switch tab {
                    case .controls:
                        DuinoControlsTab(session: session)
                    case .analog:
                        DuinoAnalogTab(session: session, selectedControl: selectedControl)
                    case .pins:
                        DuinoPinsTab(session: session)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .disabled(!session.isPowered)
        }
        .controlSize(.small)
        .onChange(of: selectedControl) { _, selection in
            guard let selection else { return }
            tab = selection.hasPrefix("R") || selection == "SW3" ? .analog : .controls
        }
    }
}

private struct DuinoControlsTab: View {
    let session: DuinoSimSession

    private var displayText: String {
        if session.display.raw && session.display.valid { return "RAW" }
        let text = session.display.text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "0" : text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("CH455G", systemImage: "display")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(displayText)
                    .font(.title2.monospacedDigit())
                    .foregroundStyle(session.display.enabled ? .red : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))

            GroupBox("Pushbuttons") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    MomentaryPinControl(title: "SW1 · 10", channel: 10, session: session)
                    MomentaryPinControl(title: "SW2 · 11", channel: 11, session: session)
                    MomentaryPinControl(title: "SW4 · 12", channel: 12, session: session)
                    MomentaryPinControl(title: "Board SW3 · 14", channel: 14, activeLow: true, session: session)
                    MomentaryPinControl(title: "Board SW4 · 15", channel: 15, activeLow: true, session: session)
                }
                .padding(.top, 4)
            }

            GroupBox("Temperature") {
                VStack(spacing: 10) {
                    DuinoSensorRow(title: "TMP75", value: session.temperatures.tmp75, range: -20...80) { value in
                        session.setTemperature(tmp75: value, ds18b20: session.temperatures.ds18b20)
                    }
                    DuinoSensorRow(title: "DS18B20", value: session.temperatures.ds18b20, range: -55...125) { value in
                        session.setTemperature(tmp75: session.temperatures.tmp75, ds18b20: value)
                    }
                    Toggle("1-Wire sensor attached", isOn: Binding(
                        get: { session.ds18b20Attached },
                        set: { session.setDS18B20Attached($0) }))
                }
                .padding(.top, 4)
            }

            Button(session.eStopActive ? "Reset E-Stop" : "Trip E-Stop") {
                session.eStopActive ? session.clearEStop() : session.tripEStop()
            }
            .buttonStyle(.borderedProminent)
            .tint(session.eStopActive ? .green : .red)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct DuinoAnalogTab: View {
    let session: DuinoSimSession
    let selectedControl: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Potentiometers · 0…4095") {
                VStack(spacing: 12) {
                    DuinoPotRow(title: "R16 · AI0", channel: 0, selected: selectedControl == "R16", session: session)
                    DuinoPotRow(title: "R9 · AI1", channel: 1, selected: selectedControl == "R9", session: session)
                    DuinoPotRow(title: "R18 · AI2", channel: 2, selected: selectedControl == "R18", session: session)
                    DuinoPotRow(title: "R22 · AI3", channel: 3, selected: selectedControl == "R22", session: session)
                        .disabled(session.ai3UsesLDR)
                }
                .padding(.top, 4)
            }

            GroupBox("SW3 · AI3 source") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("AI3 source", selection: Binding(
                        get: { session.ai3UsesLDR },
                        set: { session.setAI3UsesLDR($0) })) {
                            Text("R22 pot").tag(false)
                            Text("R24 LDR").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    HStack {
                        Text("Illumination")
                        Spacer()
                        Text("\(session.analogInputs[3])").monospacedDigit()
                    }
                    Slider(value: Binding(get: { Double(session.lightLevel) },
                                          set: { session.setLightLevel(Float($0)) }), in: 0...1)
                        .disabled(!session.ai3UsesLDR)
                }
                .padding(.top, 4)
            }
        }
    }
}

private struct DuinoPinsTab: View {
    let session: DuinoSimSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Digital inputs") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 58))], spacing: 5) {
                    ForEach(Array(2...7) + Array(9...27), id: \.self) { channel in
                        Toggle("DI\(channel)", isOn: Binding(
                            get: { session.digitalInputs[channel] },
                            set: { session.setDigitalInput(channel, $0) }))
                            .toggleStyle(.button)
                            .font(.caption2.monospacedDigit())
                    }
                }
                .padding(.top, 4)
            }

            GroupBox("Live outputs") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("AO0").foregroundStyle(.secondary)
                        Text("\(session.analogOutputs[0])").monospacedDigit()
                        Spacer()
                        Text("AO1").foregroundStyle(.secondary)
                        Text("\(session.analogOutputs[1])").monospacedDigit()
                    }
                    Text("PWM " + session.pwmDuties.map { String(format: "%.0f%%", $0) }.joined(separator: "  "))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
    }
}

private struct DuinoPotRow: View {
    let title: String
    let channel: Int
    let selected: Bool
    let session: DuinoSimSession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).foregroundStyle(selected ? Color.accentColor : Color.primary)
                Spacer()
                Text("\(session.analogInputs[channel])").monospacedDigit()
            }
            Slider(value: Binding(get: { Double(session.potentiometers[channel]) },
                                  set: { session.setPotentiometer(channel, Int32($0.rounded())) }), in: 0...4095)
        }
    }
}

private struct DuinoSensorRow: View {
    let title: String
    let value: Float
    let range: ClosedRange<Float>
    let onChange: (Float) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value, specifier: "%.1f")°C").monospacedDigit()
            }
            Slider(value: Binding(get: { Double(value) }, set: { onChange(Float($0)) }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
        }
    }
}
