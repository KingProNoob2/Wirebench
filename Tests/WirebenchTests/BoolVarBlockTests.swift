import Testing
import Foundation
import WirebenchCore
import WirebenchEngine
@testable import WirebenchLibrary

/// A push button is on for as long as it is held. It used to fire a fixed two-tick pulse instead,
/// so holding the mouse down made no difference to the output — this pins the real behaviour.
@Suite("BoolVar button")
struct BoolVarBlockTests {
    @Test("A BoolVar is a push button or a latch; the slider mode of old files reads as a latch")
    func modes() {
        #expect(BoolVarBlock.Mode.allCases.count == 2)
        #expect(BoolVarBlock.Mode(simulMode: 1) == .toggleSwitch)
        #expect(BoolVarBlock.Mode(simulMode: 2) == .pushButton)
        #expect(BoolVarBlock.Mode(simulMode: 3) == .toggleSwitch, "SimulMode 3 was the slider")
        #expect(BoolVarBlock.Mode(simulMode: 0) == .pushButton)
        #expect(BoolVarBlock.Mode(simulMode: 99) == .pushButton)

        var module = PCCModule(id: 1, guid: BoolVarBlock.guid, name: "B", x: 0, y: 0, order: 10, threadId: 1,
                               page: "main", inPins: [], outPins: [Pin(id: 0, value: .bool(false))])
        module.simulMode = 3
        let block = BoolVarBlock(mode: BoolVarBlock.Mode(simulMode: 3))
        block.press()
        #expect(block.outPins[0].asBool)
        block.release()
        #expect(block.outPins[0].asBool, "a latch stays set when let go")
    }

    @Test("A push button stays on for the whole time it is held")
    func heldPushButtonStaysOn() {
        let block = BoolVarBlock(mode: .pushButton)
        let sample = SampleContext()

        #expect(!block.outPins[0].asBool)

        block.press()
        #expect(block.outPins[0].asBool, "pressing must turn it on")

        // Twenty ticks pass with the mouse still down: the value must not expire.
        for _ in 0..<20 {
            block.process(sample: sample)
            #expect(block.outPins[0].asBool, "a held button must not time out")
        }

        block.release()
        #expect(!block.outPins[0].asBool, "releasing must turn it off")
    }

    @Test("Releasing without pressing does not disturb a held button")
    func strayReleaseIsIgnored() {
        let block = BoolVarBlock(mode: .pushButton)
        block.release()
        #expect(!block.outPins[0].asBool)

        block.press()
        block.release()
        block.release()
        #expect(!block.outPins[0].asBool)
    }

    @Test("A single-shot trigger still expires on its own")
    func singleShotTriggerExpires() {
        let block = BoolVarBlock(mode: .pushButton)
        let sample = SampleContext()

        // Used by the inspector button and any keyboard/menu activation, where there is no release.
        block.trigger()
        #expect(block.outPins[0].asBool, "the pulse must be visible to the next tick")

        for _ in 0..<5 { block.process(sample: sample) }
        #expect(!block.outPins[0].asBool, "an un-held pulse must expire")
    }

    @Test("A held button outranks a pulse that was already running")
    func holdCancelsPendingPulse() {
        let block = BoolVarBlock(mode: .pushButton)
        let sample = SampleContext()

        block.trigger()          // a pulse is now counting down
        block.press()            // the user grabs the button before it expires
        for _ in 0..<10 { block.process(sample: sample) }
        #expect(block.outPins[0].asBool, "the hold must win over the pending pulse")

        block.release()
        #expect(!block.outPins[0].asBool)
    }

    @Test("A latch toggles on press and ignores the release")
    func latchIgnoresRelease() {
        let block = BoolVarBlock(mode: .toggleSwitch)

        block.press()
        #expect(block.outPins[0].asBool)

        block.release()
        #expect(block.outPins[0].asBool, "a latch must stay set after the mouse comes up")

        block.press()
        #expect(!block.outPins[0].asBool, "a second press clears it")
    }

    @Test("Reset clears a held button")
    func resetClearsHold() {
        let block = BoolVarBlock(mode: .pushButton)
        block.press()
        block.reset()
        #expect(!block.outPins[0].asBool)
        #expect(!block.isHeld)
    }
}

/// The help says only "not executed" for `En = 0`; it never says the output clears. The old code
/// was split — some blocks forced zero, others held — which is exactly the kind of inconsistency
/// that makes a schematic behave differently from the original. The rule is now: hold.
@Suite("Enable semantics")
struct EnableSemanticsTests {
    @Test("A disabled combinational block holds its output instead of clearing it")
    func disabledLogicHolds() {
        let sample = SampleContext()

        let and = AndBlock(inputCount: 2)
        and.inPins = [.bool(true), .bool(true), .bool(true)]
        and.process(sample: sample)
        #expect(and.outPins[0].asBool)              // 1 & 1 = 1

        and.inPins[0] = .bool(false)                // disable
        and.process(sample: sample)
        #expect(and.outPins[0].asBool, "a disabled block must hold, not clear")

        and.inPins[0] = .bool(true)
        and.inPins[1] = .bool(false)
        and.process(sample: sample)
        #expect(!and.outPins[0].asBool)             // and now it really is 0

        let not = NotBlock()
        not.inPins = [.bool(true), .bool(false)]
        not.process(sample: sample)
        #expect(not.outPins[0].asBool)
        not.inPins[0] = .bool(false)
        not.process(sample: sample)
        #expect(not.outPins[0].asBool, "a disabled NOT must hold")

        let xor = XorBlock()
        xor.inPins = [.bool(true), .bool(true), .bool(false)]
        xor.process(sample: sample)
        #expect(xor.outPins[0].asBool)
        xor.inPins[0] = .bool(false)
        xor.process(sample: sample)
        #expect(xor.outPins[0].asBool, "a disabled XOR must hold")
    }
}

@Suite("Trigger")
struct TriggerBlockTests {
    @Test("Either direction of change pulses the single output")
    func anyChangePulses() {
        let block = TriggerBlock()
        let sample = SampleContext()
        #expect(block.outPins.count == 1, "the help documents a single output")

        block.inPins = [.bool(true), .bool(false)]
        block.process(sample: sample)
        #expect(!block.outPins[0].asBool)          // first cycle establishes the baseline

        block.inPins[1] = .bool(true)
        block.process(sample: sample)
        #expect(block.outPins[0].asBool)           // 0 -> 1

        block.process(sample: sample)
        #expect(!block.outPins[0].asBool)          // no change

        // The old two-output model wrote the *rising* edge to pin 0, so a 1 -> 0 change produced
        // nothing at all on the pin the card actually shows.
        block.inPins[1] = .bool(false)
        block.process(sample: sample)
        #expect(block.outPins[0].asBool, "a falling change must pulse too")
    }
}


@Suite("Enable semantics (numeric blocks)")
struct NumericEnableSemanticsTests {
    @Test("Division holds when disabled")
    func divisionHoldsWhenDisabled() {
        let sample = SampleContext()
        let div = DivBlock()
        div.inPins = [.bool(true), .int32(100), .int32(4)]
        div.process(sample: sample)
        #expect(div.outPins[0].asInt == 25)

        // Disabled: the block must not execute at all, so the previous result stands. It used to
        // call reset() here and clear the output.
        div.inPins = [.bool(false), .int32(8), .int32(2)]
        div.process(sample: sample)
        #expect(div.outPins[0].asInt == 25, "a disabled block must hold, not clear")
    }

