import Testing
import Foundation
import WirebenchCore
import WirebenchLibrary
import WirebenchEngine
import WirebenchHardware
@testable import WirebenchModel

/// What a corrupt, truncated or hostile `.pcc` does: refuse it, or read what it can — never trap.
///
/// The files a user opens are not always the ones Dirigo wrote: a transfer over a network share, a text editor,
/// a half-written save. A parser that traps turns a bad file into a lost session.
@Suite("Malformed input")
struct RobustnessTests {
    @Test("Truncated and wrongly rooted documents are refused, not crashed on")
    func refusal() {
        let cases: [String] = [
            "",
            "   ",
            "<PCC_PROJECT",
            "<PCC_PROJECT APPLICATION=\"Dirigo\"",
            "<PCC_PROJECT>",
            "<PCC_PROJECT></PCC_PROJECTX>",
            "<FOO/>",
            "<pcc_project/>",
            "<?xml version=\"1.0\"?><PCC_PROJECT>",
            "<PCC_PROJECT><MODULES><MODULE></MODULES></PCC_PROJECT>",
            "\u{0}\u{1}\u{2}",
        ]
        for text in cases {
            // Whatever it decides, it must decide: either a project or a thrown error.
            do {
                let project = try PCCParser().parse(xmlString: text)
                _ = PCCSerializer().serialize(project: project)
            } catch {
                // refusing is the right answer for a document that is not a project
            }
        }
    }

    @Test("Absurd attribute values fall back instead of trapping")
    func absurdValues() throws {
        let xml = """
        <PCC_PROJECT NAME="x" PAGESIZE="999999999999999999999" THREADINDEX="-99" OLD_EXPORT_MODE="banana">
          <PAGES>
            <PAGE CAPTION=""/>
            <PAGE CAPTION=""/>
            <PAGE/>
          </PAGES>
          <MODULES>
            <MODULE GUID="not-a-guid" NAME="" ID="999999999999999999999" X="1e400" Y="nan" ORDER="-1" THREAD_ID="-3" PAGE="nope">
              <IN_PINS>
                <IN_PIN VALUE="&#9;"/>
                <IN_PIN VALUE="999999999999999999999999999"/>
                <IN_PIN VALUE="nan"/>
                <IN_PIN VALUE="Infinity"/>
                <IN_PIN VALUE="-0"/>
                <IN_PIN INVERTED="yes"/>
              </IN_PINS>
              <OUT_PINS><OUT_PIN VALUE="1e400" RIGHTS="-7"/></OUT_PINS>
            </MODULE>
            <MODULE GUID="{74F92168-F67B-4364-8AC0-B735DAA400A3}" NAME="huge-thread" ID="2" THREAD_ID="2000000000"/>
            <MODULE GUID="{74F92168-F67B-4364-8AC0-B735DAA400A3}" NAME="dup" ID="1"/>
            <MODULE GUID="{74F92168-F67B-4364-8AC0-B735DAA400A3}" NAME="dup2" ID="1"/>
          </MODULES>
          <CONNECTIONS>
            <IN_CONNECTIONS>
              <CONNECTION IN_MODULE_ID="-1" IN_PIN_ID="-2" OUT_MODULE_ID="0" OUT_PIN_ID="99999"/>
              <CONNECTION/>
            </IN_CONNECTIONS>
            <PARAM_CONNECTIONS><CONNECTION IN_MODULE_ID="1" IN_PIN_ID="7" OUT_MODULE_ID="1" OUT_PIN_ID="7"/></PARAM_CONNECTIONS>
          </CONNECTIONS>
        </PCC_PROJECT>
        """
        let project = try PCCParser().parse(xmlString: xml)
        #expect(project.pages.count == 3)
        #expect(project.modules.count == 4)
        // Saving and running must be survivable too.
        _ = try TortureCorpusTests.expectRoundTrip(project, "absurd values", modelStable: false)
        let core = CxxSimulationCore(project: project, profileScheduling: false)
        for _ in 0..<20 { core.step(deltaMs: 7, now: TortureProjects.now) }
    }

    /// A `THREAD_ID` outside the threads this simulator has must not reach the schedule array.
    ///
    /// It did: `schedule[threadId]` was indexed with the file's value, so a negative one became a huge `size_t` and wrote
    /// out of bounds — a libc++ hardening assertion in a debug build, silent memory corruption in a release one — and a
    /// large one would have allocated a vector per thread id. Both are one `THREAD_ID` attribute away in a hand-edited
    /// file. A module outside every thread keeps its pins and never runs, which is what a block on no thread is.
    @Test("A thread id no thread has is not scheduled and does not trap")
    func threadIdsAreBounded() {
        for threadId in [-3, -1, 0, 1, 63, 64, 2_000_000_000, Int.max, Int.min] {
            var project = TortureProjects.chain(3)
            project.modules[0].threadId = threadId
            let core = CxxSimulationCore(project: project, profileScheduling: false)
            for _ in 0..<10 { core.step(deltaMs: 7, now: TortureProjects.now) }
            #expect(core.tickCount == 10, "thread id \(threadId) stopped the simulation")
            #expect(core.contains(moduleId: project.modules[0].id), "thread id \(threadId) lost the module")
            if threadId < 0 || threadId >= 64 {
                #expect(core.threadRunCounts[threadId] == nil,
                        "thread id \(threadId) is not a thread, but the module ran on it")
            }
        }
    }

    /// Every truncation and a spread of single-byte mutations of a real project: each must parse or throw.
    @Test("A mutated real project never traps the parser")
    func mutationFuzz() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent("Tests/Fixtures/rulkoshad-sevenseg.pcc")
        let original = try String(contentsOf: fixture, encoding: .utf8)
        let bytes = Array(original.utf8)

        var parsed = 0, refused = 0
        for cut in stride(from: 0, to: bytes.count, by: max(1, bytes.count / 400)) {
            let slice = Data(bytes.prefix(cut))
            if let project = try? PCCParser().parse(data: slice) {
                parsed += 1
                _ = PCCSerializer().serialize(project: project)
            } else {
                refused += 1
            }
        }
        // Single-byte corruption in the structure, where the parser has to make a decision.
        for offset in stride(from: 0, to: bytes.count, by: max(1, bytes.count / 400)) {
            var copy = bytes
            copy[offset] = UInt8(ascii: "<")
            if let project = try? PCCParser().parse(data: Data(copy)) {
                parsed += 1
                _ = PCCSerializer().serialize(project: project)
            } else {
                refused += 1
            }
        }
        #expect(parsed + refused >= 700, "the fuzz did not run: \(parsed) parsed, \(refused) refused")
    }
}
