# Wirebench project format (`.wbp`)

Wirebench saves its own documents as `.wbp`: a UTF-8 JSON file with a small envelope around the project model. Dirigo's
`.pcc` is now an import and export format only — **Save** never writes it, and **Export Legacy .PCC** is the one path
that does.

## Why JSON

- Projects are small (tens of kilobytes), so readability and diffability cost nothing.
- The app, the command line and any future tool can read it with the JSON support they already have.
- It is a text format like Dirigo's XML, but without the legacy XML's writer quirks, so no byte-exactness is needed
  for normal saves. Byte-exact `.pcc` writing remains a property of the legacy export and its tests.

## Envelope

```json
{
  "format" : "wirebench-project",
  "formatVersion" : 2,
  "project" : { ... }
}
```

- `format` must be `wirebench-project`; a different JSON document is refused with a clear error.
- `formatVersion` is the schema version of `project`. This build reads versions **1 and 2** and refuses other versions
  rather than guessing. Version 2 adds the optional `project.maraflow` object; version 1 files open unchanged.
- The file is pretty-printed with sorted keys and ends with a newline. Sorted keys do not reorder XML attributes:
  attributes are stored as an ordered array of `[name, value]` pairs, so the legacy export reproduces their order.

`project` is the editor's `PCCProject`, including everything the legacy export needs to reproduce a `.pcc`:

- pages, modules (ids, GUIDs, positions, orders, threads, pin values and per-pin attributes), input and parameter
  connections;
- the PLC configuration, graphics, application options and simulation options;
- the raw root attributes, unknown sections, unknown section children, root comments and the legacy writer's
  self-closing-space style;
- an optional `maraflow` object: the verbatim `.mfl` property table (tags, E-Stop rules, graphics, bus ids, wire
  routes, ST code and anything else a future reader learns to interpret). It is absent for native and Dirigo projects.

## Versioning and compatibility

- Unknown keys are ignored when reading, so a later version can add fields without breaking this reader, provided the
  version number stays the same.
- A reader older than the file refuses a newer `formatVersion`; the error names the version.
- Renaming or removing a field, or changing its meaning, is a format change: bump `formatVersion` and add a migration in
  `WirebenchDocument.decode`.

## Opening older files

`.pcc` and `.xml` files still open: the format is detected from the content (a JSON object is a `.wbp`; anything else is
parsed as legacy XML). A legacy document stays readable, but **Save** asks for a `.wbp` destination instead of
overwriting the `.pcc`. The old file remains untouched for Dirigo.

## API

`WirebenchCore`:

- `WirebenchDocument.encode(_:)` / `.decode(_:)` — the bytes and the schema check.
- `WirebenchDocument.looksLikeDocument(_:)` — JSON-object sniff used for extension-less and misnamed files.
- `ProjectFile.read(at:)` — returns a project and `.wirebench`/`.dirigo`; `ProjectFile.write(_:to:)` always writes the
  current format.

The command line uses the same reader/writer, so `info`, `sim`, `blocks`, `build`, `symbols`, `pins` and `profile`
accept either format, while `roundtrip` and `resave` are specifically legacy-XML tools. `st` writes `.wbp`.