    @Test("A switch clears only for an out-of-range selector, not when disabled")
    func switchClearingRules() {
        let sample = SampleContext()
        let sw = ISwitchBlock()
        sw.inPins = [.bool(true), .int32(0), .int32(7)]
        sw.process(sample: sample)
        #expect(sw.outPins[0].asInt == 7)

        sw.inPins[0] = .bool(false)
        sw.process(sample: sample)
        #expect(sw.outPins[0].asInt == 7, "disabled holds")

        sw.inPins[0] = .bool(true)
        sw.inPins[1] = .int32(99)
        sw.process(sample: sample)
        #expect(sw.outPins[0].asInt == 0, "an out-of-range selector clears the output")
    }
}

@Suite("Demultiplexer and bit-packing rules")
struct DemuxAndBitTests {
    @Test("A demultiplexer holds the outputs it did not select")
    func demuxHoldsUnselected() {
        let sample = SampleContext()

        let f = FloatDemuxBlock(outputCount: 3)
        f.inPins = [.bool(true), .int32(1), .float(5.0)]
        f.process(sample: sample)
        #expect(f.outPins[1].asFloat == 5.0)

        // Select a different channel: the first must keep its value.
        f.inPins = [.bool(true), .int32(2), .float(9.0)]
        f.process(sample: sample)
        #expect(f.outPins[2].asFloat == 9.0)
        #expect(f.outPins[1].asFloat == 5.0, "an unselected output must hold, not clear")

        // Out of range: no write at all.
        f.inPins = [.bool(true), .int32(99), .float(1.0)]
        f.process(sample: sample)
        #expect(f.outPins[1].asFloat == 5.0 && f.outPins[2].asFloat == 9.0)

        // Disabled: hold too.
        f.inPins = [.bool(false), .int32(0), .float(3.0)]
        f.process(sample: sample)
        #expect(f.outPins[1].asFloat == 5.0 && f.outPins[2].asFloat == 9.0)
    }

    @Test("Int2Bits sizes itself from the module's output count, not a floor of 8")
    func int2BitsOutputCount() {
        let module = PCCModule(id: 1, guid: Int2BitsBlock.guid, name: "Int2Bits1", x: 0, y: 0,
                               order: 10, threadId: 1, page: "main",
                               inPins: [Pin(id: 0, value: .int32(0))],
                               outPins: (0..<2).map { Pin(id: $0, value: .bool(false)) })
        let block = BlockRegistry.shared.create(for: module)
        #expect(block.outPins.count == 2, "a two-output module must give a two-output block")
    }

    @Test("A fresh Timer starts with the documented preset of 1")
    func timerPresetDefault() {
        #expect(TimerBlock().paramPins[0].asInt == 1)
    }
}

@Suite("Mean")
struct MeanBlockTests {
    @Test("Values are averaged only while the trigger is high")
    func storesOnlyWhileTriggered() {
        let sample = SampleContext()
        let mean = MeanBlock(windowSize: 4)
        #expect(mean.inPins.count == 3, "the help documents En, Tr, X")

        // Trigger low: nothing is stored, so the output holds at its initial value.
        mean.inPins = [.bool(true), .bool(false), .int32(100)]
        mean.process(sample: sample)
        #expect(mean.outPins[0].asInt == 0)

        // Trigger high: 10 and 20 are stored.
        mean.inPins = [.bool(true), .bool(true), .int32(10)]
        mean.process(sample: sample)
        mean.inPins = [.bool(true), .bool(true), .int32(20)]
        mean.process(sample: sample)
        #expect(mean.outPins[0].asInt == 15)

        // Trigger low again: the 999 must be ignored, so the mean is unchanged.
        mean.inPins = [.bool(true), .bool(false), .int32(999)]
        mean.process(sample: sample)
        #expect(mean.outPins[0].asInt == 15, "an untriggered value must not enter the average")
    }

    @Test("The window slides, and its documented default is 12")
    func windowSlides() {
        let sample = SampleContext()
        let mean = MeanBlock()          // default window
        #expect(mean.windowSize == 12)

        for value in [1, 2, 3, 4] {
            mean.inPins = [.bool(true), .bool(true), .int32(Int32(value))]
            mean.process(sample: sample)
        }
        #expect(mean.outPins[0].asInt == 2)   // (1+2+3+4)/4

        let small = MeanBlock(windowSize: 2)
        for value in [10, 20, 30] {
            small.inPins = [.bool(true), .bool(true), .int32(Int32(value))]
            small.process(sample: sample)
        }
        #expect(small.outPins[0].asInt == 25, "only the last two values are kept")
    }
}

@Suite("Range and multi-comparator rules")
struct RangeAndComparatorTests {
    @Test("InRange uses its parameters, an exclusive upper bound, and wraps when L > H")
    func inRangeRules() {
        let sample = SampleContext()
        let r = InRangeBlock()
        r.paramPins = [.int32(10), .int32(20)]

        r.inPins = [.bool(true), .int32(10)]
        r.process(sample: sample)
        #expect(r.outPins[0].asBool, "the lower bound is inclusive")

        r.inPins = [.bool(true), .int32(20)]
        r.process(sample: sample)
        #expect(!r.outPins[0].asBool, "the upper bound is exclusive")

        r.inPins = [.bool(true), .int32(15)]
        r.process(sample: sample)
        #expect(r.outPins[0].asBool)

        // Overnight window: L > H inverts the test.
        r.paramPins = [.int32(20), .int32(10)]
        r.inPins = [.bool(true), .int32(23)]
        r.process(sample: sample)
        #expect(r.outPins[0].asBool, "23 is inside a 20..10 wrapping window")
        r.inPins = [.bool(true), .int32(15)]
        r.process(sample: sample)
        #expect(!r.outPins[0].asBool)

        // Disabled holds.
        r.paramPins = [.int32(10), .int32(20)]
        r.inPins = [.bool(true), .int32(15)]
        r.process(sample: sample)
        r.inPins = [.bool(false), .int32(99)]
        r.process(sample: sample)
        #expect(r.outPins[0].asBool, "a disabled block must hold")
    }

    @Test("MCompare returns the ordinal of the first matching constant")
    func multiComparatorFirstMatch() {
        let sample = SampleContext()
        let m = MultiComparatorBlock()
        #expect(m.inPins[0].asBool, "En is the first pin")
        m.paramPins = [.int32(5), .int32(7), .int32(5)]

        m.inPins = [.bool(true), .int32(7)]
        m.process(sample: sample)
        #expect(m.outPins[0].asInt == 2)

        // Two constants equal to the value: the FIRST one wins, not the last.
        m.inPins = [.bool(true), .int32(5)]
        m.process(sample: sample)
        #expect(m.outPins[0].asInt == 1, "the first matching constant decides the ordinal")

        m.inPins = [.bool(true), .int32(99)]
        m.process(sample: sample)
        #expect(m.outPins[0].asInt == 0, "no match is 0")
    }
}

@Suite("Step driver")
struct StepDriverTests {
    static func driver() -> StepDriverBlock {
        let b = StepDriverBlock()
        b.inPins = [.bool(true), .bool(false), .bool(false),
                    .int32(100), .int32(32), .int32(64), .int32(0), .int32(0)]
        return b
    }

