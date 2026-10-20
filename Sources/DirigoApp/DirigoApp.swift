import SwiftUI

@main
struct DirigoApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            MainView(model: model)
                .frame(minWidth: 1000, minHeight: 650)
                .preferredColorScheme(model.appearance.colorScheme)
                // Documents opened from Finder or `open` arrive here.
                .onOpenURL { url in
                    if model.confirmDiscardingChanges() { model.loadProject(url: url) }
                }
                .onAppear {
                    // Unsaved work is asked about before Quit, New and Open replace it.
                    appDelegate.model = model
                    model.confirmDiscardingChanges = { [weak model] in
                        // Only ever called from menu and view actions, which run on the main thread.
                        MainActor.assumeIsolated { model.map(UnsavedChanges.confirm) ?? true }
                    }
                }
        }
        Settings {
            SettingsView(model: model)
                .preferredColorScheme(model.appearance.colorScheme)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)

            Button("Redo") { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
        }

        CommandGroup(after: .pasteboard) {
            Button("Delete Block") { model.deleteSelectedModule() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selectedModuleId == nil)

            Button("Delete Text") { model.deleteSelectedAnnotation() }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .disabled(model.selectedAnnotationIndex == nil)
        }

        // The build menu: what the compiler makes of the project, and where to put it.
        CommandMenu("Build") {
            Button("Build Project") { model.buildAndShowReport() }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(model.project == nil)

            Button("Build Report") { model.isShowingBuildReport = true }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(model.buildReport == nil)

            Divider()

            Button("Export Program Binary\u{2026}") { model.exportCompiledProgram() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(model.project == nil)

            Button("Export Symbol Table (CSV)\u{2026}") { model.exportSymbolTable() }
                .disabled(model.project == nil)

            Divider()

            Button("Upload Compiled Program to PLC\u{2026}") { model.uploadCompiledProgram() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(model.project == nil || model.isUploading)

            Divider()

            Button("Use Program Binary as Build Template\u{2026}") { model.chooseBuildTemplate() }
                .disabled(model.project == nil)
        }

        CommandGroup(replacing: .newItem) {
                Button("New Project") {
                    model.createNewProject()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Open Project...") {
                    model.openProjectFile()
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Save") {
                    model.saveProject()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.project == nil)

                Button("Save As...") {
                    model.saveProjectAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model.project == nil)

                Divider()

                Button("Add Block\u{2026}") {
                    NotificationCenter.default.post(name: .showBlockPalette, object: nil)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(model.project == nil)

                Button("Add Text") { model.addTextAnnotation() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(model.project == nil)

                Divider()

                Button("Organize Blocks") {
                    model.organizeBlocks()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(model.project == nil)

                Button("Reset Wire Routing") {
                    model.resetWireRouting()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.project == nil)

                Button("Export Legacy .PCC") {
                    model.exportForDirigo()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.project == nil)

                Divider()

                Button("Upload Program to PLC…") {
                    model.uploadProgramFile()
                }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(model.isUploading)
            }
        }
    }
}

public extension Notification.Name {
    /// Asks the main window to open the block palette. Lets the menu bar and the toolbar share one
    /// popover instead of each needing its own presentation state.
    static let showBlockPalette = Notification.Name("com.dirigo.showBlockPalette")
}
