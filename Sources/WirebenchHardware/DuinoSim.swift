import Foundation
import WirebenchDuinoSim

/// A software Duino-S on localhost: the firmware's own MaraVM behind a real MaraProt v1 TCP
/// server (`WirebenchDuinoSim`). The macOS app, the Qt app and the tests drive it identically to
/// a board on the LAN: `MaraTCPTransport(host: "127.0.0.1", port:)` and the normal client.
public final class DuinoSim: @unchecked Sendable {
    public enum SimError: Error, LocalizedError {
        case failed(String)
        public var errorDescription: String? {
            switch self {
            case .failed(let detail): return "The Duino-S simulator could not start: \(detail)"
            }
        }
    }

    private let handle: UnsafeMutablePointer<WirebenchDuinoSim>?
    /// The port actually bound — the Duino-S default (5020) unless the caller asked for another.
    public let port: UInt16

    /// - Parameter port: 0 binds the default Duino-S port (5020); pass another to run several.
    public init(port requested: UInt16 = 0) throws {
        guard let handle = wirebench_duinosim_create(requested) else {
            var probe: UnsafeMutablePointer<WirebenchDuinoSim>? = nil
            _ = probe
            throw SimError.failed("port \(requested == 0 ? 5020 : requested) is unavailable or a simulator is already running")
        }
        self.handle = handle
        self.port = wirebench_duinosim_port(handle)
    }

    deinit { wirebench_duinosim_destroy(handle) }

    public var isPowered: Bool { wirebench_duinosim_powered(handle) != 0 }

    public func setPowered(_ powered: Bool) {
        wirebench_duinosim_set_power(handle, powered ? 1 : 0)
    }

    public var vmState: MaraProt.VMRunState {
        MaraProt.VMRunState(rawValue: wirebench_duinosim_vm_state(handle)) ?? .fault
    }

    public func controlVM(_ action: UInt8) {
        wirebench_duinosim_control_vm(handle, action)
    }

    /// What a connected program last wrote to a digital output channel.
    public func digitalOutput(_ channel: Int) -> Bool {
        wirebench_duinosim_get_do(handle, UInt32(channel)) != 0
    }

    /// Reads a host-driven digital input channel.
    public func digitalInput(_ channel: Int) -> Bool {
        wirebench_duinosim_di(handle, UInt32(channel)) != 0
    }

    /// Drives a digital input channel the way a wired switch would.
    public func setDigitalInput(_ channel: Int, _ value: Bool) {
        wirebench_duinosim_set_di(handle, UInt32(channel), value ? 1 : 0)
    }

    /// What a connected program last wrote to an analog output channel.
    public func analogOutput(_ channel: Int) -> Int32 {
        wirebench_duinosim_get_ao(handle, UInt32(channel))
    }

    public func setAnalogInput(_ channel: Int, _ value: Int32) {
        wirebench_duinosim_set_ai(handle, UInt32(channel), value)
    }

    public func analogInput(_ channel: Int) -> Int32 {
        wirebench_duinosim_ai(handle, UInt32(channel))
    }

    public func pwmDuty(_ channel: Int) -> Float {
        wirebench_duinosim_get_pwm(handle, UInt32(channel))
    }

    public func tripEStop(mask: UInt32 = 0) { wirebench_duinosim_trip_estop(handle, mask) }
    public func clearEStop() { wirebench_duinosim_clear_estop(handle) }
    /// Whether the VM is e-stopped right now (same-process read).
    public var vmEStopActive: Bool { wirebench_duinosim_estop_active(handle) != 0 }

    /// The shield's sensors: what the simulated TMP75 and 1-Wire DS18B20 report.
    public func setTemperature(tmp75: Float, ds18b20: Float) {
        wirebench_duinosim_set_temperature_c(handle, tmp75, ds18b20)
    }

    /// Attaches a DS18B20 to the 1-Wire bus (nil detaches), so ONEWIRE_SCAN finds it.
    public func setOneWireSensor(rom: [UInt8]?) {
        var bytes = [UInt8](repeating: 0, count: 8)
        if let rom { bytes.replaceSubrange(0..<min(8, rom.count), with: rom.prefix(8)) }
        wirebench_duinosim_set_onewire_rom(handle, rom == nil ? nil : bytes)
    }

    /// Backs the retentive store with a 32 KiB EEPROM image file, so values survive restarts.
    public func setEEPROMPath(_ path: String?) {
        wirebench_duinosim_set_eeprom_path(handle, path)
    }

    /// The shield's CH455G display, decoded from the VM's last update.
    public struct Display: Equatable {
        public var text: String
        public var valid: Bool
        public var enabled: Bool
        public var raw: Bool
        public var digitMask: UInt8
        public var decimals: Int
        public var brightness: Int
        public var value: Float
        public var segments: [UInt8]

        public init(text: String = "", valid: Bool = false, enabled: Bool = false, raw: Bool = true,
                    digitMask: UInt8 = 0, decimals: Int = 0, brightness: Int = 0, value: Float = 0,
                    segments: [UInt8] = [0, 0, 0, 0]) {
            self.text = text
            self.valid = valid
            self.enabled = enabled
            self.raw = raw
            self.digitMask = digitMask
            self.decimals = decimals
            self.brightness = brightness
            self.value = value
            self.segments = segments
        }
    }

    public var display: Display {
        var raw = WirebenchDuinoSimDisplay()
        wirebench_duinosim_display(handle, &raw)
        var text = ""
        withUnsafeBytes(of: raw.text) { bytes in
            if let base = bytes.baseAddress, bytes.count > 0 {
                text = String(cString: base.assumingMemoryBound(to: CChar.self))
            }
        }
        let segments = withUnsafeBytes(of: raw.segments) { Array($0) }
        return Display(text: text,
                       valid: raw.valid != 0,
                       enabled: raw.enabled != 0,
                       raw: raw.raw != 0,
                       digitMask: raw.digitMask,
                       decimals: Int(raw.decimals),
                       brightness: Int(raw.brightness),
                       value: raw.value,
                       segments: segments)
    }
}