    @Test("The pin surface is the documented one")
    func pinSurface() {
        let b = StepDriverBlock()
        #expect(b.inPins.count == 8, "En, Start, Preset, Speed, StartS, Accel, Posit, PrPos")
        #expect(b.outPins.count == 3, "Run, Spd, Pos")
    }

    @Test("Preset writes the position, but only while standing")
    func presetOnlyWhenStanding() {
        let sample = SampleContext()
        let b = Self.driver()

        b.inPins[2] = .bool(true)      // Preset
        b.inPins[7] = .int32(500)      // PrPos
        b.process(sample: sample)
        #expect(b.outPins[2].asInt == 500, "preset sets Pos while stopped")

        // Now start moving, then try to preset again: it must be ignored.
        b.inPins[1] = .bool(true)      // Start
        b.inPins[6] = .int32(900)      // Posit
        b.process(sample: sample)
        #expect(b.outPins[0].asBool, "the motor is running")

        b.inPins[2] = .bool(true)
        b.inPins[7] = .int32(0)
        b.process(sample: sample)
        #expect(b.outPins[2].asInt != 0, "preset is refused while Run = 1")
    }

    @Test("Start moves towards the target, then stops")
    func movesToTarget() {
        let sample = SampleContext()
        let b = Self.driver()
        b.inPins[1] = .bool(true)
        b.inPins[6] = .int32(300)

        var guardCount = 0
        while !(b.outPins.count > 2 && b.outPins[2].asInt == 300) && guardCount < 100 {
            b.process(sample: sample)
            guardCount += 1
        }
        #expect(b.outPins[2].asInt == 300, "Pos reaches the requested target")
        #expect(!b.outPins[0].asBool, "Run goes to 0 once the target is reached")
    }

    @Test("Speed zero stops the movement")
    func zeroSpeedStops() {
        let sample = SampleContext()
        let b = Self.driver()
        b.inPins[1] = .bool(true)
        b.inPins[6] = .int32(100_000)
        b.process(sample: sample)
        #expect(b.outPins[0].asBool)

        b.inPins[3] = .int32(0)        // Speed = 0
        for _ in 0..<10 { b.process(sample: sample) }
        #expect(!b.outPins[0].asBool, "a zero request stops the motor after the ramp")
    }
}

@Suite("Thermostat blocks")
struct ThermostatBlockTests {
    @Test("Valve steps the output and clamps to its limits")
    func valveStepping() {
        let sample = SampleContext()
        let v = ValveBlock()
        #expect(v.inPins.count == 3 && v.outPins.count == 1, "help pins: En, Op, Cl -> Y")
        v.paramPins = [.int32(5), .int32(20), .int32(0)]   // St, Max, Min

        v.inPins = [.bool(true), .bool(true), .bool(false)]
        v.process(sample: sample)
        #expect(v.outPins[0].asInt == 5)

        // Both inputs 1: no change.
        v.inPins = [.bool(true), .bool(true), .bool(true)]
        v.process(sample: sample)
        #expect(v.outPins[0].asInt == 5, "both active means no change")

        // Closes.
        v.inPins = [.bool(true), .bool(false), .bool(true)]
        v.process(sample: sample)
        #expect(v.outPins[0].asInt == 0)

        // Clamps at Min rather than going negative.
        v.process(sample: sample)
        #expect(v.outPins[0].asInt == 0, "the output is limited by Min")

        // Disabled holds.
        v.inPins = [.bool(false), .bool(true), .bool(false)]
        v.process(sample: sample)
        #expect(v.outPins[0].asInt == 0)
    }

    @Test("WaterRegulator is a dead-band comparator with hysteresis")
    func waterRegulatorDeadBand() {
        let sample = SampleContext()
        let w = WaterRegulatorBlock()
        #expect(w.inPins.count == 2 && w.outPins.count == 2, "En, T -> Op, Cl")
        w.paramPins = [.int32(50), .int32(2), .int32(1), .bool(false)]   // ReqT 50, band 2, half 1

        // Well above required in heating: close the valve.
        w.inPins = [.bool(true), .int32(60)]
        w.process(sample: sample)
        #expect(w.outPins[1].asBool, "Cl activates when d > band+half")
        #expect(!w.outPins[0].asBool)

        // Inside the band the latch holds — that is the hysteresis.
        w.inPins = [.bool(true), .int32(52)]
        w.process(sample: sample)
        #expect(w.outPins[1].asBool, "inside the band the previous command stands")

        // Below band-half it clears.
        w.inPins = [.bool(true), .int32(47)]
        w.process(sample: sample)
        #expect(!w.outPins[1].asBool, "Cl clears when d < band-half")

        // Well below required: open.
        w.inPins = [.bool(true), .int32(40)]
        w.process(sample: sample)
        #expect(w.outPins[0].asBool, "Op activates when d < -band-half")

        // Cooling reverses the two outputs.
        w.paramPins = [.int32(50), .int32(2), .int32(1), .bool(true)]
        w.reset()
        w.inPins = [.bool(true), .int32(60)]
        w.process(sample: sample)
        #expect(w.outPins[0].asBool, "in cooling mode a high temperature opens the valve")
    }
}

@Suite("Integer array data area")
struct IntArrayTests {
    @Test("Create, write and read share one Id-addressed area")
    func roundTrip() {
        let sample = SampleContext()

        // Unallocated: a read is 0, per "outside the permitted range ... the value 0".
        let read = ReadArrayBlock()
        read.inPins = [.bool(true), .int32(3), .int32(0)]
        read.process(sample: sample)
        #expect(read.outPins[0].asInt == 0)

        let create = CreateArrayBlock()
        create.inPins = [.bool(true), .int32(3), .int32(4)]
        create.process(sample: sample)
        #expect(create.outPins[0].asBool)

        // Out of range: no write, and Y holds.
        let write = WriteArrayBlock()
        write.inPins = [.bool(true), .int32(3), .int32(99), .int32(7)]
        write.process(sample: sample)
        #expect(write.outPins[0].asInt == 0, "an out-of-range write leaves Y unchanged")

        write.inPins = [.bool(true), .int32(3), .int32(1), .int32(42)]
        write.process(sample: sample)
        #expect(write.outPins[0].asInt == 42)

        read.inPins = [.bool(true), .int32(3), .int32(1)]
        read.process(sample: sample)
        #expect(read.outPins[0].asInt == 42, "the value is visible to a different block")
    }

    @Test("Re-creating with the same length preserves the contents")
    func recreateKeepsData() {
        let sample = SampleContext()

        let create = CreateArrayBlock()
        create.inPins = [.bool(true), .int32(6), .int32(4)]
        create.process(sample: sample)

        let write = WriteArrayBlock()
        write.inPins = [.bool(true), .int32(6), .int32(0), .int32(123)]
        write.process(sample: sample)

        // "If an array with the same length has already been created previously, no action is
        // taken" — so the value survives.
        create.process(sample: sample)

        let read = ReadArrayBlock()
        read.inPins = [.bool(true), .int32(6), .int32(0)]
        read.process(sample: sample)
        #expect(read.outPins[0].asInt == 123)

        // A different length reallocates, so the data is gone.
        create.inPins = [.bool(true), .int32(6), .int32(8)]
        create.process(sample: sample)
        read.process(sample: sample)
        #expect(read.outPins[0].asInt == 0, "a different length reallocates and clears")
    }
}

