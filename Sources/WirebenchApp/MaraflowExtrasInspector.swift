import SwiftUI
import WirebenchCore
import WirebenchModel

/// Read-only Maraflow project metadata shown when nothing is selected: what the import preserved that the Dirigo
/// model has no native place for. Editing stays out of scope; the values are the source of truth for a later export.
struct MaraflowExtrasInspector: View {
    let extras: MaraflowExtras

    var body: some View {
        InspectorStack {
            InspectorCard(title: "Maraflow import") {
                LabeledContent("Target", value: extras.targetPlatform.isEmpty ? "unknown" : extras.targetPlatform)
                LabeledContent("Language", value: extras.primaryLanguage)
                LabeledContent("Pages", value: "\(extras.pageSummaries.count)")
                LabeledContent("Wires", value: "\(extras.wireCount)")
                LabeledContent("Graphics", value: "\(extras.graphicCount)")
                LabeledContent("Bus bundles", value: "\(extras.busCount)")
                if extras.hiddenWireCount > 0 {
                    LabeledContent("Hidden wires", value: "\(extras.hiddenWireCount)")
                }
            }

            if !extras.tags.isEmpty {
                InspectorCard(title: "Symbolic tags") {
                    ForEach(Array(extras.tags.prefix(16).enumerated()), id: \.offset) { _, tag in
                        LabeledContent(tag.name, value: tag.type)
                    }
                    if extras.tags.count > 16 {
                        Text("+ \(extras.tags.count - 16) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            let eStop = extras.eStop
            InspectorCard(title: "E-Stop") {
                LabeledContent("Enabled", value: eStop.enabled ? "yes" : "no")
                LabeledContent("Mode", value: eStop.mode)
                LabeledContent("Manual reset", value: eStop.manualReset ? "yes" : "no")
                if !eStop.pageName.isEmpty {
                    LabeledContent("Page", value: eStop.pageName)
                }
                ForEach(Array(eStop.rules.enumerated()), id: \.offset) { _, rule in
                    LabeledContent(rule.channel, value: rule.activeLow ? "active low" : "active high")
                }
            }

            InspectorCard(title: "Pages") {
                ForEach(Array(extras.pageSummaries.enumerated()), id: \.offset) { _, page in
                    LabeledContent(page.name, value: "\(page.language) · \(page.blocks) blocks · \(page.rungs) rungs")
                }
            }
        }
    }
}
