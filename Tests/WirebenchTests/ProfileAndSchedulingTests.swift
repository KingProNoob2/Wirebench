import Testing
import Foundation
@testable import WirebenchCore
@testable import WirebenchLibrary
@testable import WirebenchEngine

@Suite("Hardware profiles")
struct ProfilesParserTests {
    /// The compiled-in profiles, which is what the app uses.
    static func loadDatabase() throws -> ProfileDatabase { ProfileRegistry.builtIn }

    @Test("Every profile and the whole SystemCmd catalogue are parsed")
    func parsesEverything() throws {
        let db = try Self.loadDatabase()
        #expect(db.profiles.count == 22)
        #expect(db.systemCommands.count == 41)
    }

    @Test("Sybas P3 is the default and declares the documented threads")
    func defaultProfile() throws {
        let db = try Self.loadDatabase()
        let profile = try #require(db.defaultProfile)
        #expect(profile.name == "Sybas P3")
        #expect(profile.alias == "P3 Commun v2.0")
        #expect(profile.threads.map(\.id) == [1, 2, 3, 4])
        #expect(profile.threads.map(\.name) == ["Timer 1s", "Tick", "Communication", "Idle"])
        #expect(profile.threads.map(\.intervalMs) == [1000, 71, 1000, 50])
        #expect(profile.intRamSize == 2048)
        #expect(profile.programDataSize == 14336)
        #expect(profile.directConstMin == -8191)
        #expect(profile.directConstMax == 8191)
        #expect(profile.constantDataTypeAliases == ["Int", "Long", "Int64", "Float"])
    }

    @Test("A derived profile inherits hardware but not identity")
    func inheritance() throws {
        let db = try Self.loadDatabase()

        // `Sybas D-DISP` derives from `Sybas QVGA` which derives from the default `Sybas P3`.
        // It must inherit the P3 thread table but must NOT inherit `Default=Yes`.
        let display = try #require(db.profile(named: "Sybas D-DISP"))
        #expect(display.baseProfile == "Sybas QVGA")
        #expect(!display.isDefault)
        #expect(display.thread(id: 2)?.intervalMs == 100)   // QVGA overrides the Tick period
        #expect(display.thread(id: 1)?.name == "Timer 1s")  // ...and inherits the rest
        #expect(display.intRamSize == 2048)                 // from P3

        let p3plus = try #require(db.profile(named: "Sybas P3+"))
        #expect(p3plus.programDataSize == 45568)
        #expect(p3plus.intRamSize == 2048)

        let k5 = try #require(db.profile(named: "Sybas K5-ETH"))
        #expect(k5.threads.count == 5)
        #expect(k5.thread(id: 5)?.name == "IQRF")

        let pic32 = try #require(db.profile(named: "Sybas PIC32"))
        #expect(pic32.cpuBits == 32)
        #expect(pic32.threads.count == 16)
        #expect(pic32.thread(id: 2)?.intervalMs == 100)
        #expect(pic32.programDataSize == 245760)
    }

    @Test("SystemCmd entries carry the documented command word and pins")
    func systemCommandTable() throws {
        let db = try Self.loadDatabase()

        let wdo = try #require(db.systemCommands["WDO_0301"])
        #expect(wdo.command == 0x0301)
        #expect(wdo.text == "DO")
        #expect(wdo.title == "Write DO")
        #expect(wdo.input1 == .init(dataType: "Int", name: "DO_L", isHidden: false))
        #expect(wdo.input2 == .init(dataType: "Int", name: "DO_H", isHidden: false))
        #expect(wdo.output == .init(dataType: "Int", name: "Out", isHidden: false))

        // `(Hidden)` parameters are modelled but not drawn as pins.
        let fwt = try #require(db.systemCommands["FWT_0000"])
        #expect(fwt.command == 0x0000)
        #expect(fwt.input1.isHidden)
        #expect(fwt.output.name == "Fw")

        // One command word can appear under several mnemonics.
        let rdt = try #require(db.systemCommands["RDT_0312"])
        #expect(rdt.command == 0x0312)
        #expect(rdt.title == "DS18B20 Read T")
    }

