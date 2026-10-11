import Testing
import Foundation
@testable import DirigoCore
@testable import DirigoLibrary

/// Verifies that every block type used by the real sample projects dispatches to the correct
/// implementation, and that the dispatch table matches the registry recovered from the original
/// binaries (`docs/dirigo-block-guids.json` → `BlockTypeCatalog`).
@Suite("Block registry and type dispatch")
struct BlockRegistryTests {
    static let workspace = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// Dirigo library block name -> the Swift type that must handle it.
    ///
    /// Deliberately explicit: if a GUID is ever re-pointed at a different implementation, this
    /// table is what fails.
    static let blockNameToSwiftType: [String: String] = [
        "8xDI": "8xDI", "8xDO": "8xDO", "8xPWM": "8xPWM",
        "And": "And", "Or": "Or", "Not": "Not", "Xor": "Xor", "RS": "RS",
        "Trigger": "Trigger", "Yes": "Yes",
        "Comparator": "Comparator", "Int2Bits": "Int2Bits", "Bits2Int": "Bits2Int",
        "Div": "Div", "IAdd": "IAdd", "IMul": "IMul", "ISub": "ISub",
        "IAbs": "Abs", "IInc": "Inc", "INeg": "Neg",
        "IAnd": "IntAnd", "IOr": "IntOr", "IXor": "IntXor", "INot": "IntNot",
        "Shl": "Shl", "Sar": "Sar", "Ext": "Ext", "Ins": "Ins",
        "ISwitch": "ISwitch", "Set": "Set", "MCompare": "MultiComparator",
        "HystComparator": "HysteresisComparator", "InRange": "InRange",
        "ILimiter": "Limiter", "Mean": "Mean", "Filter": "Filter",
        "DelayFilter": "DelayFilter", "Ramp": "Ramp", "CalibTransf": "CalibTransf",
        "Valve": "Valve", "WaterRegulator": "WaterRegulator", "Equitherm": "Equitherm",
        "StepDriver": "StepDriver",
        "PulseGen": "PulseGen", "Timer": "Timer", "SinglePulse": "SinglePulse",
        "PulseLen": "PulseLen", "Counter": "Counter", "AdvCounter": "AdvCounter",
        "Copy": "Copy",
        "If": "If", "Else": "Else", "EndIf": "EndIf", "Switch": "Switch",
        "Case": "Case", "Results": "Results",
        "CreateIntArray": "CreateIntArray", "ReadIntArray": "ReadIntArray",
        "WriteIntArray": "WriteIntArray", "IDemux": "IDemux", "FDemux": "FDemux",
        "IntVar": "IntVar", "FloatVar": "FloatVar", "DateTime": "DateTime",
        "WeekProgram": "WeekProgram", "EncodeDate": "EncodeDate", "DecodeDate": "DecodeDate",
        "BoolVar": "BoolVar", "Value": "Value", "Segment": "Segment", "Macro": "Macro",
        "SystemCmd": "SystemCmd",
        // `Macro IO` is one block type (`TMacroInterface`) whose role is chosen by KIND and is
        // handled specially below.
    ]

    static let sampleProjects = ["rulkoshaddirigo.pcc", "ruleta_kostka_had.pcc"]