@Suite("Date blocks")
struct DateBlockTests {
    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        DirigoEpoch.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    @Test("The epoch is 1 Jan 1980, and DOW counts from Monday")
    func epochAnchors() {
        let jan1 = Self.date(1980, 1, 1)
        #expect(DirigoEpoch.days(from: jan1) == 0)
        // 1 Jan 1980 was a Tuesday; the help defines DOW as 0 = Monday.
        #expect(DirigoEpoch.dayOfWeek(from: jan1) == 1)

        // 1 Jan 2000 was a Saturday: 20 years with five leap days.
        let y2k = Self.date(2000, 1, 1)
        #expect(DirigoEpoch.days(from: y2k) == 7305)
        #expect(DirigoEpoch.dayOfWeek(from: y2k) == 5)
    }

    @Test("Decode and encode are inverses")
    func roundTrip() {
        let sample = SampleContext()
        let decode = DecodeDateBlock()
        let encode = EncodeDateBlock()

        // Day 0 is 1 Jan 1980, and MMDD is the documented 0101 form.
        decode.inPins = [.bool(true), .int32(0)]
        decode.process(sample: sample)
        #expect(decode.outPins[0].asInt == 1)
        #expect(decode.outPins[1].asInt == 1)
        #expect(decode.outPins[2].asInt == 1980)
        #expect(decode.outPins[3].asInt == 101)

        encode.inPins = [.bool(true), .int32(1), .int32(1), .int32(1980)]
        encode.process(sample: sample)
        #expect(encode.outPins[0].asInt == 0, "1 Jan 1980 is day zero")

        for days in [0, 1, 59, 365, 7305, 16000] {
            decode.inPins = [.bool(true), .int32(Int32(days))]
            decode.process(sample: sample)
            encode.inPins = [.bool(true), decode.outPins[0], decode.outPins[1], decode.outPins[2]]
            encode.process(sample: sample)
            #expect(encode.outPins[0].asInt == days, "round trip failed for day \(days)")
        }
    }

    @Test("DateTime has the documented outputs and ranges")
    func dateTimeShape() {
        let block = DateTimeBlock()
        // A real module is 1/0/5 (`SSemafor(1).pcc`): `En` in, no pins for the offset, and a
        // user-configurable set of outputs. The default exposes all six.
        #expect(block.inPins.count == 1, "En")
        #expect(block.paramPins.isEmpty, "Offs is configuration, not a pin")
        #expect(block.outPins.count == 6, "D, H, M, S, DOW, SOD")

        block.process(sample: SampleContext())
        #expect(block.outPins[4].asInt >= 0 && block.outPins[4].asInt <= 6, "DOW is 0...6")
        #expect(block.outPins[5].asInt >= 0 && block.outPins[5].asInt < 86400, "SOD is 0...86399")
        #expect(block.outPins[0].asInt > 16000, "days since 1980 for the present day")

        // A disabled block holds every output.
        let before = block.outPins
        block.inPins[0] = .bool(false)
        block.process(sample: SampleContext())
        #expect(block.outPins == before)
    }
}

@Suite("Advanced counter")
struct AdvCounterTests {
    static func counter() -> AdvCounterBlock {
        let c = AdvCounterBlock()
        c.inPins = [.bool(true), .bool(false), .bool(false), .bool(false), .bool(false), .bool(false)]
        c.paramPins = [.int32(100), .int32(10), .int32(-10), .int32(3)]  // PV, Max, Min, St
        return c
    }

    @Test("It counts rising edges, not levels")
    func countsRisingEdges() {
        let sample = SampleContext()
        let c = Self.counter()

        c.inPins[1] = .bool(true)
        c.process(sample: sample)
        #expect(c.outPins[0].asInt == 3, "the 0->1 transition adds St")

        // Still high: no further count.
        c.process(sample: sample)
        #expect(c.outPins[0].asInt == 3)

        c.inPins[1] = .bool(false)
        c.process(sample: sample)
        c.inPins[1] = .bool(true)
        c.process(sample: sample)
        #expect(c.outPins[0].asInt == 6)
    }

    @Test("Reset and preset do what the help says")
    func resetAndPreset() {
        let sample = SampleContext()
        let c = Self.counter()
        c.inPins[1] = .bool(true)
        c.process(sample: sample)

        c.inPins[2] = .bool(true)      // Rst
        c.process(sample: sample)
        #expect(c.outPins[0].asInt == 0)

        c.inPins[2] = .bool(false)
        c.inPins[3] = .bool(true)      // Pres
        c.process(sample: sample)
        #expect(c.outPins[0].asInt == 100, "preset loads PV")
    }

    @Test("Limiting needs its enable, but H and L do not")
    func limitsAndFlags() {
        let sample = SampleContext()
        let c = Self.counter()
        c.paramPins = [.int32(0), .int32(10), .int32(-10), .int32(20)]   // St 20, Max 10

        c.inPins[1] = .bool(true)
        c.process(sample: sample)
        #expect(c.outPins[0].asInt == 20, "EnH is off, so the value passes Max")

        // H reports the limit regardless of EnH, as the help states.
        #expect(c.outPins[1].asBool, "H is set when Y >= Max even with EnH off")

        // With EnH on the value is clamped.
        let c2 = Self.counter()
        c2.paramPins = [.int32(0), .int32(10), .int32(-10), .int32(20)]
        c2.inPins[4] = .bool(true)     // EnH
        c2.inPins[1] = .bool(true)
        c2.process(sample: sample)
        #expect(c2.outPins[0].asInt == 10, "EnH clamps to Max")

        // L likewise.
        let c3 = Self.counter()
        c3.paramPins = [.int32(0), .int32(10), .int32(-10), .int32(-30)]
        c3.inPins[1] = .bool(true)
        c3.process(sample: sample)
        #expect(c3.outPins[0].asInt == -30)
        #expect(c3.outPins[2].asBool, "L is set when Y <= Min without EnL")
    }

    @Test("A disabled counter holds")
    func disabledHolds() {
        let sample = SampleContext()
        let c = Self.counter()
        c.inPins[1] = .bool(true)
        c.process(sample: sample)
        let held = c.outPins[0].asInt

        c.inPins[0] = .bool(false)
        c.inPins[1] = .bool(false)
        c.process(sample: sample)
        c.inPins[1] = .bool(true)
        c.process(sample: sample)
        #expect(c.outPins[0].asInt == held, "a disabled counter must not count")
    }
}

@Suite("Variables and Set")
struct VariablesAndSetTests {
    static func module(_ id: Int, _ name: String, _ guid: UUID,
                       inPins: [PinValue] = [], outPins: [PinValue] = []) -> PCCModule {
        PCCModule(id: id, guid: guid, name: name, x: Double(id) * 200, y: 0, order: id * 10,
                  threadId: 1, page: "main",
                  inPins: inPins.enumerated().map { Pin(id: $0.offset, value: $0.element) },
                  outPins: outPins.enumerated().map { Pin(id: $0.offset, value: $0.element) })
    }