    @Test("A profile restricts the command catalogue to its own list")
    func profileCommandFiltering() throws {
        let db = try Self.loadDatabase()
        let p3 = try #require(db.profile(named: "Sybas P3"))
        let p3Commands = db.systemCommands(for: p3)
        #expect(p3Commands.map(\.mnemonic).sorted()
                == ["CMS_0103", "DBA_0100", "FWT_0000", "FWV_0001", "MNU_0201", "TMR_0004"])

        let duinoE = try #require(db.profile(named: "Sybas Duino-E"))
        let duinoCommands = Set(db.systemCommands(for: duinoE).map(\.mnemonic))
        #expect(duinoCommands.contains("RHD_0300"))
        #expect(duinoCommands.contains("WDO_0301"))
        #expect(duinoCommands.contains("CFG_0302"))
        #expect(duinoCommands.contains("PWM_0303"))
        #expect(!duinoCommands.contains("MNU_0201"))
    }

    /// The compiled-in data is the only copy the app has: `tools/gen_profiles.py` writes it from Dirigo's `Profiles.ini`, which is not in
    /// this repository and that nothing here reads. These are the values a bad regeneration would move — how many profiles and commands
    /// there are, and the command lists that decide what the PLC Configuration menu offers.
    @Test("The compiled-in profiles and commands are the ones the app relies on")
    func compiledInDataIsIntact() throws {
        let db = ProfileRegistry.builtIn
        #expect(Set(db.profiles.keys) == [
            "P3 v0.1", "P3 Commun v1.0", "Sybas P1", "Sybas P3", "Sybas P3+", "Sybas K5-ETH",
            "Sybas Termostat V1.1", "Sybas Duino-P", "Sybas Duino-E", "Sybas Eth-Duino-P", "Sybas RB-Sensor",
            "Sybas PDiff", "Sybas QVGA", "Sybas D-DISP", "Sybas P24", "Sybas PIC32", "Sybas SCU-32",
            "Sybas DUINO-32", "Sybas CV-32", "ESP32-DevKit", "Micro:bit V2", "Arduino M0",
        ])
        #expect(db.systemCommands.count == 41)
        // Every board that configures pins lists one of these four variants.
        for mnemonic in ["CFG_0302", "CFL_0302", "CFA_0302", "CFM_0302"] {
            #expect(db.systemCommands[mnemonic] != nil, "\(mnemonic) is missing")
        }
        // The two profiles that decide the reported behaviour: the Duino-E configures pins, the P3 has no pin command at all.
        let duinoE = try #require(db.profile(named: "Sybas Duino-E"))
        #expect(db.systemCommands(for: duinoE).count == 9)
        #expect(db.systemCommands(for: duinoE).contains { $0.command == 0x0302 })
        let p3 = try #require(db.profile(named: "Sybas P3"))
        #expect(db.systemCommands(for: p3).count == 6)
        #expect(!db.systemCommands(for: p3).contains { $0.command == 0x0302 })
    }

    @Test("A cycle in BaseProfile does not hang the parser")
    func baseProfileCycleIsSafe() {
        let ini = """
        [A]
        BaseProfile=B
        IntRamDataSize=111

        [B]
        BaseProfile=A
        LongRamDataSize=222
        """
        let db = ProfilesParser().parse(iniString: ini)
        #expect(db.profiles.count == 2)
        // Whatever the resolution order, the parser must terminate and produce both profiles.
        #expect(db.profiles["A"] != nil)
        #expect(db.profiles["B"] != nil)
    }
}

@Suite("Thread scheduling")
struct ThreadSchedulingTests {
    /// A project with two threads and a 10 ms cycle delay.
    static func makeProject() -> PCCProject {
        var project = PCCProject(name: "scheduling")
        project.appOptions.cycleDelay = 10
        project.modules = [
            PCCModule(id: 1, guid: AndBlock.guid, name: "And1", x: 0, y: 0, order: 10,
                      threadId: 1, page: "main"),
            PCCModule(id: 2, guid: AndBlock.guid, name: "And2", x: 0, y: 0, order: 20,
                      threadId: 2, page: "main"),
            PCCModule(id: 3, guid: AndBlock.guid, name: "And3", x: 0, y: 0, order: 30,
                      threadId: 7, page: "main"),
        ]
        return project
    }

