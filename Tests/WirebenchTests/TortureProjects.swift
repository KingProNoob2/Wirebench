import Foundation
import WirebenchCore
import WirebenchLibrary
import WirebenchModel

/// Projects built to break the port rather than to look like Dirigo's own files.
///
/// The corpus on disk is 24 projects drawn by hand: mostly small sheets, one macro, one thread. These are the
/// shapes it does not contain — every block type at once, containers inside macros, extreme values, broken wire
/// graphs — because those are where a port breaks and nobody notices. Every one is built through the same
/// `BlockFactory` the editor uses, so a project here is what the editor would make.
enum TortureProjects {
    /// The instant every run is pinned to, so a `DateTime` pin cannot differ between two runs.
    static let now = Date(timeIntervalSince1970: 1_709_623_628)

    // MARK: - Pieces

    static func module(_ guid: UUID, id: Int, name: String, order: Int,
                       page: String = "main", thread: Int = 1) -> PCCModule {
        BlockFactory.makeModule(guid: guid, id: id, name: name, x: Double(id * 40), y: Double(order * 8),
                                order: order, threadId: thread, page: page)
    }

    static func connection(_ inModule: Int, _ inPin: Int, _ outModule: Int, _ outPin: Int,
                           points: Int = 0, isParam: Bool = false) -> Connection {
        Connection(inModuleId: inModule, inPinId: inPin, outModuleId: outModule, outPinId: outPin,
                   nameX: points > 0 ? 12.5 : 0, nameY: points > 0 ? -3 : 0,
                   points: (0..<points).map { RoutePoint(x: Double($0) * 3, y: Double($0) * -1) },
                   isParam: isParam)
    }

    static func project(_ name: String, pages: [String], modules: [PCCModule],
                        inConnections: [Connection] = [], paramConnections: [Connection] = []) -> PCCProject {
        var project = PCCProject(name: name)
        project.pages = pages.map { ProjectPage(caption: $0) }
        project.appOptions.cycleDelay = 7
        project.modules = modules
        project.inConnections = inConnections
        project.paramConnections = paramConnections
        return project
    }

    // MARK: - Every catalogued type at once

    /// All 147 catalogued types, on three pages and two threads, each at its default pin count.
    ///
    /// It is one project on purpose: a per-type test can pass while a *file* holding them all loses one on save, and
    /// the point is the file.
    static func kitchenSink() -> PCCProject {
        let pages = ["main", "second", "třetí"]
        var modules: [PCCModule] = []
        for (index, info) in BlockTypeCatalog.all.enumerated() {
            var module = BlockFactory.makeModule(
                guid: info.guid, id: index + 1, name: "\(info.blockName)\(index + 1)",
                x: Double((index % 7) * 140), y: Double((index / 7) * 90),
                order: (index + 1) * 10, threadId: (index % 2) + 1, page: pages[index % pages.count])
            // A couple of every block's pins get a value that is not its default, so a save that drops values shows.
            for pin in module.inPins.indices where pin % 3 == 1 { module.inPins[pin].value = .bool(true) }
            for pin in module.paramPins.indices where pin % 3 == 1 { module.paramPins[pin].value = .int32(3) }
            modules.append(module)
        }
        // The type with the most pins is wired to a `Not`, which uses three of everything the model has.
        var wires: [Connection] = []
        if modules.count > 3 {
            wires = [connection(2, 0, 1, 0, points: 4), connection(1, 1, 3, 0)]
        }
        return project("kitchen-sink", pages: pages, modules: modules, inConnections: wires)
    }

    // MARK: - Containers

