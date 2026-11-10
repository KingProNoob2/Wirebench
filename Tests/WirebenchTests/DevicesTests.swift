import Testing
import Foundation
@testable import WirebenchHardware

/// Which `/dev` entries are offered as serial adapters.
///
/// This is where the Hardware Link section gets its list, and it was wrong in two ways at once: the
/// rule recognised only `cu.usb*`, `cu.SLAB*` and `cu.wch*` — missing an FTDI (`cu.usbserial-*`), a
/// CDC board (`cu.usbmodem*`) and a Prolific (`cu.PL2303*`) — and `AppModel.refreshPorts`, the only
/// thing that ever populated the list, was never called from anywhere. So the section read "No serial
/// ports found." on a machine with a working adapter attached.
///
/// The directory listing is passed in rather than read, because the one thing a test cannot do is
/// plug in a USB adapter.
@Suite("Serial devices")
struct SerialDeviceTests {
    @Test("Real adapters are offered, whatever their naming scheme")
    func realAdaptersAreOffered() {
        let devices = [
            "cu.usbserial-110",      // FTDI / Silicon Labs — the adapter on this machine
            "cu.usbserial-0001",     // a second FTDI, different suffix form
            "cu.usbmodem14201",      // CDC ACM, e.g. an Arduino or STM32
            "cu.SLAB_USBtoUART",     // Silicon Labs CP210x
            "cu.wchusbserial1420",   // CH340 — note this never matched the old `cu.wch*` arm
            "cu.PL2303-111",         // Prolific
        ]
        let offered = SerialPort.serialDeviceNames(in: devices)
        #expect(offered == devices, "every real adapter must be offered, got \(offered)")
    }

    @Test("macOS built-in pseudo-ports are not offered")
    func builtInPseudoPortsAreNotOffered() {
        let devices = ["cu.Bluetooth-Incoming-Port", "cu.debug-console", "cu.SerialPort",
                       "cu.usbserial-110"]
        let offered = SerialPort.serialDeviceNames(in: devices)
        #expect(offered == ["cu.usbserial-110"],
                "only the adapter should be offered, got \(offered)")
    }

    @Test("Callout-only devices and non-serial entries are ignored")
    func nonSerialEntriesAreIgnored() {
        // `tty.*` is the dial-in side of the same device, not a second port; offering both would list
        // an adapter twice.
        let devices = ["tty.usbserial-110", "tty.Bluetooth-Incoming-Port",
                       "disk0", "null", "random", "cu.", "cu", "CU.usbserial-1"]
        let offered = SerialPort.serialDeviceNames(in: devices)
        #expect(offered.isEmpty, "nothing here is a callout serial device, got \(offered)")
    }

    @Test("Linux adapters are offered by their own names, and the built-in ttyS ports are not")
    func linuxDevices() {
        let devices = ["ttyUSB0", "ttyUSB1",      // FTDI, CH340, Prolific
                       "ttyACM0",                  // a CDC board
                       "rfcomm0"]                  // Bluetooth serial
        #expect(SerialPort.serialDeviceNames(in: devices) == devices)
        let notAdapters = ["ttyS0", "ttyS1", "tty0", "tty", "console", "ttyUSB", "ttyACM", "rfcomm", "null"]
        #expect(SerialPort.serialDeviceNames(in: notAdapters).isEmpty,
                "the built-in ttyS ports go nowhere, and a bare prefix is not a device")
    }

    @Test("A port that will not open is explained, with the fix on Linux")
    func openFailureMessages() {
        let denied = SerialPort.openFailureMessage(path: "/dev/ttyUSB0", error: POSIXError(.EACCES))
        #expect(denied.contains("/dev/ttyUSB0"))
        #if os(Linux)
        #expect(denied.contains("dialout") && denied.contains("uucp"), "says which group, on each family of distribution")
        #endif
        #expect(SerialPort.openFailureMessage(path: "/dev/cu.x", error: POSIXError(.EBUSY)).contains("in use"))
        #expect(SerialPort.openFailureMessage(path: "/dev/cu.x", error: POSIXError(.ENOENT)).contains("not there"))
        #expect(SerialPort.openFailureMessage(path: "/dev/cu.x", error: POSIXError(.EIO)).contains("/dev/cu.x"))
    }

    /// The rule against what is *actually* attached, so the test is not only about strings.
    @Test("The devices on this machine are filtered the way the picker expects")
    func thisMachinesDevices() {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        let offered = SerialPort.serialDeviceNames(in: all)
        #expect(!offered.contains("cu.Bluetooth-Incoming-Port"),
                "the Bluetooth pseudo-port must never be offered")
        #expect(!offered.contains("cu.debug-console"))
        for name in offered {
            #expect(name.hasPrefix("cu.") || ["ttyUSB", "ttyACM", "rfcomm"].contains { name.hasPrefix($0) }, "\(name) is not a serial device")
        }
        // If an adapter is attached, the picker must not be empty — this is the exact failure that was
        // reported: a working `cu.usbserial-110` present, and nothing shown.
        if all.contains("cu.usbserial-110") {
            #expect(offered.contains("cu.usbserial-110"),
                    "the attached adapter is missing from the offered list")
        }
    }
}
