import SwiftUI

/// The Settings window (⌘,): preferences that are remembered between launches.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Picker("Appearance", selection: $model.appearance) {
                ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Toggle("Mouse wheel zooms the canvas (off: it pans)", isOn: $model.scrollZooms)
            Toggle("Snap blocks to grid", isOn: $model.snapToGrid)
            Toggle("Optimise program when building", isOn: $model.optimizeProgram)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
