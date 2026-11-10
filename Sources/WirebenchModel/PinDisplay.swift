import Foundation
import WirebenchCore
import WirebenchLibrary

/// How a pin's value is written on screen, where that is not just `PinValue.description`. Shared by every frontend.
public enum PinDisplay {
    /// The text for the value of input `index` of a block with this type: a `SystemCmd`'s command word (its `Cmd` pin) is a code that
    /// is read in hex — `0x302`, not 770 — and every other value is its plain description. Typing `0x302` back is understood.
    public static func inputText(_ value: PinValue, index: Int, guid: UUID) -> String {
        if guid == SystemCmdBlock.guid, index == 1 {
            switch value {
            case .int16, .int32, .int64:
                let word = value.asInt
                if word >= 0 { return "0x" + String(word, radix: 16, uppercase: true) }
            default: break
            }
        }
        return value.description
    }
}
