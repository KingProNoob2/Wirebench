import SwiftUI
import WirebenchModel

@main
struct WirebenchApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some Scene {
        WindowGroup {
            MainView(model: model)
                .frame(minWidth: 1000, minHeight: 650)
                .preferredColorScheme(model.appearance.colorScheme)
                // Documents opened from Finder or `open` arrive here.
                .onOpenURL { url in
                    model.openProjectFromFinder(url)
                }
                .onAppear {
                    // Unsaved work is asked about before Quit, New and Open replace it; the question
                    // itself is the SwiftUI alert in `MainView`, and the delegate only waits on it.
                    appDelegate.model = model
                }
        }
        // A window of its own for the agent, one at a time: opening it again brings it forward.
        Window("Agent", id: "agent") {
            AgentPanelView(agent: model.agent)
                .preferredColorScheme(model.appearance.colorScheme)
                // A window that comes back at launch (macOS restores the ones that were open), or is open when the project goes, closes with no project.
                .onAppear { if model.project == nil { dismissWindow(id: "agent") } }
                .onChange(of: model.project == nil) { _, none in if none { dismissWindow(id: "agent") } }
        }
        .defaultSize(width: 380, height: 540)
        // The block reference, one window at a time like the agent's.
        Window("Block Reference", id: "help") {
            HelpView(help: model.help)
                .preferredColorScheme(model.appearance.colorScheme)
        }
        .defaultSize(width: 900, height: 640)
        Settings {
            SettingsView(model: model)
                .preferredColorScheme(model.appearance.colorScheme)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            // View ▸ Show/Hide Sidebar (⌃⌘S) and Show/Hide Inspector (⌃⌘I): a hidden pane can come
            // back from the menu and the keyboard, not only from its toolbar button. The inspector is a
            // plain split pane rather than `.inspector`, so its command is ours rather than `InspectorCommands`.
            SidebarCommands()
            CommandGroup(after: .sidebar) {
                Button("Toggle Inspector") {
                    NotificationCenter.default.post(name: .toggleInspector, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.control, .command])

                // The agent works on the open project, so it is not offered without one.
                Button("Agent Panel") { openWindow(id: "agent") }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(model.project == nil)
            }

            // Help ▸ Block Reference (⌘?), in place of the empty help the system adds.
            CommandGroup(replacing: .help) {
                Button("Block Reference") { openWindow(id: "help") }
                    .keyboardShortcut("/", modifiers: [.command, .shift])
            }

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

            Button("Delete Object") { model.deleteSelectedAnnotation() }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .disabled(model.selectedAnnotationIndex == nil)
        }

        // The build menu: what the compiler makes of the project.
        CommandMenu("Build") {
            Button("Build Project") { model.buildAndShowReport() }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(model.project == nil)

            Button("PLC Configuration\u{2026}") { model.isShowingPLCConfiguration = true }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(model.project == nil)

            Divider()

            Button("Use Program Binary as Build Template\u{2026}") { model.chooseBuildTemplate() }
                .disabled(model.project == nil)
        }

        // What a build produces. Both are also buttons on the build report, which is where you reach
        // them with a report already open; from here they compile first if nothing is built yet.
        //
        // "Program Variables" is Dirigo's own name for the symbol table, and this writes the file the
        // original leaves beside a project: its `AFileExportVariables` action runs
        // `ExportFileVariables`, which writes the same rows through `TDBFTable` as a dBase III `.dbf`.
        // The `.csv` of those same rows stays on the build report, where it has always been.
        CommandMenu("Export") {
            Button("Export Program Variables\u{2026}") { model.exportProgramVariables() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(model.project == nil)

            Button("Export Program Binary\u{2026}") { model.exportCompiledProgram() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(model.project == nil)
        }

        CommandGroup(replacing: .newItem) {
                Button("New Project") {
                    model.createNewProject()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Open Project\u{2026}") {
                    model.openProjectFile()
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Save") {
                    model.saveProject()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.project == nil)

                Button("Save As\u{2026}") {
                    model.saveProjectAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model.project == nil)

                Divider()

                Button("Add Block\u{2026}") {
                    NotificationCenter.default.post(name: .showBlockPalette, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(model.project == nil)

                Button("Add Text") { model.addTextAnnotation() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(model.project == nil)

                Button("Add Rectangle") { model.addShape(.rectangle) }
                    .keyboardShortcut("r", modifiers: [.control, .command])
                    .disabled(model.project == nil)

                Button("Add Circle") { model.addShape(.ellipse) }
                    .keyboardShortcut("c", modifiers: [.control, .command])
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

                Button("Export Legacy .PCC\u{2026}") {
                    model.exportForDirigo()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.project == nil)
            }
        }
    }
}

public extension Notification.Name {
    /// Asks the main window to open the block palette. Lets the menu bar and the toolbar share one
    /// popover instead of each needing its own presentation state.
    static let showBlockPalette = Notification.Name("com.wirebench.showBlockPalette")
    /// Closes it again, after a block was dragged out of it onto the sheet.
    static let dismissBlockPalette = Notification.Name("com.wirebench.dismissBlockPalette")
    /// A drag out of the block picker has finished and its picture is gone; `userInfo["payload"]` is what was dragged.
    static let paletteDragEnded = Notification.Name("com.wirebench.paletteDragEnded")
    /// Asks the main window to show or hide the inspector pane, from the View menu.
    static let toggleInspector = Notification.Name("com.wirebench.toggleInspector")
    /// Asks the main window to show the inspector pane, from a block's, shape's or text's own context
    /// menu. Opening is one-way on purpose: *Inspect* from a right-click means "show me this", and a
    /// toggle there would sometimes close the pane the user just asked for.
    static let showInspector = Notification.Name("com.wirebench.showInspector")
    /// Asks for the block reference to open at a block type; `userInfo["block"]` is its name.
    static let showHelp = Notification.Name("com.wirebench.showHelp")
}