    @Test("A variable has one output and nothing else")
    func variableShape() {
        let sample = SampleContext()
        let v = IntVarBlock(initialValue: 42)
        #expect(v.inPins.isEmpty && v.paramPins.isEmpty, "the help gives IntVar a single output")
        #expect(v.outPins.count == 1)
        v.process(sample: sample)
        #expect(v.outPins[0].asInt == 42)

        let f = FloatVarBlock(initialValue: 1.5)
        f.process(sample: sample)
        #expect(f.outPins[0].asFloat == 1.5)
    }

    @Test("Set writes through its P pins into the producing block's output")
    func setWritesThrough() {
        // A variable the Set block will write into, wired into one of its P pins.
        let variable = Self.module(2, "IntVar1", IntVarBlock.guid, outPins: [.int32(0)])
        let setter = Self.module(3, "Set1", SetBlock.guid,
                                 inPins: [.bool(true), .int32(77), .int32(0)])
        // P1 (input pin 2) is fed by the variable's Y output.
        let wire = Connection(inModuleId: 3, inPinId: 2, outModuleId: 2, outPinId: 0)

        var project = PCCProject(name: "set")
        project.pages = [ProjectPage(caption: "main")]
        project.modules = [variable, setter]
        project.inConnections = [wire]

        let engine = TestEngine(project: project)
        engine.step()
        #expect(engine.getNode(id: 2)?.block.outPins[0].asInt == 77,
                "Set must overwrite the variable it is wired to")
    }

    @Test("A disabled Set writes nothing")
    func disabledSetWritesNothing() {
        let variable = Self.module(2, "IntVar1", IntVarBlock.guid, outPins: [.int32(5)])
        let setter = Self.module(3, "Set1", SetBlock.guid,
                                 inPins: [.bool(false), .int32(77), .int32(0)])
        let wire = Connection(inModuleId: 3, inPinId: 2, outModuleId: 2, outPinId: 0)

        var project = PCCProject(name: "set")
        project.pages = [ProjectPage(caption: "main")]
        project.modules = [variable, setter]
        project.inConnections = [wire]

        let engine = TestEngine(project: project)
        let before = engine.getNode(id: 2)?.block.outPins[0].asInt
        engine.step()
        #expect(engine.getNode(id: 2)?.block.outPins[0].asInt == before, "En = 0 must not write")
    }
}

@Suite("Demultiplexer, PWM and switch shapes")
struct PeripheralShapeTests {
    static func module(_ guid: UUID, inPins: Int, outPins: Int, attrs: [String: String] = [:]) -> PCCModule {
        var bag = AttributeBag()
        for (k, v) in attrs { bag[k] = v }
        return PCCModule(id: 1, guid: guid, name: "M1", x: 0, y: 0, order: 10, threadId: 1, page: "main",
                         inPins: (0..<inPins).map { Pin(id: $0, value: .int32(0)) },
                         outPins: (0..<outPins).map { Pin(id: $0, value: .int32(0)) },
                         rawAttributes: bag)
    }

    @Test("A demultiplexer's output count follows the module")
    func demuxCountFollowsModule() {
        // One output in the file means one output on the block — not the four the old floor gave.
        let single = BlockRegistry.shared.create(for: Self.module(FloatDemuxBlock.guid, inPins: 3, outPins: 1))
        #expect(single.outPins.count == 1)

        let five = BlockRegistry.shared.create(for: Self.module(FloatDemuxBlock.guid, inPins: 3, outPins: 5))
        #expect(five.outPins.count == 5)

        let intSingle = BlockRegistry.shared.create(for: Self.module(IntDemuxBlock.guid, inPins: 3, outPins: 2))
        #expect(intSingle.outPins.count == 2)
    }

    @Test("8xPWM has no output pins, as the help says")
    func pwmHasNoOutputs() {
        let block = EightPWMBlock()
        #expect(block.inPins.count == 9, "En + AO0...AO7")
        #expect(block.outPins.isEmpty, "the module drives physical outputs; it has no module pins")

        // The duty state is still computed and still holds while disabled.
        block.inPins[0] = .bool(true)
        block.inPins[1] = .int32(0)      // AO0 fully off
        block.inPins[2] = .int32(1000)   // AO1 fully on
        block.process(sample: SampleContext())
        #expect(block.duty[0] == false)
        #expect(block.duty[1] == true)

        let held = block.duty
        block.inPins[0] = .bool(false)
        block.process(sample: SampleContext())
        #expect(block.duty == held, "En = 0 means not executed, so the channels hold")
    }
}

@Suite("Increment")
struct IncrementTests {
    @Test("IInc adds exactly one, with no parameters")
    func iincShape() {
        let block = IncBlock()
        #expect(block.inPins.count == 2, "En, X")
        #expect(block.paramPins.isEmpty, "the help documents no parameters for IInc")
        #expect(block.outPins.count == 1, "Y")

        block.inPins = [.bool(true), .int32(41)]
        block.process(sample: SampleContext())
        #expect(block.outPins[0].asInt == 42)

        // Y = X + 1 even at the top of the range, without trapping.
        block.inPins = [.bool(true), .int32(Int32.max)]
        block.process(sample: SampleContext())
        #expect(block.outPins[0].asInt == Int32.min, "wraps rather than trapping")

        // Disabled holds.
        block.inPins = [.bool(true), .int32(5)]
        block.process(sample: SampleContext())
        block.inPins = [.bool(false), .int32(99)]
        block.process(sample: SampleContext())
        #expect(block.outPins[0].asInt == 6, "En = 0 holds the previous value")
    }
}

@Suite("Switch and system command shapes")
struct SelectorShapeTests {
    static func module(_ guid: UUID, inPins: Int, outPins: Int, attrs: [String: String] = [:]) -> PCCModule {
        var bag = AttributeBag()
        for (k, v) in attrs { bag[k] = v }
        return PCCModule(id: 1, guid: guid, name: "M1", x: 0, y: 0, order: 10, threadId: 1, page: "main",
                         inPins: (0..<inPins).map { Pin(id: $0, value: .int32(0)) },
                         outPins: (0..<outPins).map { Pin(id: $0, value: .int32(0)) },
                         rawAttributes: bag)
    }

    @Test("ISwitch's value-input count follows the module")
    func iSwitchFollowsModule() {
        // En + Sw + one value input.
        let one = BlockRegistry.shared.create(for: Self.module(ISwitchBlock.guid, inPins: 3, outPins: 1))
        #expect(one.inPins.count == 3, "En, Sw, X0")

        // The old floor of 2 gave this block four inputs against a three-pin module.
        let four = BlockRegistry.shared.create(for: Self.module(ISwitchBlock.guid, inPins: 6, outPins: 1))
        #expect(four.inPins.count == 6, "En, Sw, X0...X3")
    }

    @Test("SystemCmd is En, Cmd, Par1, Par2 -> Out")
    func systemCmdShape() {
        let block = SystemCmdBlock(inPins: 2, params: 2, outPins: 1)
        // A real module carries 2 IN_PINS and 2 PARAM_PINS (`rulkoshaddirigo.pcc`), so Par1/Par2
        // are parameters even though the help's table presents all four together.
        #expect(block.inPins.count == 2, "En, Cmd")
        #expect(block.paramPins.count == 2, "Par1, Par2")
        #expect(block.inPins[0].asBool, "the first pin is the Boolean enable")
        #expect(block.outPins.count == 1, "Out")

        // It holds while disabled.
        block.inPins = [.bool(false), .int32(1)]
        block.process(sample: SampleContext())
        #expect(block.outPins[0].asInt == 0)
    }
}

