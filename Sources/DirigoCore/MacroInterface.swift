import Foundation

/// A macro's interface: the `Inputs` and `Outputs` modules inside its `*` sheet, and the call sites whose pins mirror
/// them.
///
/// Dirigo has no separate "macro definition": the sheet's `Inputs` block *is* the list of input pins, its `Outputs`
/// block the list of output pins, and every call is a module whose pins carry the same names. So editing the
/// interface means editing the sheet and then rebuilding each call to match — which is what `syncCalls` does, keeping
/// the values and wires of the pins that are still there.
public enum MacroInterface {
    /// The block type of a call site.
    public static let callGUID = UUID(uuidString: "848C8ACE-58B9-48D8-9CAC-DE5DB5055674")!
    /// The block type of the `Inputs` / `Outputs` / `Params` modules inside a sheet.
    public static let interfaceGUID = UUID(uuidString: "3FFBEEC3-FD74-4C54-96F7-864A9D7F5DFC")!

    public enum Kind: Int, Sendable, CaseIterable {
        case inputs = 0, outputs = 1

        public var attributeName: String { self == .inputs ? "Inputs" : "Outputs" }
    }

    /// The macro name of a sheet caption: `*SCITACKA` is `SCITACKA`.
    public static func name(ofSheet caption: String) -> String {
        caption.hasPrefix("*") ? String(caption.dropFirst()) : caption
    }

    /// The interface kind of a module, or `nil` when it is not one (a `Params` block is left alone).
    public static func kind(of module: PCCModule) -> Kind? {
        switch module.rawAttributes["MACRO_NAME"]?.lowercased() {
        case "inputs": return .inputs
        case "outputs": return .outputs
        default: return nil
        }
    }

    /// The names of an interface module's pins: the output pins of `Inputs`, the input pins of `Outputs`.
    public static func pinNames(of module: PCCModule) -> [String] {
        let pins = kind(of: module) == .outputs ? module.inPins : module.outPins
        return pins.enumerated().map { $0.element.name ?? "Pin\($0.offset + 1)" }
    }
}

extension PCCProject {
    /// The interface module of `kind` on a sheet.
    public func macroInterface(_ kind: MacroInterface.Kind, onSheet sheet: String) -> PCCModule? {
        modules.first { $0.page == sheet && MacroInterface.kind(of: $0) == kind }
    }

    /// Every call of the macro `sheet` names, on any page.
    public func calls(ofSheet sheet: String) -> [PCCModule] {
        let name = MacroInterface.name(ofSheet: sheet).lowercased()
        return modules.filter { MacroCalls.target(of: $0)?.lowercased() == name }
    }

    /// The `*` sheets a macro can be called from `page` without the call ending up inside itself: not the sheet
    /// the call is on, and not a sheet that (through any chain of calls) already calls it.
    public func callableSheets(from page: String) -> [String] {
        func reaches(_ from: String, _ target: String, seen: Set<String>) -> Bool {
            if from.lowercased() == target.lowercased() { return true }
            guard !seen.contains(from.lowercased()) else { return false }
            return modules.contains { module in
                guard module.page == from, let callee = MacroCalls.target(of: module) else { return false }
                return reaches("*" + callee, target, seen: seen.union([from.lowercased()]))
            }
        }
        return pages.map(\.caption).filter { $0.hasPrefix("*") && !reaches($0, page, seen: []) }
    }

    // MARK: - Making the pieces

    private static func interfacePin(_ name: String, side: MacroInterface.Kind, value: PinValue = .bool(false)) -> Pin {
        var pin = Pin(id: 0, value: value, inverted: false, rights: side == .inputs ? 2 : 0, name: name, format: nil)
        pin.rawAttributes["TYPE"] = "1"
        return pin
    }

