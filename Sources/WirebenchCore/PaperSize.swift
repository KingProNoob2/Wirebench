import Foundation

/// The fixed workspace rectangle Dirigo gives a project.
///
/// Dirigo's **File ▸ Paper size** ("Velikost papíru") sets "the size of the graphical part of the
/// project window, which represents one printed page" — a *fixed* sheet, unlike the free-scrolling
/// canvas this reimplementation started with. The chosen size is stored on the project root as
/// `PAGESIZE`.
///
/// ## How `PAGESIZE` is decoded
///
/// **Superseded in part (2026-11-06, from the decompilation; see `docs/port-status.md`).** `PAGESIZE` is the `Tag` of the File ▸ Paper Size item: 8 = A4,
/// 7 = A3, 63 = A2, 50 = A4 Extra, 60 = **A3 Extra**, and the sheet is the printer's printable area for that paper, not a width in 5 mm units. The
/// decoding below (42/47/60/65/84, with 60 called A3) was inferred before that was known: its labels are wrong, 60 and the 7 units/mm still give a sheet
/// that fits the corpus, and a file with 7, 8, 50 or 63 falls through to the default. Left as it is until the margins and units are decoded.
///
/// Dirigo offers five sheet sizes — A4, A4 Extra, A3, A3 Extra and A2. `PAGESIZE` stores a *single*
/// integer, which is only possible because every one of those has the same aspect ratio: the number
/// encodes the width, and the height follows the ISO A-series ratio.
///
/// The encoding is the width in **5 mm units**, rounded up: A4 = ceil(210/5) = 42, A4 Extra = 47,
/// A3 = ceil(297/5) = **60**, A3 Extra = 65, A2 = 84. `PAGESIZE="60"` in the sample projects
/// therefore reads as **A3**, and the sizes land on the five choices Dirigo actually offers with no
/// gaps or collisions — which is what makes this more than a guess. (The 2023 changelog records the
/// default for a *new* project moving to A3 Extra, i.e. 60 -> 65.)
///
/// A canvas unit is 1/7 mm: **7 units per millimetre**.
///
/// ## How this is pinned down, and why the earlier value was wrong
///
/// It used to be 5 units/mm, leaving `PAGESIZE=60` a 1485 x 2100 sheet. That is **smaller than real
/// Dirigo content**, so it was not cosmetic after all: `prepareForDirigo` scales a layout that its
/// sheet cannot hold, and at 5 units/mm **18 of the 24 `.pcc` files on this machine were rewritten on
/// export** — `had.pcc`, both `kostička`s, `ruleta_kostka_had.pcc`, all three `AHOJ`s and more — moved
/// and scaled to 82-87% for no reason a user could see. The claim that a wrong reading was harmless was
/// wrong because the reader only feeds the *drawing*, while the exporter also uses it to decide
/// whether a layout "fits".
///
/// The value comes from the content itself. Across all 24 projects the greatest extent is x=1692, and
/// an export must leave a layout alone when `maxX + card + margin <= width`; at 297 mm wide that needs
/// **>= 6.27 units/mm**. At 7.0 no project on disk is touched; at 6.0 one still is.
///
/// 7.0 is the value that also comes out exactly: Dirigo's A3 sheet is an integer number of units wide,
/// and 7 x 297 = 2079 is the smallest multiple of 297 that clears the 1862-unit requirement — whereas
/// 5 x 297 = 1485 is demonstrably too small to be what Dirigo uses.
///
/// This value is only ever used to *draw* the sheet, to keep modules on it, and to decide whether an
/// export has to move anything. It is never written to the file — `PAGESIZE` is preserved verbatim on
/// save — so it cannot break compatibility, but it *can* silently rearrange someone's schematic, which
/// is what the old value did.
public enum PaperSize {
    /// Canvas units per millimetre. See the note above on how this is pinned down.
    public static let unitsPerMillimetre: Double = 7.0

