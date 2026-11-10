import Foundation
import WirebenchCore

/// What the PLC Configuration menu says about a command and its two parameters, and the presets it offers for them.
///
/// Where the words come from: *Configure Pins* is described in Dirigo's own tutorial on the PLC ports (`Doc/Navody/PLC_GPIOhw_Port.pdf`: the TRIS
/// register, `0x302` as its address, `Par1` as its value, bit n for pin I/O n, 1 for an input, I/O0 and I/O1 permanently the serial link). Every
/// other command is described from `Profiles.ini`, which gives its name and the name and type of each parameter and says which are not used; where
/// a name says what a parameter is, the text says so, and where it does not, the text only repeats the name and type rather than guess.
public struct PLCCommandGuide: Codable, Sendable, Equatable {
    public struct Preset: Codable, Sendable, Equatable {
        public var label: String
        public var value: Int
    }

    /// A parameter that is a row of on/off pins, shown as a grid.
    public struct Bits: Codable, Sendable, Equatable {
        /// One name per bit, lowest first (`I/O0`, `I/O1`…).
        public var names: [String]
        /// Bits whose value changes nothing (the serial link's pins).
        public var fixed: [Int]
        /// What 1 and 0 mean.
        public var onLabel: String
        public var offLabel: String
    }

    public struct Parameter: Codable, Sendable, Equatable {
        public var name: String
        public var dataType: String
        /// Whether the command uses it: a parameter `Profiles.ini` marks hidden is not.
        public var isUsed: Bool
        public var meaning: String
        public var presets: [Preset]
        public var bits: Bits?

        public init(name: String, dataType: String, isUsed: Bool, meaning: String, presets: [Preset] = [], bits: Bits? = nil) {
            self.name = name; self.dataType = dataType; self.isUsed = isUsed; self.meaning = meaning; self.presets = presets; self.bits = bits
        }

        /// A parameter nothing is known about: the command is not in the profile's list.
        public static func unlisted(_ slot: Int) -> Parameter {
            Parameter(name: "Par\(slot)", dataType: "Int", isUsed: true, meaning: "")
        }
    }

    public var title: String
    /// The command word, as `0x0302`.
    public var word: String
    public var summary: String
    public var parameters: [Parameter]
    /// What the command answers with, which a configuration does not read.
    public var answer: String

    /// The guide for a command. `threads` are the project's profile's (name, 1-based number), offered as presets where a parameter is a thread.
    public static func guide(for info: SystemCommandInfo, threads: [(name: String, id: Int)] = []) -> PLCCommandGuide {
        let word = String(format: "0x%04X", info.command)
        func parameter(_ pin: SystemCommandInfo.PinSchema, meaning: String, presets: [Preset] = [], bits: Bits? = nil) -> Parameter {
            Parameter(name: pin.name, dataType: pin.dataType, isUsed: !pin.isHidden,
                      meaning: pin.isHidden ? "Not used by this command." : meaning, presets: presets, bits: bits)
        }
        func plain(_ pin: SystemCommandInfo.PinSchema) -> String { "\(pin.name) (\(pin.dataType)): an input of the command; the profile names it and does not say more." }
        let threadPresets = threads.map { Preset(label: "\($0.name) (thread \($0.id))", value: $0.id) }

        var summary = "\(info.title). Sends command \(word) to the PLC's firmware."
        var p1 = parameter(info.input1, meaning: plain(info.input1))
        var p2 = parameter(info.input2, meaning: plain(info.input2))

        switch info.command {
        case 0x0302:
            summary = "Sets whether each of the PLC's I/O pins is an input or an output, as the microcontroller's TRIS register does. Bit n of the value "
                + "is pin I/O n: 1 makes it an input, 0 an output. Pins I/O0 and I/O1 are always the serial link (Rx and Tx) and bits 0 and 1 change "
                + "nothing; I/O2 to I/O13 can be set one by one."
            let pins = Bits(names: (0..<14).map { "I/O\($0)" }, fixed: [0, 1], onLabel: "Input", offLabel: "Output")
            p1 = parameter(info.input1, meaning: "The direction of each pin, I/O0 to I/O13: 1 is an input, 0 an output. Written as one number; the grid sets its bits.",
                           presets: [
                            Preset(label: "All outputs", value: 0),
                            Preset(label: "I/O4 to I/O6 inputs, the rest outputs (the three buttons of the Duino board)", value: 0x70),
                            Preset(label: "All of I/O2 to I/O13 inputs", value: 0x3FFC),
                           ], bits: pins)
            if info.input2.name == "Tris_H" {
                p2 = parameter(info.input2, meaning: "The high part of the same value, for hardware with more than 16 pins. Leave 0 otherwise.", presets: [Preset(label: "0", value: 0)])
            } else if info.input2.name == "AnSel" {
                p2 = parameter(info.input2, meaning: "AnSel: which pins are analog. Leave 0 for none.", presets: [Preset(label: "None", value: 0)])
            } else if info.input2.name == "Mask" {
                p2 = parameter(info.input2, meaning: "A mask (Long) of the pins this command changes.", presets: [Preset(label: "0", value: 0)])
            }
        case 0x0301:
            summary = "Writes the PLC's digital outputs from the values of its parameters."
            p1 = parameter(info.input1, meaning: info.input1.name == "DO_L" ? "DO_L: the low part of the value written to the outputs." : plain(info.input1),
                           presets: [Preset(label: "All off", value: 0)])
            if info.input2.name == "DO_H" { p2 = parameter(info.input2, meaning: "DO_H: the high part of the value written to the outputs.", presets: [Preset(label: "All off", value: 0)]) }
        case 0x0303:
            summary = "Drives a PWM output: Par1 names the channel and Par2 the value."
            p1 = parameter(info.input1, meaning: "PwmCH: the PWM channel.")
            p2 = parameter(info.input2, meaning: "Value: the value for that channel.")
        case 0x0400:
            summary = "Sets the watchdog."
            p1 = parameter(info.input1, meaning: "Ms: the watchdog time, in milliseconds.")
        case 0x0401:
            summary = "Changes the period of a thread."
            p1 = parameter(info.input1, meaning: "Thread: the number of the thread to change.", presets: threadPresets)
            p2 = parameter(info.input2, meaning: "Period: the new period for that thread.")
        case 0x0402:
            summary = "Starts a thread."
            p1 = parameter(info.input1, meaning: "Thread: the number of the thread to start.", presets: threadPresets)
        case 0x0103:
            summary = "Starts thread 3, the communication thread."
        case 0x0201:
            summary = "Sets a menu item."
            p1 = parameter(info.input1, meaning: "Item: the number of the menu item.")
        case 0x0101:
            summary = "Sets the PLC's RNet address."
            p1 = parameter(info.input1, meaning: "Addr: the address to set.")
            p2 = parameter(info.input2, meaning: "Lock: whether the address is locked; the profile names it and does not say more.")
        default:
            break
        }
        return PLCCommandGuide(title: info.title, word: word, summary: summary, parameters: [p1, p2],
                               answer: "\(info.output.name) (\(info.output.dataType)): the command's answer. A configuration does not read it.")
    }
}
