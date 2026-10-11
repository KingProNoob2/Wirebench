import SwiftUI
import AppKit
import DirigoCore

public struct CanvasView: View {
    @Bindable var model: AppModel
    /// Live drag translation per module, applied on top of the model position until the drag ends.
    @State private var dragOffsets: [Int: CGSize] = [:]
    /// The wire currently being dragged, if any. `nil` means no wiring in progress.
    @State private var pendingWire: PendingWire?
    /// True while the current card drag is drawing a wire rather than moving the card. Decided once,
    /// when the drag starts, so a gesture cannot change its mind halfway through.
    @State private var isDrawingWire = false

    /// Routed wire paths, kept between frames.
    ///
    /// Routing is a path search around the sheet's obstacles, and it depends only on *geometry* — module
    /// positions, the drag offsets, and a connection's own hand-drawn `POINTS`. It never depends on a
    /// signal value, so recomputing it inside `body` meant every tick re-routed every cable, which is
    /// where a profile put the app's main-thread time (3.99 s of 4.40 s on the main thread, against 5 ms
    /// in SwiftUI's renderer). Only the points are cached; a wire's colour and dash still come from the
    /// live values.
    @State private var routeCache = WireRouteCache()

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
                    CanvasGrid(zoomScale: model.zoomScale, panOffset: model.panOffset)
                        .contentShape(Rectangle())
                        // Clicking the sheet ends a text edit. The grid sits *behind* the objects,
                        // so a click on one still reaches it — a catch-all gesture would cancel the
                        // edit the double-click had just started.
                        .onTapGesture {
                            // Clicking the sheet clears both kinds of selection, the way it already
                            // cleared the block selection.
                            model.editingAnnotationIndex = nil
                            model.selectedAnnotationIndex = nil
                        }