    @Test("Every block in the sample projects resolves to the expected implementation")
    func sampleProjectsDispatchCorrectly() throws {
        let parser = PCCParser()
        let registry = BlockRegistry.shared

        for name in Self.sampleProjects {
            let url = Self.workspace.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let project = try parser.parse(fileAt: url)

            for module in project.modules {
                let info = try #require(BlockTypeCatalog.info(forGuid: module.guid),
                                        "\(name): \(module.name) uses GUID \(module.guid), which the recovered registry does not know")

                let resolved = try #require(registry.resolvedTypeName(for: module),
                                            "\(name): \(module.name) (\(info.blockName)) did not resolve to any block")

                if info.blockName == "Macro IO" {
                    let kind = module.rawAttributes["KIND"]
                    let expected = kind == "1" ? "Outputs" : "Inputs"
                    #expect(resolved == expected,
                            "\(name): \(module.name) KIND=\(kind ?? "nil") resolved to \(resolved)")
                } else if let expected = Self.blockNameToSwiftType[info.blockName] {
                    #expect(resolved == expected,
                            "\(name): \(module.name) is \(info.blockName) but resolved to \(resolved), expected \(expected)")
                } else {
                    Issue.record("\(name): \(info.blockName) has no entry in the expected-type table")
                }
            }
        }
    }

    @Test("No sample-project module falls back to an unresolved placeholder")
    func noUnresolvedBlocksInSamples() throws {
        let parser = PCCParser()
        let registry = BlockRegistry.shared
        for name in Self.sampleProjects {
            let url = Self.workspace.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let project = try parser.parse(fileAt: url)
            let unresolved = project.modules.filter { registry.resolvedTypeName(for: $0) == nil }
            #expect(unresolved.isEmpty,
                    "\(name): \(unresolved.count) unresolved block(s): \(unresolved.map(\.name).sorted())")
        }
    }

    @Test("Instance names resolve without relying on the GUID")
    func nameFallbackHandlesDirigoNaming() {
        // Dirigo names instances `<Type><n>`; trailing digits must be stripped, but the type
        // name itself may contain digits (`8xDO`, `8xPWM`) which must be kept.
        #expect(BlockRegistry.lookupKeys(for: "8xDO1").contains("8xdo"))
        #expect(BlockRegistry.lookupKeys(for: "8xPWM1").contains("8xpwm"))
        #expect(BlockRegistry.lookupKeys(for: "PulseGen12").contains("pulsegen"))
        #expect(BlockRegistry.lookupKeys(for: "AktivniRezim").contains("aktivnirezim"))
        // The lossy legacy key is still available, last.
        #expect(BlockRegistry.lookupKeys(for: "8xDO1").last == "xdo")
    }

    @Test("Registered block GUIDs are unique")
    func registeredGuidsAreUnique() {
        // Two block *classes* may share a GUID only where Dirigo does the same, which is the
        // Macro IO type (Inputs and Outputs).
        let shared = Set([InputsBlock.guid])
        var seen: [UUID: String] = [:]
        var collisions: [String] = []

        func consider(_ type: Any.Type, _ guid: UUID) {
            let name = "\(type)"
            if let other = seen[guid], !shared.contains(guid) {
                collisions.append("\(other) and \(name) both use \(guid)")
            }
            seen[guid] = name
        }

        consider(AndBlock.self, AndBlock.guid)
        consider(OrBlock.self, OrBlock.guid)
        consider(NotBlock.self, NotBlock.guid)
        consider(XorBlock.self, XorBlock.guid)
        consider(RSBlock.self, RSBlock.guid)
        consider(TriggerBlock.self, TriggerBlock.guid)
        consider(YesBlock.self, YesBlock.guid)
        consider(ComparatorBlock.self, ComparatorBlock.guid)
        consider(Int2BitsBlock.self, Int2BitsBlock.guid)
        consider(Bits2IntBlock.self, Bits2IntBlock.guid)
        consider(DivBlock.self, DivBlock.guid)
        consider(AddBlock.self, AddBlock.guid)
        consider(MulBlock.self, MulBlock.guid)
        consider(SubBlock.self, SubBlock.guid)
        consider(AbsBlock.self, AbsBlock.guid)
        consider(IncBlock.self, IncBlock.guid)
        consider(NegBlock.self, NegBlock.guid)
        consider(IntAndBlock.self, IntAndBlock.guid)
        consider(IntOrBlock.self, IntOrBlock.guid)
        consider(IntXorBlock.self, IntXorBlock.guid)
        consider(IntNotBlock.self, IntNotBlock.guid)
        consider(ShlBlock.self, ShlBlock.guid)
        consider(SarBlock.self, SarBlock.guid)
        consider(ExtBlock.self, ExtBlock.guid)
        consider(InsBlock.self, InsBlock.guid)
        consider(ISwitchBlock.self, ISwitchBlock.guid)
        consider(SetBlock.self, SetBlock.guid)
        consider(MultiComparatorBlock.self, MultiComparatorBlock.guid)
        consider(HysteresisComparatorBlock.self, HysteresisComparatorBlock.guid)
        consider(InRangeBlock.self, InRangeBlock.guid)
        consider(LimiterBlock.self, LimiterBlock.guid)
        consider(MeanBlock.self, MeanBlock.guid)
        consider(FilterBlock.self, FilterBlock.guid)
        consider(DelayFilterBlock.self, DelayFilterBlock.guid)
        consider(RampBlock.self, RampBlock.guid)
        consider(CalibratedTransformBlock.self, CalibratedTransformBlock.guid)
        consider(ValveBlock.self, ValveBlock.guid)
        consider(WaterRegulatorBlock.self, WaterRegulatorBlock.guid)
        consider(EquithermBlock.self, EquithermBlock.guid)
        consider(StepDriverBlock.self, StepDriverBlock.guid)
        consider(PulseGenBlock.self, PulseGenBlock.guid)
        consider(TimerBlock.self, TimerBlock.guid)
        consider(SinglePulseBlock.self, SinglePulseBlock.guid)
        consider(PulseLengthBlock.self, PulseLengthBlock.guid)
        consider(CounterBlock.self, CounterBlock.guid)
        consider(AdvCounterBlock.self, AdvCounterBlock.guid)
        consider(CopyBlock.self, CopyBlock.guid)
        consider(IfBlock.self, IfBlock.guid)
        consider(ElseBlock.self, ElseBlock.guid)
        consider(EndIfBlock.self, EndIfBlock.guid)
        consider(SwitchBlock.self, SwitchBlock.guid)
        consider(CaseBlock.self, CaseBlock.guid)
        consider(ResultsBlock.self, ResultsBlock.guid)
        consider(CreateArrayBlock.self, CreateArrayBlock.guid)
        consider(ReadArrayBlock.self, ReadArrayBlock.guid)
        consider(WriteArrayBlock.self, WriteArrayBlock.guid)
        consider(IntDemuxBlock.self, IntDemuxBlock.guid)
        consider(FloatDemuxBlock.self, FloatDemuxBlock.guid)
        consider(IntVarBlock.self, IntVarBlock.guid)
        consider(FloatVarBlock.self, FloatVarBlock.guid)
        consider(DateTimeBlock.self, DateTimeBlock.guid)
        consider(WeekProgramBlock.self, WeekProgramBlock.guid)
        consider(EncodeDateBlock.self, EncodeDateBlock.guid)
        consider(DecodeDateBlock.self, DecodeDateBlock.guid)
        consider(EightDOBlock.self, EightDOBlock.guid)
        consider(EightDIBlock.self, EightDIBlock.guid)
        consider(EightPWMBlock.self, EightPWMBlock.guid)
        consider(BoolVarBlock.self, BoolVarBlock.guid)
        consider(ValueDisplayBlock.self, ValueDisplayBlock.guid)
        consider(SegmentBlock.self, SegmentBlock.guid)
        consider(MacroBlock.self, MacroBlock.guid)
        consider(SystemCmdBlock.self, SystemCmdBlock.guid)
        consider(FloatMathBlock.self, FloatMathBlock.guid)
        consider(UnresolvedBlock.self, UnresolvedBlock.guid)

        #expect(collisions.isEmpty, "\(collisions)")
    }

    @Test("Every block class either uses a real Dirigo GUID or a documented synthetic one")
    func guidsAreRealOrExplicitlySynthetic() {
        // Blocks that genuinely have no Dirigo counterpart derive their GUID from a fixed
        // namespace inside tools/gen_block_catalog.py.
        let synthetic: Set<UUID> = [
            FloatMathBlock.guid,
            UnresolvedBlock.guid,
        ]
        let guids: [(String, UUID)] = [
            ("AndBlock", AndBlock.guid), ("OrBlock", OrBlock.guid), ("NotBlock", NotBlock.guid),
            ("XorBlock", XorBlock.guid), ("RSBlock", RSBlock.guid), ("TriggerBlock", TriggerBlock.guid),
            ("YesBlock", YesBlock.guid), ("ComparatorBlock", ComparatorBlock.guid),
            ("Int2BitsBlock", Int2BitsBlock.guid), ("Bits2IntBlock", Bits2IntBlock.guid),
            ("DivBlock", DivBlock.guid), ("AddBlock", AddBlock.guid), ("MulBlock", MulBlock.guid),
            ("SubBlock", SubBlock.guid), ("AbsBlock", AbsBlock.guid), ("IncBlock", IncBlock.guid),
            ("NegBlock", NegBlock.guid), ("IntAndBlock", IntAndBlock.guid),
            ("IntOrBlock", IntOrBlock.guid), ("IntXorBlock", IntXorBlock.guid),
            ("IntNotBlock", IntNotBlock.guid), ("ShlBlock", ShlBlock.guid), ("SarBlock", SarBlock.guid),
            ("ExtBlock", ExtBlock.guid), ("InsBlock", InsBlock.guid),
            ("ISwitchBlock", ISwitchBlock.guid), ("SetBlock", SetBlock.guid),
            ("MultiComparatorBlock", MultiComparatorBlock.guid),
            ("HysteresisComparatorBlock", HysteresisComparatorBlock.guid),
            ("InRangeBlock", InRangeBlock.guid), ("LimiterBlock", LimiterBlock.guid),
            ("MeanBlock", MeanBlock.guid), ("FilterBlock", FilterBlock.guid),
            ("DelayFilterBlock", DelayFilterBlock.guid), ("RampBlock", RampBlock.guid),
            ("CalibratedTransformBlock", CalibratedTransformBlock.guid),
            ("ValveBlock", ValveBlock.guid), ("WaterRegulatorBlock", WaterRegulatorBlock.guid),
            ("EquithermBlock", EquithermBlock.guid), ("StepDriverBlock", StepDriverBlock.guid),
            ("PulseGenBlock", PulseGenBlock.guid), ("TimerBlock", TimerBlock.guid),
            ("SinglePulseBlock", SinglePulseBlock.guid), ("PulseLengthBlock", PulseLengthBlock.guid),
            ("CounterBlock", CounterBlock.guid), ("AdvCounterBlock", AdvCounterBlock.guid),
            ("CopyBlock", CopyBlock.guid), ("IfBlock", IfBlock.guid), ("ElseBlock", ElseBlock.guid),
            ("EndIfBlock", EndIfBlock.guid), ("SwitchBlock", SwitchBlock.guid),
            ("CaseBlock", CaseBlock.guid), ("ResultsBlock", ResultsBlock.guid),
            ("CreateArrayBlock", CreateArrayBlock.guid), ("ReadArrayBlock", ReadArrayBlock.guid),
            ("WriteArrayBlock", WriteArrayBlock.guid), ("IntDemuxBlock", IntDemuxBlock.guid),
            ("FloatDemuxBlock", FloatDemuxBlock.guid), ("IntVarBlock", IntVarBlock.guid),
            ("FloatVarBlock", FloatVarBlock.guid), ("DateTimeBlock", DateTimeBlock.guid),
            ("WeekProgramBlock", WeekProgramBlock.guid), ("EncodeDateBlock", EncodeDateBlock.guid),
            ("DecodeDateBlock", DecodeDateBlock.guid), ("EightDOBlock", EightDOBlock.guid),
            ("EightDIBlock", EightDIBlock.guid), ("EightPWMBlock", EightPWMBlock.guid),
            ("BoolVarBlock", BoolVarBlock.guid), ("ValueDisplayBlock", ValueDisplayBlock.guid),
            ("SegmentBlock", SegmentBlock.guid), ("MacroBlock", MacroBlock.guid),
            ("SystemCmdBlock", SystemCmdBlock.guid),
        ]

        var wrong: [String] = []
        for (name, guid) in guids where !synthetic.contains(guid) {
            if BlockTypeCatalog.info(forGuid: guid) == nil {
                wrong.append("\(name) declares \(guid), which is not in the recovered registry")
            }
        }
        #expect(wrong.isEmpty, "\(wrong)")

        // And the reverse: if a synthetic GUID does appear in the catalog it must be marked as a
        // reimplementation extra, never as a real Dirigo block type.
        for guid in synthetic {
            if let info = BlockTypeCatalog.info(forGuid: guid) {
                #expect(info.category == "Reimplementation",
                        "\(info.blockName) uses a synthetic GUID but claims category \(info.category)")
            }
        }

        // The recovered registry must know every real Dirigo type.
        #expect(BlockTypeCatalog.all.count >= 144)
        #expect(BlockTypeCatalog.info(forBlockName: "IAdd")?.delphiClass == "TMIntAdd")
        #expect(BlockTypeCatalog.info(forBlockName: "And")?.category == "Bool")
    }
}

