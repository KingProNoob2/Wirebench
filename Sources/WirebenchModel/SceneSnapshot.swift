import Foundation
import WirebenchCore
import WirebenchLibrary

/// Everything a frontend draws for the current page, as plain values. Built from the model and the wire layout, and
/// encoded as JSON by the bridge, so a frontend needs no knowledge of the model's types.
public struct SceneSnapshot: Codable, Sendable {
    public struct Pin: Codable, Sendable {
        public var label: String
        /// The live value; a boolean pin is 0 or 1 with `isBool` set.
        public var value: Double
        public var isBool: Bool
        /// Whether a wire on this page ends at the pin; a frontend draws the pin's stub to the card's edge only then.
        public var connected: Bool = false
    }

    public struct Module: Codable, Sendable {
        public var id: Int
        public var name: String
        public var type: String
        /// The block's category as it reads in the picker, for colouring.
        public var category: String
        public var x: Double
        public var y: Double
        public var w: Double
        public var h: Double
        public var selected: Bool
        public var inPins: [Pin]
        public var paramPins: [Pin]
        public var outPins: [Pin]
        /// The lit segments, for a `Segment` block.
        public var segments: [Bool]
        /// For a `Segment` block, its display's window in the card, `[x, y, w, h]`, and the eight bars placed in the sheet's card coordinates
        /// (`SegmentDisplayLayout`), so every frontend draws the digit the same size and place. Empty for any other block.
        public var segmentWindow: [Double]
        public var segmentBars: [[Double]]
        /// What the card lets a person do: `control` (BoolVar), `slider` (IntVar, LongVar), `pinToggles` (8xDI, a macro's
        /// Inputs) or empty.
        public var interaction: String
        /// A BoolVar's behaviour: `pushButton` or `toggleSwitch`; empty for anything else.
        public var boolMode: String
        /// The top of an IntVar's slider.
        public var sliderMax: Int
        /// The sheet a macro call opens, `*name`; empty for anything else.
        public var macroTarget: String
    }

    private static func interactionName(_ interaction: BlockInteraction) -> String {
        switch interaction {
        case .none: return ""
        case .control: return "control"
        case .slider: return "slider"
        case .pinToggles: return "pinToggles"
        }
    }

    public struct Wire: Codable, Sendable {
        public var outModule: Int
        public var outPin: Int
        public var inModule: Int
        public var inPin: Int
        /// The wire ends on the module's parameter pin `inPin`, not on an input.
        public var inParam: Bool
        public var points: [[Double]]
        /// The route with rounded corners, as an SVG path.
        public var svg: String
        public var high: Bool
        public var feedback: Bool
    }

    /// A rectangle, ellipse or text object on the sheet. Colours are `#rrggbb`; Dirigo's black ink and white paper are
    /// flagged instead (`penInk`, `brushWash`), so the frontend can draw them in its own theme.
    public struct Graphic: Codable, Sendable {
        public var index: Int
        /// `rectangle`, `ellipse` or `text`.
        public var kind: String
        public var x: Double
        public var y: Double
        public var w: Double
        public var h: Double
        public var text: String
        public var pen: String
        public var penInk: Bool
        public var penWidth: Double
        public var brush: String
        public var brushWash: Bool
        public var fontSize: Int
        public var bold: Bool
        public var italic: Bool
        public var fontColor: String
        public var fontInk: Bool
        public var selected: Bool
    }


    /// One Maraflow graphic object on the current page, already resolved for painting.
    public struct MaraflowGraphic: Codable, Sendable {
        public var index: Int
        public var kind: String
        public var x: Double
        public var y: Double
        public var w: Double
        public var h: Double
        public var text: String
        public var stroke: String
        public var fill: String
        public var filled: Bool
        public var strokeWidth: Double
        public var dashed: Bool
        public var ngonSides: Int
        public var fontSize: Int
        /// The object is an indicator and its bound output is high.
        public var active: Bool
        public var indicator: Bool
        public var activeStroke: String
        public var activeFill: String
        public var boundTargetPin: String
        /// A visual button's bound input is currently on.
        public var pressed: Bool
    }