                    if let project = model.project {
                        schematic(for: project)
                            .frame(width: contentSize(for: project).width,
                                   height: contentSize(for: project).height,
                                   alignment: .topLeading)
                            .scaleEffect(model.zoomScale, anchor: .topLeading)
                            .offset(model.panOffset)

                        if let pending = pendingWire {
                            wirePreview(pending, in: project)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            model.panOffset = CGSize(
                                width: model.dragStartPan.width + value.translation.width,
                                height: model.dragStartPan.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            model.dragStartPan = model.panOffset
                        }
                )
                .simultaneousGesture(
                    TapGesture().onEnded {
                        model.selectedModuleId = nil
                        model.selectedAnnotationIndex = nil
                    }
                )
                .onTapGesture(count: 2) {
                    model.zoomToFit()
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
            .onDeleteCommand { model.deleteSelectedModule() }
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
        for module in project.modules where module.page == model.selectedPage {
            maxX = max(maxX, module.x + Double(ModuleCardView.cardWidth(for: module)))
            maxY = max(maxY, module.y + Double(ModuleCardView.cardHeight(for: module)))
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

        let pageModules = project.modules.filter { $0.page == model.selectedPage }
        let pageModuleIds = Set(pageModules.map { $0.id })
        let byId = Dictionary(project.modules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        ZStack(alignment: .topLeading) {
            // Both layers take plain values and are `Equatable`, so on a simulation tick SwiftUI
            // only re-renders the ones whose inputs actually changed.
            WireLayer(wires: routedWires(project: project,
                                         pageModuleIds: pageModuleIds,
                                         modulesById: byId),
                      onDelete: { key in
                          model.disconnectPin(PinReference(moduleId: key.inModule,
                                                           side: .input,
                                                           index: key.inPin))
                      })
                .equatable()

            annotations(for: project)

            // NOTE: deliberately *not* wrapped in `GlassEffectContainer`. That container does not
            // preserve the coordinate space a `ForEach` of `.position`-placed views lays out in,
            // which pushed cards hundreds of points away from their model position (most of them
            // off-screen). The cards are independent panes rather than a merging cluster, so the
            // container buys nothing here.
            moduleLayer(pageModules)
        }
    }

    /// Converts a gesture location into canvas content coordinates.
    ///
    /// The content is drawn as `content * zoomScale + panOffset`, so a drag location — which arrives
    /// in the "CanvasViewport" space, already scaled and panned — has to be mapped back before it can
    /// be compared with `inPinPoint`/`outPinPoint`, which are in content space. Without this the drop
    /// hit-test only ever matched at 100% zoom with no pan.
    private func contentPoint(from viewport: CGPoint) -> CGPoint {
        CanvasTransform.contentPoint(from: viewport, zoom: model.zoomScale, pan: model.panOffset)
    }

    /// The wire in flight. Drawn with the cards so it shares their transform, and hit-testing is
    /// off so it cannot swallow the drag that is drawing it.
    ///
    /// Written flat, without a `ViewBuilder` branch, on purpose: inlined or branched, this modifier
    /// chain exceeded the type-checker's budget and the file stopped compiling.
    private func wirePreview(_ pending: PendingWire, in project: PCCProject) -> some View {
        let source = project.modules.first { $0.id == pending.from.moduleId }
        let anchor: CGPoint = {
            guard let source else { return .zero }
            return pending.from.side == .output
                ? ModuleCardView.outPinPoint(for: source, pinIndex: pending.from.index)
                : ModuleCardView.inPinPoint(for: source, pinIndex: pending.from.index)
        }()
        let size = contentSize(for: project)

        var path = Path()
        path.move(to: anchor)
        path.addLine(to: pending.point)

        return path
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .scaleEffect(model.zoomScale, anchor: .topLeading)
            .offset(model.panOffset)
            .allowsHitTesting(false)
    }

    /// One block card. Extracted from the `ForEach` body because the combined expression — the card
    /// plus its gesture, context menu and position modifiers, plus the wiring closures — exceeded the
    /// Swift type-checker's budget and stopped the file compiling.
    @ViewBuilder
    private func cardView(for mod: PCCModule, pageIds: Set<Int>, renderScale: CGFloat,
                          searchMatches: Set<Int>) -> some View {
        let w = ModuleCardView.cardWidth(for: mod)
        let h = ModuleCardView.cardHeight(for: mod)
        let drag = dragOffsets[mod.id] ?? .zero
        // Read the observable snapshot, not the engine: the engine is a plain class, so a value
        // taken from it during `body` is invisible to SwiftUI's diffing and only ever repaints by
        // luck. The snapshot is value data in observable state.
        let snapshot = model.snapshots[mod.id]

        ModuleCardView(
            module: mod,
            inValues: snapshot?.inValues ?? mod.inPins.map(\.value),
            paramValues: snapshot?.paramValues ?? mod.paramPins.map(\.value),
            outValues: snapshot?.outValues ?? [],
            boolVarMode: snapshot?.boolVarMode,
            isSearchMatch: searchMatches.contains(mod.id),
            isRenaming: model.renamingModuleId == mod.id,
            segments: snapshot?.segments ?? [],
            isSelected: model.selectedModuleId == mod.id,
            renderScale: renderScale,
            onSelect: { model.selectedModuleId = mod.id },
            onToggleInput: { pinIdx in
                model.toggleModuleInput(moduleId: mod.id, pinIndex: pinIdx)
            },
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
                      let target = PinHitTest.pin(at: drop, in: project, pageModuleIds: pageIds)
                else { return }
                model.connectPins(from: reference, to: target)
            },
            onBeginRename: { model.renamingModuleId = mod.id },
            onRename: { newName in model.renameModule(id: mod.id, name: newName) },
            onCancelRename: { model.renamingModuleId = nil },
            onDelete: { _ = model.deleteModule(id: mod.id) }
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
                    model.selectedModuleId = mod.id
                    dragOffsets[mod.id] = CGSize(
                        width: value.translation.width / model.zoomScale,
                        height: value.translation.height / model.zoomScale
                    )
                }
                .onEnded { value in
                    if isDrawingWire {
                        isDrawingWire = false
                        let drop = contentPoint(from: value.location)
                        let origin = pendingWire?.from
                        pendingWire = nil
                        if let origin,
                           let target = PinHitTest.pin(at: drop, in: model.project ?? PCCProject(name: ""), pageModuleIds: pageIds) {
                            model.connectPins(from: origin, to: target)
                        }
                        return
                    }
                    model.updateModulePosition(
                        id: mod.id,
                        deltaX: Double(value.translation.width / model.zoomScale),
                        deltaY: Double(value.translation.height / model.zoomScale)
                    )
                    dragOffsets.removeValue(forKey: mod.id)
                }
        )
        .position(
            x: mod.x + Double(drag.width) + w / 2,
            y: mod.y + Double(drag.height) + h / 2
        )
    
    }

    @ViewBuilder
    private func moduleLayer(_ pageModules: [PCCModule]) -> some View {
        let pageIds = Set(pageModules.map(\.id))
        // Sharpened only once the gesture has stopped; see `AppModel.isZoomSettled`.
        let renderScale: CGFloat = model.isZoomSettled
            ? ModuleCardView.renderScale(for: model.zoomScale)
            : 1.0
        // Read once for the whole layer rather than per card, so every card sees the same set.
        let searchMatches = model.highlightedModuleIds

        ForEach(pageModules) { mod in
            cardView(for: mod, pageIds: pageIds, renderScale: renderScale,
                     searchMatches: searchMatches)
        }
    }

    // MARK: - Wires

    /// A single routed wire as a complete polyline, so `WireLayer` only has to draw it.
    struct RoutedWire: Equatable {
        /// Identity of the connection this wire was built from. It travels with the wire and is
        /// unique per connection, so it can identify the drawn shape across updates — a position
        /// in the array would not, and `ForEach` would treat every edit as a whole new set.
        struct Key: Hashable {
            var outModule: Int
            var outPin: Int
            var inModule: Int
            var inPin: Int
        }

        var key: Key
        var points: [CGPoint]
        var isHigh: Bool
        var isFeedback: Bool
        var width: CGFloat

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.points == rhs.points && lhs.isHigh == rhs.isHigh
                && lhs.isFeedback == rhs.isFeedback && lhs.width == rhs.width
        }
    }

