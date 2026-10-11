import Testing
import Foundation
import DirigoCore
import DirigoLibrary
import DirigoEngine
@testable import DirigoApp

@Suite("Probe")
@MainActor
struct ProbeTests {
    @Test("where does an app tick go")
    func breakdown() throws {
        let url = URL(fileURLWithPath: "/Users/erik/Nextcloud/School")
            .appendingPathComponent("Informační a Řídící Systémy")
            .appendingPathComponent("Dirigo").appendingPathComponent("had.pcc")
        let project = try PCCParser().parse(fileAt: url)
        let delta = Double(max(1, project.appOptions.cycleDelay))
        let n = 5_000

        func time(_ label: String, _ body: () -> Void) {
            body()   // warm
            let t0 = ContinuousClock.now
            for _ in 0..<n { body() }
            let d = t0.duration(to: ContinuousClock.now)
            let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
            print(String(format: "TICK %-34s %7.2f us/call", (label as NSString).utf8String!, ms * 1000 / Double(n)))
        }

        let engine = SimulationEngine(project: project, scheduling: .everyTick)
        let core = CxxSimulationCore(project: project, profileScheduling: false)

        time("SimulationEngine.step()") { engine.step() }
        time("CxxSimulationCore.step()") { core.step(deltaMs: delta) }
        time("mirror out: get_out x modules") {
            for m in project.modules {
                guard let node = engine.getNode(id: m.id) else { continue }
                for pin in 0..<node.block.outPins.count {
                    _ = core.outValue(moduleId: m.id, pin: pin)
                }
            }
        }

        let model = AppModel()
        model.loadProject(url: url)
        print("TICK usesCxxCore=\(model.isUsingCxxCore) modules=\(project.modules.count)")
        time("refreshSnapshots()") { _ = model.refreshSnapshots() }
        time("simulationDidChange()") { model.simulationDidChange() }
    }
}
