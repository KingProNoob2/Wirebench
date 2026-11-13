import WirebenchModel
import SwiftUI
import UniformTypeIdentifiers
import AppKit
import WirebenchCore
import WirebenchLibrary

public struct CanvasView: View {
    @Bindable var model: AppModel
    /// Live drag translation per module, applied on top of the model position until the drag ends.
    @State private var dragOffsets: [Int: CGSize] = [:]
    /// The wire currently being dragged, if any. `nil` means no wiring in progress.
    @State private var pendingWire: PendingWire?
    /// Where the Maraflow page-runtime card has been dragged to, per page. It is a floating explanation, not a block,
    /// so it can be moved out of the way of the sheet.
    @State private var pageRuntimeOffsets: [String: CGSize] = [:]
    @State private var pageRuntimeDragOrigin: CGSize?
    /// True while the current card drag is drawing a wire rather than moving the card. Decided once,
    /// when the drag starts, so a gesture cannot change its mind halfway through.
    @State private var isDrawingWire = false
    /// The selection rectangle being dragged on the empty sheet, in viewport coordinates.
    @State private var marquee: CGRect?
    /// Live translation per shape object, applied on top of its stored box until the drag ends.
    @State private var shapeDragOffsets: [Int: CGSize] = [:]
    /// Live growth of the bottom-right corner of a shape being resized, likewise.
    @State private var shapeResizeOffsets: [Int: CGSize] = [:]

    /// Routed wire paths, kept between frames.
    ///
    /// Routing is a path search around the sheet's obstacles, and it depends only on *geometry* — module
    /// positions, the drag offsets, and a connection's own hand-drawn `POINTS`. It never depends on a
    /// signal value, so recomputing it inside `body` meant every tick re-routed every cable, which is
    /// where a profile put the app's main-thread time (3.99 s of 4.40 s on the main thread, against 5 ms
    /// in SwiftUI's renderer). Only the points are cached; a wire's colour and dash still come from the
    /// live values.
    @State private var wireLayout = WireLayout()

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        // LOAD-BEARING — do not remove.
        //
        // The canvas draws live values straight out of the simulation engine, and the engine is a
        // plain class, not observable state. Nothing else in this view changes on a tick, so without
        // this read SwiftUI has no reason to re-evaluate the body: the simulation runs and the
        // toolbar's tick counter advances (it reads a different property), while the canvas sits
        // frozen until some unrelated interaction forces a repaint. Deleting this line is a silent
        // regression — it looks like dead code, which is exactly how it got removed once already.
        //
        // Reading it here is what makes the body re-run each tick; `.equatable()` on the cards then
        // keeps the repaint cheap by skipping the ones whose values did not change.
        // LOAD-BEARING — do not remove. The canvas draws live values straight out of the engine,
        // which is a plain class and not observable state; nothing else here changes on a tick. This
        // read is what makes the body re-run each tick (`equatable()` on the cards then keeps the
        // repaint cheap). Without it the canvas never re-evaluates and blocks appear frozen until an
        // unrelated interaction forces a repaint.
        let _ = model.snapshots
        let _ = model.simulationVersion

        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                // 1. Ambient wash. Glass needs tonal variation behind it to read as glass; this
                //    sits in viewport space so panels refract a stable field while the sheet pans.
                AmbientBackdrop()

                // 2. Pannable schematic surface: grid plus content.
                ZStack(alignment: .topLeading) {
                    CanvasGridHost(model: model)
                        .contentShape(Rectangle())
                        // Clicking the sheet ends a text edit. The grid sits *behind* the objects,
                        // so a click on one still reaches it — a catch-all gesture would cancel the
                        // edit the double-click had just started.
                        .onTapGesture {
                            // Clicking the sheet clears every kind of selection. It lives on the grid, not
                            // on the whole canvas, so a click that lands on a block never clears the
                            // selection that block's own tap has just made.
                            model.editingAnnotationIndex = nil
                            model.selectedAnnotationIndex = nil
                            model.selectedModuleId = nil
                            model.selectedWire = nil
                        }
                        // Double-clicking the empty sheet fits it to the window. Simultaneous, so the single
                        // tap above never waits for it; and on the grid rather than the whole canvas, so a
                        // double-click on a block (rename, open macro) does not also zoom.
                        .simultaneousGesture(TapGesture(count: 2).onEnded { model.zoomToFit() })
                        .contextMenu {
                            Button("Paste", systemImage: "doc.on.clipboard") { model.paste() }
                                .disabled(!model.canPaste)
                            Button("Add Block\u{2026}", systemImage: "plus.square") {
                                NotificationCenter.default.post(name: .showBlockPalette, object: nil)
                            }
                            Divider()
                            Button("Organize Blocks", systemImage: "square.grid.3x3") { model.organizeBlocks() }
                            Button("Reset Wire Routing", systemImage: "arrow.counterclockwise") { model.resetWireRouting() }
                            Button("Zoom to Fit", systemImage: "arrow.up.left.and.arrow.down.right") { model.zoomToFit() }
                        }

                    if let project = model.project {
                        // The pan and the zoom are read inside `SheetTransform`, not here: a body that read them
                        // would be rebuilt — every card, wire and shape of the schematic — at each step of a pan.
                        SheetTransform(model: model) {
                            schematic(for: project)
                                .frame(width: contentSize(for: project).width,
                                       height: contentSize(for: project).height,
                                       alignment: .topLeading)
                        }

                        // The pin values, drawn over the cards in one canvas; see `LiveValuesLayer`.
                        liveValues(for: project)

                        if let pending = pendingWire {
                            wirePreview(pending, in: project)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    // Primary button: a selection rectangle. (The middle button pans: `TouchpadNSView`.)
                    DragGesture(minimumDistance: 2, coordinateSpace: .named("CanvasViewport"))
                        .onChanged { value in
                            marquee = CGRect(from: value.startLocation, to: value.location)
                            // Live, so what is highlighted always matches the rectangle on screen.
                            selectModules(in: CGRect(from: contentPoint(from: value.startLocation),
                                                     to: contentPoint(from: value.location)))
                        }
                        .onEnded { value in
                            marquee = nil
                        }
                )
                .overlay {
                    if let marquee {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.12))
                            .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1))
                            .frame(width: marquee.width, height: marquee.height)
                            .position(x: marquee.midX, y: marquee.midY)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                if model.project == nil {
                    emptyState
                }