/// Guards a failure mode that is invisible to `swift build`: Xcode targets list their source
/// files explicitly, so a file added to `Sources/` after the project was last generated simply
/// is not compiled — producing "cannot find type X in scope" errors in Xcode while SwiftPM builds
/// cleanly. Regenerate with `xcodegen generate` (or `./bundle-app.sh`) after adding files.
@Suite("Xcode project membership")
struct XcodeProjectMembershipTests {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("Every Swift source on disk is referenced by the Xcode project")
    func everySourceIsInTheProject() throws {
        let root = Self.packageRoot
        let pbxproj = root.appendingPathComponent("Dirigo.xcodeproj/project.pbxproj")
        guard let project = try? String(contentsOf: pbxproj, encoding: .utf8) else {
            // Not an error: the Xcode project is optional for SwiftPM-only workflows.
            return
        }

        var onDisk: [String] = []
        for directory in ["Sources", "Tests"] {
            let base = root.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                onDisk.append(url.lastPathComponent)
            }
        }
        #expect(!onDisk.isEmpty)

        let missing = onDisk.filter { !project.contains("/* \($0) in Sources */") }
        if !missing.isEmpty {
            let detail = "not in Dirigo.xcodeproj (run `xcodegen generate`): "
                + "found \(onDisk.count) sources, missing \(missing.sorted())"
            Issue.record("\(detail)")
        }
    }
}

