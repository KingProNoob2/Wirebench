import Testing
import Foundation
@testable import DirigoCore
@testable import DirigoEngine
@testable import DirigoLibrary
@testable import DirigoApp

/// `If` / `Switch` as containers: they expand into Dirigo's marker blocks for the simulator and the legacy export.
@Suite("Construct containers")
struct ConstructContainerTests {
    static func module(_ id: Int, _ name: String, _ guid: UUID, order: Int,
                       inPins: [PinValue] = [], outPins: [PinValue] = [],
                       attributes: [String: String] = [:]) -> PCCModule {
        var m = PCCModule(id: id, guid: guid, name: name, x: 0, y: 0, order: order, threadId: 1, page: "main",
                          inPins: inPins.enumerated().map { Pin(id: $0.offset, value: $0.element) },
                          outPins: outPins.enumerated().map { Pin(id: $0.offset, value: $0.element) })
        for (key, value) in attributes { m.rawAttributes[key] = value }
        return m
    }

    static func yes(_ id: Int, order: Int, container: Int? = nil, arm: String? = nil) -> PCCModule {
        var attrs: [String: String] = [:]
        if let container, let arm { attrs = ["IN_CONTAINER": "\(container)", "ARM": arm] }
        return module(id, "Yes\(id)", YesBlock.guid, order: order,
                      inPins: [.bool(true)], outPins: [.bool(false)], attributes: attrs)
    }

    static func project(_ modules: [PCCModule]) -> PCCProject {
        var p = PCCProject(name: "containers")
        p.pages = [ProjectPage(caption: "main")]
        p.modules = modules
        return p
    }

    static let ifContainer = module(1, "If1", ConstructContainers.ifGuid, order: 10, inPins: [.bool(true)],
                                    outPins: [.bool(true)], attributes: ["CONTAINER": "1"])

    @Test("A project with no containers is returned as it was")
    func untouched() {
        let p = Self.project([Self.yes(1, order: 10), Self.yes(2, order: 20)])
        #expect(ConstructContainers.expanded(p) == p)
    }

    @Test("An If container expands to If, Then body, Else, Else body, EndIf in execution order")
    func ifExpansion() {
        let p = Self.project([
            Self.ifContainer,
            Self.yes(2, order: 99, container: 1, arm: "else"),
            Self.yes(3, order: 50, container: 1, arm: "then"),
            Self.yes(4, order: 30),
        ])
        let out = ConstructContainers.expanded(p).modules
        let run = out.sorted { $0.order < $1.order }.map(\.name)
        // Yes4 (order 30) stays after the container's own position by its original order; the container's body follows it.
        #expect(run == ["If1", "Yes3", "Else", "Yes2", "EndIf", "Yes4"])
        #expect(out.allSatisfy { $0.rawAttributes["CONTAINER"] == nil && $0.rawAttributes["ARM"] == nil })
        #expect(Set(out.map(\.id)).count == out.count)
    }

    @Test("A switch container writes a Case marker per case, with its values, then Default and EndSwitch")
    func switchExpansion() {
        let sw = Self.module(1, "Switch1", ConstructContainers.switchGuid, order: 10, inPins: [.bool(true), .int32(0)],
                             attributes: ["CONTAINER": "1", "CASES": "1|5..7", "DEFAULT": "1"])
        let p = Self.project([sw, Self.yes(2, order: 20, container: 1, arm: "case1"),
                              Self.yes(3, order: 30, container: 1, arm: "default")])
        let out = ConstructContainers.expanded(p).modules.sorted { $0.order < $1.order }
        #expect(out.map(\.name) == ["Switch1", "Case", "Case", "Yes2", "Default", "Yes3", "EndSwitch"])
        #expect(out.filter { $0.guid == ConstructContainers.caseGuid }.map { $0.rawAttributes["VALUES"] } == ["1", "5..7"])
    }

    @Test("A container holding itself, or naming a missing branch, is treated as ordinary blocks")
    func badMembership() {
        var a = Self.ifContainer
        a.rawAttributes["IN_CONTAINER"] = "5"; a.rawAttributes["ARM"] = "then"
        var b = Self.module(5, "If2", ConstructContainers.ifGuid, order: 20, inPins: [.bool(true)],
                            attributes: ["CONTAINER": "1", "IN_CONTAINER": "1", "ARM": "then"])
        b.rawAttributes["CONTAINER"] = "1"
        let lost = Self.yes(6, order: 30, container: 1, arm: "nonsense")
        let out = ConstructContainers.expanded(Self.project([a, b, lost])).modules
        #expect(Set(out.map(\.id)).isSuperset(of: [1, 5, 6]))
    }

    @Test("The simulator gates a container's body by its En")
    func simulation() {
        var p = Self.project([Self.ifContainer, Self.yes(2, order: 20, container: 1, arm: "then"),
                              Self.yes(3, order: 30, container: 1, arm: "else")])
        p.modules[1].inPins[0] = Pin(id: 0, value: .bool(true))
        let engine = SimulationEngine(project: p)
        engine.step()
        #expect(engine.getNode(id: 2)?.block.outPins[0].asBool == true)    // then ran
        #expect(engine.getNode(id: 3)?.block.outPins[0].asBool == false)   // else did not
        engine.getNode(id: 1)?.block.inPins[0] = .bool(false)
        engine.step()
        #expect(engine.getNode(id: 3)?.block.outPins[0].asBool == true)    // now the else branch runs
    }