    /// The hidden runtime page behind a Maraflow ST or ladder sheet.
    public struct MaraflowPageInfo: Codable, Sendable {
        public var kind: String
        public var code: String
        public var lines: Int
        public var threadId: Int
        public var order: Int
    }

    /// The user's preferences, which the model remembers between launches.
    public struct Settings: Codable, Sendable {
        public var appearance: String
        public var snapToGrid: Bool
        public var scrollZooms: Bool
        public var optimize: Bool
        /// Distance between pin rows, which a frontend lays its cards out by.
        public var pinPitch: Double
        /// Distance from a card's top to its first pin's centre.
        public var firstPin: Double
        /// How fast simulated time runs, as a multiple of the base pace (1 is 100%), and the steps the speed slider offers.
        public var speed: Double
        public var speedSteps: [Double]
    }

    /// The PLC link: the serial port, and what an upload is doing.
    public struct PageInfo: Codable, Sendable {
        public var caption: String
        public var macro: Bool
        public var count: Int
    }

    public struct Hardware: Codable, Sendable {
        public var connected: Bool
        public var uploading: Bool
        public var port: String
        public var ports: [[String: String]]
        public var status: String
        public var phase: String
        /// 0...1 while an upload runs, else -1.
        public var progress: Double
        public var log: [String]
    }

    public var title: String
    /// The project's file, or empty for one never saved.
    public var file: String
    public var page: String
    public var pages: [String]
    /// Each page with whether it is a macro sheet and how many blocks it holds.
    public var pagesInfo: [PageInfo]
    /// A question the frontend must put to the user, or empty: `unsaved` (save before replacing the project?).
    public var question: String
    /// A file dialog the model has asked for: `open`, `saveAs` or empty.
    public var panel: String
    /// Set once the model has agreed to quit (after an unsaved-changes answer): the frontend should exit.
    public var quit: Bool
    public var modules: [Module]
    public var wires: [Wire]
    public var graphics: [Graphic]
    /// Maraflow's own graphics (signed boxes, buttons, indicators), kept separate from Dirigo's `graphics`.
    public var maraflowGraphics: [MaraflowGraphic]
    /// Its ST/LD page runtime, when the current page is one.
    public var maraflowPage: MaraflowPageInfo?
    public var playing: Bool
    /// False until a project is opened or created; a frontend shows its welcome screen then.
    public var hasProject: Bool
    public var tick: UInt64
    public var hardware: Hardware
    public var settings: Settings
    public var canUndo: Bool
    public var canRedo: Bool
    public var canCopy: Bool
    public var canPaste: Bool
    public var edited: Bool
    /// A message the frontend should show once (a failed open, say); empty when there is none.
    public var alert: String

    private static func pin(_ label: String, _ value: PinValue?) -> Pin {
        guard let value else { return Pin(label: label, value: 0, isBool: false) }
        if case .bool(let flag) = value { return Pin(label: label, value: flag ? 1 : 0, isBool: true) }
        if case .float(let number) = value { return Pin(label: label, value: Double(number), isBool: false) }
        return Pin(label: label, value: Double(value.asInt), isBool: false)
    }

    /// The wire's rounded route as an SVG path (`M`, `L`, `Q`), which Qt's `PathSvg` reads.
    private static func svg(_ points: [CGPoint]) -> String {
        WireRouter.roundedSegments(points).map { segment -> String in
            switch segment {
            case .move(let p): return "M \(p.x) \(p.y)"
            case .line(let p): return "L \(p.x) \(p.y)"
            case .quad(let end, let control): return "Q \(control.x) \(control.y) \(end.x) \(end.y)"
            }
        }.joined(separator: " ")
    }