@Suite("Canvas interaction policy")
struct BlockInteractionTests {
    static func module(_ blockName: String, name: String, kind: String? = nil) throws -> PCCModule {
        let info = try #require(BlockTypeCatalog.info(forBlockName: blockName))
        var attrs: AttributeBag = [:]
        if let kind { attrs["KIND"] = kind }
        return PCCModule(
            id: 1, guid: info.guid, name: name, x: 0, y: 0, order: 10, threadId: 4,
            page: "main", rawAttributes: attrs
        )
    }

    @Test("Blocks that are not controls get no button")
    func nonControlsHaveNoButton() throws {
        // The bug this guards: `ISwitch` contains the substring "switch", so a name-based
        // heuristic gave a multiplexer a push-button that toggled its enable pin.
        for (blockName, instance) in [
            ("ISwitch", "ISwitch1"),
            ("And", "And1"),
            ("Or", "OrPrepinac"),
            ("Switch", "Switch1"),
            ("Case", "Case1"),
            ("Counter", "Counter1"),
            ("Segment", "Segment1"),
            ("SystemCmd", "SystemCmd1"),
            ("Comparator", "Comparator1"),
            ("Value", "AktivniRezim"),
        ] {
            let module = try Self.module(blockName, name: instance)
            #expect(BlockInteraction.classify(module) == .none,
                    "\(instance) (\(blockName)) should not be interactive")
        }
    }

    @Test("Only BoolVar gets a control")
    func onlyBoolVarIsAControl() throws {
        #expect(BlockInteraction.classify(try Self.module("BoolVar", name: "BoolVar1")) == .control)
        #expect(BlockInteraction.classify(try Self.module("BoolVar", name: "PrepinacRezim")) == .control)
        #expect(BlockInteraction.classify(try Self.module("BoolVar", name: "RoztoctRuletu")) == .control)
    }

    @Test("Input blocks toggle individual pins rather than showing a button")
    func inputBlocksTogglePins() throws {
        #expect(BlockInteraction.classify(try Self.module("8xDI", name: "8xDI1")) == .pinToggles)
        // `TMacroInterface` covers both directions; only Inputs (KIND 0) is user-driven.
        #expect(BlockInteraction.classify(try Self.module("Macro IO", name: "Inputs1", kind: "0")) == .pinToggles)
        #expect(BlockInteraction.classify(try Self.module("Macro IO", name: "OutputsHad", kind: "1")) == .none)
    }

    @Test("An unknown block type has no controls")
    func unknownTypeIsInert() {
        let unknown = PCCModule(
            id: 1, guid: UUID(uuidString: "3A1667B3-2E18-4764-905E-DFBF85F52D2A")!,  // Cnt
            name: "Cnt1", x: 0, y: 0, order: 1, threadId: 1, page: "main"
        )
        #expect(BlockInteraction.classify(unknown) == .none)
    }
}