    /// Routes every wire on the page.
    ///
    /// Module and pin lookups go through dictionaries rather than `first(where:)` on the module
    /// array: the previous version was O(connections x modules), ~6,500 comparisons per frame.
    ///
    /// Routing honours the project file. `POINTS` is Dirigo's own route (offsets from the source
    /// pin): a connection with two or more stored points was routed deliberately by the user and is
    /// followed exactly. A single stored point is just the stub Dirigo writes for a freshly drawn
    /// wire, so those are re-routed cleanly instead — which is what removes the long rectangular
    /// detours. Nothing here is ever written back, so the file is untouched either way.
    private func routedWires(
        project: PCCProject,
        pageModuleIds: Set<Int>,
        modulesById: [Int: PCCModule]
    ) -> [RoutedWire] {
        routeCache.beginFrame(key: routeKey(project: project, pageModuleIds: pageModuleIds))
        var wires: [RoutedWire] = []
        wires.reserveCapacity(project.inConnections.count)

        // Every block on the page, so cables can be routed around them rather than through them.
        let obstacles: [Int: CGRect] = pageModuleIds.reduce(into: [:]) { result, id in
            guard let module = modulesById[id] else { return }
            let drag = dragOffsets[id] ?? .zero
            result[id] = CGRect(
                x: module.x + drag.width,
                y: module.y + drag.height,
                width: Double(ModuleCardView.cardWidth(for: module)),
                height: Double(ModuleCardView.cardHeight(for: module))
            )
        }

        for (index, conn) in project.inConnections.enumerated() {
            guard pageModuleIds.contains(conn.outModuleId),
                  pageModuleIds.contains(conn.inModuleId),
                  let srcMod = modulesById[conn.outModuleId],
                  let dstMod = modulesById[conn.inModuleId] else { continue }

            let sourceValues = model.snapshots[srcMod.id]?.outValues
            let isHigh = sourceValues?.indices.contains(conn.outPinId) == true
                ? (sourceValues![conn.outPinId].asBool)
                : false

            let srcDrag = dragOffsets[srcMod.id] ?? .zero
            let dstDrag = dragOffsets[dstMod.id] ?? .zero

            let rawSrc = ModuleCardView.outPinPoint(for: srcMod, pinIndex: conn.outPinId)
            let rawDst = ModuleCardView.inPinPoint(for: dstMod, pinIndex: conn.inPinId)
            let src = CGPoint(x: rawSrc.x + srcDrag.width, y: rawSrc.y + srcDrag.height)
            let dst = CGPoint(x: rawDst.x + dstDrag.width, y: rawDst.y + dstDrag.height)

            // Keep parallel runs from stacking exactly on top of one another.
            let lane = Double(index % 4) * 3.0

            let wireKey = "\(conn.outModuleId).\(conn.outPinId)->\(conn.inModuleId).\(conn.inPinId)"
            let points: [CGPoint] = routeCache.points(for: wireKey) {
                routingPoints(conn: conn, src: src, dst: dst, lane: lane,
                              srcMod: srcMod, dstMod: dstMod,
                              srcDrag: srcDrag, dstDrag: dstDrag, obstacles: obstacles)
            }

            wires.append(RoutedWire(
                key: .init(outModule: conn.outModuleId, outPin: conn.outPinId,
                           inModule: conn.inModuleId, inPin: conn.inPinId),
                points: points,
                isHigh: isHigh,
                // REVERSE marks a feedback wire in Dirigo; drawn dashed so it reads as one.
                isFeedback: conn.rawAttributes["REVERSE"].map { $0 == "1" || $0.lowercased() == "true" } ?? false,
                width: CGFloat(Double(conn.rawAttributes["WIDTH"] ?? "") ?? 0)
            ))
        }

        // Draw live wires last so they sit on top of the idle ones.
        return wires.sorted { !$0.isHigh && $1.isHigh }
    }

