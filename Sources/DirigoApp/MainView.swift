import SwiftUI
import AppKit
import DirigoCore

public struct MainView: View {
    @Bindable var model: AppModel
    @State private var showInspector: Bool = true
    @State private var showingPalette = false
    @State private var newPageName: String = ""
    @State private var newPageIsMacro = false
    @State private var showingNewPage = false
    /// Caption of the page whose deletion is awaiting confirmation.
    @State private var pendingPageDeletion: String?

    public init(model: AppModel = AppModel.shared ?? AppModel()) {
        self.model = model
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
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            CanvasView(model: model)
                .inspector(isPresented: $showInspector) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 250, ideal: 280, max: 340)
                }
        }
        .coordinateSpace(name: "AppWindow")
        .navigationTitle(model.projectTitle)
        .toolbar { toolbarContent }
        .background { shortcutsBackground }
        .onReceive(NotificationCenter.default.publisher(for: .showBlockPalette)) { _ in
            if model.project != nil { showingPalette = true }
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
        // File panels and messages are presented by the view; the model only records what it wants,
        // which is what keeps it free of AppKit.
        .fileImporter(isPresented: panelBinding(.open),
                      allowedContentTypes: [.pccProject, .xml],
                      allowsMultipleSelection: false,
                      onCompletion: chosenFile("Could not open that file") { model.openProject(at: $0) })
        .fileImporter(isPresented: panelBinding(.uploadProgram),
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: false,
                      onCompletion: chosenFile("Could not read that file") { model.uploadProgram(from: $0) })
        .fileExporter(isPresented: panelBinding(.saveAs),
                      document: LegacySaveDocument(project: model.project),
                      contentType: .pccProject,
                      defaultFilename: model.saveAsDefaultName,
                      onCompletion: savedFile("Could not save the project", kind: .critical) {
                          model.didChooseSaveURL($0)
                      })
        .fileExporter(isPresented: panelBinding(.export),
                      document: LegacySaveDocument(project: model.project),
                      contentType: .pccProject,
                      defaultFilename: model.exportDefaultName,
                      onCompletion: savedFile("Could not export the project") { model.finishExport(to: $0) })
        .fileExporter(isPresented: panelBinding(.exportProgramBinary),
                      document: ProgramBinaryDocument(),
                      contentType: .programBinary,
                      defaultFilename: model.programBinaryDefaultName,
                      onCompletion: savedFile("Could not export the program") {
                          model.finishProgramBinaryExport(to: $0)
                      })
        .fileExporter(isPresented: panelBinding(.exportSymbolTable),
                      document: SymbolTableDocument(),
                      contentType: .commaSeparatedText,
                      defaultFilename: model.symbolTableDefaultName,
                      onCompletion: savedFile("Could not export the symbol table") {
                          model.finishSymbolTableExport(to: $0)
                      })
        .fileImporter(isPresented: panelBinding(.importBuildTemplate),
                      allowedContentTypes: [.programBinary]) { result in
            switch result {
            case .success(let url): model.loadBuildTemplate(from: url)
            case .failure(let error):
                model.presentMessage(title: "Could not read that program binary",
                                     message: error.localizedDescription, kind: .warning)
            }
        }
        .sheet(isPresented: buildSheetBinding) {
            if let report = model.buildReport {
                BuildReportSheet(report: report,
                                 onExportProgram: { model.exportCompiledProgram() },
                                 onExportSymbols: { model.exportSymbolTable() },
                                 // The report has done its job once the upload starts: close it, and the
                                 // sidebar's upload log shows the progress.
                                 onUpload: {
                                     model.isShowingBuildReport = false
                                     model.uploadCompiledProgram()
                                 },
                                 onClose: { model.isShowingBuildReport = false })
            }
        }
        .alert(model.pendingAlert?.title ?? "", isPresented: alertBinding) {
            Button("OK", role: .cancel) { model.pendingAlert = nil }
        } message: {
            Text(model.pendingAlert?.message ?? "")
        }
    }

    /// An importer's completion: the chosen file goes to `use`; a failure becomes a warning with `failure` as
    /// its title.
    private func chosenFile(_ failure: String, _ use: @escaping (URL) -> Void) -> (Result<[URL], Error>) -> Void {
        { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { use(url) }
            case .failure(let error):
                model.presentMessage(title: failure, message: error.localizedDescription, kind: .warning)
            }
        }
    }

    /// An exporter's completion: where it was written goes to `use`; a failure is reported as `kind`.
    private func savedFile(_ failure: String, kind: AppModel.PendingAlert.Kind = .warning,
                           _ use: @escaping (URL) -> Void) -> (Result<URL, Error>) -> Void {
        { result in
            switch result {
            case .success(let url): use(url)
            case .failure(let error):
                model.presentMessage(title: failure, message: error.localizedDescription, kind: kind)
            }
        }
    }

    /// Whether a given file panel is the one being presented.
    private func panelBinding(_ panel: AppModel.FilePanel) -> Binding<Bool> {
        Binding(get: { model.pendingFilePanel == panel },
                set: { presented in if !presented { model.pendingFilePanel = nil } })
    }

    /// Whether the build report is up — and only while there is a report to show.
    private var buildSheetBinding: Binding<Bool> {
        Binding(get: { model.isShowingBuildReport && model.buildReport != nil },
                set: { model.isShowingBuildReport = $0 })
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
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No project open")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Open a .pcc file, or start a project from the toolbar.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 170)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var pageList: some View {
        List(selection: $model.selectedPage) {
            if isSearching {
                searchSummaryRow
            }

            // These are rows, not `Section` headers. macOS gives a section header a large fixed gap
            // that cannot be adjusted (`listSectionSpacing` is unavailable there), which left the
            // sidebar looking like content was missing between groups.
            sectionLabel("Pages", tint: Color.accentColor, isMacro: false)
            ForEach(mainPages, id: \.caption) { pageRow(for: $0, isMacro: false) }

            sectionLabel("Macros", tint: Color.accentColor, isMacro: true)
            ForEach(macroPages, id: \.caption) { pageRow(for: $0, isMacro: true) }

            sectionLabel("Hardware Link", tint: nil, isMacro: nil)
            // Same leading inset as every other row's content, so the hardware block lines up with
            // the titles above it instead of sitting 8pt out to the left.
            HardwareLinkSection(model: model)
                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 0))
        }
        .listStyle(.sidebar)
    }

    /// A group title in the sidebar. A row rather than a section header, so its spacing is ours.
    @ViewBuilder
    private func sectionLabel(_ title: String, tint: Color?, isMacro: Bool?) -> some View {
        HStack(spacing: 6) {
            SidebarSectionTitle(title: title)
            Spacer(minLength: 0)
            if let tint, let isMacro {
                SidebarAddButton(tint: tint, help: isMacro ? "Add a macro page" : "Add a page") {
                    newPageName = ""
                    newPageIsMacro = isMacro
                    showingNewPage = true
                }
                .disabled(model.project == nil)
            }
        }
        // Measured off a screenshot: with trailing 8 the add button ended 34pt from the right while
        // the title began 27.5pt from the left. Trailing 0 lines the button up with the row badges
        // and makes the two margins match.
        .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 3, trailing: 0))
        .selectionDisabled()
    }

    // MARK: - Sidebar chrome

    private var isSearching: Bool {
        !model.blockSearchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var searchSummaryRow: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: model.blockSearchMatchCount == 0 ? "questionmark.circle" : "sparkle.magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(model.blockSearchMatchCount == 0 ? Color.secondary : Theme.searchHighlight)
            Text(searchSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pageDeletionMessage: String {
        guard let caption = pendingPageDeletion else { return "" }
        let count = model.moduleCount(onPage: caption)
        if count == 0 { return "This page is empty. It cannot be the last page." }
        return "\(count) block\(count == 1 ? "" : "s") on it, and their wires, will be removed too."
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
            .help("Add Block (⌘⇧A)")
            .popover(isPresented: $showingPalette, arrowEdge: .bottom) {
                BlockPaletteView(
                    onInsert: { guid in model.addBlock(guid: guid) },
                    dismiss: { showingPalette = false }
                )
            }

            Button {
                model.openProjectFile()
            } label: {
                Label("Open", systemImage: "folder")
            }
            .help("Open Project (⌘O)")

            Button {
                model.saveProject()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .disabled(model.project == nil)
            .help("Save Project (⌘S)")
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

            HStack(spacing: 6) {
                TickCountBadge(model: model)

                // Simulation speed, as a percentage of real time, in the steps worth having: the thread periods
                // stay the profile's, and this only changes how fast time passes.
                Slider(value: speedIndex, in: 0...Double(AppModel.speedSteps.count - 1), step: 1)
                    .frame(width: 150)
                    .disabled(model.project == nil)
                    .help("Simulation speed. 100% is real time, as the PLC would run it.")

                Text("\(Int((model.simulationSpeed * 100).rounded()))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 30, alignment: .trailing)
                    .onTapGesture(count: 2) { model.simulationSpeed = 1 }
                    .help("Double-click to return to 100% (real time).")
            }
            // Equal room either side inside the toolbar's capsule. A leading `Spacer` used to soak up the slack and
            // push everything right, which left a wide gap on the left and none on the right.
            .padding(.horizontal, 4)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation {
                    showInspector.toggle()
                }
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Toggle Inspector")
        }
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
        NavigationLink(value: page.caption) {
            SidebarRow(symbol: isMacro ? "shippingbox" : "square.grid.2x2", tint: Color.accentColor,
                       title: isMacro ? String(page.caption.dropFirst()) : page.caption,
                       count: moduleCount(for: page.caption))
        }
        .contextMenu {
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
                .shadow(color: model.isPlaying ? Theme.signalHigh.opacity(0.8) : .clear, radius: 3)
            Text("\(model.tickCount)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
            Text("ticks")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}