    /// The sheet for a given `PAGESIZE` value, in canvas units.
    public static func sheet(forPageSize value: Int) -> CGSize {
        // Nominal width in millimetres; height follows the ISO A-series ratio (1 : sqrt(2)).
        let widthMM: Double
        switch value {
        case 42: widthMM = 210      // A4
        case 47: widthMM = 235      // A4 Extra
        case 60: widthMM = 297      // A3 — what the sample projects use
        case 65: widthMM = 322      // A3 Extra, Dirigo's default for new projects
        case 84: widthMM = 420      // A2
        default: widthMM = 297      // unrecognised: fall back to the sample projects' sheet
        }
        return size(widthMM: widthMM)
    }

    private static func size(widthMM: Double) -> CGSize {
        let width = widthMM * unitsPerMillimetre
        return CGSize(width: width, height: width * (420.0 / 297.0))
    }

    /// The usable sheet for a project: the nominal paper size, grown if the project already has
    /// content outside it.
    ///
    /// Growing rather than clamping matters: a file written by a Dirigo configuration we have
    /// mis-sized must still open with every module reachable (and must never be silently moved on
    /// save).
    public static func usableSheet(for project: PCCProject) -> CGSize {
        var sheet = sheet(forPageSize: project.pageSize)
        var maxX: Double = 0
        var maxY: Double = 0
        for module in project.modules {
            maxX = max(maxX, module.x + 140)
            maxY = max(maxY, module.y + 160)
        }
        for graphic in project.graphics {
            for node in graphic.nodes {
                maxX = max(maxX, node.x + 60)
                maxY = max(maxY, node.y + 60)
            }
        }
        sheet.width = max(sheet.width, CGFloat(maxX) + 80)
        sheet.height = max(sheet.height, CGFloat(maxY) + 80)
        return sheet
    }
}

// MARK: - Exporting for the original Dirigo

/// The result of preparing an unlimited-workspace project for the original Dirigo.
public struct DirigoExport {
    /// A project whose geometry fits Dirigo's sheet, ready to serialise.
    public var project: PCCProject
    /// Human-readable notes about anything that had to be moved or scaled.
    public var adjustments: [String]
    /// Set when the layout could not be made to fit at a usable scale.
    public var warning: String?

    public var fitsWithoutChanges: Bool { adjustments.isEmpty && warning == nil }
}

public extension PaperSize {
    /// Margin left around the layout when it is moved onto the sheet.
    static let exportMargin: Double = 20

    /// Nominal size of a block, used only to bound the layout. The real card is sized from its pin
    /// count, which lives in the app layer; this is the largest one it produces.
    static let nominalModuleExtent = CGSize(width: 150, height: 200)