@Suite("DelayFilter block")
struct DelayFilterBlockTests {
    @Test("Output appears after exactly Dly active cycles")
    func delayLength() {
        let block = DelayFilterBlock()
        let sample = SampleContext()
        block.inPins[0] = .bool(true)                 // En
        block.paramPins[0] = .int32(5)                // Dly

        block.inPins[1] = .bool(false)                // idle loads the countdown
        block.process(sample: sample)
        #expect(block.outPins[1].asBool == false)
        #expect(block.outPins[0].asInt == 5)

        block.inPins[1] = .bool(true)
        for cycle in 1...4 {
            block.process(sample: sample)
            #expect(block.outPins[1].asBool == false, "output early on cycle \(cycle)")
            #expect(block.outPins[0].asInt == 5 - cycle)
        }
        block.process(sample: sample)
        #expect(block.outPins[1].asBool == true)
        #expect(block.outPins[0].asInt == 0)

        // Holding the input keeps the output latched.
        for _ in 0..<5 {
            block.process(sample: sample)
            #expect(block.outPins[1].asBool == true)
        }
    }

    @Test("Clearing the input resets the countdown")
    func clearingResets() {
        let block = DelayFilterBlock()
        let sample = SampleContext()
        block.paramPins[0] = .int32(3)
        block.inPins[1] = .bool(true)
        block.process(sample: sample)
        block.process(sample: sample)
        #expect(block.outPins[1].asBool == false)

        block.inPins[1] = .bool(false)
        block.process(sample: sample)
        #expect(block.outPins[1].asBool == false)
        #expect(block.outPins[0].asInt == 3)

        block.inPins[1] = .bool(true)
        block.process(sample: sample)
        #expect(block.outPins[1].asBool == false)
        #expect(block.outPins[0].asInt == 2)
    }

    @Test("A zero delay passes the signal straight through")
    func zeroDelay() {
        let block = DelayFilterBlock()
        let sample = SampleContext()
        block.paramPins[0] = .int32(0)
        block.inPins[1] = .bool(true)
        block.process(sample: sample)
        #expect(block.outPins[1].asBool == true)
    }

    @Test("Disabling the block freezes it")
    func disabledHoldsState() {
        let block = DelayFilterBlock()
        let sample = SampleContext()
        block.paramPins[0] = .int32(2)
        block.inPins[1] = .bool(true)
        block.process(sample: sample)
        let held = block.outPins[0]

        block.inPins[0] = .bool(false)
        block.process(sample: sample)
        #expect(block.outPins[0] == held)
    }
}
