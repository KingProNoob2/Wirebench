import WirebenchModel
import SwiftUI
import WirebenchCore

public struct MainView: View {
    @Bindable var model: AppModel
    /// Hidden until asked for: the sheet is the point of the window, and the pane opens from
    /// *Inspect* in a block's, shape's or text's context menu, from the toolbar, or with ⌃⌘I.
    @Environment(\.openWindow) private var openWindow
    @State private var showInspector: Bool = false
    /// The inspector's width, which the divider drags. The split view used to own this.
    @State private var inspectorWidth: CGFloat = MainView.inspectorIdealWidth
    /// The width the current divider drag started from, so the panes do not creep.
    @State private var dragStartWidth: CGFloat?
    /// The width of the detail area, which is what the toolbar spans. Measured, so the run controls know how
    /// far they have room to move (`inspectorShift`).
    @State private var detailWidth: CGFloat = 0
    /// The height of the toolbar — the top safe-area inset of the detail area — which the top bar's material fills.
    @State private var topInset: CGFloat = 0
    /// The shift the toolbar shows right now. It eases to `inspectorShift` when the inspector opens or closes
    /// (`easeShift`), where the pane itself slides in the same time.
    @State private var shownShift: CGFloat = 0
    @State private var shiftEasing: Task<Void, Never>?
    /// True while the inspector's own slide is what is moving the balance, so the width-driven path stays out of it.
    @State private var easingShiftForToggle = false
    @State private var shiftSettle: Task<Void, Never>?
    @State private var showingPalette = false
    @State private var newPageName: String = ""
    @State private var newPageIsMacro = false
    @Namespace private var pageSelection
    /// The sidebar is kept open while the build report is up: the report is a popover on the sidebar's Build button.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingNewPage = false
    /// Caption of the page whose deletion is awaiting confirmation.
    @State private var pendingPageDeletion: String?
    @State private var renamingPage: String?
    @State private var renameText = ""

    public init(model: AppModel = AppModel.shared ?? AppModel()) {
        self.model = model
    }

    /// The inspector's width range, which the old split pane asked for as `minWidth`/`maxWidth`.
    private static let inspectorMinWidth: CGFloat = 250
    private static let inspectorIdealWidth: CGFloat = 280
    private static let inspectorMaxWidth: CGFloat = 340
    /// The divider's grab area. The line drawn inside it stays a hairline.
    private static let inspectorDividerWidth: CGFloat = 6
    /// About how wide the run controls are, and how much of each end of the toolbar is taken by the title and the
    /// trailing buttons. Estimates: the toolbar will not take more than they leave room for.
    private static let runControlsWidth: CGFloat = 410
    private static let toolbarSideReserve: CGFloat = 140

