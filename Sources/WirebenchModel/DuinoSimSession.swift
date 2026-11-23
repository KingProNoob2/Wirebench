import Foundation
import WirebenchHardware

/// A running Duino-S simulator as observable UI state: the model behind the 3D board window.
/// Polls the simulator's virtual hardware at ~20 Hz and forwards writes (pins, sensors, e-stop,
/// VM transport) to it. The simulator itself speaks MaraProt on 127.0.0.1:5020, so Maraflow or
/// another Wirebench window can attach to the same simulated board while the window is open.
@MainActor
@Observable
public final class DuinoSimSession {
    public let sim: DuinoSim
    public let port: UInt16
    public private(set) var digitalInputs = [Bool](repeating: false, count: 28)
    public private(set) var digitalOutputs = [Bool](repeating: false, count: 28)
    public private(set) var analogInputs = [Int32](repeating: 0, count: 4)
    public private(set) var analogOutputs = [Int32](repeating: 0, count: 2)
    public private(set) var pwmDuties = [Float](repeating: 0, count: 8)
    public private(set) var display = DuinoSim.Display(text: "", enabled: false, raw: true,
                                                       digitMask: 0, decimals: 0, brightness: 0, value: 0)
    public private(set) var temperatures: (tmp75: Float, ds18b20: Float) = (25, 22.5)
    public private(set) var potentiometers = [Int32](repeating: 0, count: 4)
    public private(set) var lightLevel: Float = 0.5
    public private(set) var ai3UsesLDR = false
    public private(set) var ds18b20Attached = true
    public private(set) var isPowered = true
    public private(set) var eStopActive = false
    public private(set) var vmState: MaraProt.VMRunState = .stopped

    private nonisolated(unsafe) var pollTask: Task<Void, Never>?
    private nonisolated(unsafe) var pulseTasks: [Int: Task<Void, Never>] = [:]

    /// - Parameter port: 0 = the Duino-S default (5020).
    public init(port requested: UInt16 = 0) throws {
        let sim = try DuinoSim(port: requested)
        self.sim = sim
        self.port = sim.port
        sim.setDigitalInput(14, true)
        sim.setDigitalInput(15, true)
        sim.setOneWireSensor(rom: [0x28, 0x44, 0x49, 0x4E, 0x4F, 0x2D, 0x53, 0x01])
        digitalInputs[14] = true
        digitalInputs[15] = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self {
                    let powered = sim.isPowered
                    let stopped = sim.vmEStopActive
                    let state = sim.vmState
                    let inputs = (0..<28).map { sim.digitalInput($0) }
                    let outputs = (0..<28).map { sim.digitalOutput($0) }
                    let analogIn = (0..<4).map { sim.analogInput($0) }
                    let analogOut = (0..<2).map { sim.analogOutput($0) }
                    let pwm = (0..<8).map { sim.pwmDuty($0) }
                    let newDisplay = sim.display
                    if isPowered != powered { isPowered = powered }
                    if eStopActive != stopped { eStopActive = stopped }
                    if vmState != state { vmState = state }
                    if digitalInputs != inputs { digitalInputs = inputs }
                    if digitalOutputs != outputs { digitalOutputs = outputs }
                    if analogInputs != analogIn { analogInputs = analogIn }
                    if analogOutputs != analogOut { analogOutputs = analogOut }
                    if pwmDuties != pwm { pwmDuties = pwm }
                    if display != newDisplay { display = newDisplay }
                } else {
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    deinit {
        pollTask?.cancel()
        for task in pulseTasks.values { task.cancel() }
    }

    public func controlVM(_ action: UInt8) {
        sim.controlVM(action)
        vmState = sim.vmState
    }

    public func setDigitalInput(_ channel: Int, _ value: Bool) {
        guard digitalInputs.indices.contains(channel) else { return }
        sim.setDigitalInput(channel, value)
        digitalInputs[channel] = value
    }

    public func pulseButton(channel: Int, activeLow: Bool = false) {
        let released = activeLow
        setDigitalInput(channel, !released)
        pulseTasks[channel]?.cancel()
        pulseTasks[channel] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.setDigitalInput(channel, released)
            self?.pulseTasks.removeValue(forKey: channel)
        }
    }

    public func setPotentiometer(_ channel: Int, _ value: Int32) {
        guard potentiometers.indices.contains(channel) else { return }
        let clamped = min(4095, max(0, value))
        potentiometers[channel] = clamped
        if channel < 3 || !ai3UsesLDR {
            sim.setAnalogInput(channel, clamped)
            analogInputs[channel] = clamped
        }
    }

    public func setLightLevel(_ value: Float) {
        lightLevel = min(1, max(0, value))
        if ai3UsesLDR { updateAI3() }
    }

    public func setAI3UsesLDR(_ value: Bool) {
        ai3UsesLDR = value
        updateAI3()
    }

    private func updateAI3() {
        let value = ai3UsesLDR ? Int32((lightLevel * 4095).rounded()) : potentiometers[3]
        sim.setAnalogInput(3, value)
        analogInputs[3] = value
    }

    public func setTemperature(tmp75: Float, ds18b20: Float) {
        sim.setTemperature(tmp75: tmp75, ds18b20: ds18b20)
        temperatures = (tmp75, ds18b20)
    }

    public func setDS18B20Attached(_ attached: Bool) {
        ds18b20Attached = attached
        sim.setOneWireSensor(rom: attached ? [0x28, 0x44, 0x49, 0x4E, 0x4F, 0x2D, 0x53, 0x01] : nil)
    }

    public func setPowered(_ powered: Bool) {
        sim.setPowered(powered)
        isPowered = powered
        vmState = sim.vmState
        if !powered {
            digitalOutputs = [Bool](repeating: false, count: 28)
            analogOutputs = [Int32](repeating: 0, count: 2)
            pwmDuties = [Float](repeating: 0, count: 8)
            display = DuinoSim.Display()
            eStopActive = false
        }
    }

    public func tripEStop() {
        sim.tripEStop()
        eStopActive = sim.vmEStopActive
        vmState = sim.vmState
    }

    public func clearEStop() {
        sim.clearEStop()
        eStopActive = sim.vmEStopActive
        vmState = sim.vmState
    }
}
