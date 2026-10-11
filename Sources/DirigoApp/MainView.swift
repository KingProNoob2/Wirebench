import SwiftUI
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
        content
            .onReceive(NotificationCenter.default.publisher(for: .showBlockPalette)) { _ in
                if model.project != nil { showingPalette = true }
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

    private var content: some View {
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
        .toolbar {
            toolbarContent
        }
        .background {
            shortcutsBackground
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
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { model.openProject(at: url) }
            case .failure(let error):
                model.presentMessage(title: "Could not open that file",
                                     message: error.localizedDescription,
                                     kind: .warning)
            }
        }
        .fileImporter(isPresented: panelBinding(.uploadProgram),
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { model.uploadProgram(from: url) }
            case .failure(let error):
                model.presentMessage(title: "Could not read that file",
                                     message: error.localizedDescription,
                                     kind: .warning)
            }
        }
        .fileExporter(isPresented: panelBinding(.saveAs),
                      document: LegacySaveDocument(project: model.project),
                      contentType: .pccProject,
                      defaultFilename: model.saveAsDefaultName) { result in
            switch result {
            case .success(let url): model.didChooseSaveURL(url)
            case .failure(let error):
                model.presentMessage(title: "Could not save the project",
                                     message: error.localizedDescription,
                                     kind: .critical)
            }
        }
        .fileExporter(isPresented: panelBinding(.export),
                      document: LegacySaveDocument(project: model.project),
                      contentType: .pccProject,
                      defaultFilename: model.exportDefaultName) { result in
            switch result {
            case .success(let url): model.finishExport(to: url)
            case .failure(let error):
                model.presentMessage(title: "Could not export the project",
                                     message: error.localizedDescription,
                                     kind: .warning)
            }
        }
        .fileExporter(isPresented: panelBinding(.exportProgramBinary),
                      document: ProgramBinaryDocument(),
                      contentType: .programBinary,
                      defaultFilename: model.programBinaryDefaultName) { result in
            switch result {
            case .success(let url): model.finishProgramBinaryExport(to: url)
            case .failure(let error):
                model.presentMessage(title: "Could not export the program",
                                     message: error.localizedDescription,
                                     kind: .warning)
            }
        }
        .fileExporter(isPresented: panelBinding(.exportSymbolTable),
                      document: SymbolTableDocument(),
                      contentType: .commaSeparatedText,
                      defaultFilename: model.symbolTableDefaultName) { result in
            switch result {
            case .success(let url): model.finishSymbolTableExport(to: url)
            case .failure(let error):
                model.presentMessage(title: "Could not export the symbol table",
                                     message: error.localizedDescription,
                                     kind: .warning)
            }
        }
        .fileImporter(isPresented: panelBinding(.importBuildTemplate),
                      allowedContentTypes: [.programBinary]) { result in
            switch result {
            case .success(let url): model.loadBuildTemplate(from: url)
            case .failure(let error):
                model.presentMessage(title: "Could not read that program binary",
                                     message: error.localizedDescription,
                                     kind: .warning)
            }
        }
        .sheet(isPresented: buildSheetBinding) {
            if let report = model.buildReport {
                BuildReportSheet(report: report,
                                 onExportProgram: { model.exportCompiledProgram() },
                                 onExportSymbols: { model.exportSymbolTable() },
                                 onUpload: { model.uploadCompiledProgram() },
                                 onClose: { model.isShowingBuildReport = false })
            }
        }
        .alert(model.pendingAlert?.title ?? "", isPresented: alertBinding) {
            Button("OK", role: .cancel) { model.pendingAlert = nil }
        } message: {
            Text(model.pendingAlert?.message ?? "")
        }
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
            ForEach(mainPages, id: \.caption) { pageRow(for: $0) }

            sectionLabel("Macros", tint: Color.accentColor, isMacro: true)
            ForEach(macroPages, id: \.caption) { macroRow(for: $0) }

            sectionLabel("Hardware Link", tint: nil, isMacro: nil)
            // Same leading inset as every other row's content, so the hardware block lines up with
            // the titles above it instead of sitting 8pt out to the left.
            hardwareSection
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

    @ViewBuilder
    private var hardwareSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle()
                    .fill(model.isHardwareConnected ? Theme.signalHigh : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                    .shadow(color: model.isHardwareConnected ? Theme.signalHigh.opacity(0.8) : .clear, radius: 3)
                Text(model.isHardwareConnected ? "Connected" : "Disconnected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.isHardwareConnected ? Theme.signalHigh : .secondary)
                Spacer(minLength: 4)
                if let port = model.availablePorts.first(where: { $0.path == model.selectedPortPath }) {
                    Text(port.name)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            // An empty picker is a dead control; say what is wrong instead.
            if model.availablePorts.isEmpty {
                Text("No serial ports found.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Serial Port", selection: $model.selectedPortPath) {
                    ForEach(model.availablePorts) { port in
                        Text(port.name).tag(port.path)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }

            // A standard macOS push button — no bolt glyph, no custom glass style. A ternary cannot
            // pick between two button styles, so the two cases are spelled out.
            Group {
                if model.isHardwareConnected {
                    Button {
                        model.disconnectHardware()
                    } label: {
                        Text("Disconnect").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        model.connectHardware()
                    } label: {
                        Text("Connect").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.regular)
            .disabled(model.availablePorts.isEmpty)

            // Uploading a table Dirigo produced. The sequence and every byte of it are the captured
            // ones; see docs/plc-protocol.md.
            Button {
                model.uploadProgramFile()
            } label: {
                Text(model.isUploading ? "Uploading…" : "Upload Program…")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(model.isUploading || !model.isHardwareConnected)

            if !model.uploadStatus.isEmpty {
                Text(model.uploadStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
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
                Spacer()
                TickCountBadge(model: model)

                // A *ceiling*, not a cadence: the loop now steps when the project's threads are due
                // (`Tick` every 71 ms, `Timer 1s` every 1000 ms), so this only bites when a thread asks
                // to run faster than the user wants to allow.
                Slider(value: $model.tickRateHz, in: 20...200)
                    .frame(width: 200)
                    .disabled(model.project == nil)
                    .help("Maximum step rate. Threads run on the periods their profile declares.")

                Text("\(Int(model.tickRateHz)) Hz")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 46, alignment: .leading)
            }
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

    @ViewBuilder
    private func pageRow(for page: ProjectPage) -> some View {
        NavigationLink(value: page.caption) {
            SidebarRow(symbol: "square.grid.2x2", tint: Color.accentColor,
                       title: page.caption, count: moduleCount(for: page.caption))
        }
        .contextMenu {
            Button("Delete Page", systemImage: "trash", role: .destructive) {
                pendingPageDeletion = page.caption
            }
            // A project with no pages has nowhere to put a block, so the last one stays.
            .disabled((model.project?.pages.count ?? 0) <= 1)
        }
    }

    private func macroRow(for page: ProjectPage) -> some View {
        NavigationLink(value: page.caption) {
            SidebarRow(symbol: "shippingbox", tint: Color.accentColor,
                       title: cleanMacroName(page.caption), count: moduleCount(for: page.caption))
        }
        .contextMenu {
            Button("Delete Macro Page", systemImage: "trash", role: .destructive) {
                pendingPageDeletion = page.caption
            }
            .disabled((model.project?.pages.count ?? 0) <= 1)
        }
    }

    private func cleanMacroName(_ caption: String) -> String {
        if caption.hasPrefix("*") {
            return String(caption.dropFirst())
        }
        return caption
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