    /// Prepares a project for the original Dirigo.
    ///
    /// This editor deliberately allows an unlimited workspace, which Dirigo does not: it gives a
    /// project one fixed A3 sheet. Exporting therefore has to reconcile the two, and it does so in
    /// the least destructive order available:
    ///
    /// 1. If the layout already fits, nothing is touched beyond pinning `PAGESIZE`.
    /// 2. Otherwise it is **translated** so its bounding box starts at the sheet margin. Moving a
    ///    schematic does not change it, so this is always preferred.
    /// 3. Only if it still overflows is it **scaled down** uniformly — the last resort, because it
    ///    changes how the drawing reads. The scale is reported so the user can undo it by hand.
    ///
    /// - Parameter extent: the size of a block in Dirigo, which is fixed: a block does not shrink when the layout is scaled, only the distances
    ///   between blocks do. It is how far the block reaches right and down of its position, so that the bounding box and the scale use what is
    ///   really on the sheet. The default is a bound on any block; the app passes each block's own.
    static func prepareForDirigo(_ project: PCCProject, extent: (PCCModule) -> CGSize = { _ in nominalModuleExtent }) -> DirigoExport {
        var output = project
        var adjustments: [String] = []
        var warning: String?

        // Dirigo's sheet, and the only paper size its floor actually supports (A2 and the rest do
        // not lay out correctly there).
        output.pageSize = 60
        let sheet = sheet(forPageSize: 60)
        let usable = CGSize(width: sheet.width - 2 * exportMargin,
                            height: sheet.height - 2 * exportMargin)

        // Bounding box of everything that is positioned.
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        func include(_ x: Double, _ y: Double) {
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }
        for module in output.modules { include(module.x, module.y) }
        for graphic in output.graphics {
            for node in graphic.nodes { include(node.x, node.y) }
        }
        guard minX <= maxX else {
            return DirigoExport(project: output, adjustments: [], warning: nil)   // nothing to place
        }

        // A card extends beyond its module's origin, and does so at a fixed size: the bounding box has to account for that or a block on the
        // edge would be judged to fit when it does not.
        let sizes = Dictionary(output.modules.map { ($0.id, extent($0)) }, uniquingKeysWith: { first, _ in first })
        var reachRight = -Double.greatestFiniteMagnitude, reachDown = -Double.greatestFiniteMagnitude
        for module in output.modules {
            let size = sizes[module.id] ?? nominalModuleExtent
            reachRight = max(reachRight, module.x + size.width)
            reachDown = max(reachDown, module.y + size.height)
        }
        for graphic in output.graphics {
            for node in graphic.nodes { reachRight = max(reachRight, node.x); reachDown = max(reachDown, node.y) }
        }
        let width = reachRight - minX
        let height = reachDown - minY

        // Already on the sheet? Then leave the composition exactly as the user arranged it.
        let alreadyOnSheet = minX >= 0 && minY >= 0
            && reachRight <= Double(sheet.width) - exportMargin
            && reachDown <= Double(sheet.height) - exportMargin
        if alreadyOnSheet {
            return DirigoExport(project: output, adjustments: [], warning: nil)
        }

        // Only the distances between blocks shrink: a block keeps its size. So the scale is the largest at which every block, at its scaled
        // position and its own size, is still inside the margins — not the one that would shrink the blocks with the layout, which left the
        // outermost ones hanging over the sheet's edge.
        var scale = 1.0
        if width > usable.width || height > usable.height {
            var fit = 1.0
            for module in output.modules {
                let size = sizes[module.id] ?? nominalModuleExtent
                let across = module.x - minX, down = module.y - minY
                if across > 0 { fit = min(fit, max(0, usable.width - size.width) / across) }
                if down > 0 { fit = min(fit, max(0, usable.height - size.height) / down) }
            }
            for graphic in output.graphics {
                for node in graphic.nodes {
                    if node.x - minX > 0 { fit = min(fit, usable.width / (node.x - minX)) }
                    if node.y - minY > 0 { fit = min(fit, usable.height / (node.y - minY)) }
                }
            }
            scale = max(fit, 0.01)
            adjustments.append(String(format: "Layout scaled to %.0f%% to fit an A3 sheet.", scale * 100))
            if scale < 0.5 {
                warning = "This schematic is far larger than one A3 page; at this scale it will be "
                    + "hard to read. Consider splitting it across pages before exporting."
            }
        }

        let dx = exportMargin - minX * scale
        let dy = exportMargin - minY * scale
        if scale == 1.0 {
            adjustments.append("Layout moved onto the sheet (Dirigo pages start at the top left).")
        }
        if true {
            for i in output.modules.indices {
                output.modules[i].x = output.modules[i].x * scale + dx
                output.modules[i].y = output.modules[i].y * scale + dy
            }
            for g in output.graphics.indices {
                for n in output.graphics[g].nodes.indices {
                    output.graphics[g].nodes[n].x = output.graphics[g].nodes[n].x * scale + dx
                    output.graphics[g].nodes[n].y = output.graphics[g].nodes[n].y * scale + dy
                }
            }
            // Wire routes are stored as offsets from the source pin, so they scale too.
            for i in output.inConnections.indices {
                for p in output.inConnections[i].points.indices {
                    output.inConnections[i].points[p].x *= scale
                    output.inConnections[i].points[p].y *= scale
                }
            }
            for i in output.paramConnections.indices {
                for p in output.paramConnections[i].points.indices {
                    output.paramConnections[i].points[p].x *= scale
                    output.paramConnections[i].points[p].y *= scale
                }
            }
        }

        return DirigoExport(project: output, adjustments: adjustments, warning: warning)
    }
}