                // Native AppKit gesture overlay (pinch and two-finger scroll).
                CanvasTouchpadView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                ZoomControlBar(model: model)
                    .padding(16)

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(name: "CanvasViewport")
            .clipped()
            // Delete key, scoped to the canvas. Using `.onDeleteCommand` rather than a global menu
            // shortcut means it cannot steal the key from a search field or the inspector.
            .focusable()
            // Suppress the focus ring: the canvas needs focus to receive the Delete key, but it is
            // not a control and should not draw like one.
            .focusEffectDisabled()
            .onDeleteCommand {
                // Delete acts on whatever was picked last. A wire is its own selection (Qt's order: the picked
                // connection first), then a graphic, then blocks — each selection clears the others when made.
                if model.deleteSelectedWire() { return }
                if model.selectedAnnotationIndex != nil {
                    model.deleteSelectedAnnotation()
                } else {
                    model.deleteSelectedModule()
                }
            }
            // Copy, cut and paste, scoped to the canvas the same way: the blocks live in the model, and the system pasteboard
            // only gets a note, which is what makes Paste available in the Edit menu.
            .onCopyCommand { model.copySelection() ? [NSItemProvider(object: "Dirigo blocks" as NSString)] : [] }
            .onCutCommand { model.cutSelection() ? [NSItemProvider(object: "Dirigo blocks" as NSString)] : [] }
            .onPasteCommand(of: [.plainText]) { _ in model.paste() }
            // A row dragged out of the block picker lands where it is dropped, centred on the pointer.
            //
            // The drop itself only notes where. Adding the block rebuilds the engine, and doing that inside the drop kept the drag's picture on
            // screen until it finished; the block is added when the drag session has ended (`PaletteDragSource` says so), which is the moment
            // the picture is gone. What was dragged is known to the row, so nothing has to be read back from the pasteboard.
            .onDrop(of: [.plainText], isTargeted: nil) { _, location in
                model.paletteDropPoint = CanvasTransform.contentPoint(from: location, zoom: model.zoomScale, pan: model.panOffset)
                return true
            }
            .onReceive(NotificationCenter.default.publisher(for: .paletteDragEnded)) { note in
                let point = model.paletteDropPoint
                model.paletteDropPoint = nil
                guard let point, let payload = note.userInfo?["payload"] as? String else { return }   // dropped elsewhere, or cancelled
                // The picker's popover is still open under the drop; close it once something was added.
                if model.placePaletteItem(payload, atContent: point) {
                    NotificationCenter.default.post(name: .dismissBlockPalette, object: nil)
                }
            }
            .onAppear {
                model.viewportSize = geometry.size
                model.canvasGlobalFrame = geometry.frame(in: .named("AppWindow"))
                model.performPendingZoomToFit()
            }
            .onChange(of: geometry.size) { _, newSize in
                model.viewportSize = newSize
                model.canvasGlobalFrame = geometry.frame(in: .named("AppWindow"))
                model.performPendingZoomToFit()
            }
        }
    }

    // MARK: - Schematic content

    /// Extent of the drawable content: everything placed, plus room to drag further.
    ///
    /// This was a fixed 3000 x 2500, which silently clipped anything dragged outside it. The
    /// workspace is meant to be unbounded, so the frame now follows the content — with a generous
    /// apron so a module can always be dragged past the current edge.
    func contentSize(for project: PCCProject) -> CGSize {
        var maxX: Double = 0
        var maxY: Double = 0
        for module in project.modules where module.page == model.selectedPage && !BlockRole.isMaraflowPageRuntime(module) {
            maxX = max(maxX, module.x + Double(ModuleCardView.cardWidth(for: module)))
            maxY = max(maxY, module.y + Double(ModuleCardView.cardHeight(for: module)))
        }
        if let extras = project.maraflow {
            let index = project.pages.firstIndex { $0.caption == model.selectedPage } ?? 0
            for graphic in extras.graphics(onPageIndex: index) {
                let x1 = Double(graphic.gridX) * 32
                let y1 = Double(graphic.gridY) * 32
                let x2 = Double(graphic.gridX + graphic.gridW) * 32
                let y2 = Double(graphic.gridY + graphic.gridH) * 32
                maxX = max(maxX, max(x1, x2))
                maxY = max(maxY, max(y1, y2))
            }
        }
        for graphic in project.graphics where graphic.page == model.selectedPage {
            for node in graphic.nodes {
                maxX = max(maxX, node.x)
                maxY = max(maxY, node.y)
            }
        }
        // Content plus room to pan. Dirigo's sheet used to set a floor here so that its reference
        // outline was always fully visible; with the outline gone the canvas only needs to hold what
        // is actually on the page.
        return CGSize(width: max(1200, maxX + 600),
                      height: max(900, maxY + 500))
    }

    @ViewBuilder

    private func schematic(for project: PCCProject) -> some View {

        let pageModules = project.modules.filter { $0.page == model.selectedPage && !BlockRole.isMaraflowPageRuntime($0) }
        let pageModuleIds = Set(pageModules.map { $0.id })
        let byId = Dictionary(project.modules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        ZStack(alignment: .topLeading) {
            containerRegions(pageModules)

            MaraflowGraphicsLayer(model: model, version: model.simulationVersion)
                .allowsHitTesting(true)

            // Both layers take plain values and are `Equatable`, so on a simulation tick SwiftUI
            // only re-renders the ones whose inputs actually changed.
            WireLayer(wires: wireLayout.wires(project: project,
                                              selectedPage: model.selectedPage,
                                              snapToGrid: model.snapToGrid,
                                              pageModuleIds: pageModuleIds,
                                              modulesById: byId,
                                              dragOffsets: dragOffsets,
                                              snapshots: model.snapshots),
                      picked: model.selectedWire,
                      onPick: { model.selectWire($0) },
                      onDelete: { key in
                          model.selectWire(key)
                          model.deleteSelectedWire()
                      })
                .equatable()

            graphicObjects(for: project)

            // NOTE: deliberately *not* wrapped in `GlassEffectContainer`. That container does not
            // preserve the coordinate space a `ForEach` of `.position`-placed views lays out in,
            // which pushed cards hundreds of points away from their model position (most of them
            // off-screen). The cards are independent panes rather than a merging cluster, so the
            // container buys nothing here.
            moduleLayer(pageModules)
            if let runtime = pageRuntimeInfo(project) {
                let offset = pageRuntimeOffsets[model.selectedPage] ?? .zero
                MaraflowPageRuntimeCard(kind: runtime.kind, detail: runtime.detail, code: runtime.code)
                    .position(x: 300 + offset.width, y: 190 + offset.height)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let origin = pageRuntimeDragOrigin ?? offset
                                if pageRuntimeDragOrigin == nil { pageRuntimeDragOrigin = offset }
                                pageRuntimeOffsets[model.selectedPage] = CGSize(
                                    width: origin.width + value.translation.width,
                                    height: origin.height + value.translation.height)
                            }
                            .onEnded { _ in pageRuntimeDragOrigin = nil }
                    )
            }
        }
    }

    private struct PageRuntimeInfo {
        let kind: String
        let detail: String
        let code: String
    }

    /// A Maraflow ST/LD page has no ordinary blocks; it carries one hidden runtime module. Explain the empty sheet
    /// instead of drawing that module as a card.
    private func pageRuntimeInfo(_ project: PCCProject) -> PageRuntimeInfo? {
        let modules = project.modules.filter { $0.page == model.selectedPage }
        if let st = modules.first(where: { $0.guid == MaraflowStPage.guid }) {
            let code = st.rawAttributes["MARAFLOW_ST_CODE"] ?? ""
            let lines = code.split(separator: "\n", omittingEmptySubsequences: false).count
            return PageRuntimeInfo(kind: "Structured Text page",
                                   detail: "Executed by the native ST interpreter · \(lines) line\(lines == 1 ? "" : "s")",
                                   code: code)
        }
        if let ld = modules.first(where: { $0.guid == MaraflowLdPage.guid }) {
            let rungs = (ld.rawAttributes["MARAFLOW_LD_RUNGS"] ?? "")
                .split(separator: "\n").filter { $0.hasPrefix("R") }.count
            return PageRuntimeInfo(kind: "Ladder page",
                                   detail: "Executed by the native ladder evaluator · \(rungs) rung\(rungs == 1 ? "" : "s")",
                                   code: "")
        }
        return nil
    }

    /// The live pin values drawn over the cards. A function of its own, to keep `body` within the type-checker's budget.
    private func liveValues(for project: PCCProject) -> some View {
        LiveValuesLayer(model: model, modules: project.modules.filter { $0.page == model.selectedPage && !BlockRole.isMaraflowPageRuntime($0) }, dragOffsets: dragOffsets)
    }

    /// Converts a gesture location into canvas content coordinates.
    ///
    /// The content is drawn as `content * zoomScale + panOffset`, so a drag location — which arrives
    /// in the "CanvasViewport" space, already scaled and panned — has to be mapped back before it can
    /// be compared with `inPinPoint`/`outPinPoint`, which are in content space. Without this the drop
    /// hit-test only ever matched at 100% zoom with no pan.
    /// Selects the blocks and graphic objects on this page that the rectangle (content coordinates)
    /// touches. Text and shapes share one selection because they share one array of indices.
    private func selectModules(in rect: CGRect) {
        model.selectedWire = nil
        let hit = (model.project?.modules ?? []).filter {
            $0.page == model.selectedPage
                && !BlockRole.isMaraflowPageRuntime($0)
                && rect.intersects(CGRect(x: $0.x, y: $0.y,
                                          width: ModuleCardView.cardWidth(for: $0),
                                          height: ModuleCardView.cardHeight(for: $0)))
        }.map(\.id)
        let texts = model.textAnnotations(onPage: model.selectedPage).filter { entry in
            let node = entry.graphic.nodes.first
            let size = CGFloat(entry.graphic.fontSize ?? 11)
            // Close to the drawn chip: monospaced glyphs plus the chip's padding.
            // The text can be several lines: width follows the longest, height the line count.
            let lines = (entry.graphic.text ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            let chip = CGRect(x: node?.x ?? 0, y: node?.y ?? 0,
                              width: CGFloat(lines.map(\.count).max() ?? 0) * size * 0.6 + 16,
                              height: CGFloat(max(1, lines.count)) * size * 1.25 + 10)
            return rect.intersects(chip)
        }.map(\.index)
        // A shape is hit on its whole box, the way a block is — not only on its outline.
        let shapes = model.shapes(onPage: model.selectedPage).filter { entry in
            guard let box = entry.graphic.boundingBox else { return false }
            return rect.intersects(CGRect(x: box.x, y: box.y, width: box.width, height: box.height))
        }.map(\.index)
        let graphics = texts + shapes
        model.editingAnnotationIndex = nil
        model.selectedAnnotationIndices = Set(graphics)
        model.selectedAnnotationIndex = graphics.first
        model.selectedModuleIds = Set(hit)
        model.selectedModuleId = hit.first
    }

    private func contentPoint(from viewport: CGPoint) -> CGPoint {
        CanvasTransform.contentPoint(from: viewport, zoom: model.zoomScale, pan: model.panOffset)
    }

    /// The wire in flight: Qt's elbow from the pin to the pointer, and a ring round the pin it has snapped to.
    ///
    /// Drawn in the same content space and with the same transform as the cards, so it stays attached to the pin while
    /// the sheet is panned or zoomed, and above them (`Qt` draws its pending cable at z 50) so the ring is never hidden
    /// under the card it is on.
    private func wirePreview(_ pending: PendingWire, in project: PCCProject) -> some View {
        let start = PinHitTest.anchor(for: pending.from, in: project) ?? .zero
        let target = snapTarget(for: pending, in: project)
        let end = target.flatMap { PinHitTest.anchor(for: $0, in: project) } ?? pending.point
        var path = Path()
        path.addLines(WirePreview.elbow(from: start, to: end, leaving: pending.from.side))
        let size = contentSize(for: project)

        return ZStack(alignment: .topLeading) {
            path.stroke(Color.accentColor,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [4, 3]))
            if target != nil {
                // The ring round the pin the cable would join, sized to the pin: the bead is 6 pt across
                // (`PinRows.bead`), so a 12 pt ring sits just outside it instead of swallowing the row.
                Circle()
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .frame(width: 12, height: 12)
                    .offset(x: end.x - 6, y: end.y - 6)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .scaleEffect(model.zoomScale, anchor: .topLeading)
        .offset(model.panOffset)
        .allowsHitTesting(false)
    }

    /// The pin the cable in flight would join, if the pointer is over one: the same answer at the drop as the ring showed.
    private func snapTarget(for pending: PendingWire, in project: PCCProject) -> PinReference? {
        PinHitTest.target(at: pending.point, from: pending.from, in: project,
                          pageModuleIds: Set(project.modules.filter { $0.page == model.selectedPage }.map(\.id)))
    }

    /// A dashed frame and label behind the blocks of each branch of each container on the page.
    @ViewBuilder
    private func containerRegions(_ pageModules: [PCCModule]) -> some View {
        ForEach(pageModules.filter(ConstructContainers.isContainer), id: \.id) { owner in
            ForEach(ConstructContainers.arms(of: owner), id: \.id) { arm in
                let frames = pageModules
                    .filter { $0.rawAttributes["IN_CONTAINER"] == "\(owner.id)" && $0.rawAttributes["ARM"] == arm.id }
                    // Where the cards are drawn, drag included, so the frame moves with them.
                    .map { CGRect(x: $0.x + (dragOffsets[$0.id]?.width ?? 0), y: $0.y + (dragOffsets[$0.id]?.height ?? 0),
                                  width: ModuleCardView.cardWidth(for: $0), height: ModuleCardView.cardHeight(for: $0)) }
                if let first = frames.first {
                    let box = frames.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -14, dy: -22)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.tint(forCategory: "Main"), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .background(Theme.tint(forCategory: "Main").opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .topLeading) {
                            Text("\(owner.name) · \(arm.label)")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 10).padding(.top, 4)
                        }
                        .frame(width: box.width, height: box.height)
                        .offset(x: box.minX, y: box.minY)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private func moduleLayer(_ pageModules: [PCCModule]) -> some View {
        let pageIds = Set(pageModules.map(\.id))
        // Follows the zoom in quarter steps; see `AppModel.cardRenderScale`.
        let renderScale = model.cardRenderScale
        // Read once for the whole layer rather than per card, so every card sees the same set.
        let searchMatches = model.highlightedModuleIds

        ForEach(pageModules) { mod in
            // Each card in a view of its own, compared on what it draws: a tick that changes a few values redraws those
            // few, and the wrappers of the rest — gesture, frame, position — are not rebuilt at all.
            CardHost(model: model,
                     mod: mod,
                     pageIds: pageIds,
                     renderScale: renderScale,
                     isSearchMatch: searchMatches.contains(mod.id),
                     isRenaming: model.renamingModuleId == mod.id,
                     isSelected: model.selectedModuleId == mod.id || model.selectedModuleIds.contains(mod.id),
                     snapshot: model.snapshots[mod.id].map { ModuleCardView.cardSnapshot($0, of: mod) },
                     drag: dragOffsets[mod.id] ?? .zero,
                     dragOffsets: $dragOffsets,
                     pendingWire: $pendingWire,
                     isDrawingWire: $isDrawingWire)
                .equatable()
        }
    }

    // MARK: - Wires

    // MARK: - Graphic objects

    /// The sheet's graphic objects, shapes first and text over them, so a label written across a
    /// rectangle stays readable. Both are indices into `project.graphics` and share one selection.
    @ViewBuilder
    private func graphicObjects(for project: PCCProject) -> some View {
        // Top-leading aligned, so each object's own top-left corner lands on the node Dirigo stores.
        // The previous version centred a chip at `node + (100, 40)` — an offset with nothing behind
        // it, which put real objects a hundred points away from where they belong.
        ZStack(alignment: .topLeading) {
            ForEach(model.shapes(onPage: model.selectedPage), id: \.index) { entry in
                shapeView(entry.graphic, index: entry.index)
            }

            ForEach(model.textAnnotations(onPage: model.selectedPage), id: \.index) { entry in
                annotationView(entry.graphic, index: entry.index)
                    .offset(x: entry.graphic.nodes.first?.x ?? 0,
                            y: entry.graphic.nodes.first?.y ?? 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A rectangle or circle. The drawing and the gestures are `GraphicShapeView`'s; what stays here is
    /// the state a drag moves through and the document it lands on.
    private func shapeView(_ graphic: ProjectGraphic, index: Int) -> some View {
        // Dragging any member of a marquee selection moves all of them, exactly as with blocks.
        let group: Set<Int> = model.selectedAnnotationIndices.contains(index) ? model.selectedAnnotationIndices : [index]

        return GraphicShapeView(
            graphic: graphic,
            index: index,
            drag: shapeDragOffsets[index] ?? .zero,
            grow: shapeResizeOffsets[index] ?? .zero,
            zoomScale: { [model] in model.zoomScale },
            isSelected: model.selectedAnnotationIndex == index || model.selectedAnnotationIndices.contains(index),
            isActive: model.graphicIsActive(graphic) ?? false,
            isSoleSelection: group == [index],
            onSelect: {
                model.selectedModuleId = nil
                model.selectedAnnotationIndex = index
            },
            onDelete: { model.deleteAnnotation(at: index) },
            onDrag: { delta in
                for id in group { shapeDragOffsets[id] = delta }
            },
            onDragEnd: { delta in
                model.moveShapes(group, lead: index,
                                 deltaX: Double(delta.width), deltaY: Double(delta.height))
                for id in group { shapeDragOffsets.removeValue(forKey: id) }
            },
            onResize: { delta in shapeResizeOffsets[index] = delta },
            onResizeEnd: { delta in
                if let box = graphic.boundingBox {
                    model.updateShape(at: index,
                                      to: box.resized(maxX: box.maxX + Double(delta.width),
                                                      maxY: box.maxY + Double(delta.height)))
                }
                shapeResizeOffsets.removeValue(forKey: index)
            }
        )
    }

    @ViewBuilder
    private func annotationView(_ graphic: ProjectGraphic, index: Int) -> some View {
        let isSelected = model.selectedAnnotationIndex == index || model.selectedAnnotationIndices.contains(index)
        let isEditing = model.editingAnnotationIndex == index
        let size = CGFloat(graphic.fontSize ?? 11)

        Group {
            if isEditing {
                TextAnnotationEditor(
                    initial: graphic.text ?? "",
                    fontSize: size,
                    onCommit: { text in
                        model.updateAnnotationText(at: index, text: text)
                        model.editingAnnotationIndex = nil
                    },
                    onCancel: { model.editingAnnotationIndex = nil }
                )
                // A fresh editor per object: its draft must not leak from one to the next.
                .id(index)
            } else {
                Text(graphic.text ?? "")
                    .font(.system(size: size, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .glassPanel(RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous))
            }
        }
        .overlay {
            if isSelected && !isEditing {
                RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
                    .strokeBorder(Theme.searchHighlight, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        // Simultaneous, not a count-2 / count-1 `onTapGesture` pair: that pair holds the single tap back
        // until the double-click window has passed, which is a visible lag before the selection.
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.beginEditingAnnotation(at: index) })
        .simultaneousGesture(TapGesture().onEnded {
            model.selectedModuleId = nil
            model.selectedAnnotationIndex = index
        })
        .contextMenu {
            Button("Inspect Text", systemImage: "info.circle") {
                model.selectedModuleId = nil
                model.selectedAnnotationIndex = index
                NotificationCenter.default.post(name: .showInspector, object: nil)
            }
            Button("Edit Text") { model.beginEditingAnnotation(at: index) }
            Button("Delete Text", systemImage: "trash", role: .destructive) {
                model.deleteAnnotation(at: index)
            }
        }
        .help("Text object — double-click to edit")
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Project Open", systemImage: "cpu")
        } description: {
            Text("Open a .wbp project (or a legacy .pcc), or start a new one.")
        } actions: {
            HStack(spacing: 10) {
                Button {
                    model.createNewProject()
                } label: {
                    Text("New Project").frame(minWidth: 110)
                }
                Button {
                    model.openProjectFile()
                } label: {
                    Text("Open…").frame(minWidth: 110)
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.extraLarge)
            .padding(.top, 6)
        }
        // Sized to its content, in a glass panel of its own, rather than spread over the whole canvas.
        .fixedSize()
        .padding(.horizontal, 36)
        .padding(.vertical, 28)
        .glassPanel(cornerRadius: 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

// MARK: - Wire layer

/// Draws every wire on the page.
///
/// A separate, `Equatable` view on purpose: the polylines only change when a module moves or a
/// source pin changes state, so on a simulation tick the whole layer is skipped unless some wire
/// actually changed. It used to be rebuilt inline in `CanvasView.body`, which meant 100+ polylines
/// were reconstructed on every tick *and* on every frame of a zoom or pan.
struct WireLayer: View, Equatable {
    nonisolated let wires: [RoutedWire]
    /// The wire the user picked, drawn picked (Qt: accent, thicker).
    nonisolated let picked: RoutedWire.Key?
    /// Called when a wire is clicked. The closures are excluded from `==`, like every other callback in this
    /// codebase: they are recreated on each pass and capture nothing that changes.
    var onPick: ((RoutedWire.Key) -> Void)?
    var onDelete: ((RoutedWire.Key) -> Void)?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.wires == rhs.wires && lhs.picked == rhs.picked }

    var body: some View {
        ZStack {
            ForEach(wires, id: \.key) { wire in
                WireShape(wire: wire, isPicked: wire.key == picked, onPick: onPick, onDelete: onDelete).equatable()
            }
        }
    }

    /// Builds the drawn shape for a wire: a polyline with rounded corners.
    nonisolated static func path(for wire: RoutedWire) -> Path {
        Path(WireRouter.roundedPath(wire.points))
    }
}

/// One wire: its stroke, and the wide invisible one that takes its right-click.
///
/// A view of its own, comparable on its route and look, so that a tick that changes the colour of a few wires
/// re-evaluates those few and builds their paths — and not a path or two for every wire on the sheet, which is what one
/// body over all of them did at every such tick.
private struct WireShape: View, Equatable {
    nonisolated let wire: RoutedWire
    nonisolated let isPicked: Bool
    var onPick: ((RoutedWire.Key) -> Void)?
    var onDelete: ((RoutedWire.Key) -> Void)?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.wire == rhs.wire && lhs.isPicked == rhs.isPicked }

    /// How far either side of a wire still counts as touching it. A 1 pt line is far too thin to
    /// right-click reliably, so the menu hangs off a wide invisible stroke instead of the drawn one.
    private static let hitWidth: CGFloat = 14

    var body: some View {
        let path = WireLayer.path(for: wire)
        ZStack {
            // Picked reads as Qt's: the accent colour and a heavier line, so the wire under the pointer is
            // unmistakably the one Delete will remove.
            path.stroke(
                isPicked ? Color.accentColor : (wire.isHigh ? Theme.wireLive : Theme.wireIdle),
                style: StrokeStyle(
                    lineWidth: isPicked ? 3 : (wire.isHigh ? max(1.8, wire.width) : max(1.2, wire.width)),
                    lineCap: .round,
                    lineJoin: .round,
                    dash: wire.isFeedback ? [5, 4] : []
                )
            )
            // Invisible, but hit-testable: a clear view whose hit area is the wide band along the wire, so nothing is
            // drawn for it. It was a second, near-transparent stroke, which the renderer drew like any other — a wide
            // stroke per wire at every frame of a pan or a zoom, for something nobody sees. Above the visible stroke,
            // so it wins the hit.
            Color.clear
                .contentShape(path.strokedPath(StrokeStyle(lineWidth: Self.hitWidth, lineCap: .round, lineJoin: .round)))
                .onTapGesture { onPick?(wire.key) }
                .contextMenu {
                    Button("Delete Connection", role: .destructive) { onDelete?(wire.key) }
                }
        }
    }
}

// MARK: - Grid

/// The drafting grid. Two tiers keep it readable at any zoom: fine cells that fade out as you
/// zoom away, and a coarser ruled grid with dots at its intersections.
public struct CanvasGrid: View, Equatable {
    public var zoomScale: CGFloat = 1.0
    public var panOffset: CGSize = .zero
    /// The scheme is passed in rather than read from the environment: an `Equatable` view that read it itself would miss the
    /// change, and the host re-runs on an environment change anyway.
    public var colorScheme: ColorScheme = .dark

    private static let baseStep = CGFloat(GridSnap.step)
    private static let majorEvery = 5

    public init(zoomScale: CGFloat = 1.0, panOffset: CGSize = .zero, colorScheme: ColorScheme = .dark) {
        self.zoomScale = zoomScale
        self.panOffset = panOffset
        self.colorScheme = colorScheme
    }

    /// Compared on what it draws, so a simulation tick — which changes none of it — does not redraw the grid. The canvas is
    /// synchronous and inside the canvas view's own update, so this is only about not doing the same work sixty times a second.
    nonisolated public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.zoomScale == rhs.zoomScale && lhs.panOffset == rhs.panOffset && lhs.colorScheme == rhs.colorScheme
    }

    /// The on-screen grid pitch, kept within a legible band by doubling or halving.
    private var step: CGFloat {
        var value = Self.baseStep * max(0.1, zoomScale)
        while value < 14 { value *= 2 }
        while value > 90 { value /= 2 }
        return value
    }

    public var body: some View {
        // Drawn synchronously. An asynchronous canvas lands a frame after the cards it sits behind, so a pan or a zoom
        // (both of which move it every event) left the grid trailing the sheet — it read as the background shaking.
        Canvas { context, size in
            let pitch = step
            guard pitch > 0 else { return }

            let panX = panOffset.width
            let panY = panOffset.height

            var minor = Path()
            var major = Path()

            let firstCol = Int(floor((0 - panX) / pitch)) - 1
            let lastCol = Int(ceil((size.width - panX) / pitch)) + 1
            for i in firstCol...lastCol {
                let x = panX + CGFloat(i) * pitch
                if i % Self.majorEvery == 0 {
                    major.move(to: CGPoint(x: x, y: 0))
                    major.addLine(to: CGPoint(x: x, y: size.height))
                } else {
                    minor.move(to: CGPoint(x: x, y: 0))
                    minor.addLine(to: CGPoint(x: x, y: size.height))
                }
            }

            let firstRow = Int(floor((0 - panY) / pitch)) - 1
            let lastRow = Int(ceil((size.height - panY) / pitch)) + 1
            for j in firstRow...lastRow {
                let y = panY + CGFloat(j) * pitch
                if j % Self.majorEvery == 0 {
                    major.move(to: CGPoint(x: 0, y: y))
                    major.addLine(to: CGPoint(x: size.width, y: y))
                } else {
                    minor.move(to: CGPoint(x: 0, y: y))
                    minor.addLine(to: CGPoint(x: size.width, y: y))
                }
            }

            // Fine cells recede as the grid compresses so the surface never looks noisy.
            // Light mode needs more: dark lines on a light page vanish at the dark-mode strengths.
            let boost = colorScheme == .light ? 2.4 : 1.0
            let minorOpacity = min(0.055, max(0.014, 0.055 * (pitch - 14) / 40)) * boost
            context.stroke(minor, with: .color(Color.primary.opacity(minorOpacity)), lineWidth: 1)
            context.stroke(major, with: .color(Color.primary.opacity(0.085 * boost)), lineWidth: 1)

        }
        .allowsHitTesting(false)
    }
}

// MARK: - Zoom control

/// Floating zoom control in the app's glass language.
struct ZoomControlBar: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 6) { control }
            } else {
                control
            }
        }
    }

    private var control: some View {
        HStack(spacing: 2) {
            iconButton("minus.magnifyingglass", help: "Zoom Out (⌘-)") {
                model.zoomOut()
            }

            Menu {
                Button("Zoom to Fit (⌘9)") { model.zoomToFit() }
                Button("Actual Size 100% (⌘0)") { model.resetZoom() }
                Divider()
                Button("200%") { model.zoomTo(2.0) }
                Button("150%") { model.zoomTo(1.5) }
                Button("125%") { model.zoomTo(1.25) }
                Button("100%") { model.zoomTo(1.0) }
                Button("75%") { model.zoomTo(0.75) }
                Button("50%") { model.zoomTo(0.5) }
                Button("35%") { model.zoomTo(0.35) }
            } label: {
                Text("\(Int(round(model.zoomScale * 100)))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .frame(minWidth: 46)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            iconButton("plus.magnifyingglass", help: "Zoom In (⌘+)") {
                model.zoomIn()
            }

            Divider().frame(height: 14)

            // 100% is in the percentage menu and on ⌘0, so it has no button of its own here.
            iconButton("arrow.up.left.and.arrow.down.right", help: "Zoom to Fit (⌘9)") {
                model.zoomToFit()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .glassCapsule()
        .shadow(color: Theme.softShadow.opacity(0.6), radius: 10, y: 3)
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Touchpad bridge

public struct CanvasTouchpadView: NSViewRepresentable {
    public var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public func makeNSView(context: Context) -> TouchpadNSView {
        let view = TouchpadNSView()
        view.model = model
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.autoresizingMask = [.width, .height]
        return view
    }

    public func updateNSView(_ nsView: TouchpadNSView, context: Context) {
        nsView.model = model
    }
}

public final class TouchpadNSView: NSView {
    public weak var model: AppModel?

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if let type = NSApp.currentEvent?.type {
            if type == .magnify || type == .scrollWheel || type == .smartMagnify
                || type == .otherMouseDown || type == .otherMouseDragged || type == .otherMouseUp {
                return self
            }
        }
        return nil
    }

    // Middle button (the third): drag the sheet.
    public override func otherMouseDragged(with event: NSEvent) {
        guard let model = model, event.buttonNumber == 2 else { return }
        model.panOffset.width += event.deltaX
        model.panOffset.height += event.deltaY
        model.dragStartPan = model.panOffset
    }

    public override func magnify(with event: NSEvent) {
        guard let model = model else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let anchor = CGPoint(x: loc.x, y: loc.y)
        let factor = 1.0 + event.magnification * 1.5
        model.zoomBy(factor: factor, anchor: anchor)
    }

    public override func scrollWheel(with event: NSEvent) {
        guard let model = model else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let anchor = CGPoint(x: loc.x, y: loc.y)

        // A trackpad scroll comes with gesture phases (fingers down, momentum); a mouse wheel, even a
        // smooth-scrolling one, has none. Wheel scrolling zooms (unless the setting is off); the
        // trackpad pans, and ⌘/⌥ zoom either.
        let isTrackpad = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        if (model.scrollZooms && !isTrackpad) || event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let delta = event.scrollingDeltaY
            guard abs(delta) > 0.001 else { return }
            let factor: CGFloat
            if event.hasPreciseScrollingDeltas {
                factor = 1.0 + (delta * 0.008)
            } else {
                factor = delta > 0 ? 1.15 : 0.85
            }
            model.zoomBy(factor: factor, anchor: anchor)
        } else {
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            model.panOffset.width += dx
            model.panOffset.height += dy
            model.dragStartPan = model.panOffset
        }
    }

    public override func smartMagnify(with event: NSEvent) {
        guard let model = model else { return }
        if abs(model.zoomScale - 1.0) < 0.15 {
            model.zoomToFit()
        } else {
            model.resetZoom()
        }
    }
}

private extension CGRect {
    /// The rectangle spanned by two opposite corners, in either order.
    init(from a: CGPoint, to b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

/// The sheet's pan and zoom, applied where they are read.
///
/// A view of its own so that a pan or a zoom re-evaluates only this — a modifier or two on content that is already
/// built — and not the canvas, whose body would rebuild every card, wire and shape of the schematic for a change that
/// moves none of them.
private struct SheetTransform<Content: View>: View {
    let model: AppModel
    let content: Content

    init(model: AppModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.content = content()
    }

    var body: some View {
        content
            .scaleEffect(model.zoomScale, anchor: .topLeading)
            .offset(model.panOffset)
    }
}

/// The grid, reading the pan and zoom itself for the same reason.
private struct CanvasGridHost: View {
    let model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        CanvasGrid(zoomScale: model.zoomScale, panOffset: model.panOffset, colorScheme: colorScheme)
            .equatable()
    }
}

/// One block on the sheet: its card, and the frame, gesture and position that put it there and let it be moved.
///
/// A view of its own, compared on what it draws (`==`), and used through `.equatable()`. Built in the canvas body, the
/// same wrapper was rebuilt with fresh closures for every block at every tick that changed a value, and SwiftUI had to
/// treat each as changed; profiled, most of such a tick was that, and not the cards. Here a card whose block, values,
/// selection and offset are the same is skipped whole.
///
/// What a gesture needs that changes while it runs — the drag offsets, the wire being drawn — is reached through
/// bindings, which `==` does not look at, and the zoom and pan through the model at the moment of the gesture.
private struct CardHost: View, Equatable {
    let model: AppModel
    let mod: PCCModule
    let pageIds: Set<Int>
    let renderScale: CGFloat
    let isSearchMatch: Bool
    let isRenaming: Bool
    let isSelected: Bool
    let snapshot: BlockSnapshot?
    let drag: CGSize
    @Binding var dragOffsets: [Int: CGSize]
    @Binding var pendingWire: PendingWire?
    @Binding var isDrawingWire: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.mod == rhs.mod
            && lhs.snapshot == rhs.snapshot
            && lhs.drag == rhs.drag
            && lhs.isSelected == rhs.isSelected
            && lhs.isSearchMatch == rhs.isSearchMatch
            && lhs.isRenaming == rhs.isRenaming
            && lhs.renderScale == rhs.renderScale
            && lhs.pageIds == rhs.pageIds
    }

    /// A point in the viewport, in sheet coordinates: the content is drawn scaled and panned.
    private func contentPoint(from viewport: CGPoint) -> CGPoint {
        CanvasTransform.contentPoint(from: viewport, zoom: model.zoomScale, pan: model.panOffset)
    }

    /// The block's menu entries for `If` / `Switch` containers: where it can go, and out of the one it is in.
    private func containerActions() -> [ModuleCardView.ContainerAction] {
        var actions = model.containerChoices(for: mod.id).map { choice in
            ModuleCardView.ContainerAction(title: "Move into \(choice.container.name) ▸ \(choice.arm.label)") {
                model.setContainer(of: mod.id, to: (choice.container.id, choice.arm.id))
            }
        }
        if let modules = model.project?.modules,
           let owner = ConstructContainers.container(of: mod, in: modules) {
            actions.append(.init(title: "Take out of \(owner.name)") { model.setContainer(of: mod.id, to: nil) })
        }
        return actions
    }

    /// Leaves the selection alone when `id` is in it, and makes `id` the selection when it is not.
    private func keepSelection(of id: Int) {
        guard !(model.selectedModuleIds.contains(id) || model.selectedModuleId == id) else { return }
        model.selectedAnnotationIndex = nil
        model.selectedModuleId = id
    }

    var body: some View {
        let w = ModuleCardView.cardWidth(for: mod)
        let h = ModuleCardView.cardHeight(for: mod)

        ModuleCardView(
            module: mod,
            inValues: snapshot?.inValues ?? mod.inPins.map(\.value),
            paramValues: snapshot?.paramValues ?? mod.paramPins.map(\.value),
            outValues: snapshot?.outValues ?? [],
            boolVarMode: snapshot?.boolVarMode,
            isSearchMatch: isSearchMatch,
            isRenaming: isRenaming,
            segments: snapshot?.segments ?? [],
            isSelected: isSelected,
            renderScale: renderScale,
            onSelect: {
                // One thing selected at a time: the inspector shows whichever was picked last, and a
                // block left selected would win over the shape or text just clicked.
                model.selectedAnnotationIndex = nil
                model.selectedModuleId = mod.id
            },
            onToggleInput: { pinIdx in
                model.toggleModuleInput(moduleId: mod.id, pinIndex: pinIdx)
            },
            onSetValue: { model.setVariableValue(moduleId: mod.id, value: $0) },
            onPressInput: { pinIdx, isPressed in
                model.setModuleInputPressed(moduleId: mod.id, pinIndex: pinIdx,
                                            isPressed: isPressed)
            },
            onOpenMacro: { targetPage in
                model.selectedPage = targetPage
            },
            onConfigure: {
                model.openConfigureModule(id: mod.id)
            },
            onPinDragBegan: { reference in
                pendingWire = PendingWire(from: reference, point: .zero)
            },
            onPinDragMoved: { location in
                pendingWire?.point = contentPoint(from: location)
            },
            onPinDragEnded: { location, reference in
                let drop = contentPoint(from: location)
                pendingWire = nil
                guard let project = model.project,
                      let target = PinHitTest.target(at: drop, from: reference, in: project, pageModuleIds: pageIds)
                else { return }
                model.connectPins(from: reference, to: target)
            },
            onBeginRename: { model.renamingModuleId = mod.id },
            onRename: { newName in model.renameModule(id: mod.id, name: newName) },
            onCancelRename: { model.renamingModuleId = nil },
            // The menu acts on the selection: right-clicking a block that is part of it keeps the group, right-clicking
            // one that is not selects just that one first.
            onDelete: { keepSelection(of: mod.id); model.deleteSelectedModule() },
            onCopy: { keepSelection(of: mod.id); model.copySelection() },
            onCut: { keepSelection(of: mod.id); model.cutSelection() },
            onPaste: { model.paste() },
            containerActions: { containerActions() }
        )
        // Skip the card entirely when nothing it draws has changed.
        .equatable()
        .frame(width: w, height: h)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named("CanvasViewport"))
                .onChanged { value in
                    // Decide once, from where the drag started: a drag beginning on a pin draws a wire,
                    // anywhere else moves the block. One gesture, so there is no precedence problem —
                    // a pin-row gesture never fired because the card's own drag captured the event.
                    if !isDrawingWire && pendingWire == nil && dragOffsets[mod.id] == nil {
                        if let pin = PinHitTest.pin(at: contentPoint(from: value.startLocation),
                                                    in: model.project ?? PCCProject(name: ""), pageModuleIds: pageIds) {
                            isDrawingWire = true
                            pendingWire = PendingWire(from: pin, point: contentPoint(from: value.location))
                            return
                        }
                    }
                    if isDrawingWire {
                        pendingWire?.point = contentPoint(from: value.location)
                        return
                    }
                    if !model.selectedModuleIds.contains(mod.id) {
                        model.selectedAnnotationIndex = nil
                        model.selectedModuleId = mod.id
                    }
                    let group = model.selectedModuleIds.contains(mod.id) ? model.selectedModuleIds : [mod.id]
                    let raw = CGSize(
                        width: value.translation.width / model.zoomScale,
                        height: value.translation.height / model.zoomScale
                    )
                    // With snapping on the card previews the position it will land on.
                    var shown = raw
                    if let snapped = model.snappedPosition(id: mod.id, deltaX: raw.width, deltaY: raw.height) {
                        shown = CGSize(width: snapped.x - mod.x, height: snapped.y - mod.y)
                    }
                    for id in group { dragOffsets[id] = shown }
                }
                .onEnded { value in
                    if isDrawingWire {
                        isDrawingWire = false
                        let drop = contentPoint(from: value.location)
                        let origin = pendingWire?.from
                        pendingWire = nil
                        if let origin,
                           let target = PinHitTest.target(at: drop, from: origin,
                                                          in: model.project ?? PCCProject(name: ""), pageModuleIds: pageIds) {
                            model.connectPins(from: origin, to: target)
                        }
                        return
                    }
                    let group = model.selectedModuleIds.contains(mod.id) ? model.selectedModuleIds : [mod.id]
                    model.moveModules(
                        group, lead: mod.id,
                        deltaX: Double(value.translation.width / model.zoomScale),
                        deltaY: Double(value.translation.height / model.zoomScale)
                    )
                    for id in group { dragOffsets.removeValue(forKey: id) }
                }
        )
        .position(
            x: mod.x + Double(drag.width) + w / 2,
            y: mod.y + Double(drag.height) + h / 2
        )
    }
}