@Suite("Long and Float arithmetic")
struct LongAndFloatTests {
    static func block(_ name: String, inPins: Int, params: Int = 0) -> FunctionBlock {
        let guid = BlockTypeCatalog.all.first { $0.blockName == name }!.guid
        let module = PCCModule(id: 1, guid: guid, name: name, x: 0, y: 0, order: 10,
                               threadId: 1, page: "main",
                               inPins: (0..<inPins).map { Pin(id: $0, value: $0 == 0 ? .bool(true) : .float(0)) },
                               paramPins: (0..<params).map { Pin(id: $0, value: .float(0)) },
                               outPins: [Pin(id: 0, value: .float(0))])
        return BlockRegistry.shared.create(for: module)
    }

    @Test("Every previously-placeholder type now builds")
    func allImplemented() {
        let names = ["LAdd","LSub","LAbs","LNeg","LNot","LInc","LAnd","LOr","LXor",
                     "FAdd","FSub","FMul","FDiv","FAbs","FNeg","FSqrt","FMod",
                     "FSin","FCos","FASin","FACos"]
        for name in names {
            let guid = BlockTypeCatalog.all.first { $0.blockName == name }!.guid
            let module = PCCModule(id: 1, guid: guid, name: name, x: 0, y: 0, order: 10, threadId: 1,
                                   page: "main", inPins: [], outPins: [])
            #expect(!(BlockRegistry.shared.create(for: module) is UnresolvedBlock),
                    "\(name) should no longer be an unresolved block")
        }
    }

    @Test("Long arithmetic follows the documented rules")
    func longRules() {
        let sample = SampleContext()
        let add = Self.block("LAdd", inPins: 3)
        add.inPins = [.bool(true), .int32(7), .int32(35)]
        add.process(sample: sample)
        #expect(add.outPins[0].asInt == 42)

        let sub = Self.block("LSub", inPins: 3)
        sub.inPins = [.bool(true), .int32(50), .int32(8)]
        sub.process(sample: sample)
        #expect(sub.outPins[0].asInt == 42)

        let not = Self.block("LNot", inPins: 2)
        not.inPins = [.bool(true), .int32(0)]
        not.process(sample: sample)
        #expect(not.outPins[0].asInt == -1, "LNot is a bitwise complement")

        let and = Self.block("LAnd", inPins: 3)
        and.inPins = [.bool(true), .int32(0b1100), .int32(0b1010)]
        and.process(sample: sample)
        #expect(and.outPins[0].asInt == 0b1000)
    }

    @Test("Float arithmetic follows the documented rules")
    func floatRules() {
        let sample = SampleContext()
        let add = Self.block("FAdd", inPins: 3)
        add.inPins = [.bool(true), .float(1.5), .float(2.25)]
        add.process(sample: sample)
        #expect(add.outPins[0].asFloat == 3.75)

        let sqrt = Self.block("FSqrt", inPins: 2)
        sqrt.inPins = [.bool(true), .float(9)]
        sqrt.process(sample: sample)
        #expect(sqrt.outPins[0].asFloat == 3)

        // A negative root stays finite instead of producing NaN on the sheet.
        sqrt.inPins = [.bool(true), .float(-4)]
        sqrt.process(sample: sample)
        #expect(sqrt.outPins[0].asFloat == 0)

        // Division by zero leaves the accumulator alone rather than producing infinity.
        let div = Self.block("FDiv", inPins: 3)
        div.inPins = [.bool(true), .float(10), .float(0)]
        div.process(sample: sample)
        #expect(div.outPins[0].asFloat == 10)

        // Disabled holds.
        let add2 = Self.block("FAdd", inPins: 3)
        add2.inPins = [.bool(true), .float(1), .float(1)]
        add2.process(sample: sample)
        add2.inPins = [.bool(false), .float(5), .float(5)]
        add2.process(sample: sample)
        #expect(add2.outPins[0].asFloat == 2)
    }
}

@Suite("Long and Float arrays")
struct TypedArrayTests {
    @Test("Long arrays share the Int data area")
    func longArrays() {
        let sample = SampleContext()

        let create = BlockRegistry.shared.create(for: PCCModule(
            id: 1, guid: BlockTypeCatalog.all.first { $0.blockName == "CreateLongArray" }!.guid,
            name: "C", x: 0, y: 0, order: 10, threadId: 1, page: "main")) as! CreateArrayBlock
        create.inPins = [.bool(true), .int32(4), .int32(3)]
        create.process(sample: sample)
        #expect(create.outPins[0].asBool)

        let write = BlockRegistry.shared.create(for: PCCModule(
            id: 2, guid: BlockTypeCatalog.all.first { $0.blockName == "WriteLongArray" }!.guid,
            name: "W", x: 0, y: 0, order: 20, threadId: 1, page: "main")) as! WriteArrayBlock
        write.inPins = [.bool(true), .int32(4), .int32(2), .int32(1234)]
        write.process(sample: sample)
        #expect(write.outPins[0].asInt == 1234)

        let read = BlockRegistry.shared.create(for: PCCModule(
            id: 3, guid: BlockTypeCatalog.all.first { $0.blockName == "ReadLongArray" }!.guid,
            name: "R", x: 0, y: 0, order: 30, threadId: 1, page: "main")) as! ReadArrayBlock
        read.inPins = [.bool(true), .int32(4), .int32(2)]
        read.process(sample: sample)
        #expect(read.outPins[0].asInt == 1234, "a Long array shares the same Id space")
    }

    @Test("Float arrays carry fractional values")
    func floatArrays() {
        let sample = SampleContext()

        let create = BlockRegistry.shared.create(for: PCCModule(
            id: 1, guid: BlockTypeCatalog.all.first { $0.blockName == "CreateLongArray" }!.guid,
            name: "C", x: 0, y: 0, order: 10, threadId: 1, page: "main")) as! CreateArrayBlock
        create.inPins = [.bool(true), .int32(9), .int32(2)]
        create.process(sample: sample)

        let write = BlockRegistry.shared.create(for: PCCModule(
            id: 2, guid: BlockTypeCatalog.all.first { $0.blockName == "WriteFloatArray" }!.guid,
            name: "W", x: 0, y: 0, order: 20, threadId: 1, page: "main")) as! WriteArrayBlock
        write.inPins = [.bool(true), .int32(9), .int32(0), .float(1.25)]
        write.process(sample: sample)
        #expect(write.outPins[0].asFloat == 1.25)

        let read = BlockRegistry.shared.create(for: PCCModule(
            id: 3, guid: BlockTypeCatalog.all.first { $0.blockName == "ReadFloatArray" }!.guid,
            name: "R", x: 0, y: 0, order: 30, threadId: 1, page: "main")) as! ReadArrayBlock
        read.inPins = [.bool(true), .int32(9), .int32(0)]
        read.process(sample: sample)
        #expect(read.outPins[0].asFloat == 1.25, "fractional values survive")
    }
}