// MARK: - Resetting stored wire routes

public extension PCCProject {
    /// Collapses hand-drawn wire routes back to Dirigo's default single point, on one page.
    ///
    /// Mirrors Dirigo's own *Default points* command. A route built from the default single point is
    /// re-routed cleanly by the editor, whereas a route with two or more points is followed exactly
    /// — so this is how a wire that was dragged out of shape gets tidied up. The stored point is
    /// left as the file already uses it: Dirigo's writers are inconsistent about the value (30, 56,
    /// 70, ... across the sample projects), so the most common one *on this page* is reused rather
    /// than inventing a number.
    ///
    /// - Returns: how many connections were reset.
    @discardableResult
    mutating func resetWireRouting(onPage page: String) -> Int {
        let pageIds = Set(modules.filter { $0.page == page }.map(\.id))
        let indices = inConnections.indices.filter {
            pageIds.contains(inConnections[$0].outModuleId)
                && pageIds.contains(inConnections[$0].inModuleId)
        }

        var occurrences: [Double: Int] = [:]
        for i in indices where inConnections[i].points.count == 1 {
            occurrences[inConnections[i].points[0].x, default: 0] += 1
        }
        // Most frequent, ties broken towards the smaller offset so the result is deterministic.
        let defaultX = occurrences
            .sorted { ($0.value, -$0.key) > ($1.value, -$1.key) }
            .first?.key ?? 30

        var reset = 0
        for i in indices where inConnections[i].points.count > 1 {
            inConnections[i].points = [RoutePoint(x: defaultX, y: 0)]
            reset += 1
        }
        return reset
    }

    /// Connections on `page` that carry a hand-drawn route.
    func handRoutedConnectionCount(onPage page: String) -> Int {
        let pageIds = Set(modules.filter { $0.page == page }.map(\.id))
        return inConnections.filter {
            $0.points.count > 1 && pageIds.contains($0.outModuleId) && pageIds.contains($0.inModuleId)
        }.count
    }
}

// MARK: - Deleting blocks

public extension PCCProject {
    /// Deletes a block and every connection that referred to it.
    ///
    /// The connections have to go with the block. A `<CONNECTION>` whose `IN_MODULE_ID` or
    /// `OUT_MODULE_ID` names a module that no longer exists still *parses* — both here and in
    /// Dirigo — but it is a wire to nowhere, and it would be silently resurrected as a stray cable
    /// if a later block happened to reuse the id.
    ///
    /// - Returns: how many connections were removed, or `nil` if there was no such block.
    @discardableResult
    mutating func deleteModule(id: Int) -> Int? {
        guard modules.contains(where: { $0.id == id }) else { return nil }

        modules.removeAll { $0.id == id }

        let before = inConnections.count + paramConnections.count
        inConnections.removeAll { $0.outModuleId == id || $0.inModuleId == id }
        paramConnections.removeAll { $0.outModuleId == id || $0.inModuleId == id }
        return before - (inConnections.count + paramConnections.count)
    }

    /// Every module id referenced by a connection but not present in `modules`.
    ///
    /// Used to check that an edit has not left the document referring to a block that is gone.
    func danglingConnectionCount() -> Int {
        let ids = Set(modules.map(\.id))
        return (inConnections + paramConnections).filter {
            !ids.contains($0.outModuleId) || !ids.contains($0.inModuleId)
        }.count
    }
}