    /// `If` inside `Switch` inside `If`, with an else arm, two cases and a default — and a block nested in each.
    ///
    /// `ConstructContainers.expanded` renumbers and re-threads what it touches, so the interesting part is not that
    /// the blocks run but that the *file* is untouched and the expansion is a permutation of the same modules.
    static func deepContainers() -> PCCProject {
        var outer = module(ConstructContainers.ifGuid, id: 1, name: "If1", order: 10)
        outer.rawAttributes["CONTAINER"] = "1"
        var innerSwitch = module(ConstructContainers.switchGuid, id: 2, name: "Switch1", order: 20)
        innerSwitch.rawAttributes["CONTAINER"] = "1"
        innerSwitch.rawAttributes["CASES"] = "c1:1, 5..7|c2:9"
        innerSwitch.rawAttributes["DEFAULT"] = "1"
        innerSwitch.rawAttributes["IN_CONTAINER"] = "1"
        innerSwitch.rawAttributes["ARM"] = "then"
        var innerIf = module(ConstructContainers.ifGuid, id: 3, name: "If2", order: 30)
        innerIf.rawAttributes["CONTAINER"] = "1"
        innerIf.rawAttributes["IN_CONTAINER"] = "2"
        innerIf.rawAttributes["ARM"] = "c2"

        func member(_ id: Int, _ name: String, _ guid: UUID, container: Int, arm: String, order: Int) -> PCCModule {
            var module = module(guid, id: id, name: name, order: order,
                                page: "main", thread: 1)
            module.rawAttributes["IN_CONTAINER"] = "\(container)"
            module.rawAttributes["ARM"] = arm
            return module
        }

        let modules = [
            outer, innerSwitch, innerIf,
            member(4, "Yes1", YesBlock.guid, container: 1, arm: "then", order: 11),
            member(5, "Yes2", YesBlock.guid, container: 1, arm: "else", order: 50),
            member(6, "Yes3", YesBlock.guid, container: 2, arm: "c1", order: 21),
            member(7, "Yes4", YesBlock.guid, container: 2, arm: "default", order: 60),
            member(8, "Yes5", YesBlock.guid, container: 3, arm: "then", order: 31),
            member(9, "Yes6", YesBlock.guid, container: 3, arm: "else", order: 32),
            module(NotBlock.guid, id: 10, name: "Not1", order: 70),
        ]
        // Feed both the If and the Switch from one block, so both branches have a live condition.
        let wires = [
            connection(1, 0, 10, 0), connection(2, 0, 10, 0), connection(3, 0, 10, 0),
            connection(6, 0, 5, 0),
        ]
        return project("deep-containers", pages: ["main"], modules: modules, inConnections: wires)
    }

    // MARK: - Macros

    /// A macro whose sheet holds a container, called three times, plus a macro that calls another macro.
    ///
    /// `MacroInstancing` copies a sheet and rewrites its ids, wires and call names. A container is identified by
    /// module id in the project's own attributes (`IN_CONTAINER`), and a copy that is not rewritten points its
    /// members at the *original* container — so the clone's blocks silently run inside someone else's branch.
    static func macroWithContainers() -> PCCProject {
        var project = PCCProject(name: "macro-containers")
        let sheets = ["main", "*Adder", "*Outer"]
        project.pages = sheets.map { ProjectPage(caption: $0) }
        project.appOptions.cycleDelay = 7

        // The sheet `*Adder`: Inputs → Add (inside an If) → Outputs.
        var sheet: [PCCModule] = [
            project.makeMacroInterface(.inputs, onSheet: "*Adder", id: 100, name: "Inputs1", x: 0, y: 0, order: 10),
            project.makeMacroInterface(.outputs, onSheet: "*Adder", id: 101, name: "Outputs1", x: 600, y: 0, order: 60),
        ]
        var ifContainer = module(ConstructContainers.ifGuid, id: 102, name: "If1", order: 20, page: "*Adder")
        ifContainer.rawAttributes["CONTAINER"] = "1"
        sheet.append(ifContainer)
        var add = module(AddBlock.guid, id: 103, name: "Add1", order: 30, page: "*Adder")
        add.rawAttributes["IN_CONTAINER"] = "102"
        add.rawAttributes["ARM"] = "then"
        sheet.append(add)
        // `*Outer` calls `*Adder`, so a call on it is a nested one.
        sheet.append(project.makeMacroInterface(.inputs, onSheet: "*Outer", id: 200, name: "Inputs1",
                                                x: 0, y: 0, order: 10))
        sheet.append(project.makeMacroInterface(.outputs, onSheet: "*Outer", id: 201, name: "Outputs1",
                                                x: 600, y: 0, order: 50))
        project.modules = sheet

        // Two calls on Main and one inside `*Outer`, so the `*Adder` sheet is cloned twice.
        var modules = sheet
        modules.append(project.makeMacroCall(sheet: "*Adder", id: 1, name: "Adder1", x: 0, y: 0, order: 10,
                                             threadId: 1, page: "main"))
        modules.append(project.makeMacroCall(sheet: "*Adder", id: 2, name: "Adder2", x: 0, y: 0, order: 20,
                                             threadId: 1, page: "main"))
        modules.append(project.makeMacroCall(sheet: "*Adder", id: 3, name: "Adder3", x: 0, y: 0, order: 40,
                                             threadId: 1, page: "*Outer"))
        modules.append(project.makeMacroCall(sheet: "*Outer", id: 4, name: "Outer1", x: 0, y: 0, order: 30,
                                             threadId: 1, page: "main"))
        project.modules = modules

        project.inConnections = [
            // Inside each sheet: the interface feeds the work, the work feeds the outputs.
            connection(103, 0, 100, 0), connection(101, 0, 103, 1),
            connection(3, 0, 200, 0),
        ]
        // Apply the macro interface's pin names to the calls.
        project.syncCalls(ofSheet: "*Adder")
        project.syncCalls(ofSheet: "*Outer")
        return project
    }

