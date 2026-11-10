import Testing
import Foundation
import WirebenchCore

/// The wiring rules from `GrafickeOkno.html`, as recorded in docs/spec/ui-original.md §5:
/// wiring runs input-to-output, an output may feed many inputs, and an input holds exactly one
/// connection.
///
/// Note the shape of these tests: `#expect` captures its expression in a closure, so a `mutating`
/// call cannot appear inside it. Every connection is therefore made through a local first.
@Suite("Wiring rules")
struct WiringTests {
    static func module(_ id: Int, inPins: Int, outPins: Int) -> PCCModule {
        PCCModule(id: id, guid: UUID(), name: "M\(id)", x: Double(id) * 200, y: 0, order: id * 10,
                  threadId: 1, page: "main",
                  inPins: (0..<inPins).map { Pin(id: $0, value: .int32(0)) },
                  outPins: (0..<outPins).map { Pin(id: $0, value: .int32(0)) })
    }

    static func project(_ modules: [PCCModule]) -> PCCProject {
        var p = PCCProject(name: "wire")
        p.pages = [ProjectPage(caption: "main")]
        p.modules = modules
        return p
    }

    @Test("An output pin connects to an input pin")
    func connectBasic() {
        var p = Self.project([Self.module(1, inPins: 1, outPins: 1), Self.module(2, inPins: 2, outPins: 0)])
        let error = p.connect(outModuleId: 1, outPinId: 0, toModuleId: 2, inPinId: 1)
        #expect(error == nil)
        #expect(p.connection(inModuleId: 2, inPinId: 1)?.outModuleId == 1)
        #expect(p.inConnections.count == 1)
    }

    @Test("One output may feed many inputs")
    func fanOut() {
        var p = Self.project([Self.module(1, inPins: 0, outPins: 1),
                              Self.module(2, inPins: 1, outPins: 0),
                              Self.module(3, inPins: 1, outPins: 0)])
        let first = p.connect(outModuleId: 1, outPinId: 0, toModuleId: 2, inPinId: 0)
        let second = p.connect(outModuleId: 1, outPinId: 0, toModuleId: 3, inPinId: 0)
        #expect(first == nil && second == nil)
        #expect(p.connections(outModuleId: 1, outPinId: 0).count == 2)
        #expect(p.inConnections.count == 2)
    }

    @Test("An input holds exactly one connection, so a new wire replaces the old")
    func inputIsExclusive() {
        var p = Self.project([Self.module(1, inPins: 0, outPins: 1),
                              Self.module(2, inPins: 0, outPins: 1),
                              Self.module(3, inPins: 1, outPins: 0)])
        let first = p.connect(outModuleId: 1, outPinId: 0, toModuleId: 3, inPinId: 0)
        #expect(first == nil)
        #expect(p.connection(inModuleId: 3, inPinId: 0)?.outModuleId == 1)

        // Reconnecting the same input must replace rather than accumulate.
        let second = p.connect(outModuleId: 2, outPinId: 0, toModuleId: 3, inPinId: 0)
        #expect(second == nil)
        #expect(p.inConnections.count == 1, "the old wire is replaced")
        #expect(p.connection(inModuleId: 3, inPinId: 0)?.outModuleId == 2)
    }

    @Test("Refused cases are reported rather than silently accepted")
    func refusals() {
        var selfWire = Self.project([Self.module(1, inPins: 2, outPins: 2)])
        let same = selfWire.connect(outModuleId: 1, outPinId: 0, toModuleId: 1, inPinId: 0)
        #expect(same == .sameModule, "a module cannot wire to itself")
        #expect(selfWire.inConnections.isEmpty)

        var q = Self.project([Self.module(1, inPins: 0, outPins: 1), Self.module(2, inPins: 1, outPins: 0)])
        let badOut = q.connect(outModuleId: 1, outPinId: 5, toModuleId: 2, inPinId: 0)
        let badIn = q.connect(outModuleId: 1, outPinId: 0, toModuleId: 2, inPinId: 7)
        let badModule = q.connect(outModuleId: 99, outPinId: 0, toModuleId: 2, inPinId: 0)
        #expect(badOut == .unknownPin)
        #expect(badIn == .unknownPin)
        #expect(badModule == .unknownPin)
        #expect(q.inConnections.isEmpty)

        let ok = q.connect(outModuleId: 1, outPinId: 0, toModuleId: 2, inPinId: 0)
        let again = q.connect(outModuleId: 1, outPinId: 0, toModuleId: 2, inPinId: 0)
        #expect(ok == nil)
        #expect(again == .alreadyConnected, "an identical wire is not added twice")
        #expect(q.inConnections.count == 1)
    }

    @Test("Disconnecting an input leaves the output's other wires alone")
    func disconnectIsPerInput() {
        var p = Self.project([Self.module(1, inPins: 0, outPins: 1),
                              Self.module(2, inPins: 1, outPins: 0),
                              Self.module(3, inPins: 1, outPins: 0)])
        _ = p.connect(outModuleId: 1, outPinId: 0, toModuleId: 2, inPinId: 0)
        _ = p.connect(outModuleId: 1, outPinId: 0, toModuleId: 3, inPinId: 0)

        let removed = p.disconnect(inModuleId: 2, inPinId: 0)
        let removedAgain = p.disconnect(inModuleId: 2, inPinId: 0)
        #expect(removed)
        #expect(!removedAgain, "disconnecting nothing reports false")
        #expect(p.connection(inModuleId: 2, inPinId: 0) == nil)
        #expect(p.connection(inModuleId: 3, inPinId: 0) != nil, "the other branch survives")
    }

    @Test("A connected project survives a save and re-parse")
    func roundTripsThroughXML() throws {
        var p = Self.project([Self.module(1, inPins: 0, outPins: 1), Self.module(2, inPins: 1, outPins: 0)])
        _ = p.connect(outModuleId: 1, outPinId: 0, toModuleId: 2, inPinId: 0)

        let xml = PCCSerializer().serialize(project: p)
        let reparse = try PCCParser().parse(xmlString: xml)
        #expect(reparse.inConnections.count == 1, "a new wire must survive the round trip")
        #expect(reparse.connection(inModuleId: 2, inPinId: 0)?.outModuleId == 1)
    }
}