    /// The path for one cable, computed once per geometry and then cached.
    ///
    /// The two branches are the original rules: a connection with two or more stored `POINTS` was routed
    /// deliberately in Dirigo and is followed exactly, while a single stored point is just the stub
    /// Dirigo writes for a freshly drawn wire and is re-routed cleanly.
    private func routingPoints(
        conn: Connection,
        src: CGPoint,
        dst: CGPoint,
        lane: Double,
        srcMod: PCCModule,
        dstMod: PCCModule,
        srcDrag: CGSize,
        dstDrag: CGSize,
        obstacles: [Int: CGRect]
    ) -> [CGPoint] {
        if conn.points.count >= 2 {
            return [src] + conn.points.map { CGPoint(x: src.x + $0.x, y: src.y + $0.y) } + [dst]
        }
        let srcBottom = srcMod.y + Double(ModuleCardView.cardHeight(for: srcMod)) + srcDrag.height
        let dstBottom = dstMod.y + Double(ModuleCardView.cardHeight(for: dstMod)) + dstDrag.height
        let srcTop = srcMod.y + srcDrag.height
        let dstTop = dstMod.y + dstDrag.height
        // Route around every block except the two this cable joins.
        let others = obstacles.filter { $0.key != conn.outModuleId && $0.key != conn.inModuleId }
            .map(\.value)
        return WireRouter.route(from: src, to: dst, lane: lane,
                               obstacles: others,
                               clearAbove: min(srcTop, dstTop) - 26,
                               clearBelow: max(srcBottom, dstBottom) + 26)
    }

    /// Everything routing depends on, and nothing that a tick changes.
    ///
    /// Hashing this costs a walk of the page's modules and a connection's stored points — arithmetic
    /// against a path search per cable.
    private func routeKey(project: PCCProject, pageModuleIds: Set<Int>) -> Int {
        var hasher = Hasher()
        hasher.combine(model.selectedPage)
        for module in project.modules where pageModuleIds.contains(module.id) {
            hasher.combine(module.id)
            hasher.combine(module.x)
            hasher.combine(module.y)
        }
        for (id, offset) in dragOffsets {
            hasher.combine(id)
            hasher.combine(offset.width)
            hasher.combine(offset.height)
        }
        for conn in project.inConnections {
            hasher.combine(conn.outModuleId)
            hasher.combine(conn.outPinId)
            hasher.combine(conn.inModuleId)
            hasher.combine(conn.inPinId)
            hasher.combine(conn.points.count)
            for point in conn.points {
                hasher.combine(point.x)
                hasher.combine(point.y)
            }
        }
        return hasher.finalize()
    }

    // MARK: - Annotations