    // MARK: - Extremes

    /// Names, values and geometry at the edges: unicode, XML metacharacters, a 400-character name, `Int64.min`,
    /// `Float.greatestFiniteMagnitude`, fractional and negative coordinates, and 64-pin blocks.
    static func extremes() -> PCCProject {
        let unicode = "Číslo & <vstup> \"A\"\tTAB\nNEWLINE\rCR — 中文 🚀"
        let long = String(repeating: "Dlouhý název bloku – ", count: 16)
        var wide = module(AndBlock.guid, id: 1, name: long, order: 10)
        wide.inputCount = 64
        wide.inPins = (0...64).map { Pin(id: $0, value: .bool($0 % 2 == 0)) }
        // The values a 32-bit text field has no room for, and the ones that look like something else on the way back.
        wide.inPins[2].value = .int64(Int64.min)
        wide.inPins[3].value = .float(Float.greatestFiniteMagnitude)
        wide.inPins[4].value = .float(-0.0)
        wide.inPins[5].value = .int32(Int32.min)
        wide.inPins[6].value = .int16(-32768)
        wide.inPins[7].value = .undefined
        wide.outPins = [Pin(id: 0, value: .bool(false), rights: 2)]
        wide.x = -1234.5
        wide.y = 9876.25

        var unicodeModule = module(NotBlock.guid, id: 2, name: unicode, order: 20, page: "stránka & <2>")
        unicodeModule.inPins[0] = Pin(id: 0, value: .bool(true), inverted: true,
                                      rawAttributes: ["PIN_NAME": unicode])
        unicodeModule.x = 0.1 + 0.2  // 0.30000000000000004
        unicodeModule.y = -0.0

        var wideConnection = connection(2, 0, 1, 0, points: 40)
        wideConnection.rawAttributes["CUSTOM"] = "kept & <as-is>"

        var project = project("extremes", pages: ["main", "stránka & <2>", ""],
                              modules: [wide, unicodeModule],
                              inConnections: [wideConnection])
        project.description = unicode
        project.author = long
        project.applicationPath = #"C:\Users\user\Škola\Dirigo\Dirigo.exe"#
        project.projectPath = "smb://server/share/soubor & <x>.pcc"
        project.pageSize = 8
        project.oldExportMode = true
        // An unmodelled section, and a modelled one with an attribute this model has no field for.
        project.rawSections = [RawXMLNode(name: "CONSTANTS_X", attributes: ["A": "1 & 2"], children: [
            RawXMLNode(name: "ITEM", attributes: ["V": "3"], children: []),
        ])]
        return project
    }

    // MARK: - Graphs

    /// `count` `Not` blocks in a ring, so every wire feeds a block that already ran: the execution order cannot
    /// satisfy them all, and a step must still terminate with every pin defined.
    static func ring(_ count: Int) -> PCCProject {
        var modules = (1...count).map { index in
            module(NotBlock.guid, id: index, name: "Not\(index)", order: index * 10)
        }
        modules[0].inPins[0].value = .bool(true)
        var wires: [Connection] = []
        for index in 0..<count {
            let target = modules[index].id
            let source = modules[(index + 1) % count].id
            wires.append(connection(target, 0, source, 0))
            wires.append(connection(target, 1, source, 0))
        }
        return project("ring", pages: ["main"], modules: modules, inConnections: wires)
    }