    /// The `Inputs` or `Outputs` module of a sheet, with one pin called `A` / `Out1` so it can be wired at once.
    public func makeMacroInterface(_ kind: MacroInterface.Kind, onSheet sheet: String, id: Int, name: String,
                                   x: Double, y: Double, order: Int) -> PCCModule {
        var module = PCCModule(id: id, guid: MacroInterface.interfaceGUID, name: name, x: x, y: y, order: order,
                               threadId: 0, page: sheet)
        module.rawAttributes["MACRO_NAME"] = kind.attributeName
        module.rawAttributes["KIND"] = String(kind.rawValue)
        switch kind {
        case .inputs: module.outPins = [Self.interfacePin("A", side: .inputs)]
        case .outputs: module.inPins = [Self.interfacePin("Out1", side: .outputs)]
        }
        return module
    }

    /// A call of the macro `sheet`, its pins named after the sheet's interface.
    public func makeMacroCall(sheet: String, id: Int, name: String, x: Double, y: Double, order: Int,
                              threadId: Int, page: String) -> PCCModule {
        var module = PCCModule(id: id, guid: MacroInterface.callGUID, name: name, x: x, y: y, order: order,
                               threadId: threadId, page: page)
        module.rawAttributes["MACRO_NAME"] = MacroInterface.name(ofSheet: sheet)
        shape(&module, to: sheet)
        return module
    }

    /// Gives `call` the pins its macro's interface lists, keeping what the pins it already has hold.
    private func shape(_ call: inout PCCModule, to sheet: String) {
        let inputs = macroInterface(.inputs, onSheet: sheet).map(MacroInterface.pinNames(of:)) ?? []
        let outputs = macroInterface(.outputs, onSheet: sheet).map(MacroInterface.pinNames(of:)) ?? []

        var ins: [Pin] = []
        for (index, name) in inputs.enumerated() {
            var pin = index < call.inPins.count ? call.inPins[index] : Pin(id: index, value: PinValue.parse("0"))
            pin.id = index
            pin.name = name
            pin.rawAttributes["TYPE"] = pin.rawAttributes["TYPE"] ?? "1"
            ins.append(pin)
        }
        var outs: [Pin] = []
        for (index, name) in outputs.enumerated() {
            var pin = index < call.outPins.count ? call.outPins[index] : Pin(id: index, rights: 2)
            pin.id = index
            pin.name = name
            pin.rights = 2
            pin.rawAttributes["TYPE"] = pin.rawAttributes["TYPE"] ?? "1"
            outs.append(pin)
        }
        call.inPins = ins
        call.outPins = outs
    }

    // MARK: - Keeping calls in step

    /// Rebuilds every call of `sheet` to match the interface, and drops the wires that ended on a pin that is gone.
    public mutating func syncCalls(ofSheet sheet: String) {
        let callIds = Set(calls(ofSheet: sheet).map(\.id))
        for index in modules.indices where callIds.contains(modules[index].id) {
            var call = modules[index]
            shape(&call, to: sheet)
            modules[index] = call
        }
        inConnections.removeAll { wire in
            if callIds.contains(wire.inModuleId),
               let call = modules.first(where: { $0.id == wire.inModuleId }), wire.inPinId >= call.inPins.count { return true }
            if callIds.contains(wire.outModuleId),
               let call = modules.first(where: { $0.id == wire.outModuleId }), wire.outPinId >= call.outPins.count { return true }
            return false
        }
    }

    /// Appends a pin to an interface module and brings the calls along.
    @discardableResult
    public mutating func addInterfacePin(moduleId: Int) -> Bool {
        guard let index = modules.firstIndex(where: { $0.id == moduleId }),
              let kind = MacroInterface.kind(of: modules[index]) else { return false }
        let names = MacroInterface.pinNames(of: modules[index])
        let stem = kind == .inputs ? "A" : "Out"
        var number = kind == .inputs ? names.count : names.count + 1
        while names.contains("\(stem)\(number)") { number += 1 }
        let candidate = "\(stem)\(number)"
        var pin = Self.interfacePin(candidate, side: kind)
        switch kind {
        case .inputs: pin.id = modules[index].outPins.count; modules[index].outPins.append(pin)
        case .outputs: pin.id = modules[index].inPins.count; modules[index].inPins.append(pin)
        }
        syncCalls(ofSheet: modules[index].page)
        return true
    }

