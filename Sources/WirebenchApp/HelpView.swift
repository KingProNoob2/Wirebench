import SwiftUI
import WirebenchModel

/// The block reference: a searchable list of every block and a page for the one chosen, from Dirigo's library manual, in English or Czech.
/// What is shown and in which language lives in `HelpModel`, which the Qt app draws as well; this is only its SwiftUI face.
struct HelpView: View {
    @Bindable var help: HelpModel

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 360)
            page
                .frame(minWidth: 420, maxWidth: .infinity)
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 480, idealHeight: 640)
    }

    // MARK: - The list

    private var list: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                TextField(help.strings.search, text: $help.query)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $help.language) {
                    ForEach(HelpLanguage.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(10)
            Divider()
            let sections = help.sections
            if sections.isEmpty {
                Text(help.strings.noResults).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $help.selected) {
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.entries) { entry in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.name)
                                    Text(entry.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .tag(entry.name)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    // MARK: - A page

    @ViewBuilder
    private var page: some View {
        if let entry = help.entry {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(entry)
                    if help.isFallback {
                        Label(help.strings.notTranslated, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    }
                    pinTable(entry)
                    if !entry.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(help.strings.notes).font(.headline)
                            ForEach(Array(entry.notes.enumerated()), id: \.offset) { _, note in
                                Text(note).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    ForEach(Array(entry.tables.enumerated()), id: \.offset) { _, table in
                        tableView(table)
                    }
                    Text(help.strings.source).font(.caption).foregroundStyle(.tertiary)
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        } else if let selected = help.selected {
            ContentUnavailableView(selected, systemImage: "questionmark.circle", description: Text(help.strings.noPage))
        } else {
            ContentUnavailableView(help.strings.title, systemImage: "book", description: Text(help.strings.pickABlock))
        }
    }

    private func header(_ entry: HelpEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.name).font(.largeTitle.weight(.semibold))
            Text(entry.title).font(.title3)
            Text(entry.group.isEmpty ? entry.category : "\(entry.category) › \(entry.group)").font(.callout).foregroundStyle(.secondary)
            if !entry.formula.isEmpty {
                Text(entry.formula).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).padding(.top, 2)
            }
        }
    }

    private func pinTable(_ entry: HelpEntry) -> some View {
        let s = help.strings
        return VStack(alignment: .leading, spacing: 8) {
            Text(s.pins).font(.headline)
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach([s.abbreviation, s.kind, s.dataType, s.name, s.description, s.defaultValue], id: \.self) {
                        Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                Divider().gridCellColumns(6)
                ForEach(Array(entry.pins.enumerated()), id: \.offset) { _, pin in
                    GridRow {
                        Text(pin.abbreviation).font(.system(.body, design: .monospaced).weight(.medium))
                        Text(s.kind(pin.kind)).foregroundStyle(.secondary)
                        Text(pin.dataType)
                        Text(pin.name)
                        Text(pin.text).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        Text(pin.defaultValue).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func tableView(_ table: HelpTable) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
            GridRow { ForEach(Array(table.head.enumerated()), id: \.offset) { _, h in Text(h).font(.caption.weight(.semibold)).foregroundStyle(.secondary) } }
            Divider().gridCellColumns(max(1, table.head.count))
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, cell in Text(cell).font(.system(.body, design: .monospaced)) } }
            }
        }
    }
}