    /// A long chain: `count` `Not` blocks, each fed by the one before, so a value has to travel the whole wire.
    static func chain(_ count: Int) -> PCCProject {
        var modules = (1...count).map { index in
            module(index % 2 == 0 ? NotBlock.guid : AndBlock.guid, id: index, name: "N\(index)", order: index * 10)
        }
        // Give every And two inputs so the chain has one pin to carry and one to hold.
        for index in modules.indices where modules[index].guid == AndBlock.guid {
            modules[index].inPins = [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .bool(true))]
        }
        modules[0].inPins[0].value = .bool(true)
        var wires: [Connection] = []
        for index in 1..<count {
            wires.append(connection(modules[index].id, 0, modules[index - 1].id, 0))
        }
        return project("chain", pages: ["main"], modules: modules, inConnections: wires)
    }

    /// The wire graph a corrupt or hand-edited file can hold: a self-loop, a missing module, a pin past the end,
    /// a duplicate module id, an input driven twice, and a parameter wire from nowhere.
    static func brokenGraph() -> PCCProject {
        let modules = [
            module(NotBlock.guid, id: 1, name: "Not1", order: 10),
            module(NotBlock.guid, id: 1, name: "Not1-duplicate", order: 20),
            module(AndBlock.guid, id: 2, name: "And1", order: 30),
            module(YesBlock.guid, id: 3, name: "Yes1", order: 40),
        ]
        let wires = [
            connection(1, 0, 1, 0),        // self-loop
            connection(1, 1, 99, 0),       // a module that is not there
            connection(2, 17, 3, 0),       // a pin past the end of the block
            connection(2, 0, 3, 40),       // an output pin past the end of the producer
            connection(3, 0, 2, 0),        // a second driver for an input already fed
            connection(3, 0, 2, 0),        // and the same wire twice
        ]
        let params = [connection(2, 0, 99, 3, isParam: true)]
        return project("broken-graph", pages: ["main", "main"], modules: modules,
                       inConnections: wires, paramConnections: params)
    }

    /// A project as the editor saves one: a command added in *PLC Configuration* is a `SystemCmd` held off the sheets,
    /// with no page and thread 0 until something builds it. Compiling the saved file as it stands drops it from the
    /// program without saying so, because the compiler leaves out every module with no thread.
    static func withConfiguration() -> PCCProject {
        var project = ring(4)
        project.plcConfiguration = [PLCConfiguration.newEntry(nil)]
        return project
    }

    // MARK: - Hand-written XML

    /// A `.pcc` written by hand in Dirigo's own shape, holding everything the parser is supposed to leave alone:
    /// an unknown section and attribute, a legacy pin spelling, character references, and unicode.
    static let gnarlyXML = """
    <PCC_PROJECT APPLICATION="Dirigo" APPLICATION_VERSION="v2.5.9.449" NAME="Gnarly &amp; &lt;odd&gt;" DESCRIPTION="Číslo &#x10D; &#9; tab" AUTHOR="" VERSION="" PROFILE="Sybas Duino-E" THREADINDEX="2" OLD_EXPORT_MODE="True" PAGESIZE="8" FUTURE_ATTRIBUTE="kept">
      <COMMUNICATION TYPE="0" PLC_ADDRESS="1" PC_ADDRESS="31" BAUD_RATE="57600" HOST="127.0.0.1" PORT="59" PC_PORT="59" PASSWORD="" TIMEOUT="5000" UNKNOWN_COMM="x"/>
      <APP_OPTIONS IQRF_NETWORK="1" IQRF_ADDRESS="1" CYCLE_DELAY="7"/>
      <SIM_OPTIONS ENABLED="False" ADDRESS="1" PORT="59" PASSWORD="">
        <PEER_1 IP="127.0.0.1" PORT="59" TIMEOUT="500" PASSWORD=""/>
        <PEER_2 IP="10.0.0.2" PORT="60" TIMEOUT="250" PASSWORD=""/>
      </SIM_OPTIONS>
      <PAGES>
        <PAGE CAPTION="List 1" READONLY="True"/>
        <PAGE CAPTION="Prázdná"/>
      </PAGES>
      <FUTURE_SECTION KIND="7">
        <CHILD VALUE="&lt;kept&gt;"/>
      </FUTURE_SECTION>
      <CONSTANTS>
        <CONSTANT NAME="C1" VALUE="5"/>
      </CONSTANTS>
      <MODULES>
        <MODULE GUID="{74F92168-F67B-4364-8AC0-B735DAA400A3}" NAME="Not &amp; one" ID="1" X="-12.75" Y="0.30000000000000004" ORDER="10" THREAD_ID="2" PAGE="List 1" UNKNOWN_MODULE="keep">
          <IN_PINS>
            <IN_PIN NAME="Legacy" VALUE="1" RIGHTS="0" INVERTED="1"/>
          </IN_PINS>
          <PARAM_PINS/>
          <OUT_PINS>
            <OUT_PIN VALUE="0" RIGHTS="2"/>
          </OUT_PINS>
          <FUTURE_CHILD A="b"/>
        </MODULE>
      </MODULES>
      <CONNECTIONS>
        <IN_CONNECTIONS>
          <CONNECTION IN_MODULE_ID="1" IN_PIN_ID="0" OUT_MODULE_ID="1" OUT_PIN_ID="0" NAME_X="1.5" NAME_Y="-2.5" UNKNOWN_CONN="keep">
            <POINTS>
              <POINT X="0" Y="0"/>
              <POINT X="10.5" Y="-20.25"/>
            </POINTS>
            <FUTURE_CONN_CHILD/>
          </CONNECTION>
        </IN_CONNECTIONS>
        <PARAM_CONNECTIONS/>
      </CONNECTIONS>
      <PROJECT_GRAPHICS>
        <GRAPHICS TYPE="1" PAGE="List 1" TEXT="Popisek &amp; &#x10D;"/>
      </PROJECT_GRAPHICS>
    </PCC_PROJECT>
    """
}