    /// `$BBGGRR` (Delphi's colour order) as `#rrggbb`, with whether it is black ink or white paper.
    private static func colour(_ markup: String?) -> (hex: String, black: Bool, white: Bool)? {
        guard var digits = markup?.uppercased() else { return nil }
        if digits.hasPrefix("$") { digits.removeFirst() }
        if digits.hasPrefix("0X") { digits.removeFirst(2) }
        guard (6...8).contains(digits.count), let value = UInt64(digits, radix: 16) else { return nil }
        let r = Double(value & 0xFF) / 255, g = Double((value >> 8) & 0xFF) / 255, b = Double((value >> 16) & 0xFF) / 255
        let hex = String(format: "#%02X%02X%02X", Int(value & 0xFF), Int((value >> 8) & 0xFF), Int((value >> 16) & 0xFF))
        return (hex, r < 0.04 && g < 0.04 && b < 0.04, r > 0.96 && g > 0.96 && b > 0.96)
    }

    @MainActor
    static func graphics(of model: AppModel, page: String, drag: [Int: CGSize]) -> [Graphic] {
        (model.project?.graphics ?? []).enumerated().compactMap { index, graphic -> Graphic? in
            guard graphic.page == page else { return nil }
            let selected = model.selectedAnnotationIndex == index || model.selectedAnnotationIndices.contains(index)
            let pen = colour(graphic.penColor)
            let brush = graphic.brushStyle == 1 ? nil : colour(graphic.brushColor)
            let font = colour(graphic.fontColor)
            let offset = drag[index] ?? .zero
            if graphic.isShape, let box = graphic.boundingBox, let kind = graphic.objectKind {
                return Graphic(index: index, kind: kind == .ellipse ? "ellipse" : "rectangle",
                               x: box.x + Double(offset.width), y: box.y + Double(offset.height),
                               w: max(1, box.width), h: max(1, box.height), text: "",
                               pen: pen?.hex ?? "", penInk: pen?.black ?? true, penWidth: Double(graphic.penWidth ?? 1),
                               brush: brush?.hex ?? "", brushWash: brush?.white ?? false,
                               fontSize: 0, bold: false, italic: false, fontColor: "", fontInk: true, selected: selected)
            }
            if let text = graphic.text, let node = graphic.nodes.first {
                return Graphic(index: index, kind: "text", x: node.x, y: node.y, w: 0, h: 0, text: text,
                               pen: "", penInk: true, penWidth: 0, brush: "", brushWash: false,
                               fontSize: graphic.fontSize ?? 12, bold: graphic.fontBold ?? false,
                               italic: graphic.fontItalic ?? false, fontColor: font?.hex ?? "", fontInk: font?.black ?? true,
                               selected: selected)
            }
            return nil
        }
    }

