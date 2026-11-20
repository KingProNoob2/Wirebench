import Foundation
import WirebenchCore
import WirebenchLibrary

/// Expands FBD macro calls into ordinary modules before MFLW emission.
///
/// The VM has no call instruction: Maraflow inlines each macro page at the call site, and so does the
/// Dirigo compiler. Doing that once here keeps the emitter a flat block compiler. Interface blocks
/// (`Macro IO`) are wiring-only and are removed after their wires have been redirected.
enum DuinoMacroExpander {
    static func expand(_ project: PCCProject) throws -> PCCProject {
        var result = project
        var nextID = (result.modules.map(\.id).max() ?? 0) + 1
        var rounds = 0
        while rounds < 1_000 {
            rounds += 1
            guard let callIndex = result.modules.firstIndex(where: {
                $0.guid == MacroBlock.guid && !$0.page.hasPrefix("*")
            }) else { break }
            let call = result.modules[callIndex]
            let target = (call.rawAttributes["MARAFLOW_DEF"].map { String($0.dropFirst("Macro.User.".count)) }
                          ?? call.rawAttributes["MACRO_NAME"] ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else {
                throw DuinoCompiler.CompileError.missingDefinition(call.name)
            }
            let pageName = "*" + target.lowercased()
            let pageModules = result.modules.filter { $0.page.lowercased() == pageName }
            guard !pageModules.isEmpty else {
                throw DuinoCompiler.CompileError.missingDefinition(call.name)
            }

            var idMap: [Int: Int] = [:]
            for module in pageModules.sorted(by: { ($0.order, $0.id) < ($1.order, $1.id) }) {
                idMap[module.id] = nextID
                nextID += 1
            }
            var clones: [PCCModule] = []
            for module in pageModules {
                var copy = module
                copy.id = idMap[module.id]!
                copy.page = call.page
                copy.threadId = call.threadId
                copy.order = call.order
                clones.append(copy)
            }

            func isInterface(_ module: PCCModule, kind: String? = nil) -> Bool {
                guard module.guid == InputsBlock.guid else { return false }
                guard let kind else { return true }
                return (module.rawAttributes["MACRO_NAME"] ?? "").lowercased() == kind.lowercased()
                    || (module.rawAttributes["KIND"] ?? "") == (kind.lowercased() == "outputs" ? "1" : "0")
            }
            func clonePinValue(moduleID: Int, pin: Int, inPins: Bool, value: PinValue) {
                guard let index = clones.firstIndex(where: { $0.id == moduleID }) else { return }
                if inPins, clones[index].inPins.indices.contains(pin) {
                    clones[index].inPins[pin].value = value
                }
            }

            var newConnections: [Connection] = []
            let pageConnections = (result.inConnections + result.paramConnections)
            let pageConnectionsInternal = pageConnections.filter { connection in
                idMap[connection.inModuleId] != nil && idMap[connection.outModuleId] != nil
            }
            let interfaceIDs = pageModules.filter { isInterface($0) }.map(\.id)
            let interfaceCloneIDs = Set(interfaceIDs.compactMap { idMap[$0] })
            let inputsInterfaces = pageModules.filter { isInterface($0, kind: "inputs") }
            let outputsInterfaces = pageModules.filter { isInterface($0, kind: "outputs") }

            // Wire caller inputs into what reads each Macro IO output.
            for interface in inputsInterfaces {
                for pin in interface.outPins.indices {
                    let callerPin = call.inPins.indices.contains(pin) ? call.inPins[pin].id : pin
                    let callerConnection = pageConnections.first {
                        $0.inModuleId == call.id && $0.inPinId == callerPin
                    }
                    let readers = pageConnectionsInternal.filter {
                        $0.outModuleId == interface.id && $0.outPinId == pin
                    }
                    for reader in readers {
                        guard let targetModule = idMap[reader.inModuleId] else { continue }
                        if let callerConnection {
                            newConnections.append(Connection(
                                inModuleId: targetModule, inPinId: reader.inPinId,
                                outModuleId: callerConnection.outModuleId, outPinId: callerConnection.outPinId,
                                isParam: reader.isParam
                            ))
                        } else {
                            let source = call.inPins.indices.contains(pin) ? call.inPins[pin].value : .undefined
                            clonePinValue(moduleID: targetModule, pin: reader.inPinId, inPins: true, value: source)
                        }
                    }
                }
            }

            // Wire what feeds each Macro IO input out to the caller's readers.
            for interface in outputsInterfaces {
                for pin in interface.inPins.indices {
                    let sources = pageConnectionsInternal.filter {
                        $0.inModuleId == interface.id && $0.inPinId == pin
                    }
                    let callerPin = call.outPins.indices.contains(pin) ? call.outPins[pin].id : pin
                    let readers = pageConnections.filter {
                        $0.outModuleId == call.id && $0.outPinId == callerPin
                    }
                    for source in sources {
                        guard let sourceModule = idMap[source.outModuleId] else { continue }
                        for reader in readers {
                            newConnections.append(Connection(
                                inModuleId: reader.inModuleId, inPinId: reader.inPinId,
                                outModuleId: sourceModule, outPinId: source.outPinId,
                                isParam: reader.isParam
                            ))
                        }
                    }
                }
            }

            // Clone wiring that neither endpoint is an interface block.
            for connection in pageConnectionsInternal where
                !interfaceIDs.contains(connection.inModuleId) && !interfaceIDs.contains(connection.outModuleId) {
                guard let source = idMap[connection.outModuleId], let target = idMap[connection.inModuleId] else { continue }
                var copy = connection
                copy.outModuleId = source
                copy.inModuleId = target
                newConnections.append(copy)
            }

            // Replace the call with its inlined body. Interface blocks are wiring only and are not compiled.
            result.modules.removeAll { $0.id == call.id || interfaceCloneIDs.contains($0.id) }
            result.modules += clones.filter { !interfaceCloneIDs.contains($0.id) }
            let callID = call.id
            result.inConnections.removeAll { $0.inModuleId == callID || $0.outModuleId == callID }
            result.paramConnections.removeAll { $0.inModuleId == callID || $0.outModuleId == callID }
            for connection in newConnections {
                if connection.isParam { result.paramConnections.append(connection) }
                else { result.inConnections.append(connection) }
            }
            rounds += 0
        }
        return result
    }
}