    @Test("The legacy export reads back as marker blocks with no container attributes")
    func exportRoundTrip() throws {
        let p = Self.project([Self.ifContainer, Self.yes(2, order: 20, container: 1, arm: "then")])
        let xml = PCCSerializer().serialize(project: ConstructContainers.expanded(p))
        #expect(!xml.contains("CONTAINER"))
        #expect(!xml.contains("IN_CONTAINER"))
        #expect(xml.uppercased().contains(ConstructContainers.endIfGuid.uuidString))
    }
}

@Suite("Container editing")
@MainActor
struct ContainerEditingTests {
    @Test("A block can be put into a branch and taken out, but a container cannot hold itself")
    func setContainer() {
        let model = AppModel()
        model.project = ConstructContainerTests.project([
            ConstructContainerTests.ifContainer,
            ConstructContainerTests.yes(2, order: 20),
            ConstructContainerTests.module(3, "If2", ConstructContainers.ifGuid, order: 30, inPins: [.bool(true)],
                                           attributes: ["CONTAINER": "1"]),
        ])
        model.setContainer(of: 2, to: (1, "then"))
        #expect(model.project?.modules[1].rawAttributes["ARM"] == "then")
        model.setContainer(of: 3, to: (1, "else"))
        model.setContainer(of: 1, to: (3, "then"))     // 3 is in 1: would loop
        #expect(model.project?.modules[0].rawAttributes["IN_CONTAINER"] == nil)
        model.setContainer(of: 2, to: (1, "bogus"))    // no such branch: unchanged
        #expect(model.project?.modules[1].rawAttributes["ARM"] == "then")
        model.setContainer(of: 2, to: nil)
        #expect(model.project?.modules[1].rawAttributes["IN_CONTAINER"] == nil)
    }

    static func switchProject(cases: String, hasDefault: Bool) -> PCCProject {
        project([
            ConstructContainerTests.module(1, "Switch1", ConstructContainers.switchGuid, order: 10,
                                           inPins: [.bool(true), .int32(0)],
                                           attributes: ["CONTAINER": "1", "CASES": cases,
                                                        "DEFAULT": hasDefault ? "1" : "0"]),
            ConstructContainerTests.yes(2, order: 20, container: 1, arm: "c1"),
            ConstructContainerTests.yes(3, order: 30, container: 1, arm: "c2"),
        ])
    }
    static func project(_ modules: [PCCModule]) -> PCCProject { ConstructContainerTests.project(modules) }
    static func arm(_ model: AppModel, _ id: Int) -> String? {
        model.project?.modules.first { $0.id == id }?.rawAttributes["ARM"]
    }

    @Test("Files from before case ids still read: a bare value list is case0, case1, …")
    func legacyCasesRead() {
        let sw = ConstructContainerTests.module(1, "Switch1", ConstructContainers.switchGuid, order: 10,
                                                attributes: ["CONTAINER": "1", "CASES": "1|5..7"])
        #expect(ConstructContainers.cases(of: sw) == [.init(id: "case0", values: "1"), .init(id: "case1", values: "5..7")])
    }

    @Test("Editing values and reordering cases keeps every block in its case, and export follows the new order")
    func reorderKeepsMembers() {
        let model = AppModel()
        model.project = Self.switchProject(cases: "c1:1|c2:2", hasDefault: false)
        model.setSwitchCases(of: 1, to: [.init(id: "c2", values: "7..9"), .init(id: "c1", values: "1")], hasDefault: false)
        #expect(Self.arm(model, 2) == "c1")
        #expect(Self.arm(model, 3) == "c2")
        // Legacy export: Switch, Case 7..9 + Yes3, Case 1 + Yes2, EndSwitch.
        let out = ConstructContainers.expanded(model.project!).modules.sorted { $0.order < $1.order }
        #expect(out.map(\.name) == ["Switch1", "Case", "Yes3", "Case", "Yes2", "EndSwitch"])
        #expect(out.filter { $0.guid == ConstructContainers.caseGuid }.map { $0.rawAttributes["VALUES"] } == ["7..9", "1"])
        #expect(out.allSatisfy { $0.rawAttributes["CASES"] == nil && $0.rawAttributes["ARM"] == nil })
    }

    @Test("Blocks of a removed case go to the default branch when there is one")
    func removedCaseGoesToDefault() {
        let model = AppModel()
        model.project = Self.switchProject(cases: "c1:1|c2:2", hasDefault: true)
        model.setSwitchCases(of: 1, to: [.init(id: "c2", values: "2")], hasDefault: true)
        #expect(Self.arm(model, 2) == "default")
        #expect(Self.arm(model, 3) == "c2")
    }

    @Test("Without a default branch, blocks of a removed case leave the switch — and one undo restores it all")
    func removedCaseLeavesSwitch() {
        let model = AppModel()
        model.project = Self.switchProject(cases: "c1:1|c2:2", hasDefault: false)
        let before = model.project
        model.setSwitchCases(of: 1, to: [.init(id: "c2", values: "2")], hasDefault: false)
        #expect(model.project?.modules.first { $0.id == 2 }?.rawAttributes["IN_CONTAINER"] == nil)
        #expect(Self.arm(model, 2) == nil)
        model.undo()
        #expect(model.project == before)
    }

    @Test("A new case gets an id no other case has")
    func newCaseIdIsUnique() {
        let existing: [ConstructContainers.Case] = [.init(id: "c2", values: "1"), .init(id: "case0", values: "2")]
        #expect(!existing.map(\.id).contains(ConstructContainers.newCaseId(among: existing)))
    }
}