    /// Opens or closes the inspector: the pane's width and the content's slide run in one animation.
    private func toggleInspector() {
        withAnimation(.easeInOut(duration: 0.22)) { showInspector.toggle() }
        easingShiftForToggle = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            easingShiftForToggle = false
        }
    }

    /// The handle that resizes the inspector — what `HSplitView` used to provide.
    ///
    /// A 6 pt strip along the pane's edge, wide enough to grab with a mouse, and drawn as nothing: the material is the
    /// pane's edge, and a line on it only makes it look like two panes.
    private var inspectorDivider: some View {
        Color.clear
            .frame(width: Self.inspectorDividerWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .modifier(ColumnResizePointer())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Measured from where the drag began, so the divider follows the pointer rather
                        // than accumulating its own translation frame after frame.
                        let start = dragStartWidth ?? inspectorWidth
                        if dragStartWidth == nil { dragStartWidth = inspectorWidth }
                        inspectorWidth = min(Self.inspectorMaxWidth,
                                             max(Self.inspectorMinWidth, start - value.translation.width))
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }

    /// The speed slider's position: the index of the nearest step.
    private var speedIndex: Binding<Double> {
        Binding(
            get: {
                let steps = AppModel.speedSteps
                let nearest = steps.indices.min { abs(steps[$0] - model.simulationSpeed) < abs(steps[$1] - model.simulationSpeed) }
                return Double(nearest ?? 0)
            },
            set: { model.simulationSpeed = AppModel.speedSteps[min(max(Int($0.rounded()), 0), AppModel.speedSteps.count - 1)] }
        )
    }

    private var allPages: [ProjectPage] {
        model.project?.pages ?? []
    }

    private var mainPages: [ProjectPage] {
        allPages.filter { !$0.caption.hasPrefix("*") }
    }

    private var macroPages: [ProjectPage] {
        allPages.filter { $0.caption.hasPrefix("*") }
    }

    /// One line describing what the block search currently matches.
    private var searchSummary: String {
        let onPage = model.highlightedModuleIds.count
        let total = model.blockSearchMatchCount
        if total == 0 { return "No blocks match." }
        if onPage == total {
            return "\(total) block\(total == 1 ? "" : "s") highlighted."
        }
        // Hits on other pages cannot be highlighted, so say so rather than looking broken.
        return "\(onPage) of \(total) matches on this page — the rest are on other pages."
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            detailContent
        }
        .onChange(of: model.isShowingBuildReport) { _, showing in
            // The popover hangs from the sidebar's Build button, so a build from the menu or ⌘B opens the sidebar first.
            if showing { columnVisibility = .all }
        }
        .coordinateSpace(name: "AppWindow")
        .navigationTitle(model.projectTitle)
        .toolbar { toolbarContent }
        .modifier(OwnToolbarBackground())
        .background { shortcutsBackground }
        .onReceive(NotificationCenter.default.publisher(for: .toggleInspector)) { _ in
            toggleInspector()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showInspector)) { _ in
            if !showInspector { toggleInspector() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showHelp)) { note in
            if let block = note.userInfo?["block"] as? String { model.help.show(blockNamed: block) }
            openWindow(id: "help")
        }
        .onReceive(NotificationCenter.default.publisher(for: .showBlockPalette)) { _ in
            if model.project != nil { showingPalette = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dismissBlockPalette)) { _ in
            showingPalette = false
        }
        // The save question is an alert, and an alert cannot attach to a window that already has a
        // sheet. Closing what is open first means ⌘Q from the config dialog asks, instead of quietly
        // cancelling the quit because the question had nowhere to appear.
        .onChange(of: model.pendingUnsavedIntent) { _, intent in
            guard intent != nil else { return }
            showingPalette = false
            showingNewPage = false
            pendingPageDeletion = nil
            renamingPage = nil
            model.configuringModuleId = nil
            model.isShowingBuildReport = false
        }
        .sheet(isPresented: Binding(
            get: { model.configuringModuleId != nil },
            set: { if !$0 { model.configuringModuleId = nil } }
        )) {
            if let id = model.configuringModuleId {
                ModuleConfigDialog(model: model, moduleId: id)
                    // Without this the sheet is the opaque window colour and every material inside
                    // it reads as a grey slab.
                    .presentationBackground(.regularMaterial)
            }
        }
        .sheet(isPresented: Binding(get: { model.isShowingPLCConfiguration }, set: { model.isShowingPLCConfiguration = $0 })) {
            PLCConfigurationView(model: model)
                .presentationBackground(.regularMaterial)
        }
        // File panels and messages are presented by the view; the model only records what it wants,
        // which is what keeps it free of AppKit.
        .fileImporter(isPresented: panelBinding(.open),
                      allowedContentTypes: [.pccProject, .xml],
                      allowsMultipleSelection: false,
                      onCompletion: chosenFile("Could not open that file") { model.openProject(at: $0) })
        .fileExporter(isPresented: panelBinding(.saveAs),
                      document: LegacySaveDocument(project: model.project),
                      contentType: .pccProject,
                      defaultFilename: model.saveAsDefaultName,
                      onCompletion: savedFile("Could not save the project", kind: .critical,
                                              onNoDestination: { model.savePanelWasCancelled() }) {
                          model.didChooseSaveURL($0)
                      })
        .fileExporter(isPresented: panelBinding(.export),
                      document: LegacySaveDocument(project: model.project),
                      contentType: .pccProject,
                      defaultFilename: model.exportDefaultName,
                      onCompletion: savedFile("Could not export the project") { model.finishExport(to: $0) })
        // The build's three save panels. The build report has its own copy (see `buildReportSheet`).
        .buildExportPanels(model, inReport: false)
        .fileImporter(isPresented: panelBinding(.importBuildTemplate),
                      allowedContentTypes: [.programBinary]) { result in
            switch result {
            case .success(let url): model.loadBuildTemplate(from: url)
            case .failure(let error):
                model.presentMessage(title: "Could not read that program binary",
                                     message: error.localizedDescription, kind: .warning)
            }
        }
        .alert(model.pendingAlert?.title ?? "", isPresented: alertBinding) {
            Button("OK", role: .cancel) { model.pendingAlert = nil }
        } message: {
            Text(model.pendingAlert?.message ?? "")
        }
        // Save / Don't Save / Cancel, before New, Open or Quit throws the work away. The model holds
        // the question; this is what shows it, and no AppKit is involved.
        .alert("Do you want to save the changes made to “\(model.projectTitle)”?",
               isPresented: unsavedChangesBinding) {
            Button("Save") { model.answerUnsavedChanges(.save) }
            Button("Don’t Save", role: .destructive) { model.answerUnsavedChanges(.discard) }
            Button("Cancel", role: .cancel) { model.answerUnsavedChanges(.cancel) }
        } message: {
            Text("Your changes will be lost if you don’t save them.")
        }
    }

    /// The canvas, with the inspector over its right edge.
    ///
    /// The inspector lies *over* the canvas, not beside it, so its material has the sheet behind it to blur.
    /// Beside the canvas there is nothing behind it but a flat colour, and a material over that is a flat grey.
    ///
    /// The top bar is the same material, and **the same layer**: one ultra-thin material, cut to an L — the toolbar's
    /// height across the whole width, and the pane's width down the right — over a canvas that runs up under the
    /// toolbar. Two pieces of material, a strip and a pane, each blur on their own, overlap in the corner, and so do
    /// not match; one layer cannot disagree with itself. The system's own toolbar background is hidden, or it would be
    /// a second layer on top.
    ///
    /// Not `.inspector`: that one is a full-height column with a toolbar section of its own, so opening it narrowed
    /// the toolbar and pushed the run controls to the left. Here the toolbar spans the whole detail area whether
    /// the inspector is open or not. And not `HSplitView`, an `NSSplitView`, which cannot be animated — it places its
    /// own divider on the next layout pass, which made a SwiftUI animation overshoot and then snap back. The pane
    /// is a plain view, and `inspectorDivider` keeps the drag-to-resize the split provided.
    private var detailContent: some View {
        ZStack(alignment: .trailing) {
            CanvasView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .top)

            // The material, above the canvas and below the pane's content.
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask {
                    ChromeShape(topInset: topInset,
                                paneWidth: showInspector ? inspectorWidth + Self.inspectorDividerWidth : 0)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if showInspector {
                HStack(spacing: 0) {
                    inspectorDivider
                    InspectorView(model: model)
                        .frame(width: inspectorWidth)
                }
                .frame(maxHeight: .infinity)
                // The pane is solid to the pointer, so a click where it has no control of its own does not reach the
                // canvas beneath. The forms inside draw no background of theirs, or it would hide the material.
                .contentShape(Rectangle())
                .onTapGesture {}
                // Slides in from the edge it lives on. Inserted and removed rather than kept at zero width: a hidden
                // inspector would re-evaluate its rows on every simulation tick.
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
        .onGeometryChange(for: CGFloat.self) { proxy in
            // The toolbar is the inset above this view; where the system does not report it as one, it is how far down
            // the window this view starts.
            let inset = proxy.safeAreaInsets.top
            return inset > 0 ? inset : proxy.frame(in: .global).minY
        } action: { topInset = $0 }
        .onChange(of: inspectorShift) { _, target in
            // The balance is a toolbar item (see `inspectorBalance`), so changing it makes the toolbar lay itself out
            // again. The inspector opening or closing is one such change and is eased, a frame at a time. The sidebar
            // opening, or the window being resized, changes the width once a frame for as long as the animation runs —
            // easing each of those laid the toolbar out that often, and it briefly folded the trailing buttons into its
            // overflow while it did. Those wait for the width to settle and then take the new balance in one step.
            if easingShiftForToggle { easeShift(to: target) } else { settleShift(to: target) }
        }
    }

    /// Whether the save question is up. It is **model-driven and read-only**: each button answers the
    /// question itself, and that answer is what clears the model and so dismisses the alert. The setter
    /// must not answer too — if SwiftUI wrote `false` before running the button's action, a `Save` or
    /// `Don't Save` would already have been turned into a `Cancel`.
    ///
    /// Escape needs no handling of its own: the alert's `.cancel` button is what Escape triggers.
    private var unsavedChangesBinding: Binding<Bool> {
        Binding(get: { model.pendingUnsavedIntent != nil }, set: { _ in })
    }

    /// An importer's completion: the chosen file goes to `use`; a failure becomes a warning with `failure` as
    /// its title. Cancelling the panel is not a failure and says nothing.
    private func chosenFile(_ failure: String, _ use: @escaping (URL) -> Void) -> (Result<[URL], Error>) -> Void {
        { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { use(url) }
            case .failure(let error):
                guard !SavePanelResult.isUserCancelled(error) else { return }
                model.presentMessage(title: failure, message: error.localizedDescription, kind: .warning)
            }
        }
    }

    /// An exporter's completion: where it was written goes to `use`; a failure is reported as `kind`.
    /// Cancelling is not a failure to report — but the save question that opened the panel has to hear
    /// about it (`onNoDestination`), or the quit it was holding would never be answered. Any failure,
    /// not only a cancellation, means no file was written, so the question is answered either way.
    private func savedFile(_ failure: String, kind: AppModel.PendingAlert.Kind = .warning,
                           onNoDestination: (() -> Void)? = nil,
                           _ use: @escaping (URL) -> Void) -> (Result<URL, Error>) -> Void {
        SavePanelResult.completion(model: model, failure: failure, kind: kind,
                                   onNoDestination: onNoDestination, use)
    }

    private var renamingPageIsMacro: Bool { renamingPage?.hasPrefix("*") ?? false }

    /// Whether a given file panel is the one being presented.
    private func panelBinding(_ panel: AppModel.FilePanel) -> Binding<Bool> {
        Binding(get: { model.pendingFilePanel == panel },
                set: { presented in if !presented { model.pendingFilePanel = nil } })
    }

    /// The message the model asked to show.
    private var alertBinding: Binding<Bool> {
        Binding(get: { model.pendingAlert != nil },
                set: { presented in if !presented { model.pendingAlert = nil } })
    }

    @ViewBuilder
    private var sidebarContent: some View {
        Group {
            if model.project == nil {
                sidebarEmptyState
            } else {
                VStack(spacing: 0) {
                    SidebarSearchField(text: $model.blockSearchText)
                    pageList
                }
            }
        }
        .alert("New Page", isPresented: $showingNewPage) {
            TextField("Name", text: $newPageName)
            Button("Create") {
                model.addPage(caption: newPageName, isMacro: newPageIsMacro)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(newPageIsMacro
                 ? "Adds a macro page. Its name is prefixed with “*”, as Dirigo stores them."
                 : "Adds a page to the project and switches to it.")
        }
        .alert(renamingPageIsMacro ? "Rename Macro" : "Rename Page",
               isPresented: Binding(get: { renamingPage != nil }, set: { if !$0 { renamingPage = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let caption = renamingPage { model.renamePage(caption, to: renameText) }
                renamingPage = nil
            }
            Button("Cancel", role: .cancel) { renamingPage = nil }
        } message: {
            Text(renamingPageIsMacro
                 ? "Every call of the macro follows the new name."
                 : "The blocks, graphics and PLC configuration on the page move with it.")
        }
        .alert("Delete “\(pendingPageDeletion ?? "")”?",
               isPresented: Binding(get: { pendingPageDeletion != nil },
                                    set: { if !$0 { pendingPageDeletion = nil } })) {
            Button("Delete", role: .destructive) {
                if let caption = pendingPageDeletion { model.deletePage(caption: caption) }
                pendingPageDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingPageDeletion = nil }
        } message: {
            Text(pageDeletionMessage)
        }
    }

    /// Shown when nothing is open: bare, empty sections look like a bug rather than a state.
    private var sidebarEmptyState: some View {
        Text("No project open")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
    }

    /// Pages, macros and the hardware link, as rows and a card of glass rather than a system `List`, so the selection can be a glass
    /// pill that flows between rows. Up and down move the selection, as in a list.
    private var pageList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if isSearching { searchSummaryRow }

                GlassGroup(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        sectionLabel("Pages", isMacro: false)
                        ForEach(mainPages, id: \.caption) { pageRow(for: $0, isMacro: false) }

                        if macroPages.isEmpty {
                            // Nothing to list: the title and "No macros" are one card.
                            SidebarEmptyGroupCard(title: "Macros", emptyText: "No macros", addHelp: "Add a macro page",
                                                  onAdd: { beginAddingPage(isMacro: true) }, addDisabled: model.project == nil)
                                .padding(.top, 14)
                        } else {
                            sectionLabel("Macros", isMacro: true)
                            ForEach(macroPages, id: \.caption) { pageRow(for: $0, isMacro: true) }
                        }
                    }
                }

                // The card carries its own title.
                HardwareLinkSection(model: model) { buildReportSheet }
                    .padding(.top, 14)
            }
            .padding(.horizontal, SidebarMetrics.outerPadding)
            .padding(.bottom, 12)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
    }

    private func moveSelection(by step: Int) {
        let captions = (mainPages + macroPages).map(\.caption)
        guard let index = captions.firstIndex(of: model.selectedPage) else { return }
        let target = min(max(index + step, 0), captions.count - 1)
        withAnimation(.smooth(duration: 0.3)) { model.selectedPage = captions[target] }
    }

    /// A group title in the sidebar: a glass chip, with the add button for the groups that have one.
    @ViewBuilder
    private func sectionLabel(_ title: String, isMacro: Bool) -> some View {
        SidebarSectionHeader(title: title, addHelp: isMacro ? "Add a macro page" : "Add a page",
                             onAdd: { beginAddingPage(isMacro: isMacro) },
                             addDisabled: model.project == nil)
            .padding(.horizontal, 2)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    /// Asks for the name of a new page, or macro page.
    private func beginAddingPage(isMacro: Bool) {
        newPageName = ""
        newPageIsMacro = isMacro
        showingNewPage = true
    }

    // MARK: - Sidebar chrome

    private var isSearching: Bool {
        !model.blockSearchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var searchSummaryRow: some View {
        Text(searchSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 11)
            .padding(.vertical, 2)
    }

    private var pageDeletionMessage: String {
        guard let caption = pendingPageDeletion else { return "" }
        let count = model.moduleCount(onPage: caption)
        if count == 0 { return "This page is empty. It cannot be the last page." }
        return "\(count) block\(count == 1 ? "" : "s") on it, and their wires, will be removed too."
    }

    /// The report sheet, out of `body` so the body stays quick to type-check.
    @ViewBuilder
    private var buildReportSheet: some View {
        if let report = model.buildReport {
            BuildReportSheet(report: report,
                             notice: model.buildReportNotice,
                             onExportProgram: { model.exportCompiledProgram() },
                             onExportSymbols: { model.exportSymbolTable() },
                             onExportVariables: { model.exportProgramVariables() },
                             optimize: optimizeBinding,
                             // The report has done its job once the upload starts: close it, and the
                             // sidebar's upload log shows the progress.
                             onUpload: {
                                 model.isShowingBuildReport = false
                                 model.uploadCompiledProgram()
                             },
                             onClose: { model.isShowingBuildReport = false })
                // The report's own save panels: a panel opened from behind it would wait for it to close.
                .buildExportPanels(model, inReport: true)
        }
    }

    /// The build report's switch: flipping it compiles again, so the report shows the program that would be sent.
    private var optimizeBinding: Binding<Bool> {
        Binding(get: { model.optimizeProgram },
                set: { model.optimizeProgram = $0; _ = model.compileProject() })
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            // The prominent "+" is the block library, matching how these editors usually work:
            // adding to the document is the common action, creating a document is not.
            Button {
                showingPalette = true
            } label: {
                Label("Add Block", systemImage: "plus")
            }
            .disabled(model.project == nil)
            .help("Add Block (⌘K)")
            .popover(isPresented: $showingPalette, arrowEdge: .bottom) {
                BlockPaletteView(
                    onInsert: { guid in model.addBlock(guid: guid) },
                    dismiss: { showingPalette = false },
                    macros: model.callableMacros,
                    interfaces: model.missingMacroInterfaces,
                    onInsertMacro: { model.addMacroCall(sheet: $0) },
                    onInsertInterface: { model.addMacroInterface($0) },
                    usage: model.blockUsage,
                    context: model.blockSuggestionContext
                )
            }

            Toggle(isOn: $model.snapToGrid) {
                Label("Snap to Grid", systemImage: "squareshape.split.3x3")
            }
            .help("Snap blocks to the grid when moving or adding them")
            // Open and Save live in the File menu (⌘O, ⌘S), as in other document apps; the toolbar
            // keeps to what is used while editing.
        }

        ToolbarItemGroup(placement: .principal) {
            ControlGroup {
                Button {
                    model.togglePlay()
                } label: {
                    Label(model.isPlaying ? "Pause" : "Run", systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                }
                .keyboardShortcut(.space, modifiers: [])

                Button {
                    model.step()
                } label: {
                    Label("Step", systemImage: "forward.frame.fill")
                }
                .disabled(model.isPlaying)

                Button {
                    model.reset()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
            }
            .disabled(model.project == nil)

            HStack(spacing: 8) {
                TickCountBadge(model: model)

                // Simulation speed, as a percentage of real time, in the steps worth having: the thread periods
                // stay the profile's, and this only changes how fast time passes.
                Slider(value: speedIndex, in: 0...Double(AppModel.speedSteps.count - 1), step: 1)
                    .controlSize(.small)
                    .frame(width: 150)
                    .disabled(model.project == nil)
                    .help("Simulation speed. 100% is the base pace; 1000% is real time, as the PLC would run it.")

                Text("\(Int((model.simulationSpeed * 100).rounded()))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
                    .onTapGesture(count: 2) { model.simulationSpeed = 1 }
                    .help("Double-click to return to 100%.")
            }
            // The capsule hugs this row, so these are its margins: the same on both sides. The label has a fixed
            // width (it used to have a minimum, which left a gap before short values like "5%") and the slider is
            // the small control size, whose thumb and tick row fit the capsule instead of overflowing it.
            .padding(.horizontal, 10)
        }

        inspectorBalance

        ToolbarItem(placement: .primaryAction) {
            Button { openWindow(id: "agent") } label: { Label("Agent", systemImage: "sparkles") }
                .help(model.project == nil ? "Open a project to use the agent" : "Agent Panel (⇧⌘A)")
                .disabled(model.project == nil)
        }

        ToolbarItem(placement: .primaryAction) {
            // The pane animates in and out; the button only starts it. A toggle, so it is drawn pressed — highlighted
            // — while the inspector is open.
            Toggle(isOn: Binding(get: { showInspector }, set: { _ in toggleInspector() })) {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .toggleStyle(.button)
            .help(showInspector ? "Hide Inspector" : "Show Inspector")
        }
    }

    /// Empty space in the toolbar as wide as the inspector pane, so the run controls centre over the canvas.
    ///
    /// The toolbar spans the whole detail area (see `detailContent`), and the controls centre in it. With the
    /// inspector open the canvas is narrower than that, so the controls would sit right of the canvas's middle.
    /// This item sits in the centre group, so the group is as much wider as the pane is — and the controls, which
    /// are centred as a whole, move left by half of it.
    ///
    /// The toolbar widens an item when its content grows but does not narrow it again: one resized item left the
    /// controls off to the left after the inspector closed. So each width is an item of its own — a change of width
    /// removes one and inserts the next, and with no shift there is no item at all.
    @ToolbarContentBuilder
    private var inspectorBalance: some ToolbarContent {
        ForEach(inspectorShiftSteps, id: \.self) { width in
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .principal) { inspectorBalanceSpace(width) }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) { inspectorBalanceSpace(width) }
            }
        }
    }

    /// How far the run controls move left: the pane's width, or less when the window is too narrow for the toolbar
    /// to hold the controls and the space beside them — a toolbar that runs out of room hides its buttons.
    private var inspectorShift: CGFloat {
        guard showInspector else { return 0 }
        let room = max(0, detailWidth - Self.runControlsWidth - 2 * Self.toolbarSideReserve)
        return min(inspectorWidth + Self.inspectorDividerWidth, room)
    }

    /// The shift as the one width to show — none for no shift. In steps of 8 pt, so that dragging a window edge
    /// or the inspector's divider swaps the item a few times and not on every pixel.
    private var inspectorShiftSteps: [CGFloat] {
        let width = (shownShift / 8).rounded(.down) * 8
        return width >= 8 ? [width] : []
    }

    /// Moves `shownShift` to `target`. A big move — the inspector opening or closing — eases over the pane's
    /// 0.22 s; a small one (a window edge or the divider being dragged) just follows.
    ///
    /// SwiftUI cannot animate this itself: each width is a toolbar item of its own (see `inspectorBalance`), and
    /// one item cannot turn into another. So the width is stepped, about once a frame.
    private func easeShift(to target: CGFloat) {
        shiftEasing?.cancel()
        let start = shownShift
        guard abs(target - start) > 24 else {
            shownShift = target
            return
        }
        shiftEasing = Task { @MainActor in
            let frames = 14
            for frame in 1..<frames {
                try? await Task.sleep(for: .milliseconds(16))
                if Task.isCancelled { return }
                let t = Double(frame) / Double(frames)
                let eased = t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) * (-2 * t + 2) / 2
                shownShift = start + (target - start) * CGFloat(eased)
            }
            if !Task.isCancelled { shownShift = target }
        }
    }

    /// Takes a new balance once the width has stopped moving. A change of 8 pt or less is not worth a toolbar relayout.
    private func settleShift(to target: CGFloat) {
        shiftSettle?.cancel()
        shiftSettle = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled, abs(target - shownShift) > 8 else { return }
            shownShift = target
        }
    }

    private func inspectorBalanceSpace(_ width: CGFloat) -> some View {
        Color.clear
            .frame(width: width, height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var shortcutsBackground: some View {
        Group {
            Button("Zoom In") { model.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Zoom In Equal") { model.zoomIn() }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { model.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { model.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
            Button("Zoom to Fit") { model.zoomToFit() }
                .keyboardShortcut("9", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    /// A sidebar row for a page or a macro page, with its delete action.
    private func pageRow(for page: ProjectPage, isMacro: Bool) -> some View {
        SidebarPageRow(symbol: isMacro ? "shippingbox" : "doc",
                       title: isMacro ? String(page.caption.dropFirst()) : page.caption,
                       count: moduleCount(for: page.caption),
                       isSelected: model.selectedPage == page.caption,
                       selection: pageSelection) {
            withAnimation(.smooth(duration: 0.3)) { model.selectedPage = page.caption }
        }
        .contextMenu {
            Button(isMacro ? "Rename Macro…" : "Rename Page…", systemImage: "pencil") {
                renameText = isMacro ? String(page.caption.dropFirst()) : page.caption
                renamingPage = page.caption
            }
            Button(isMacro ? "Delete Macro Page" : "Delete Page", systemImage: "trash", role: .destructive) {
                pendingPageDeletion = page.caption
            }
            // A project with no pages has nowhere to put a block, so the last one stays.
            .disabled((model.project?.pages.count ?? 0) <= 1)
        }
    }

    private func moduleCount(for pageCaption: String) -> Int {
        model.project?.modules.filter { $0.page == pageCaption }.count ?? 0
    }
}

/// Prominent when idle, quiet when already connected — so the button that needs attention is
/// the one that stands out.
private struct TickCountBadge: View {
    @Bindable var model: AppModel

    var body: some View {
        // Deliberately chrome-free: the toolbar already provides the material, and a nested
        // glass capsule there renders as an opaque blob.
        HStack(spacing: 6) {
            Circle()
                .fill(model.isPlaying ? Theme.signalHigh : Color.secondary.opacity(0.55))
                .frame(width: 6, height: 6)
            Text("\(model.tickCount)")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text("ticks")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}

/// Hides the system's toolbar background, so the material the detail area draws behind the toolbar is the only one.
/// (`toolbarBackgroundVisibility` is macOS 15; before that the toolbar keeps its own, which is fine.)
private struct OwnToolbarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}

/// The pointer a column's edge gets, where the system has one (macOS 15): the handle is drawn as nothing, so this is
/// what says it can be dragged.
private struct ColumnResizePointer: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.columnResize)
        } else {
            content
        }
    }
}

/// The shape of the material: the toolbar's height across the top, and the pane's width down the right while it is
/// out — an L, with square corners. `animatableData` is what lets the pane's slide animate.
struct ChromeShape: Shape {
    var topInset: CGFloat
    var paneWidth: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topInset, paneWidth) }
        set { (topInset, paneWidth) = (newValue.first, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        let barBottom = min(rect.minY + max(topInset, 0), rect.maxY)
        let paneLeft = rect.maxX - max(paneWidth, 0)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: paneLeft, y: rect.maxY))
        path.addLine(to: CGPoint(x: paneLeft, y: barBottom))
        path.addLine(to: CGPoint(x: rect.minX, y: barBottom))
        path.closeSubpath()
        return path
    }
}
