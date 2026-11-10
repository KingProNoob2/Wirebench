import Foundation
import WirebenchCore
import WirebenchLibrary
import WirebenchModel

/// What a handle from `wirebench_create` points at: the model, its wire layout, and whether the scene changed.
@MainActor
final class BridgeSession {
    let model: AppModel
    let layout = WireLayout()
    var dirty = true
    /// Set when the model has agreed to quit.
    var quitRequested = false
    /// Blocks being dragged, shown moved before the move is committed.
    var dragOffsets: [Int: CGSize] = [:]
    /// The same for shapes, by their index in the project's graphics.
    var graphicDrag: [Int: CGSize] = [:]

    init() {
        // A session of its own must not share what the block picker learned with the app's defaults.
        model = AppModel()
        model.playsOnHostTimer = true
        model.quitHandler = { [weak self] in self?.quitRequested = true }
    }
}

private func string(_ text: String) -> UnsafeMutablePointer<CChar>? { strdup(text) }

private func session(_ address: Int) -> BridgeSession {
    Unmanaged<BridgeSession>.fromOpaque(UnsafeRawPointer(bitPattern: address)!).takeUnretainedValue()
}

@_cdecl("wirebench_create")
public func wirebench_create() -> UnsafeMutableRawPointer? {
    let address = MainActor.assumeIsolated { Int(bitPattern: Unmanaged.passRetained(BridgeSession()).toOpaque()) }
    return UnsafeMutableRawPointer(bitPattern: address)
}

@_cdecl("wirebench_destroy")
public func wirebench_destroy(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    Unmanaged<BridgeSession>.fromOpaque(pointer).release()
}

@_cdecl("wirebench_free")
public func wirebench_free(_ text: UnsafeMutablePointer<CChar>?) { free(text) }

@_cdecl("wirebench_scene")
public func wirebench_scene(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? {
    let address = Int(bitPattern: pointer)
    let text: String = MainActor.assumeIsolated {
        let s = session(address)
        s.dirty = false
        let snapshot = SceneSnapshot.make(of: s.model, layout: s.layout, dragOffsets: s.dragOffsets, graphicDrag: s.graphicDrag, quit: s.quitRequested)
        let data = (try? JSONEncoder().encode(snapshot)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
    return string(text)
}

@_cdecl("wirebench_tick")
public func wirebench_tick(_ pointer: UnsafeMutableRawPointer?, _ elapsedMs: Double) -> Int32 {
    let address = Int(bitPattern: pointer)
    return MainActor.assumeIsolated {
        let s = session(address)
        let before = s.model.simulationVersion
        s.model.hostTick(elapsedMs: elapsedMs)
        if s.model.simulationVersion != before { s.dirty = true }
        return s.dirty ? 1 : 0
    }
}

@_cdecl("wirebench_tick_count")
public func wirebench_tick_count(_ pointer: UnsafeMutableRawPointer?) -> UInt64 {
    let address = Int(bitPattern: pointer)
    return MainActor.assumeIsolated { session(address).model.tickCount }
}

@_cdecl("wirebench_command")
public func wirebench_command(_ pointer: UnsafeMutableRawPointer?, _ json: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    let input = json.map { String(cString: $0) } ?? "{}"
    let address = Int(bitPattern: pointer)
    let output: String = MainActor.assumeIsolated {
        let s = session(address)
        let text = input
        let arguments = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        let reply = BridgeCommands.run(arguments, in: s)
        s.dirty = true
        let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{\"ok\":false}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
    return string(output)
}

/// Runs what Swift concurrency has queued for the main actor. A frontend with its own event loop (Qt) does not drain the
/// main dispatch queue, so tasks that wait on the main actor — an upload talking to the serial port — only advance when
/// this is called from its timer.
@_cdecl("wirebench_pump")
public func wirebench_pump() {
    RunLoop.main.run(mode: .default, before: Date())
}