    @ViewBuilder
    private func annotations(for project: PCCProject) -> some View {
        // Top-leading aligned, so each object's own top-left corner lands on the node Dirigo stores.
        // The previous version centred a chip at `node + (100, 40)` — an offset with nothing behind
        // it, which put real objects a hundred points away from where they belong.
        ZStack(alignment: .topLeading) {
            ForEach(model.textAnnotations(onPage: model.selectedPage), id: \.index) { entry in
                annotationView(entry.graphic, index: entry.index)
                    .offset(x: entry.graphic.nodes.first?.x ?? 0,
                            y: entry.graphic.nodes.first?.y ?? 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func annotationView(_ graphic: ProjectGraphic, index: Int) -> some View {
        let isSelected = model.selectedAnnotationIndex == index
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
        .onTapGesture(count: 2) { model.beginEditingAnnotation(at: index) }
        .onTapGesture { model.selectedAnnotationIndex = index }
        .contextMenu {
            Button("Edit Text") { model.beginEditingAnnotation(at: index) }
            Button("Delete Text", systemImage: "trash", role: .destructive) {
                model.deleteAnnotation(at: index)
            }
        }
        .help("Text object — double-click to edit")
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 18) {
            ContentUnavailableView {
                Label("No Project Open", systemImage: "cpu")
            } description: {
                Text("Open an existing .pcc project from disk, or create a new diagram to begin simulating.")
            } actions: {
                HStack(spacing: 12) {
                    Button {
                        model.openProjectFile()
                    } label: {
                        Label("Open Project…", systemImage: "folder")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        model.createNewProject()
                    } label: {
                        Label("New Project", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
        }
        .padding(28)
        .glassPanel(cornerRadius: 22)
        .padding(40)
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
    let wires: [CanvasView.RoutedWire]
    /// Called with the connection to remove. The closure is excluded from `==`, like every other
    /// callback in this codebase: it is recreated on each pass and captures nothing that changes.
    var onDelete: ((CanvasView.RoutedWire.Key) -> Void)?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.wires == rhs.wires }

    /// How far either side of a wire still counts as touching it. A 1 pt line is far too thin to
    /// right-click reliably, so the menu hangs off a wide invisible stroke instead of the drawn one.
    private static let hitWidth: CGFloat = 14

    var body: some View {
        ZStack {
            ForEach(wires, id: \.key) { wire in
                Self.path(for: wire).stroke(
                    wire.isHigh ? Theme.wireLive : Theme.wireIdle,
                    style: StrokeStyle(
                        lineWidth: wire.isHigh ? max(1.8, wire.width) : max(1.2, wire.width),
                        lineCap: .round,
                        lineJoin: .round,
                        dash: wire.isFeedback ? [5, 4] : []
                    )
                )
                // Invisible, but hit-testable. Drawn after the visible stroke so it wins the hit.
                Self.path(for: wire)
                    .stroke(Color.black.opacity(0.001), lineWidth: Self.hitWidth)
                    .contextMenu {
                        Button("Delete Connection", role: .destructive) { onDelete?(wire.key) }
                    }
            }
        }
    }

    /// Builds the drawn shape for a wire: a polyline with rounded corners.
    nonisolated static func path(for wire: CanvasView.RoutedWire) -> Path {
        Path(WireRouter.roundedPath(wire.points))
    }
}

// MARK: - Grid

/// The drafting grid. Two tiers keep it readable at any zoom: fine cells that fade out as you
/// zoom away, and a coarser ruled grid with dots at its intersections.
public struct CanvasGrid: View {
    public var zoomScale: CGFloat = 1.0
    public var panOffset: CGSize = .zero

    private static let baseStep: CGFloat = 32
    private static let majorEvery = 5

    public init(zoomScale: CGFloat = 1.0, panOffset: CGSize = .zero) {
        self.zoomScale = zoomScale
        self.panOffset = panOffset
    }

    /// The on-screen grid pitch, kept within a legible band by doubling or halving.
    private var step: CGFloat {
        var value = Self.baseStep * max(0.1, zoomScale)
        while value < 14 { value *= 2 }
        while value > 90 { value /= 2 }
        return value
    }

    public var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
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
            let minorOpacity = min(0.055, max(0.014, 0.055 * (pitch - 14) / 40))
            context.stroke(minor, with: .color(Color.primary.opacity(minorOpacity)), lineWidth: 1)
            context.stroke(major, with: .color(Color.primary.opacity(0.085)), lineWidth: 1)

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

            iconButton("arrow.up.left.and.arrow.down.right", help: "Zoom to Fit (⌘9)") {
                model.zoomToFit()
            }
            iconButton("arrow.counterclockwise", help: "Reset to 100% (⌘0)") {
                model.resetZoom()
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
            if type == .magnify || type == .scrollWheel || type == .smartMagnify {
                return self
            }
        }
        return nil
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

        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
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
            let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 12
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
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

/// Routed wire paths, kept for as long as the sheet's geometry is unchanged.
///
/// A reference type on purpose: it lives in `@State` so it survives a body evaluation, and filling it
/// during `body` does not invalidate anything — it is not observable state, just a cache.
@MainActor
final class WireRouteCache {
    private var key: Int?
    private var routes: [String: [CGPoint]] = [:]

    /// Number of paths actually computed, for tests and for anyone profiling this later.
    private(set) var routeCount = 0

    func beginFrame(key: Int) {
        guard self.key != key else { return }
        self.key = key
        routes.removeAll()
    }

    func points(for id: String, _ build: () -> [CGPoint]) -> [CGPoint] {
        if let cached = routes[id] { return cached }
        let made = build()
        routes[id] = made
        routeCount += 1
        return made
    }
}