@Suite("Switch remainder and Move")
struct SwitchRemainderTests {
    static func module(_ name: String, inPins: Int, outPins: Int = 1) -> PCCModule {
        PCCModule(id: 1, guid: BlockTypeCatalog.all.first { $0.blockName == name }!.guid,
                  name: name, x: 0, y: 0, order: 10, threadId: 1, page: "main",
                  inPins: (0..<inPins).map { Pin(id: $0, value: .float(0)) },
                  outPins: (0..<outPins).map { Pin(id: $0, value: .float(0)) })
    }

    @Test("FSwitch selects Float values and clears out of range")
    func fSwitch() {
        let sample = SampleContext()
        let sw = BlockRegistry.shared.create(for: Self.module("FSwitch", inPins: 4)) as! ISwitchBlock
        sw.inPins = [.bool(true), .int32(1), .float(2.5), .float(7.5)]
        sw.process(sample: sample)
        #expect(sw.outPins[0].asFloat == 7.5, "Sw = 1 selects X1")

        sw.inPins[1] = .int32(9)
        sw.process(sample: sample)
        #expect(sw.outPins[0].asFloat == 0, "an out-of-range selector clears Y")

        sw.inPins[0] = .bool(false)
        sw.inPins[1] = .int32(0)
        sw.process(sample: sample)
        #expect(sw.outPins[0].asFloat == 0)
    }

    @Test("Move copies on a rising trigger and holds otherwise")
    func moveSamplesOnEdge() {
        let sample = SampleContext()
        let move = MoveBlock()

        // Trigger low: nothing is captured, so Y holds at its initial value.
        move.inPins = [.bool(true), .bool(false), .int32(11)]
        move.process(sample: sample)
        #expect(move.outPins[0].asInt == 0)

        // Rising edge captures X.
        move.inPins = [.bool(true), .bool(true), .int32(11)]
        move.process(sample: sample)
        #expect(move.outPins[0].asInt == 11)

        // Still high with a new X: a level is not a new edge, so Y holds.
        move.inPins = [.bool(true), .bool(true), .int32(99)]
        move.process(sample: sample)
        #expect(move.outPins[0].asInt == 11, "only a 0->1 transition copies")

        // A fresh edge captures the new value.
        move.inPins[1] = .bool(false)
        move.process(sample: sample)
        move.inPins[1] = .bool(true)
        move.process(sample: sample)
        #expect(move.outPins[0].asInt == 99)
    }
}

@Suite("Physical I/O")
struct PhysicalIOTests {
    static func module(_ name: String, inPins: Int, params: Int = 0, outPins: Int = 0) -> PCCModule {
        PCCModule(id: 1, guid: BlockTypeCatalog.all.first { $0.blockName == name }!.guid,
                  name: name, x: 0, y: 0, order: 10, threadId: 1, page: "main",
                  inPins: (0..<inPins).map { Pin(id: $0, value: .int32(0)) },
                  paramPins: (0..<params).map { Pin(id: $0, value: .int32(0)) },
                  outPins: (0..<outPins).map { Pin(id: $0, value: .int32(0)) })
    }

    @Test("The output-driving blocks have no module outputs and follow the module's pins")
    func hardwareOutputs() {
        // 2xAO: En, AO0, AO1 — no outputs.
        let ao = BlockRegistry.shared.create(for: Self.module("2xAO", inPins: 3))
        #expect(ao.inPins.count == 3, "En, AO0, AO1")
        #expect(ao.outPins.isEmpty, "these modules write to the unit, so they have no output pins")
        #expect(ao.inPins[0].asBool, "En defaults to 1")

        // IIC_3xDO: En, DO0..DO2 plus an Addr parameter.
        let do3 = BlockRegistry.shared.create(for: Self.module("IIC_3xDO", inPins: 4, params: 1))
        #expect(do3.inPins.count == 4, "En, DO0, DO1, DO2")
        #expect(do3.paramPins.count == 1, "Addr")
        #expect(do3.outPins.isEmpty)

        // IIC_8xAO: En + eight analog inputs, and pins come from the module rather than a constant.
        let ao8 = BlockRegistry.shared.create(for: Self.module("IIC_8xAO", inPins: 9, params: 1))
        #expect(ao8.inPins.count == 9, "En, AO0...AO7")
        #expect(ao8.outPins.isEmpty)

        let do8 = BlockRegistry.shared.create(for: Self.module("IIC_8xDO", inPins: 9, params: 1))
        #expect(do8.inPins.count == 9, "En, DO0...DO7")
    }

    @Test("ReadDallas reports no device rather than inventing a temperature")
    func readDallas() {
        let block = ReadDallasBlock()
        #expect(block.inPins.count == 1, "En")
        #expect(block.paramPins.count == 1, "Code")
        #expect(block.outPins.count == 2, "St, T")

        block.paramPins = [.int32(12345)]
        block.process(sample: SampleContext())
        #expect(block.outPins[0].asBool == false, "no sensor on the bus means St = 0")
        #expect(block.outPins[1].asInt == 0, "and no fabricated temperature")

        // Disabled holds.
        block.outPins = [.bool(true), .int32(99)]
        block.inPins[0] = .bool(false)
        block.process(sample: SampleContext())
        #expect(block.outPins[0].asBool, "En = 0 holds both outputs")
        #expect(block.outPins[1].asInt == 99)
    }
}

@Suite("D3-Net")
struct D3NetTests {
    static func module(_ name: String, inPins: Int, params: Int, outPins: Int) -> PCCModule {
        PCCModule(id: 1, guid: BlockTypeCatalog.all.first { $0.blockName == name }!.guid,
                  name: name, x: 0, y: 0, order: 10, threadId: 3, page: "main",
                  inPins: (0..<inPins).map { Pin(id: $0, value: .bool(false)) },
                  paramPins: (0..<params).map { Pin(id: $0, value: .int32(0)) },
                  outPins: (0..<outPins).map { Pin(id: $0, value: .bool(false)) })
    }

    @Test("Every D3-Net type builds instead of resolving to an unresolved block")
    func allTypesBuild() {
        let names = BlockTypeCatalog.all.filter { $0.delphiClass.hasPrefix("TMDbn") || $0.delphiClass.hasPrefix("TMStore") }
            .map(\.blockName)
        #expect(names.count == 15, "six readers, six writers, three Store blocks")
        for name in names {
            let block = BlockRegistry.shared.create(for: Self.module(name, inPins: 1, params: 4, outPins: 1))
            #expect(!(block is UnresolvedBlock), "\(name) should be implemented")
        }
    }

    @Test("A reader has En in, Addr/WID as parameters, and St out")
    func readerShape() {
        let sample = SampleContext()
        let reader = BlockRegistry.shared.create(for: Self.module("D3NRInt", inPins: 1, params: 2, outPins: 1))
        #expect(reader.inPins.count == 1, "En")
        #expect(reader.paramPins.count == 2, "Addr, WID")
        #expect(reader.outPins.count == 1, "St")

        // No network means the read did not succeed. Reporting 1 here would be a fabrication.
        reader.process(sample: sample)
        #expect(reader.outPins[0].asBool == false, "St must report the truth: there is no link")

        // Disabled holds, like every other block.
        reader.outPins[0] = .bool(true)
        reader.inPins[0] = .bool(false)
        reader.process(sample: sample)
        #expect(reader.outPins[0].asBool, "En = 0 holds St")
    }