    private static func maraflowColour(_ value: Int) -> String {
        let rgb = UInt32(bitPattern: Int32(value)) & 0xFF_FFFF
        return String(format: "#%02X%02X%02X", (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF)
    }

    @MainActor
    static func maraflowGraphics(of model: AppModel, page: String) -> [MaraflowGraphic] {
        guard let project = model.project, let extras = project.maraflow,
              let pageIndex = project.pages.firstIndex(where: { $0.caption == page }) else { return [] }
        return extras.graphics(onPageIndex: pageIndex).enumerated().map { index, graphic in
            let kind = graphic.kind.uppercased()
            let active = graphic.indicatorEnabled && !graphic.indicatorPin.isEmpty
                && model.maraflowBooleanValue(graphic.indicatorPin)
            var pressed = false
            if kind == "VISUAL_BUTTON", !graphic.boundTargetPin.isEmpty,
               let binding = model.maraflowBinding(graphic.boundTargetPin, output: false),
               let node = model.getNode(id: binding.moduleId), binding.pinIndex < node.block.inPins.count {
                pressed = node.block.inPins[binding.pinIndex].asBool
            }
            let x1 = Double(graphic.gridX) * 32, y1 = Double(graphic.gridY) * 32
            let x2 = Double(graphic.gridX + graphic.gridW) * 32
            let y2 = Double(graphic.gridY + graphic.gridH) * 32
            let isLine = kind == "LINE", isText = kind == "TEXT"
            return MaraflowGraphic(
                index: index, kind: kind,
                x: isLine || isText ? x1 : min(x1, x2),
                y: isLine || isText ? y1 : min(y1, y2),
                w: isLine ? Double(graphic.gridW * 32) : max(32, abs(x2 - x1)),
                h: isLine ? Double(graphic.gridH * 32) : max(32, abs(y2 - y1)),
                text: graphic.text,
                stroke: maraflowColour(graphic.strokeRgb),
                fill: maraflowColour(graphic.indicatorEnabled ? graphic.indicatorInactiveColor : graphic.fillRgb),
                filled: graphic.filled,
                strokeWidth: Double(max(1, graphic.strokeWidth)),
                dashed: graphic.dashed,
                ngonSides: max(3, graphic.ngonSides),
                fontSize: graphic.fontSize,
                active: active,
                indicator: graphic.indicatorEnabled && !graphic.indicatorPin.isEmpty,
                activeStroke: maraflowColour(graphic.strokeRgb),
                activeFill: maraflowColour(graphic.indicatorEnabled ? graphic.indicatorActiveColor : 0x76D7C4),
                boundTargetPin: graphic.boundTargetPin,
                pressed: pressed)
        }
    }

    @MainActor
    static func maraflowPage(of model: AppModel, page: String) -> MaraflowPageInfo? {
        guard let project = model.project,
              let module = project.modules.first(where: { $0.page == page &&
                  ($0.guid == MaraflowStPage.guid || $0.guid == MaraflowLdPage.guid) }) else { return nil }
        let code = module.rawAttributes["MARAFLOW_ST_CODE"] ?? ""
        return MaraflowPageInfo(kind: module.guid == MaraflowStPage.guid ? "Structured Text" : "Ladder",
                                code: code,
                                lines: code.split(separator: "\n", omittingEmptySubsequences: false).count,
                                threadId: module.threadId, order: module.order)
    }

    @MainActor
    public static func make(of model: AppModel, layout: WireLayout,
                            dragOffsets: [Int: CGSize] = [:], graphicDrag: [Int: CGSize] = [:], quit: Bool = false) -> SceneSnapshot {
        let project = model.project
        let page = model.selectedPage
        let onPage = project?.modules.filter { $0.page == page && !BlockRole.isMaraflowPageRuntime($0) } ?? []
        let ids = Set(onPage.map(\.id))
        let byId = Dictionary((project?.modules ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let wires: [Wire] = project.map { project in
            layout.wires(project: project, selectedPage: page, snapToGrid: model.snapToGrid,
                         pageModuleIds: ids, modulesById: byId, dragOffsets: dragOffsets, snapshots: model.snapshots)
                .map { wire in
                    Wire(outModule: wire.key.outModule, outPin: wire.key.outPin,
                         inModule: wire.key.inModule, inPin: wire.key.inPin, inParam: wire.key.inParam,
                         points: wire.points.map { [Double($0.x), Double($0.y)] },
                         svg: Self.svg(wire.points),
                         high: wire.isHigh, feedback: wire.isFeedback)
                }
        } ?? []

        // Which pins have a wire, so a card draws a stub only where there is one.
        let wiredOut = Set(wires.map { "\($0.outModule).\($0.outPin)" })
        let wiredIn = Set(wires.filter { !$0.inParam }.map { "\($0.inModule).\($0.inPin)" })
        let wiredParam = Set(wires.filter(\.inParam).map { "\($0.inModule).\($0.inPin)" })
        func marked(_ pins: [Pin], _ wired: Set<String>, of id: Int) -> [Pin] {
            pins.enumerated().map { index, pin in var copy = pin; copy.connected = wired.contains("\(id).\(index)"); return copy }
        }

        let modules = onPage.map { module -> Module in
            let live = model.snapshots[module.id]
            let inPins = module.inPins.indices.map { i in
                pin(ModulePinCatalog.inputPinLabel(for: module, index: i),
                    live.flatMap { $0.inValues.indices.contains(i) ? $0.inValues[i] : nil } ?? module.inPins[i].value)
            }
            let paramPins = module.paramPins.indices.map { i in
                pin(ModulePinCatalog.paramPinLabel(for: module, index: i),
                    live.flatMap { $0.paramValues.indices.contains(i) ? $0.paramValues[i] : nil } ?? module.paramPins[i].value)
            }
            let outPins = module.outPins.indices.map { i in
                pin(ModulePinCatalog.outputPinLabel(for: module, index: i),
                    live.flatMap { $0.outValues.indices.contains(i) ? $0.outValues[i] : nil } ?? module.outPins[i].value)
            }
            let window = CardGeometry.segmentWindow(for: module)
            let display = window.map { SegmentDisplayLayout.fitting($0.size) }
            return Module(
                id: module.id, name: module.name,
                type: BlockTypeCatalog.info(forGuid: module.guid)?.blockName ?? "",
                category: BlockPaletteSearch.displayName(for: BlockTypeCatalog.info(forGuid: module.guid)?.category ?? ""),
                x: module.x + Double(dragOffsets[module.id]?.width ?? 0),
                y: module.y + Double(dragOffsets[module.id]?.height ?? 0),
                w: Double(CardGeometry.cardWidth(for: module)), h: Double(CardGeometry.cardHeight(for: module)),
                selected: model.selectedModuleId == module.id || model.selectedModuleIds.contains(module.id),
                inPins: marked(inPins, wiredIn, of: module.id), paramPins: marked(paramPins, wiredParam, of: module.id),
                outPins: marked(outPins, wiredOut, of: module.id),
                segments: live?.segments ?? [],
                segmentWindow: window.map { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) } ?? [],
                segmentBars: (display?.barsInWindow ?? []).map { rect in
                    [rect.minX + (window?.minX ?? 0), rect.minY + (window?.minY ?? 0), rect.width, rect.height].map(Double.init)
                },
                interaction: Self.interactionName(BlockInteraction.classify(module)),
                boolMode: BlockRole.boolVarMode(of: module).map { $0 == .pushButton ? "pushButton" : "toggleSwitch" } ?? "",
                sliderMax: BlockRole.sliderMax(of: module),
                macroTarget: MacroCalls.target(of: module).map { "*" + $0 } ?? "")
        }

        return SceneSnapshot(
            title: model.projectTitle, file: model.currentFileURL?.path ?? "", page: page, pages: project?.pages.map(\.caption) ?? [],
            pagesInfo: (project?.pages ?? []).map { page in
                PageInfo(caption: page.caption, macro: page.caption.hasPrefix("*"),
                         count: project?.modules.filter { $0.page == page.caption && !BlockRole.isMaraflowPageRuntime($0) }.count ?? 0)
            },
            question: model.pendingUnsavedIntent != nil ? "unsaved" : "",
            panel: { switch model.pendingFilePanel { case .open: return "open"; case .saveAs: return "saveAs"; default: return "" } }(),
            quit: quit,
            modules: modules, wires: wires, graphics: graphics(of: model, page: page, drag: graphicDrag),
            maraflowGraphics: maraflowGraphics(of: model, page: page), maraflowPage: maraflowPage(of: model, page: page),
            playing: model.isPlaying, hasProject: model.project != nil, tick: model.tickCount,
            hardware: Hardware(
                connected: model.isHardwareConnected, uploading: model.isUploading, port: model.selectedPortPath,
                ports: model.availablePorts.map { ["path": $0.path, "name": $0.name] },
                status: model.uploadStatus, phase: model.uploadPhase, progress: model.uploadProgress ?? -1,
                log: model.uploadLog.suffix(200).map(\.text)),
            settings: Settings(appearance: model.appearance.rawValue, snapToGrid: model.snapToGrid,
                               scrollZooms: model.scrollZooms, optimize: model.optimizeProgram,
                               pinPitch: Double(CardGeometry.pinPitch),
                               firstPin: Double(CardGeometry.Metrics.firstPinCentre),
                               speed: model.simulationSpeed, speedSteps: AppModel.speedSteps),
            canUndo: model.canUndo, canRedo: model.canRedo, canCopy: model.canCopy, canPaste: model.canPaste, edited: model.isDocumentEdited,
            alert: model.pendingAlert.map { "\($0.title): \($0.message)" } ?? "")
    }
}
