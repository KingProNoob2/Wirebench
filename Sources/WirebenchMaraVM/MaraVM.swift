import Foundation
import WirebenchMaraVMC

/// A small Swift owner for the portable MaraVM C engine.
///
/// The engine is the same `mara_vm.c` the Duino-S firmware runs, built without a HAL so tests can load
/// an emitted MFLW image, execute a thread and read the slots back. Hardware callbacks are no-ops here;
/// the real device supplies them.
public final class MaraVM {
    private var instance = VmInstance_t()

    public init() {
        var hal = VmHalVtable_t()
        hal.di_read = { _ in 0 }
        hal.do_write = { _, _ in }
        hal.ai_read = { _ in 0 }
        hal.ao_write = { _, _ in }
        hal.pwm_set = { _, _, _ in 0 }
        hal.time_micros = { 0 }
        hal.rtc_unix_sec = { 0 }
        hal.rng_next = { 0x1234_5678 }
        hal.retentive_write = { _, _ in }
        hal.retentive_read = { _ in 0 }
        hal.comm_exec = { _, _, _, _, _ in 0 }
        _ = VM_Init(&instance, &hal)
    }

    public enum VMError: Error, LocalizedError, Equatable {
        case initFailed(Int32)
        case loadFailed(Int32)
        case stateFailed(Int32)
        case stepFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case .initFailed(let code): return "MaraVM init failed (\(code))."
            case .loadFailed(let code): return "MaraVM could not load the image (\(code))."
            case .stateFailed(let code): return "MaraVM state change failed (\(code))."
            case .stepFailed(let code): return "MaraVM step failed (\(code))."
            }
        }
    }

    /// Whether the engine accepts this image and its MFLW header.
    public func load(_ image: [UInt8]) throws {
        let status = image.withUnsafeBufferPointer { buffer in
            VM_LoadImage(&instance, buffer.baseAddress, UInt32(image.count))
        }
        guard status == VM_OK else { throw VMError.loadFailed(Int32(status.rawValue)) }
    }

    public func reset() throws {
        let status = VM_Reset(&instance)
        guard status == VM_OK else { throw VMError.stateFailed(Int32(status.rawValue)) }
    }

    public func setRunning() throws {
        let status = VM_SetState(&instance, VM_STATE_RUNNING)
        guard status == VM_OK else { throw VMError.stateFailed(Int32(status.rawValue)) }
    }

    public func setStopped() throws {
        _ = VM_SetState(&instance, VM_STATE_STOPPED)
    }

    public var state: UInt8 { UInt8(truncatingIfNeeded: VM_GetState(&instance).rawValue) }
    public var hasValidImage: Bool { instance.hasValidImage }
    public var scanCount: UInt32 { instance.scanCount }
    public var lastFaultCode: Int32 { Int32(instance.lastFaultCode.rawValue) }
    public var lastFaultPC: UInt16 { instance.lastFaultPc }

    public func step(thread: Int, dtMicroseconds: UInt32 = 5_000) throws {
        let status = VM_StepThread(&instance, UInt8(thread), dtMicroseconds)
        guard status == VM_OK else { throw VMError.stepFailed(Int32(status.rawValue)) }
    }

    public func readSlot(_ slot: UInt16) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 8)
        let count = buffer.withUnsafeMutableBufferPointer { pointer in
            VM_ReadSlotRaw(&instance, slot, pointer.baseAddress)
        }
        return Array(buffer.prefix(Int(count)))
    }

    @discardableResult
    public func writeSlot(_ slot: UInt16, bytes: [UInt8]) -> Bool {
        var buffer = bytes
        return buffer.withUnsafeMutableBufferPointer { pointer in
            VM_WriteSlotRaw(&instance, slot, pointer.baseAddress) != 0
        }
    }

    public func readBool(_ slot: UInt16) -> Bool { readSlot(slot).first == 1 }
    public func readInt(_ slot: UInt16) -> Int32 {
        let bytes = readSlot(slot)
        guard bytes.count >= 4 else { return 0 }
        return Int32(bitPattern: UInt32(bytes[0]) | (UInt32(bytes[1]) << 8)
                     | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24))
    }
    public func readLong(_ slot: UInt16) -> Int64 {
        let bytes = readSlot(slot)
        guard bytes.count >= 8 else { return 0 }
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(bytes[index]) << (index * 8) }
        return Int64(bitPattern: value)
    }
    public func readFloat(_ slot: UInt16) -> Float {
        Float(bitPattern: UInt32(bitPattern: readInt(slot)))
    }

    public func writeBool(_ slot: UInt16, _ value: Bool) { writeSlot(slot, bytes: [value ? 1 : 0]) }
    public func writeInt(_ slot: UInt16, _ value: Int32) {
        let raw = UInt32(bitPattern: value)
        writeSlot(slot, bytes: [UInt8(truncatingIfNeeded: raw), UInt8(truncatingIfNeeded: raw >> 8),
                                UInt8(truncatingIfNeeded: raw >> 16), UInt8(truncatingIfNeeded: raw >> 24)])
    }
    public func writeFloat(_ slot: UInt16, _ value: Float) { writeInt(slot, Int32(bitPattern: value.bitPattern)) }
}