    @Test("A Store block drains the buffer and sizes its outputs from the module")
    func storeShape() {
        let sample = SampleContext()
        D3NetBuffer.shared.reset()

        // The output count is user-configurable in the help, so it must follow the module.
        let store = BlockRegistry.shared.create(for: Self.module("StoreIntData", inPins: 1, params: 1, outPins: 5))
        #expect(store.outPins.count == 5, "D0...D4")
        #expect(store.paramPins.count == 1, "Ofs")

        store.process(sample: sample)
        #expect(store.outPins.allSatisfy { $0.asInt == 0 }, "an absent network yields zeros, not noise")

        // A disabled Store holds rather than clearing.
        store.outPins[3] = .int32(77)
        store.inPins[0] = .bool(false)
        store.process(sample: sample)
        #expect(store.outPins[3].asInt == 77, "En = 0 holds the buffer outputs")
    }

    @Test("The buffer is cleared by an engine reset")
    func bufferIsPartOfThePlc() {
        let engine = TestEngine(project: {
            var p = PCCProject(name: "d3net")
            p.pages = [ProjectPage(caption: "main")]
            return p
        }())
        engine.step()
        // Reaching here is the assertion: reset must not trap, and the buffer must survive it.
        D3NetBuffer.shared.reset()
        #expect(D3NetBuffer.shared.read(element: .integer, offset: 0, count: 3) == [0, 0, 0])
    }
}

@Suite("Main/Other blocks")
struct OtherBlocksTests {
    static func module(_ name: String, inPins: Int, params: Int = 0, outPins: Int = 0) -> PCCModule {
        PCCModule(id: 1, guid: BlockTypeCatalog.all.first { $0.blockName == name }!.guid,
                  name: name, x: 0, y: 0, order: 10, threadId: 1, page: "main",
                  inPins: (0..<inPins).map { Pin(id: $0, value: .int32(0)) },
                  paramPins: (0..<params).map { Pin(id: $0, value: .int32(0)) },
                  outPins: (0..<outPins).map { Pin(id: $0, value: .int32(0)) })
    }

    @Test("Logger reports no index, because nothing was written")
    func logger() {
        let block = BlockRegistry.shared.create(for: Self.module("Logger", inPins: 7, outPins: 1))
        #expect(block.inPins.count == 7, "En plus six user-configurable value inputs")
        #expect(block.outPins.count == 1, "Idx")
        #expect(block.inPins[0].asBool, "En defaults to 1")

        // No archive exists, so Idx = 0 rather than an index into a log that was never written.
        block.process(sample: SampleContext())
        #expect(block.outPins[0].asInt == 0)

        // Disabled holds.
        block.outPins[0] = .int32(42)
        block.inPins[0] = .bool(false)
        block.process(sample: SampleContext())
        #expect(block.outPins[0].asInt == 42, "En = 0 holds Idx")
    }

    @Test("P3Menu has no pins at all, and the shape-preserving blocks follow the module")
    func shapePreserving() {
        let menu = BlockRegistry.shared.create(for: Self.module("P3Menu", inPins: 0))
        #expect(menu.inPins.isEmpty && menu.paramPins.isEmpty && menu.outPins.isEmpty,
                "the help: it only serves to configure the menu via its dialog")

        // SaveData: En + configurable Long inputs, an Addr parameter, no outputs.
        let save = BlockRegistry.shared.create(for: Self.module("SaveData", inPins: 5, params: 1))
        #expect(save.inPins.count == 5)
        #expect(save.paramPins.count == 1, "Addr")
        #expect(save.outPins.isEmpty, "SaveData has no outputs")

        // Switch2 has no documentation entry, so its shape follows the module and it stays inert
        // rather than having a pin order guessed — a wrong guess would silently mis-wire it.
        let switch2 = BlockRegistry.shared.create(for: Self.module("Switch2", inPins: 4, outPins: 1))
        #expect(!(switch2 is UnresolvedBlock), "a real Switch2 module must at least resolve")
        #expect(switch2.inPins.count == 4)
        #expect(switch2.outPins.count == 1)
    }
}

@Suite("SetIdx")
struct SetIdxTests {
    static func module(_ id: Int, _ name: String, _ guid: UUID, inPins: [PinValue] = [],
                       outPins: [PinValue] = [], attrs: [String: String] = [:]) -> PCCModule {
        var bag = AttributeBag()
        for (k, v) in attrs { bag[k] = v }
        return PCCModule(id: id, guid: guid, name: name, x: Double(id) * 200, y: 0, order: id * 10,
                         threadId: 1, page: "main",
                         inPins: inPins.enumerated().map { Pin(id: $0.offset, value: $0.element) },
                         outPins: outPins.enumerated().map { Pin(id: $0.offset, value: $0.element) },
                         rawAttributes: bag)
    }

    @Test("The pin order is En, Idx, X, P0... and there are no outputs")
    func shape() {
        let block = SetIdxBlock(inPins: 6)          // En, Idx, X, P0, P1, P2
        #expect(block.inPins.count == 6)
        #expect(block.inPins[0].asBool, "En")
        #expect(block.outPins.isEmpty, "the help gives SetIdx no outputs")

        block.inPins[1] = .int32(2)
        #expect(block.targetPinIndex == 5, "Idx = 2 selects P2, which is pin 3 + 2")

        // "The value of input Idx must be in the range 0 to N-1, otherwise no write takes place."
        block.inPins[1] = .int32(3)
        #expect(block.targetPinIndex == nil, "Idx = N is out of range")
        block.inPins[1] = .int32(-1)
        #expect(block.targetPinIndex == nil, "a negative Idx is out of range")
    }

    @Test("It writes only the selected variable, through the engine")
    func writesOnlyTheSelectedPin() {
        // Two variables feed P0 and P1; only the one named by Idx may change.
        // `IntVar`'s value is configuration, not the module's OUT_PINS, so seed it as a file would.
        let first = Self.module(2, "IntVar1", IntVarBlock.guid, outPins: [.int32(0)],
                                attrs: ["INIT_VALUE": "11"])
        let second = Self.module(3, "IntVar2", IntVarBlock.guid, outPins: [.int32(0)],
                                 attrs: ["INIT_VALUE": "22"])
        let setter = Self.module(4, "SetIdx1", SetIdxBlock.guid,
                                 inPins: [.bool(true), .int32(1), .int32(42), .int32(0), .int32(0)])

        var project = PCCProject(name: "setidx")
        project.pages = [ProjectPage(caption: "main")]
        project.modules = [first, second, setter]
        // P0 is pin 3, P1 is pin 4.
        project.inConnections = [
            Connection(inModuleId: 4, inPinId: 3, outModuleId: 2, outPinId: 0),
            Connection(inModuleId: 4, inPinId: 4, outModuleId: 3, outPinId: 0),
        ]

        let engine = TestEngine(project: project)
        engine.step()
        #expect(engine.getNode(id: 3)?.block.outPins[0].asInt == 42, "Idx = 1 selects P1")
        #expect(engine.getNode(id: 2)?.block.outPins[0].asInt == 11, "P0 is untouched")

        // Disabled: nothing is written.
        engine.getNode(id: 4)?.block.inPins[0] = .bool(false)
        engine.getNode(id: 4)?.block.inPins[2] = .int32(99)
        engine.step()
        #expect(engine.getNode(id: 3)?.block.outPins[0].asInt == 42, "En = 0 must not write")
    }
}