    static func makeProfile() -> PLCProfile {
        PLCProfile(
            name: "Test",
            threads: [
                PLCThreadConfig(id: 1, name: "Timer 1s", intervalMs: 30),
                PLCThreadConfig(id: 2, name: "Tick", intervalMs: 10),
            ]
        )
    }

    @Test("everyTick runs every thread on every step")
    func everyTickIsUnchanged() {
        let engine = TestEngine(project: Self.makeProject(), scheduling: .everyTick)
        engine.run(ticks: 10)
        #expect(engine.threadRunCounts[1] == 10)
        #expect(engine.threadRunCounts[2] == 10)
        #expect(engine.threadRunCounts[7] == 10)
    }

    @Test("profileIntervals honours each thread's period")
    func profileIntervals() {
        let engine = TestEngine(
            project: Self.makeProject(),
            profile: Self.makeProfile(),
            scheduling: .profileIntervals
        )
        // 100 steps x 10 ms = 1000 ms of engine time.
        engine.run(ticks: 100)
        // Every thread runs once on the first pass (see docs/spec/execution-model.md §2), then
        // keeps to its period: passes 1, 3, 6, ... 99.
        #expect(engine.threadRunCounts[1] == 34)
        #expect(engine.threadRunCounts[2] == 100)  // 1000 / 10
        // Thread 7 is not in the profile, so it runs every step.
        #expect(engine.threadRunCounts[7] == 100)
    }

    /// A slowed simulation hands the engine deltas of a fraction of a millisecond. They used to be raised to 1 ms,
    /// so below about 30% speed the simulation did not get any slower — the loop just made more, shorter steps.
    @Test("Sub-millisecond deltas are honoured, and the exact time to the next run is reported")
    func subMillisecondDeltas() {
        let engine = TestEngine(project: Self.makeProject(), profile: Self.makeProfile(),
                                      scheduling: .profileIntervals)
        engine.step(deltaMs: 1)                         // every thread runs once on the first pass
        let first = engine.threadRunCounts[1] ?? 0
        // Thread 1 has a 30 ms period: 1 ms is gone, so 29 ms remain — not rounded to a project cycle.
        #expect(engine.msUntilNextRun() > 0 && engine.msUntilNextRun() <= 9 + 1e-9,
                "thread 2 (10 ms) is next: \(engine.msUntilNextRun())")
        for _ in 0..<50 { engine.step(deltaMs: 0.1) }   // 5 ms in all
        #expect(engine.threadRunCounts[1] == first, "5 ms has not reached a 30 ms thread")
        #expect(abs(engine.msUntilNextRun() - 4) < 1e-6, "9 ms − 5 ms = 4 ms: \(engine.msUntilNextRun())")
    }

    @Test("Threads the profile does not define fall back to the cycle delay")
    func unknownThreadFallsBack() {
        let engine = TestEngine(
            project: Self.makeProject(),
            profile: Self.makeProfile(),
            scheduling: .profileIntervals
        )
        #expect(engine.intervalMs(forThread: 1) == 30)
        #expect(engine.intervalMs(forThread: 2) == 10)
        #expect(engine.intervalMs(forThread: 7) == 10)
    }

    @Test("Unresolved block types run inert and are reported")
    func unresolvedBlocksAreInertAndReported() {
        // GUID of a real Dirigo block this build does not implement.
        // A GUID that appears nowhere in the recovered catalog, with a name that matches no
        // registered type. Earlier versions of this test used a real type that later got
        // implemented — and even the *name* is enough to resolve, which is worth remembering.
        let unknownGuid = UUID()
        var project = PCCProject(name: "unresolved")
        project.modules = [
            PCCModule(id: 1, guid: unknownGuid, name: "Mystery1", x: 0, y: 0, order: 10,
                      threadId: 1, page: "main",
                      inPins: [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .int32(3))],
                      outPins: [Pin(id: 0, value: .int32(0))]),
        ]
        let engine = TestEngine(project: project)
        let unresolved = engine.unresolvedBlocks()
        #expect(unresolved.count == 1)

        #expect(unresolved[0].module.id == 1)
        #expect(CxxSimulationCore.kind(forGUID: unknownGuid) == nil, "the core has no behaviour for it")
        let block = unresolved[0].block

        // Running must not fabricate a result from the input.
        engine.run(ticks: 5)
        #expect(block.outPins[0] == .undefined)
    }
}
