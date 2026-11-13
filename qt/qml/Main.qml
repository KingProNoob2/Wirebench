import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import QtQuick.Shapes
import Wirebench

ApplicationWindow {
    id: window
    visible: true
    width: startW > 0 ? startW : 1360
    height: startH > 0 ? startH : 860
    minimumWidth: 560
    minimumHeight: 420
    title: controller.title + (controller.edited ? " — Edited" : "") + " — Wirebench"
    color: AppTheme.window

    property bool showInspector: !startHidden
    // False for the first moments, so the top bar and the welcome panel fade and sharpen in rather than appearing already there.
    property bool ready: false
    property int framesSeen: 0
    // Started once the window has actually drawn a few frames, so the animation is not spent while the window is still being made.
    Connections { target: window; function onFrameSwapped() { if (!window.ready && ++window.framesSeen >= 3) startTimer.start() } }
    Timer { id: startTimer; interval: 150; onTriggered: window.ready = true }
    Timer { running: true; interval: 1200; onTriggered: window.ready = true }     // if no frame is ever reported
    // The top bar can be folded away, leaving a small handle to bring it back; the panels then use the room.
    property bool barCollapsed: false
    property real topEdge: barCollapsed ? 12 : bar.y + bar.height + 12
    Behavior on topEdge { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
    property bool showLibrary: !startHidden
    // A narrow window has no room for both side panels beside the sheet: crossing under 860 px hides the inspector, and under 640
    // the library too. They come back when the window widens again, and the buttons still toggle them either way.
    property int roomLevel: width < 640 ? 2 : (width < 860 ? 1 : 0)
    onRoomLevelChanged: {
        if (startHidden) return
        showInspector = roomLevel < 1
        showLibrary = roomLevel < 2
    }
    property real zoom: 1
    property real panX: 40
    property real panY: 70
    property var wireSel: null           // the wire last clicked: {key, inModule, inPin}; Delete removes it
    property var wireFrom: null          // {module, pin}, while a wire is being drawn
    property point wireTo: Qt.point(0, 0)

    // Centres the page's content in the part of the window the panels leave free, at a zoom that shows all of it.
    function fitToContent() {
        const box = controller.contentBounds()
        const left = showLibrary ? library.x + library.width + 12 : 12
        const right = showInspector ? inspector.width + 24 : 12
        const top = barCollapsed ? 12 : bar.y + bar.height + 12, bottom = 12
        const freeW = Math.max(200, area.width - left - right), freeH = Math.max(150, area.height - top - bottom)
        if (box.w === undefined) { zoom = 1; panX = left + 20; panY = top + 20; return }
        zoom = Math.max(0.25, Math.min(1.4, Math.min(freeW / (box.w + 60), freeH / (box.h + 60))))
        panX = left + (freeW - box.w * zoom) / 2 - box.x * zoom
        panY = top + (freeH - box.h * zoom) / 2 - box.y * zoom
    }
    Connections {
        target: controller
        // The title the view was last fitted for. It starts as the current one: a project given on the command line is fitted by
        // the start-up timer below, and a change of page, which also reports a project change, must not fit again.
        property string lastTitle: controller.title
        function onProjectChanged() {
            if (controller.title !== lastTitle) { lastTitle = controller.title; fitTimer.restart() }
        }
    }
    Timer {
        running: startZoom > 0; interval: 300
        onTriggered: {
            const box = controller.contentBounds()
            const centre = Qt.point(box.x + box.w / 2, box.y + box.h / 2)
            window.zoom = startZoom
            window.panX = area.width / 2 - centre.x * startZoom
            window.panY = area.height / 2 - centre.y * startZoom
            if (startPan !== "") { const d = startPan.split(","); window.panX += parseFloat(d[0]); window.panY += parseFloat(d[1] || "0") }
        }
    }
    // A benchmark: a smooth pan, to see how the sheet draws while it moves.
    property real benchPhase: 0
    NumberAnimation on benchPhase { running: benchPan; from: 0; to: 6.2832; duration: 1500; loops: Animation.Infinite }
    onBenchPhaseChanged: if (benchPan) { panX = 300 + Math.sin(benchPhase) * 200; panY = 160 + Math.cos(benchPhase) * 80 }
    // WIREBENCH_TOGGLE_MS=n flips both panels after n ms (WIREBENCH_START_HIDDEN=1 starts them hidden), to look at the motion.
    // With WIREBENCH_SHOT_AFTER_TOGGLE_MS=d and WIREBENCH_SHOT_PATH, it also saves a picture d ms after the toggle and quits.
    Timer { running: toggleMs > 0; interval: toggleMs
            onTriggered: { window.showLibrary = !window.showLibrary; window.showInspector = !window.showInspector; if (shotAfterToggle > 0) shotTimer.start() } }
    Timer { id: shotTimer; interval: shotAfterToggle
            onTriggered: { controller.saveWindow(window, shotPath); window.allowClose = true; Qt.quit() } }
    // WIREBENCH_SELECT_AT=ms:name selects a block after ms, to look at the selection animation.
    Timer { running: selectAt !== ""; interval: parseInt(selectAt.split(":")[0]) || 1000
            onTriggered: controller.command({cmd: "select", name: selectAt.substring(selectAt.indexOf(":") + 1)}) }
    // WIREBENCH_PAGE_AT=ms:page switches page after ms, to check what the view does.
    Timer { running: pageAt !== ""; interval: parseInt(pageAt.split(":")[0]) || 1000
            onTriggered: controller.command({cmd: "setPage", page: pageAt.substring(pageAt.indexOf(":") + 1)}) }
    Timer { id: fitTimer; interval: 30; running: true; onTriggered: window.fitToContent() }

    function sheetPoint(x, y) { return Qt.point((x - panX) / zoom, (y - panY) / zoom) }
    function zoomAt(factor, cx, cy) {
        const next = Math.max(0.2, Math.min(3, zoom * factor))
        panX = cx - (cx - panX) * next / zoom
        panY = cy - (cy - panY) * next / zoom
        zoom = next
    }
    function setZoomCentred(target) { zoomAt(target / zoom, area.width / 2, area.height / 2) }
    function deleteSelection() {
        if (wireSel) { controller.command({cmd: "disconnect", inModule: wireSel.inModule, inPin: wireSel.inPin, inParam: wireSel.inParam === true}); wireSel = null; return }
        controller.command({cmd: "delete", ids: controller.selectedIds()})
        controller.command({cmd: "deleteGraphic", indices: controller.selectedGraphics()})
    }
    // Opens a small menu of actions at a window position, and remembers what to do with the choice.
    function openContext(entries, at, handler) {
        contextMenu.entries = entries
        contextMenu.handler = handler
        contextMenu.x = Math.min(at.x, window.width - contextMenu.width - 8)
        contextMenu.y = Math.min(at.y, window.height - 40 - entries.length * 34)
        contextMenu.open()
    }
    function addBlock(guid) {
        const left = window.showLibrary ? library.width + 24 : 0
        const right = window.showInspector ? inspector.width + 24 : 0
        const p = sheetPoint(left + (area.width - left - right) / 2, area.height / 2)
        controller.command({cmd: "addBlock", guid: guid, x: Math.round(p.x / 8) * 8, y: Math.round(p.y / 8) * 8})
    }

    // A block dragged out of the library, let go at (x, y) in the window: it lands there, centred on the pointer, unless that is over a panel.
    function dropBlock(guid, x, y) {
        if (x < 0) return
        if (window.showLibrary && x < library.x + library.width + 6) return
        if (window.showInspector && x > window.width - inspector.width - 18) return
        if (y < topEdge - 8) return
        const p = sheetPoint(x, y)
        controller.command({cmd: "addBlock", guid: guid, x: Math.round((p.x - 55) / 8) * 8, y: Math.round((p.y - 24) / 8) * 8})
    }

    // Save in place, or ask where when the project has never been saved.
    function save() {
        if (controller.file === "") saveDialog.open()
        else controller.command({cmd: "save"})
    }

    function addGraphic(cmd, args) {
        const p = sheetPoint(area.width / 2, area.height / 2)
        const spot = Object.assign({cmd: cmd, x: Math.round(p.x / 8) * 8, y: Math.round(p.y / 8) * 8}, args)
        const reply = controller.command(spot)
        if (reply.ok) controller.command({cmd: "selectGraphic", indices: [reply.index]})
    }

    Shortcut { sequences: [StandardKey.New]; onActivated: controller.command({cmd: "new"}) }
    Shortcut { sequences: [StandardKey.Open]; onActivated: controller.command({cmd: "requestOpen"}) }
    Shortcut { enabled: controller.hasProject; sequences: [StandardKey.ZoomIn, "Ctrl+="]; onActivated: window.zoomAt(1.2, area.width / 2, area.height / 2) }
    Shortcut { enabled: controller.hasProject; sequences: [StandardKey.ZoomOut]; onActivated: window.zoomAt(1 / 1.2, area.width / 2, area.height / 2) }
    Shortcut { enabled: controller.hasProject; sequence: "Ctrl+0"; onActivated: window.setZoomCentred(1) }
    Shortcut { enabled: controller.hasProject; sequence: "Ctrl+9"; onActivated: window.fitToContent() }
    Shortcut { enabled: controller.hasProject; sequence: "Ctrl+Shift+T"; onActivated: window.addGraphic("addText", {text: "Text"}) }
    Shortcut { enabled: controller.hasProject; sequences: [StandardKey.Save]; onActivated: window.save() }
    Shortcut { enabled: controller.hasProject; sequences: [StandardKey.SaveAs]; onActivated: saveDialog.open() }
    Shortcut { enabled: controller.hasProject; sequences: [StandardKey.Undo]; onActivated: controller.command({cmd: "undo"}) }
    Shortcut { enabled: controller.hasProject; sequences: [StandardKey.Redo]; onActivated: controller.command({cmd: "redo"}) }
    Shortcut { enabled: controller.hasProject; sequence: "Ctrl+K"; onActivated: { window.showLibrary = true; library.focusSearch() } }
    Shortcut { enabled: controller.hasProject; sequence: "Space"; onActivated: controller.command({cmd: controller.playing ? "pause" : "play"}) }
    Shortcut { enabled: controller.hasProject; sequences: [StandardKey.Copy]; onActivated: controller.command({cmd: "copy"}) }
    Shortcut { enabled: controller.hasProject; sequences: [StandardKey.Cut]; onActivated: controller.command({cmd: "cut"}) }
    Shortcut { enabled: controller.hasProject; sequences: [StandardKey.Paste]; onActivated: controller.command({cmd: "paste"}) }
    // The SwiftUI app's remaining shortcuts (Ctrl here is its ⌘, and Meta its ⌃).
    Shortcut { enabled: controller.hasProject; sequence: "Ctrl+B"; onActivated: buildDialog.show(0) }
    Shortcut { enabled: controller.hasProject; sequence: "Ctrl+Shift+L"; onActivated: { controller.command({cmd: "organize"}); fitTimer.restart() } }
    Shortcut { enabled: controller.hasProject; sequence: "Ctrl+Shift+R"; onActivated: controller.command({cmd: "resetWires"}) }
    Shortcut { enabled: controller.hasProject; sequence: "Meta+Ctrl+R"; onActivated: window.addGraphic("addShape", {kind: "rectangle"}) }
    Shortcut { enabled: controller.hasProject; sequence: "Meta+Ctrl+C"; onActivated: window.addGraphic("addShape", {kind: "ellipse"}) }
    Shortcut { enabled: controller.hasProject; sequence: "Meta+Ctrl+I"; onActivated: window.showInspector = !window.showInspector }
    Shortcut { enabled: controller.hasProject; sequence: "Ctrl+Backspace"; onActivated: controller.command({cmd: "delete", ids: controller.selectedIds()}) }                // Delete Block
    Shortcut { enabled: controller.hasProject; sequence: "Ctrl+Alt+Backspace"; onActivated: controller.command({cmd: "deleteGraphic", indices: controller.selectedGraphics()}) }   // Delete Object
    Shortcut { enabled: controller.hasProject; sequence: "Ctrl+Shift+B"; onActivated: { buildDialog.build(); buildDialog.exportAs("pbd", ".pbd") } }                     // Export Program Binary
    Shortcut { enabled: controller.hasProject; sequence: "Ctrl+Alt+K"; onActivated: plcConfigDialog.open() }                                           // PLC Configuration
    Shortcut { enabled: controller.hasProject; sequence: "Ctrl+Shift+V"; onActivated: { buildDialog.build(); buildDialog.exportAs("dbf", ".dbf") } }                     // Export Program Variables
    Shortcut { enabled: controller.hasProject && !controller.hardware.uploading; sequence: "Ctrl+Shift+U"          // Upload to PLC
               onActivated: { buildDialog.show(1); controller.command({cmd: "upload"}) } }
    Shortcut { sequence: "Ctrl+,"; onActivated: settingsDialog.open() }
    Shortcut { sequences: [StandardKey.HelpContents]; onActivated: helpWindow.open() }                                   // Block Reference (F1; Cmd+? on macOS)
    Shortcut { enabled: controller.hasProject; sequence: "Ctrl+Shift+A"; onActivated: agentWindow.open() }                                              // Agent Panel                                                  // Settings
    Shortcut { enabled: controller.hasProject; sequence: "Ctrl+Shift+E"; onActivated: buildDialog.exportAs("pcc", ".pcc", "-dirigo") }                                              // Export Legacy .PCC

    // The sheet fills the window; panels float over it.
    Item {
        id: area
        anchors.fill: parent
        clip: true
        focus: true
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) {
                window.deleteSelection()
                event.accepted = true
            }
        }

        SheetGrid { anchors.fill: parent; zoom: window.zoom; panX: window.panX; panY: window.panY }

        // The sheet's background: left-drag draws a selection box, middle-drag pans, the wheel zooms (or pans, see Settings).
        MouseArea {
            id: background
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
            property point last
            property point origin
            property bool panning: false
            property bool boxing: false
            onPressed: mouse => {
                area.forceActiveFocus()
                last = Qt.point(mouse.x, mouse.y); origin = last
                // A press on a wire picks it (right-click also offers to delete it); on nothing it clears and starts a box.
                const at = window.sheetPoint(mouse.x, mouse.y)
                const wire = controller.wireAt(at.x, at.y, 8 / window.zoom)
                if (mouse.button === Qt.RightButton) {
                    if (wire.key !== undefined) {
                        window.wireSel = wire
                        controller.command({cmd: "select", ids: []})
                        window.openContext([{id: "deleteWire", icon: "trash", label: "Delete Connection"}], mapToItem(null, mouse.x, mouse.y),
                                           id => { if (id === "deleteWire") window.deleteSelection() })
                    } else {
                        // The empty sheet. The selection stays as it is.
                        window.openContext([{id: "paste", icon: "paste", label: "Paste", hint: "Ctrl+V"},
                                            {id: "add", icon: "search", label: "Add Block…", hint: "Ctrl+K"},
                                            {section: "Sheet"},
                                            {id: "arrange", icon: "arrange", label: "Auto-arrange", hint: "Ctrl+Shift+L"},
                                            {id: "resetWires", icon: "reset", label: "Reset Wire Routing", hint: "Ctrl+Shift+R"},
                                            {id: "fit", icon: "fit", label: "Zoom to Fit", hint: "Ctrl+9"}],
                                           mapToItem(null, mouse.x, mouse.y), id => {
                            if (id === "paste") controller.command({cmd: "paste"})
                            else if (id === "add") { window.showLibrary = true; library.focusSearch() }
                            else if (id === "arrange") { controller.command({cmd: "organize"}); fitTimer.restart() }
                            else if (id === "resetWires") controller.command({cmd: "resetWires"})
                            else if (id === "fit") window.fitToContent()
                        })
                    }
                    return
                }
                if (mouse.button === Qt.LeftButton && wire.key !== undefined) {
                    window.wireSel = wire
                    controller.command({cmd: "select", ids: []})
                    return
                }
                window.wireSel = null
                panning = mouse.button === Qt.MiddleButton
                boxing = !panning
                if (boxing) { marquee.x = mouse.x; marquee.y = mouse.y; marquee.width = 0; marquee.height = 0 }
            }
            onPositionChanged: mouse => {
                if (!(pressedButtons & (Qt.LeftButton | Qt.MiddleButton))) return
                if (panning) {
                    window.panX += mouse.x - last.x
                    window.panY += mouse.y - last.y
                    last = Qt.point(mouse.x, mouse.y)
                } else if (boxing) {
                    marquee.x = Math.min(origin.x, mouse.x); marquee.y = Math.min(origin.y, mouse.y)
                    marquee.width = Math.abs(mouse.x - origin.x); marquee.height = Math.abs(mouse.y - origin.y)
                }
            }
            onReleased: mouse => {
                if (boxing) {
                    if (marquee.width < 4 && marquee.height < 4) {
                        controller.command({cmd: "select", ids: []})          // a plain click on the background clears
                    } else {
                        const a = window.sheetPoint(marquee.x, marquee.y), b = window.sheetPoint(marquee.x + marquee.width, marquee.y + marquee.height)
                        const hit = controller.itemsIn(a.x, a.y, b.x - a.x, b.y - a.y)
                        controller.command({cmd: "selectMany", ids: hit.ids, graphics: hit.graphics})
                    }
                }
                panning = false; boxing = false
                marquee.width = 0; marquee.height = 0
            }
            onWheel: wheel => {
                // The wheel zooms, or pans when that is turned off (Ctrl+wheel then zooms); a trackpad's two-finger scroll
                // arrives as pixel deltas and always pans.
                const zooms = controller.settings.scrollZooms !== false
                if (wheel.modifiers & Qt.ControlModifier || (zooms && wheel.pixelDelta.y === 0)) {
                    window.zoomAt(Math.pow(1.0015, wheel.angleDelta.y), wheel.x, wheel.y)
                } else {
                    window.panX += wheel.pixelDelta.x !== 0 ? wheel.pixelDelta.x : wheel.angleDelta.x / 2
                    window.panY += wheel.pixelDelta.y !== 0 ? wheel.pixelDelta.y : wheel.angleDelta.y / 2
                }
            }
        }

        // The selection box being drawn.
        Rectangle {
            id: marquee
            visible: width > 0 || height > 0
            z: 5
            color: Qt.rgba(AppTheme.accent.r, AppTheme.accent.g, AppTheme.accent.b, 0.12)
            border.width: 1; border.color: AppTheme.accent
        }

        Item {
            id: sheet
            x: window.panX; y: window.panY
            scale: window.zoom
            transformOrigin: Item.TopLeft

            Repeater {
                model: controller.graphics
                delegate: GraphicItem {
                    onPressed: index => controller.command({cmd: "selectGraphic", indices: [index]})
                    onDragging: (index, dx, dy) => controller.command({cmd: "dragGraphic", indices: controller.selectedGraphics().length ? controller.selectedGraphics() : [index], dx: dx, dy: dy})
                    onMoved: (index, dx, dy) => controller.command({cmd: "moveGraphic", indices: controller.selectedGraphics().length ? controller.selectedGraphics() : [index], dx: dx, dy: dy})
                    onResized: (index, w, h) => controller.command({cmd: "resizeShape", index: index, w: w, h: h})
                    onEditRequested: index => { textEditor.index = index; textEditor.open() }
                }
            }

            Repeater { model: controller.wires; delegate: Wire { picked: window.wireSel !== null && window.wireSel.key === model.key } }

            // The cable being drawn: from the output pin to the cursor, snapping to an input pin when the cursor is over one.
            Shape {
                id: pending
                z: 50                       // above the blocks, so the end of the cable and the ring on its pin show
                visible: window.wireFrom !== null
                preferredRendererType: Shape.CurveRenderer
                antialiasing: true
                readonly property var snap: window.wireFrom ? controller.pinAt(window.wireTo.x, window.wireTo.y, "in") : ({})
                readonly property bool snapped: snap.module !== undefined
                readonly property point start: window.wireFrom ? window.wireFrom.at : Qt.point(0, 0)
                readonly property point end: snapped ? Qt.point(snap.x, snap.y) : window.wireTo
                readonly property real turn: end.x > start.x + 36 ? (start.x + end.x) / 2 : start.x + 18
                ShapePath {
                    strokeColor: AppTheme.accent
                    strokeWidth: 2
                    strokeStyle: ShapePath.DashLine
                    dashPattern: [4, 3]
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    joinStyle: ShapePath.RoundJoin
                    startX: pending.start.x; startY: pending.start.y
                    PathLine { x: pending.turn; y: pending.start.y }
                    PathLine { x: pending.turn; y: pending.end.y }
                    PathLine { x: pending.end.x; y: pending.end.y }
                }
            }
            SmoothRect {      // a ring on the input pin the cable would join
                z: 50
                visible: pending.visible && pending.snapped
                x: pending.end.x - 9; y: pending.end.y - 9; width: 18; height: 18; radius: 9
                color: "transparent"; borderWidth: 2; borderColor: AppTheme.accent
            }

            Repeater {
                model: controller.modules
                delegate: BlockCard {
                    onPressed: (id, extend) => controller.command({cmd: "select", ids: [id]})
                    onConfigure: id => configDialog.openFor(id)
                    onContextRequested: (id, at) => {
                        window.wireSel = null
                        // Right-clicking a block that is part of the selection keeps the whole group; one outside it selects just that block.
                        if (controller.selectedIds().indexOf(id) < 0) controller.command({cmd: "select", ids: [id]})
                        const group = controller.selectedIds()
                        const single = group.length === 1
                        const entries = []
                        if (single) entries.push({id: "configure", icon: "gear", label: "Configure…"}, {id: "rename", icon: "text", label: "Rename…"},
                                                 {id: "help", icon: "help", label: "Help for this block"})
                        entries.push({section: "Edit"},
                                     {id: "copy", icon: "copy", label: "Copy", hint: "Ctrl+C"},
                                     {id: "cut", icon: "cut", label: "Cut", hint: "Ctrl+X"},
                                     {id: "paste", icon: "paste", label: "Paste", hint: "Ctrl+V"},
                                     {section: "Block"},
                                     {id: "reset", icon: "reset", label: single ? "Reset State" : "Reset State (" + group.length + ")"},
                                     {id: "delete", icon: "trash", label: single ? "Delete Block" : "Delete " + group.length + " Blocks"})
                        window.openContext(entries, at, choice => {
                            if (choice === "configure") configDialog.openFor(id)
                            else if (choice === "help") helpWindow.showBlock(id)
                            else if (choice === "rename") { renamePrompt.moduleId = id; renamePrompt.text = (controller.inspector.name || ""); renamePrompt.open() }
                            else if (choice === "copy") controller.command({cmd: "copy"})
                            else if (choice === "cut") controller.command({cmd: "cut"})
                            else if (choice === "paste") controller.command({cmd: "paste"})
                            else if (choice === "reset") { for (const g of group) controller.command({cmd: "resetState", module: g}) }
                            else if (choice === "delete") controller.command({cmd: "delete", ids: group})
                        })
                    }
                    onDragging: (id, dx, dy) => {
                        const ids = controller.selectedIds()
                        controller.command({cmd: "drag", ids: ids.indexOf(id) >= 0 ? ids : [id], dx: dx, dy: dy})
                    }
                    onMoved: (id, dx, dy) => {
                        const ids = controller.selectedIds()
                        controller.command({cmd: "move", ids: ids.length > 0 ? ids : [id], dx: dx, dy: dy})
                    }
                    onWireStarted: (id, pin, at, from) => { window.wireFrom = {module: id, pin: pin, at: from}; window.wireTo = at }
                    onWireDragged: at => window.wireTo = at
                    onWireEnded: {
                        const target = controller.pinAt(window.wireTo.x, window.wireTo.y, "in")
                        if (window.wireFrom && target.module !== undefined)
                            controller.command({cmd: "connect", outModule: window.wireFrom.module, outPin: window.wireFrom.pin,
                                                inModule: target.module, inPin: target.pin, inParam: target.param === true})
                        window.wireFrom = null
                    }
                }
            }
        }
    }

    // The blurred sheet the glass panels look onto. One quarter-resolution picture of the sheet is blurred once a frame, by a
    // separable Gaussian (two passes of gauss.frag), and every panel samples a window of the result. The sigma is in texels of
    // that picture: the radius in pixels, divided by the factor it was shrunk by.
    readonly property bool blurActive: gpuRendering && controller.blurEnabled
    readonly property real blurSigmaPx: AppTheme.blurSigma(controller.blurDepth)
    // The blur runs on a shrunken picture, shrunk less for a small radius so it does not look blocky: 1, 2, 4 or 8 times.
    readonly property int blurShrink: blurSigmaPx < 12 ? 1 : (blurSigmaPx < 24 ? 2 : (blurSigmaPx < 48 ? 4 : 8))
    // Under a wide blur the sheet itself need not be drawn at full size either: what it loses is hidden by the blur.
    readonly property real snapshotScale: blurSigmaPx < 24 ? 1 : 0.5
    readonly property size blurTexture: Qt.size(Math.max(1, Math.round(width / blurShrink)), Math.max(1, Math.round(height / blurShrink)))
    readonly property real blurSigmaTexels: blurSigmaPx / blurShrink

    ShaderEffectSource {
        id: sheetSnapshot
        anchors.fill: parent
        opacity: 0.001
        visible: window.blurActive
        sourceItem: area
        // The sheet is drawn at full size with mip levels, so that the first pass, which reads it at a fraction of that size,
        // averages it properly. Drawn straight into a small texture, thin wires and dots alias and shimmer as the sheet moves.
        textureSize: Qt.size(Math.round(window.width * window.snapshotScale), Math.round(window.height * window.snapshotScale))
        mipmap: true
        smooth: true
        live: true
    }
    ShaderEffect {      // horizontal pass
        id: passHorizontal
        width: window.width; height: window.height
        visible: window.blurActive
        property variant source: sheetSnapshot
        property vector2d texel: Qt.vector2d(1 / window.blurTexture.width, 0)
        property real sigma: window.blurSigmaTexels
        fragmentShader: "qrc:/shaders/gauss.frag.qsb"
    }
    ShaderEffectSource {
        id: horizontalSnapshot
        anchors.fill: parent
        opacity: 0.001
        visible: window.blurActive
        sourceItem: passHorizontal
        hideSource: true
        textureSize: window.blurTexture
        format: ShaderEffectSource.RGBA16F      // 8 bits per channel bands once a gradient is blurred
        live: true
    }
    ShaderEffect {      // vertical pass
        id: passVertical
        width: window.width; height: window.height
        visible: window.blurActive
        property variant source: horizontalSnapshot
        property vector2d texel: Qt.vector2d(0, 1 / window.blurTexture.height)
        property real sigma: window.blurSigmaTexels
        fragmentShader: "qrc:/shaders/gauss.frag.qsb"
    }
    ShaderEffectSource {
        id: blurredSheet
        anchors.fill: parent
        opacity: 0.001
        visible: window.blurActive
        sourceItem: passVertical
        hideSource: true
        textureSize: window.blurTexture
        format: ShaderEffectSource.RGBA16F
        smooth: true
        live: true
    }

    // ── Top bar ────────────────────────────────────────────────────────────────────────────────────
    Panel {
        id: bar
        backdrop: blurredSheet
        shown: window.ready && controller.hasProject && !window.barCollapsed     // not on the no-project screen: the welcome panel has the two ways in
        transform: Translate { y: -18 * (1 - bar.progress) }          // drops in from above as it fades
        x: 12; y: 12
        width: parent.width - 24; height: 48
        radius: 14

        // How much of the bar fits: 0 everything, 1 the Inspector without its word, 2 also without the project name. Nothing overlaps at any width: the bar is a layout, and what has no room shrinks or goes.
        readonly property int level: width >= 900 ? 0 : (width >= 700 ? 1 : (width >= 520 ? 2 : 3))
        function word(text) { return level === 0 ? text : "" }

        RowLayout {
            anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
            spacing: 6

            Row {
                id: leftGroup
                spacing: 2
                IconButton { id: menuButton; icon: "menu"; active: mainMenu.opened; property bool wasOpen: false
                    // Decided at the press: by the click the press itself has begun to close the menu, which would otherwise be reopened.
                    onPressedChanged2: down => { if (down) wasOpen = mainMenu.visible || Date.now() - mainMenu.closedAt < 150 }
                    onClicked: wasOpen ? mainMenu.close() : mainMenu.open() }
                IconButton { icon: "sidebar"; enabled: controller.hasProject; active: window.showLibrary; onClicked: window.showLibrary = !window.showLibrary }
                Rectangle { width: 1; height: 20; color: AppTheme.panelStroke; anchors.verticalCenter: parent.verticalCenter }
                IconButton { icon: "undo"; enabled: controller.hasProject && controller.canUndo; onClicked: controller.command({cmd: "undo"}) }
                IconButton { icon: "redo"; enabled: controller.hasProject && controller.canRedo; onClicked: controller.command({cmd: "redo"}) }
            }

            // The project name takes what is left, and is cut with an ellipsis before it can push anything.
            Item {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                Layout.preferredWidth: 120
                visible: bar.level < 2
                implicitHeight: 32
                clip: true
                Row {
                    anchors.centerIn: parent
                    spacing: 6
                    width: Math.min(implicitWidth, parent.width)
                    Text {
                        text: controller.title || "Untitled"
                        color: AppTheme.text; font.pixelSize: 13; font.weight: Font.Bold
                        elide: Text.ElideRight
                        width: Math.min(implicitWidth, parent.parent.width - (controller.edited ? 14 : 0))
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    SmoothRect { visible: controller.edited; width: 7; height: 7; radius: 3.5; color: AppTheme.selection; anchors.verticalCenter: parent.verticalCenter }
                }
            }
            Item { visible: bar.level >= 2; Layout.fillWidth: true }

            // The transport's pill. Its buttons are 32 high with a 8 pt corner; with 3 pt of room around them, a pill whose corner is
            // 3 pt bigger (11) is concentric with them, so a highlighted button follows the pill's curve.
            Rectangle {
                height: 38; Layout.preferredWidth: transport.contentWidth + 6; radius: 11
                color: AppTheme.field
                Row {
                    id: transport
                    anchors.centerIn: parent
                    spacing: 2
                    enabled: controller.hasProject
                    readonly property real contentWidth: childrenRect.width
                    IconButton {
                        icon: controller.playing ? "pause" : "play"
                        accented: !controller.playing
                        active: controller.playing
                        onClicked: controller.command({cmd: controller.playing ? "pause" : "play"})
                    }
                    IconButton { icon: "step"; onClicked: controller.command({cmd: "step"}) }
                    IconButton { icon: "reset"; onClicked: controller.command({cmd: "reset"}) }
                }
            }

            // The page tabs. They take the room that is left, and with more pages than fit the strip scrolls (wheel or drag).
            Flickable {
                id: tabsStrip
                Layout.fillWidth: true
                Layout.minimumWidth: 40
                Layout.maximumWidth: tabsRow.width
                Layout.preferredWidth: tabsRow.width
                implicitHeight: 32
                contentWidth: tabsRow.width
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.HorizontalFlick
                WheelHandler {
                    onWheel: event => tabsStrip.contentX = Math.max(0, Math.min(Math.max(0, tabsStrip.contentWidth - tabsStrip.width),
                        tabsStrip.contentX - (event.angleDelta.x !== 0 ? event.angleDelta.x : event.angleDelta.y) / 2))
                }
                Row {
                    id: tabsRow
                    spacing: 2
                    Repeater {
                        model: controller.pagesInfo
                        delegate: IconButton {
                            required property var modelData
                            label: modelData.caption
                            active: modelData.caption === controller.page
                            onClicked: controller.command({cmd: "setPage", page: modelData.caption})
                            onRightClicked: at => {
                                const page = modelData
                                const entries = [{id: "renamePage", icon: "text", label: page.macro ? "Rename Macro…" : "Rename Page…"},
                                                 {id: "deletePage", icon: "trash", label: page.macro ? "Delete Macro Page" : "Delete Page",
                                                  disabled: controller.pagesInfo.length <= 1}]
                                window.openContext(entries, at, choice => {
                                    if (choice === "renamePage") {
                                        pageRenamePrompt.page = page.caption
                                        pageRenamePrompt.text = page.macro ? page.caption.substring(1) : page.caption
                                        pageRenamePrompt.heading = page.macro ? "Rename macro" : "Rename page"
                                        pageRenamePrompt.open()
                                    }
                                    else if (choice === "deletePage") {
                                        confirm.heading = "Delete " + page.caption + "?"
                                        confirm.message = page.count > 0 ? "Its " + page.count + (page.count === 1 ? " block" : " blocks") + " will be deleted with it." : "The page is empty."
                                        confirm.buttons = [{id: "cancel", label: "Cancel"}, {id: "delete", label: "Delete", role: "accent"}]
                                        confirm.handler = answer => { if (answer === "delete") controller.command({cmd: "deletePage", caption: page.caption}) }
                                        confirm.open()
                                    }
                                })
                            }
                        }
                    }
                    IconButton {
                        icon: "plus"
                        enabled: controller.hasProject
                        onClicked: window.openContext([{id: "page", icon: "open", label: "New Page…"}, {id: "macro", icon: "chip", label: "New Macro Page…"}],
                                                      Qt.point(tabsStrip.mapToItem(null, 0, 0).x, bar.y + bar.height + 6), choice => {
                            pagePrompt.macro = choice === "macro"
                            pagePrompt.heading = choice === "macro" ? "New macro page" : "New page"
                            pagePrompt.text = ""
                            pagePrompt.open()
                        })
                    }
                }
            }

            IconButton { icon: "sparkle"; enabled: controller.hasProject; onClicked: agentWindow.open() }
            IconButton { icon: "sidebar"; label: bar.word("Inspector"); enabled: controller.hasProject; active: window.showInspector; onClicked: window.showInspector = !window.showInspector }
            Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 20; color: AppTheme.panelStroke }
            IconButton { icon: "chevup"; onClicked: window.barCollapsed = true }
        }
    }

    MainMenu {
        id: mainMenu
        parent: Overlay.overlay
        x: bar.x + 10
        y: bar.y + bar.height + 6
        onActivated: id => {
            if (id === "new") controller.command({cmd: "new"})
            else if (id === "open") controller.command({cmd: "requestOpen"})
            else if (id === "resetWires") controller.command({cmd: "resetWires"})
            else if (id === "save") window.save()
            else if (id === "saveAs") saveDialog.open()
            else if (id === "exportPcc") buildDialog.exportAs("pcc", ".pcc", "-dirigo")
            else if (id === "rect") window.addGraphic("addShape", {kind: "rectangle"})
            else if (id === "ellipse") window.addGraphic("addShape", {kind: "ellipse"})
            else if (id === "text") window.addGraphic("addText", {text: "Text"})
            else if (id === "arrange") { controller.command({cmd: "organize"}); fitTimer.restart() }
            else if (id === "build") buildDialog.show(0)
            else if (id === "plc") buildDialog.show(1)
            else if (id === "plcConfig") plcConfigDialog.open()
            else if (id === "settings") settingsDialog.open()
            else if (id === "agent") agentWindow.open()
            else if (id === "help") helpWindow.open()
        }
    }

    // What follows the pointer while a block is dragged out of the library.
    SmoothRect {
        id: dragGhost
        property string label: ""
        parent: Overlay.overlay
        visible: false
        z: 1000
        width: Math.max(110, ghostText.implicitWidth + 28); height: 44; radius: 10
        color: AppTheme.card; borderWidth: 1; borderColor: AppTheme.selection
        opacity: 0.92
        Text { id: ghostText; anchors.centerIn: parent; text: dragGhost.label; color: AppTheme.text; font.pixelSize: 13; font.weight: Font.DemiBold }
    }

    // What is left of the top bar when it is folded away: a small tab at the top edge that brings it back.
    Panel {
        id: barHandle
        backdrop: blurredSheet
        shown: window.ready && controller.hasProject && window.barCollapsed
        transform: Translate { y: -12 * (1 - barHandle.progress) }
        x: (parent.width - width) / 2; y: 6
        width: 64; height: 26; radius: 13
        Icon { anchors.centerIn: parent; name: "chevdown"; color: handleArea.containsMouse ? AppTheme.text : AppTheme.dim }
        MouseArea { id: handleArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: window.barCollapsed = false }
    }

    // With no project open: what the SwiftUI app shows. A panel in the middle of the sheet with the two ways in.
    Panel {
        id: welcome
        backdrop: blurredSheet
        shown: window.ready && !controller.hasProject
        anchors.centerIn: parent
        width: Math.min(420, parent.width - 48); height: welcomeColumn.implicitHeight + 64
        radius: 24
        Column {
            id: welcomeColumn
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
            spacing: 10
            Icon { name: "chip"; size: 44; color: AppTheme.dim; anchors.horizontalCenter: parent.horizontalCenter }
            Item { width: 1; height: 4 }
            Text { text: "No Project Open"; color: AppTheme.text; font.pixelSize: 20; font.weight: Font.Bold; anchors.horizontalCenter: parent.horizontalCenter }
            Text { text: "Open a .wbp project (or a legacy .pcc), or start a new one."; color: AppTheme.dim; font.pixelSize: 13
                   anchors.horizontalCenter: parent.horizontalCenter; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; width: parent.width - 48 }
            Item { width: 1; height: 8 }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 10
                IconButton { label: "New Project"; width: 130; height: 40; onClicked: controller.command({cmd: "new"}) }
                IconButton { label: "Open…"; accented: true; width: 130; height: 40; onClicked: controller.command({cmd: "requestOpen"}) }
            }
        }
    }

    BlockLibrary {
        id: library
        backdrop: blurredSheet
        shown: window.showLibrary && controller.hasProject
        x: 12; y: window.topEdge
        // Narrower windows get narrower panels, so the sheet keeps some room.
        width: Math.min(268, Math.max(190, window.width * 0.36))
        height: parent.height - y - 12
        onPicked: guid => window.addBlock(guid)
        onDragStarted: (guid, name) => { dragGhost.label = name; dragGhost.visible = true }
        onDragMoved: (x, y) => { dragGhost.x = x - dragGhost.width / 2; dragGhost.y = y - dragGhost.height / 2 }
        onDropped: (guid, x, y) => { dragGhost.visible = false; if (guid !== "") window.dropBlock(guid, x, y) }
    }

    Inspector {
        id: inspector
        backdrop: blurredSheet
        shown: window.showInspector && controller.hasProject
        x: parent.width - width - 12; y: window.topEdge
        width: Math.min(300, Math.max(210, window.width * 0.38))
        height: parent.height - y - 12
    }

    // ── Status and zoom ────────────────────────────────────────────────────────────────────────────
    Panel {
        id: zoomBar
        backdrop: blurredSheet
        shown: controller.hasProject
        Behavior on x { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        x: (window.showInspector ? inspector.x : parent.width) - width - 12
        y: parent.height - height - 12
        width: zoomRow.implicitWidth + 12; height: 40
        radius: 12
        Row {
            id: zoomRow
            anchors.centerIn: parent
            spacing: 2
            IconButton { icon: "minus"; onClicked: window.zoomAt(1 / 1.2, area.width / 2, area.height / 2) }
            Item {
                width: 52; height: 32
                Text { anchors.centerIn: parent; text: Math.round(window.zoom * 100) + "%"; color: AppTheme.dim; font.pixelSize: 12 }
                MouseArea {
                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: window.openContext([{id: "fit", icon: "fit", label: "Zoom to Fit", hint: "Ctrl+9"}, {id: "z100", icon: "search", label: "Actual Size 100%", hint: "Ctrl+0"},
                        {section: "Zoom"}, {id: "z200", label: "200%"}, {id: "z150", label: "150%"}, {id: "z125", label: "125%"}, {id: "z100", label: "100%"},
                        {id: "z75", label: "75%"}, {id: "z50", label: "50%"}, {id: "z35", label: "35%"}],
                        mapToItem(null, 0, -330), choice => {
                            if (choice === "fit") window.fitToContent()
                            else if (choice.indexOf("z") === 0) window.setZoomCentred(parseInt(choice.substring(1)) / 100)
                        })
                }
            }
            IconButton { icon: "plus"; onClicked: window.zoomAt(1.2, area.width / 2, area.height / 2) }
            IconButton { icon: "fit"; onClicked: window.fitToContent() }
        }
    }

    Panel {
        backdrop: blurredSheet
        visible: controller.hasProject && x + width + 10 < zoomBar.x
        Behavior on x { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        x: (window.showLibrary ? library.x + library.width : 0) + 12
        y: parent.height - height - 12
        width: statusRow.implicitWidth + 24; height: 32
        radius: 10
        Row {
            id: statusRow
            anchors.centerIn: parent
            spacing: 8
            SmoothRect { width: 8; height: 8; radius: 4; anchors.verticalCenter: parent.verticalCenter
                        color: controller.playing ? AppTheme.live : AppTheme.faint }
            Text { text: (controller.playing ? "Running" : "Stopped") + "  ·  tick " + controller.tick
                   color: AppTheme.dim; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter }
            // Simulation speed in the same steps as the SwiftUI slider; double-click the figure to return to 100%.
            Item {
                id: speedSlider
                readonly property var steps: controller.settings.speedSteps || [1]
                readonly property int index: { let best = 0; for (let i = 0; i < steps.length; ++i) if (Math.abs(steps[i] - (controller.settings.speed || 1)) < Math.abs(steps[best] - (controller.settings.speed || 1))) best = i; return best }
                width: 110; height: 20; anchors.verticalCenter: parent.verticalCenter
                SmoothRect { x: 6; width: parent.width - 12; height: 4; radius: 2; anchors.verticalCenter: parent.verticalCenter; color: AppTheme.field }
                SmoothRect { x: 6; width: (parent.width - 12) * speedSlider.index / Math.max(1, speedSlider.steps.length - 1); height: 4; radius: 2
                            anchors.verticalCenter: parent.verticalCenter; color: AppTheme.selection }
                SmoothRect {
                    x: 6 + (parent.width - 12) * speedSlider.index / Math.max(1, speedSlider.steps.length - 1) - width / 2
                    width: 16; height: 16; radius: 8; anchors.verticalCenter: parent.verticalCenter
                    color: AppTheme.card; borderWidth: 2; borderColor: AppTheme.selection
                }
                MouseArea {
                    anchors.fill: parent
                    function setFrom(mouse) {
                        const i = Math.round(Math.min(Math.max((mouse.x - 6) / (width - 12), 0), 1) * (speedSlider.steps.length - 1))
                        if (i !== speedSlider.index) controller.command({cmd: "setSetting", key: "speed", value: speedSlider.steps[i]})
                    }
                    onPressed: mouse => setFrom(mouse)
                    onPositionChanged: mouse => { if (pressed) setFrom(mouse) }
                }
            }
            Text {
                text: Math.round((controller.settings.speed || 1) * 100) + "%"
                width: 40; horizontalAlignment: Text.AlignRight
                color: AppTheme.dim; font.pixelSize: 12; font.family: "monospace"; anchors.verticalCenter: parent.verticalCenter
                MouseArea { anchors.fill: parent; onDoubleClicked: controller.command({cmd: "setSetting", key: "speed", value: 1}) }
            }
        }
    }

    AgentWindow { id: agentWindow }
    HelpWindow { id: helpWindow }
    ConfigDialog { id: configDialog }
    SettingsDialog { id: settingsDialog }
    PLCConfigDialog { id: plcConfigDialog }
    Popup {
        id: textEditor
        property int index: -1
        // The same motion as the panels, without the blur (a popup has no snapshot of its contents): a fade with a slight grow.
        enter: Transition { ParallelAnimation {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 220; easing.type: Easing.OutCubic }
            NumberAnimation { property: "scale"; from: 0.95; to: 1; duration: 260; easing.type: Easing.OutCubic } } }
        exit: Transition { ParallelAnimation {
            NumberAnimation { property: "opacity"; from: 1; to: 0; duration: 160; easing.type: Easing.InCubic }
            NumberAnimation { property: "scale"; from: 1; to: 0.97; duration: 160; easing.type: Easing.InCubic } } }
        modal: true
        anchors.centerIn: Overlay.overlay
        width: 380; padding: 16
        onOpened: { field.text = controller.graphic(index).text || ""; field.forceActiveFocus(); field.selectAll() }
        Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.35) }
        background: Rectangle { radius: 12; color: AppTheme.card; border.color: AppTheme.panelStroke }
        Column {
            spacing: 10; width: parent.width
            Text { text: "Edit text"; color: AppTheme.text; font.pixelSize: 14; font.weight: Font.Bold }
            Rectangle {
                width: parent.width; height: 34; radius: 9; color: AppTheme.field
                border.width: field.activeFocus ? 2 : 0; border.color: AppTheme.accent
                TextInput {
                    id: field
                    anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                    verticalAlignment: Text.AlignVCenter; color: AppTheme.text; font.pixelSize: 13; selectByMouse: true; clip: true
                    onAccepted: { controller.command({cmd: "editText", index: textEditor.index, text: text}); textEditor.close() }
                }
            }
        }
    }
    BuildDialog { id: buildDialog }
    Timer { running: startDialog === "open"; interval: 400; onTriggered: { openDialog.open() } }
    Component.onCompleted: if (startDialog === "menu") mainMenu.open(); else if (startDialog === "settings") settingsDialog.open(); else if (startDialog === "plcConfig") plcConfigDialog.open(); else if (startDialog === "build") buildDialog.show(0); else if (startDialog === "hardware") buildDialog.show(1); else if (startConfig) { const ids = controller.selectedIds(); if (ids.length) configDialog.openFor(ids[0]) }

    FileDialog {
        id: openDialog
        parentWindow: window
        title: "Open project"
        fileMode: FileDialog.OpenFile
        nameFilters: ["Wirebench projects (*.wbp)", "Dirigo projects (*.pcc *.xml)", "All files (*)"]
        onAccepted: controller.command({cmd: "open", path: controller.localPath(selectedFile)})
    }
    FileDialog {
        id: saveDialog
        title: "Save project as"
        fileMode: FileDialog.SaveFile
        defaultSuffix: "wbp"
        nameFilters: ["Wirebench projects (*.wbp)", "All files (*)"]
        onAccepted: controller.command({cmd: "saveAs", path: controller.localPath(selectedFile)})
        // A save the model asked for (before replacing an unsaved project) that is abandoned abandons what it was gating.
        onRejected: controller.command({cmd: "panelCancelled"})
    }

    // The menu for a right-click on a block, a wire or a page tab, or the zoom readout: the entries and what to do with the choice
    // are set by whoever opens it (openContext).
    MainMenu {
        id: contextMenu
        property var handler: null
        parent: Overlay.overlay
        entries: []
        onActivated: id => { if (handler) handler(id) }
    }

    TextPrompt {
        id: renamePrompt
        property int moduleId: -1
        heading: "Rename block"; accept: "Rename"
        onAccepted2: text => { if (text.trim() !== "") controller.command({cmd: "rename", module: moduleId, name: text.trim()}) }
    }
    TextPrompt {
        id: pagePrompt
        property bool macro: false
        accept: "Create"
        onAccepted2: text => controller.command({cmd: "addPage", caption: text, macro: macro})
    }
    TextPrompt {
        id: pageRenamePrompt
        property string page: ""        // the caption being renamed; a macro's starts with '*'
        heading: "Rename page"; accept: "Rename"
        // The model refuses an empty or taken name, and turns a macro's bare name back into a '*Name' caption.
        onAccepted2: text => { if (text.trim() !== "") controller.command({cmd: "renamePage", caption: page, name: text.trim()}) }
    }

    // A question with answers; whoever opens it sets `handler`.
    ConfirmDialog {
        id: confirm
        property var handler: null
        onAnswered: id => { if (handler) handler(id) }
    }
    // Replacing a project with unsaved changes: the model asks, this is the question.
    ConfirmDialog {
        id: unsavedDialog
        heading: "Do you want to save the changes to this project?"
        message: "Your changes will be lost if you don't save them."
        buttons: [{id: "cancel", label: "Cancel"}, {id: "discard", label: "Don’t Save"}, {id: "save", label: "Save", role: "accent"}]
        onAnswered: id => controller.command({cmd: "answerUnsaved", choice: id})
    }
    // What the model is waiting on the frontend for.
    Connections {
        target: controller
        function onSceneChanged() {
            if (controller.question === "unsaved" && !unsavedDialog.opened) unsavedDialog.open()
            if (controller.panel === "open") { controller.command({cmd: "panelDone"}); openDialog.open() }
            else if (controller.panel === "saveAs") { controller.command({cmd: "panelDone"}); saveDialog.open() }
            if (controller.quitRequested) { window.allowClose = true; Qt.quit() }
        }
    }
    // Closing the window asks first when there is something to lose.
    // (`allowClose` lets the app quit once the model has agreed, and lets the check hooks, which quit from C++, through.)
    property bool allowClose: false
    onClosing: close => { if (allowClose) return; close.accepted = false; controller.command({cmd: "quit"}) }

    // Dropping a project file on the window opens it.
    DropArea {
        anchors.fill: parent
        keys: ["text/uri-list"]
        onDropped: drop => { if (drop.urls.length > 0) controller.command({cmd: "openFile", path: controller.localPath(drop.urls[0])}) }
    }

    Popup {
        id: alertPopup
        // The same motion as the panels, without the blur (a popup has no snapshot of its contents): a fade with a slight grow.
        enter: Transition { ParallelAnimation {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 220; easing.type: Easing.OutCubic }
            NumberAnimation { property: "scale"; from: 0.95; to: 1; duration: 260; easing.type: Easing.OutCubic } } }
        exit: Transition { ParallelAnimation {
            NumberAnimation { property: "opacity"; from: 1; to: 0; duration: 160; easing.type: Easing.InCubic }
            NumberAnimation { property: "scale"; from: 1; to: 0.97; duration: 160; easing.type: Easing.InCubic } } }
        modal: true
        anchors.centerIn: Overlay.overlay
        padding: 20
        background: Rectangle { radius: 14; color: AppTheme.card; border.color: AppTheme.panelStroke }
        Text { text: controller.alert; color: AppTheme.text; font.pixelSize: 13; wrapMode: Text.WordWrap; width: 360 }
        Connections { target: controller; function onSceneChanged() { if (controller.alert !== "") alertPopup.open() } }
    }
}