    /// Renames an interface pin; the calls show the new name.
    @discardableResult
    public mutating func renameInterfacePin(moduleId: Int, pin: Int, to newName: String) -> Bool {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = modules.firstIndex(where: { $0.id == moduleId }),
              let kind = MacroInterface.kind(of: modules[index]) else { return false }
        switch kind {
        case .inputs:
            guard modules[index].outPins.indices.contains(pin) else { return false }
            modules[index].outPins[pin].name = name
        case .outputs:
            guard modules[index].inPins.indices.contains(pin) else { return false }
            modules[index].inPins[pin].name = name
        }
        syncCalls(ofSheet: modules[index].page)
        return true
    }

    /// Removes an interface pin. Wires on the pin go with it; the wires on the pins after it keep their pin, which
    /// now has one number less — on the interface module and on every call alike.
    @discardableResult
    public mutating func removeInterfacePin(moduleId: Int, pin: Int) -> Bool {
        guard let index = modules.firstIndex(where: { $0.id == moduleId }),
              let kind = MacroInterface.kind(of: modules[index]) else { return false }
        let sheet = modules[index].page
        let callIds = Set(calls(ofSheet: sheet).map(\.id))

        switch kind {
        case .inputs:
            guard modules[index].outPins.indices.contains(pin) else { return false }
            modules[index].outPins.remove(at: pin)
            for p in modules[index].outPins.indices { modules[index].outPins[p].id = p }
            // Inside the sheet: wires leaving the removed pin go, later pins shift down.
            inConnections.removeAll { $0.outModuleId == moduleId && $0.outPinId == pin }
            for c in inConnections.indices where inConnections[c].outModuleId == moduleId && inConnections[c].outPinId > pin {
                inConnections[c].outPinId -= 1
            }
            // At the calls: the wires and constants of the matching input pin.
            inConnections.removeAll { callIds.contains($0.inModuleId) && $0.inPinId == pin }
            for c in inConnections.indices where callIds.contains(inConnections[c].inModuleId) && inConnections[c].inPinId > pin {
                inConnections[c].inPinId -= 1
            }
            for m in modules.indices where callIds.contains(modules[m].id) && modules[m].inPins.indices.contains(pin) {
                modules[m].inPins.remove(at: pin)
            }
        case .outputs:
            guard modules[index].inPins.indices.contains(pin) else { return false }
            modules[index].inPins.remove(at: pin)
            for p in modules[index].inPins.indices { modules[index].inPins[p].id = p }
            inConnections.removeAll { $0.inModuleId == moduleId && $0.inPinId == pin }
            for c in inConnections.indices where inConnections[c].inModuleId == moduleId && inConnections[c].inPinId > pin {
                inConnections[c].inPinId -= 1
            }
            inConnections.removeAll { callIds.contains($0.outModuleId) && $0.outPinId == pin }
            for c in inConnections.indices where callIds.contains(inConnections[c].outModuleId) && inConnections[c].outPinId > pin {
                inConnections[c].outPinId -= 1
            }
            for m in modules.indices where callIds.contains(modules[m].id) && modules[m].outPins.indices.contains(pin) {
                modules[m].outPins.remove(at: pin)
            }
        }
        syncCalls(ofSheet: sheet)
        return true
    }

    /// Renames a macro sheet: its page, the modules on it, and the `MACRO_NAME` of every call.
    @discardableResult
    public mutating func renameMacroSheet(from old: String, to new: String) -> Bool {
        guard old.hasPrefix("*"), new.hasPrefix("*"), new.count > 1,
              pages.contains(where: { $0.caption == old }),
              !pages.contains(where: { $0.caption.lowercased() == new.lowercased() && $0.caption != old }) else { return false }
        let oldName = MacroInterface.name(ofSheet: old).lowercased()
        let newName = MacroInterface.name(ofSheet: new)
        for i in modules.indices {
            if MacroCalls.target(of: modules[i])?.lowercased() == oldName { modules[i].rawAttributes["MACRO_NAME"] = newName }
            if modules[i].page == old { modules[i].page = new }
        }
        for i in pages.indices where pages[i].caption == old { pages[i].caption = new }
        for i in graphics.indices where graphics[i].page == old { graphics[i].page = new }
        return true
    }
}
