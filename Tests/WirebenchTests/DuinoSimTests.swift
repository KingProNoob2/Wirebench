import Testing
import Foundation
@testable import WirebenchCore
@testable import WirebenchLibrary
@testable import WirebenchHardware
@testable import WirebenchModel
#if canImport(SwiftUI)
@testable import WirebenchApp
#endif

/// The Duino-S simulator: a real MaraProt v1 server over TCP running the firmware VM. These tests
/// are the proof it is indistinguishable from a board: the normal client speaks to it over
/// 127.0.0.1, and an MFLW image built by the real compiler runs on it.
@Suite("Duino-S simulator", .serialized)
struct DuinoSimTests {
    /// A tiny always-on pulse machine so the watch has something that moves.
    private func image() throws -> DuinoCompiler.Result {
        let definition = MaraflowCatalog.byId["Main.Timers.PulseGen"]!
        let pulse = PCCModule(id: 1, guid: definition.guid, name: "PulseGen1",
                              x: 0, y: 0, order: 10, threadId: 1, page: "Main",
                              inPins: [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .int32(5)),
                                       Pin(id: 2, value: .int32(5))],
                              paramPins: [],
                              outPins: [Pin(id: 0, value: .bool(false))],
                              rawAttributes: AttributeBag([("MARAFLOW_DEF", "Main.Timers.PulseGen")]))
        var project = PCCProject(name: "sim-test")
        project.pages = [ProjectPage(caption: "Main")]
        project.modules = [pulse]
        return try DuinoCompiler.compile(project: project)
    }

    @Test("A board on localhost: info, upload, VM control, watch and slots")
    func deviceRoundTrip() async throws {
        let sim = try DuinoSim(port: 15020)
        defer { sim.clearEStop() }
        let transport = MaraTCPTransport(host: "127.0.0.1", port: sim.port)
        let client = MaraProtClient(transport: transport, stationId: MaraProtClient.pointToPointStation)
        try client.connect()
        defer { client.close() }

        let ping = try client.ping(echo: 0x01020304)
        #expect(ping.echo == 0x01020304)
        let info = try client.info()
        #expect(info.modelId == 0x0407)
        #expect(info.modelName == "Duino - S")
        #expect(info.vmState == .stopped)

        // Upload the compiled image with auto-start, exactly like the app's uploader.
        let compiled = try image()
        let upload = try client.uploadImage(compiled.image, autoStart: true, progress: { _ in })
        #expect(upload.runState == .running)
        #expect(try client.vmStatus().runState == .running)

        // The watch sees the pulse output flip between polls.
        let qSlot = try #require(compiled.slots["PulseGen1.Q"])
        let epoch = try client.watchSubscribe([qSlot])
        let snapshot = try client.watchPoll(ackEpoch: 0)
        #expect(snapshot.changedSlots.keys.contains(qSlot))
        var flipped = false
        var acknowledged = epoch
        for _ in 0..<40 where !flipped {
            try? await Task.sleep(nanoseconds: 30_000_000)
            let update = try client.watchPoll(ackEpoch: acknowledged)
            acknowledged = update.epoch
            if let value = update.changedSlots[qSlot] {
                #expect(value == [1] || value == [0])
                flipped = true
            }
        }
        #expect(flipped, "the running VM's pulse output changed between polls")

        // Slot writes are visible to reads (the VM's input constants are plain slots).
        let tHi = try #require(compiled.slots["PulseGen1.THi"])
        _ = try client.writeSlots([tHi: [10, 0, 0, 0]])
        #expect(try client.readSlots([tHi])[tHi] == [10, 0, 0, 0])

        // VM control: pause, resume, stop.
        #expect(try client.controlVM(2) == .paused)
        #expect(try client.controlVM(1) == .running)
        #expect(try client.controlVM(0) == .stopped)

        // RTC round-trip through the simulator's clock.
        try client.rtcSet(unixSeconds: 1_735_689_000)
        #expect(try client.rtcGet() == 1_735_689_000)
    }

    @Test("E-stop state, masks and reset ride the protocol")
    func estop() throws {
        let sim = try DuinoSim(port: 15021)
        let client = MaraProtClient(transport: MaraTCPTransport(host: "127.0.0.1", port: sim.port),
                                    stationId: MaraProtClient.pointToPointStation)
        try client.connect()
        defer { client.close() }
        _ = try client.uploadImage(try image().image, autoStart: true, progress: { _ in })

        sim.tripEStop(mask: 0x0A)
        let status = try client.vmStatus()
        #expect(status.runState == .eStop)
        #expect(status.eStopActive)
        #expect(status.eStopMask == 0x0A)

        // Control 5 (ESTOP_RESET) clears flags and resumes.
        let payload = try client.controlVMWithEStopState(5)
        #expect(payload.state == .running)
        #expect(!payload.eStopActive)
    }

    /// The shield (KiCad): TMP75/DS18B20 temperatures are host-set, the CH455G display decodes
    /// to text, ONEWIRE_SCAN finds an attached sensor, and the retentive store persists through
    /// the BL24C256A image file.
    @Test("The shield's hardware is emulated: sensors, display, 1-Wire and the EEPROM")
    func shieldHardware() async throws {
        let eepromURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("duino-sim-eeprom-\(UUID()).bin")
        defer { try? FileManager.default.removeItem(at: eepromURL) }

        // First life: run a program, set the sensors, display a value, write a register.
        do {
            let sim = try DuinoSim(port: 15023)
            sim.setEEPROMPath(eepromURL.path)
            sim.setTemperature(tmp75: 21.5, ds18b20: 19.25)
            let client = MaraProtClient(transport: MaraTCPTransport(host: "127.0.0.1", port: sim.port),
                                        stationId: MaraProtClient.pointToPointStation)
            try client.connect()
            defer { client.close() }

            #expect(try client.oneWireScan().isEmpty, "a bare board has no 1-Wire sensors")
            sim.setOneWireSensor(rom: [0x28, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77])
            let roms = try client.oneWireScan()
            #expect(roms.count == 1 && roms[0] == 0x7766_5544_3322_1128, "the ROM rides little-endian, LSB first as on the wire")

            // TMP75 + CH455G + a retentive register on one page.
            func mf(_ id: String, _ name: String, moduleId: Int, order: Int) -> PCCModule {
                BlockFactory.makeModule(guid: MaraflowCatalog.byId[id]!.guid, id: moduleId, name: name,
                                        x: 0, y: 0, order: order, threadId: 1, page: "Main")
            }
            var tmp75 = mf("Comm.I2C.TMP75", "TMP75", moduleId: 1, order: 10)
            var ch455 = mf("IO.CH455G", "CH455G", moduleId: 2, order: 20)
            ch455.inPins = [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .int32(0)),
                            Pin(id: 2, value: .int32(1)), Pin(id: 3, value: .int32(8))]
            var writer = mf("Main.Execution.WriteReg", "Writer", moduleId: 3, order: 30)
            writer.inPins = [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .int32(1234))]
            writer.rawAttributes["MARAFLOW_PROP_RegisterName"] = "REG_7"
            writer.rawAttributes["MARAFLOW_PROP_RetentiveEeprom"] = "true"
            var project = PCCProject(name: "shield")
            project.pages = [ProjectPage(caption: "Main")]
            project.modules = [tmp75, ch455, writer]
            project.inConnections = [Connection(inModuleId: 2, inPinId: 1, outModuleId: 1, outPinId: 0)]
            // CH455G Val input wired from the TMP75 temperature.
            let compiled = try DuinoCompiler.compile(project: project)
            _ = try client.uploadImage(compiled.image, autoStart: true, progress: { _ in })
            let tmpSlot = try #require(compiled.slots["TMP75.Tmp"])
            try await Task.sleep(nanoseconds: 100_000_000)
            let read = try client.readSlots([tmpSlot])
            #expect(DuinoSlotType(slot: tmpSlot).map { $0.value(from: read[tmpSlot] ?? []) } == 21.5,
                    "the TMP75 reports the host-set temperature")

            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(sim.display.enabled)
            #expect(sim.display.value == 21.5 && sim.display.decimals == 1,
                    "the CH455G shows the temperature the TMP75 reported")
            #expect(sim.display.digitMask == 0x0F)
            #expect(!sim.display.raw)
            let masks = await MainActor.run { DuinoSimView.displaySegmentMasks(sim.display) }
            #expect(masks == [0x5B, 0x86, 0x6D])
        }

        // Second life on the same EEPROM file: the retentive value survived the "power cycle".
        do {
            let sim = try DuinoSim(port: 15023)
            sim.setEEPROMPath(eepromURL.path)
            let client = MaraProtClient(transport: MaraTCPTransport(host: "127.0.0.1", port: sim.port),
                                        stationId: MaraProtClient.pointToPointStation)
            try client.connect()
            defer { client.close() }
            func mf(_ id: String, _ name: String, moduleId: Int) -> PCCModule {
                BlockFactory.makeModule(guid: MaraflowCatalog.byId[id]!.guid, id: moduleId, name: name,
                                        x: 0, y: 0, order: 10, threadId: 1, page: "Main")
            }
            var reader = mf("Main.Execution.ReadReg", "Reader", moduleId: 1)
            reader.rawAttributes["MARAFLOW_PROP_RegisterName"] = "REG_7"
            reader.rawAttributes["MARAFLOW_PROP_RetentiveEeprom"] = "true"
            var project = PCCProject(name: "eeprom")
            project.pages = [ProjectPage(caption: "Main")]
            project.modules = [reader]
            let compiled = try DuinoCompiler.compile(project: project)
            _ = try client.uploadImage(compiled.image, autoStart: true, progress: { _ in })
            let slot = try #require(compiled.slots["Reader.Out"])
            try await Task.sleep(nanoseconds: 100_000_000)
            let read = try client.readSlots([slot])
            #expect(DuinoSlotType(slot: slot).map { $0.value(from: read[slot] ?? []) } == 1234,
                    "the EEPROM kept the retentive value across the restart")
        }
    }

    @Test("Virtual I/O carries values between a connected program and the host")
    func virtualIO() async throws {
        let sim = try DuinoSim(port: 15022)
        defer { sim.setDigitalInput(3, false) }
        let client = MaraProtClient(transport: MaraTCPTransport(host: "127.0.0.1", port: sim.port),
                                    stationId: MaraProtClient.pointToPointStation)
        try client.connect()
        defer { client.close() }

        // An IREF/OREF pair bridges the host's virtual pins: DI3 -> DO7.
        let iref = MaraflowCatalog.byId["IO.IREF"]!
        let oref = MaraflowCatalog.byId["IO.OREF"]!
        var modules = [PCCModule]()
        var di = BlockFactory.makeModule(guid: iref.guid, id: 1, name: "IREF1", x: 0, y: 0,
                                         order: 10, threadId: 1, page: "Main")
        di.rawAttributes["MARAFLOW_PROP_Channel"] = "DI3"
        modules.append(di)
        var doModule = BlockFactory.makeModule(guid: oref.guid, id: 2, name: "OREF1", x: 0, y: 0,
                                               order: 20, threadId: 1, page: "Main")
        doModule.rawAttributes["MARAFLOW_PROP_Channel"] = "DO7"
        doModule.inPins = [Pin(id: 0, value: .bool(false))]
        modules.append(doModule)
        var project = PCCProject(name: "io-test")
        project.pages = [ProjectPage(caption: "Main")]
        project.modules = modules
        project.inConnections = [Connection(inModuleId: 2, inPinId: 0, outModuleId: 1, outPinId: 0)]
        let compiled = try DuinoCompiler.compile(project: project)
        _ = try client.uploadImage(compiled.image, autoStart: true, progress: { _ in })

        sim.setDigitalInput(3, true)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(sim.digitalOutput(7), "the VM copied the virtual DI3 onto DO7")
        sim.setDigitalInput(3, false)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!sim.digitalOutput(7))

        sim.setPowered(false)
        #expect(!sim.isPowered)
        #expect(!sim.digitalOutput(7), "an unpowered board cannot hold its outputs high")
        #expect(throws: (any Error).self) { _ = try client.ping() }
        client.close()

        sim.setPowered(true)
        #expect(sim.isPowered)
        sim.setDigitalInput(3, true)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(sim.digitalOutput(7), "the retained program rebooted and resumed after the power cycle")
        let rebooted = MaraProtClient(transport: MaraTCPTransport(host: "127.0.0.1", port: sim.port),
                                      stationId: MaraProtClient.pointToPointStation)
        try rebooted.connect()
        defer { rebooted.close() }
        #expect(try rebooted.vmStatus().runState == .running)
    }

    @Test("Shield buttons, pots and AI3 selector channels reach the firmware VM")
    func shieldControlChannels() async throws {
        let sim = try DuinoSim(port: 15025)
        let client = MaraProtClient(transport: MaraTCPTransport(host: "127.0.0.1", port: sim.port),
                                    stationId: MaraProtClient.pointToPointStation)
        try client.connect()
        defer { client.close() }
        let inputs = [("SW1", "DI10"), ("SW2", "DI11"), ("SW4", "DI12"),
                      ("Pot0", "AI0"), ("Pot1", "AI1"), ("Pot2", "AI2"), ("A3", "AI3")]
        var modules = [PCCModule]()
        for (index, input) in inputs.enumerated() {
            var module = BlockFactory.makeModule(guid: MaraflowCatalog.byId["IO.IREF"]!.guid,
                                                 id: index + 1, name: input.0, x: 0, y: 0,
                                                 order: (index + 1) * 10, threadId: 1, page: "Main")
            module.rawAttributes["MARAFLOW_PROP_Channel"] = input.1
            if input.1.hasPrefix("AI") { module.outPins = [Pin(id: 0, value: .int32(0))] }
            modules.append(module)
        }
        var project = PCCProject(name: "shield-controls")
        project.pages = [ProjectPage(caption: "Main")]
        project.modules = modules
        let compiled = try DuinoCompiler.compile(project: project)
        _ = try client.uploadImage(compiled.image, autoStart: true, progress: { _ in })

        sim.setDigitalInput(10, true)
        sim.setDigitalInput(11, true)
        sim.setDigitalInput(12, true)
        let analog: [Int32] = [100, 200, 300, 4095]
        for channel in 0..<4 { sim.setAnalogInput(channel, analog[channel]) }
        try await Task.sleep(nanoseconds: 120_000_000)

        let slots = try inputs.map { try #require(compiled.slots["\($0.0).Y"]) }
        let values = try client.readSlots(slots)
        for name in ["SW1", "SW2", "SW4"] {
            #expect(values[compiled.slots["\(name).Y"]!] == [1])
        }
        for (index, name) in ["Pot0", "Pot1", "Pot2", "A3"].enumerated() {
            let bytes = try #require(values[compiled.slots["\(name).Y"]!])
            let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            #expect(Int32(bitPattern: raw) == analog[index])
        }

        sim.controlVM(2)
        #expect(sim.vmState == .paused)
        sim.controlVM(1)
        #expect(sim.vmState == .running)
        sim.controlVM(0)
        #expect(sim.vmState == .stopped)
    }

    @Test("The observable session drives the same pins as the hardware drawer")
    @MainActor
    func sessionHardwareControls() async throws {
        let session = try DuinoSimSession(port: 15026)
        #expect(session.digitalInputs[14] && session.digitalInputs[15])
        session.setPotentiometer(0, 1234)
        #expect(session.sim.analogInput(0) == 1234)
        session.setPotentiometer(3, 2000)
        session.setAI3UsesLDR(true)
        session.setLightLevel(1)
        #expect(session.sim.analogInput(3) == 4095)
        session.setLightLevel(0)
        #expect(session.sim.analogInput(3) == 0)
        session.setAI3UsesLDR(false)
        #expect(session.sim.analogInput(3) == 2000)
        session.pulseButton(channel: 10)
        #expect(session.sim.digitalInput(10))
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!session.sim.digitalInput(10))
        session.setDS18B20Attached(false)
        #expect(session.ds18b20Attached == false)
    }

#if canImport(SwiftUI)
    @Test("The 3D CH455G decoder handles numeric decimal points and raw segments")
    @MainActor
    func displaySegments() {
        let numeric = DuinoSim.Display(text: "21.5", enabled: true, raw: false,
                                       digitMask: 0x0F, decimals: 1, brightness: 8, value: 21.5)
        #expect(DuinoSimView.displaySegmentMasks(numeric) == [0x5B, 0x86, 0x6D])
        let raw = DuinoSim.Display(enabled: true, raw: true, digitMask: 0x0F,
                                   segments: [0x3F, 0x06, 0x5B, 0x80])
        #expect(DuinoSimView.displaySegmentMasks(raw) == [0x3F, 0x06, 0x5B])
        let placeholder = DuinoSim.Display(text: "0", valid: false, enabled: false, raw: false,
                                           digitMask: 0, decimals: 0, brightness: 0, value: 0)
        #expect(DuinoSimView.displaySegmentMasks(placeholder) == [0, 0, 0x3F])
    }
#endif
}
