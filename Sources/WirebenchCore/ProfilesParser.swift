import Foundation

/// One scheduling thread of a PLC profile.
public struct PLCThreadConfig: Sendable, Codable, Equatable {
    /// 1-based, matching `THREAD_ID` in `.pcc` files.
    public var id: Int
    public var name: String
    public var intervalMs: Int
    public var programSize: Int

    public init(id: Int, name: String, intervalMs: Int, programSize: Int = 0) {
        self.id = id
        self.name = name
        self.intervalMs = intervalMs
        self.programSize = programSize
    }
}

/// One entry of the `[@SystemCommands]` table: what the `SystemCmd` block can be configured to
/// do on a given hardware profile.
public struct SystemCommandInfo: Sendable, Codable, Equatable, Hashable {
    /// Typically a D3Net/RowNet-style mnemonic. Dirigo names these `<FUNCTION>_<CMD>` so that
    /// one command code can appear several times with different arguments.
    public var mnemonic: String
    /// The description shown in the configuration dialog.
    public var title: String
    /// The short label drawn on the block face.
    public var text: String
    /// The raw command word sent to the firmware.
    public var command: UInt16
    public var input1: PinSchema
    public var input2: PinSchema
    public var output: PinSchema

    public init(mnemonic: String, title: String, text: String, command: UInt16,
                input1: PinSchema, input2: PinSchema, output: PinSchema) {
        self.mnemonic = mnemonic
        self.title = title
        self.text = text
        self.command = command
        self.input1 = input1
        self.input2 = input2
        self.output = output
    }

    /// One `I1=` / `I2=` / `O1=` field of the table.
    public struct PinSchema: Sendable, Codable, Equatable, Hashable {
        /// `Int`, `Long` or `Bit`, as written in `Profiles.ini`.
        public var dataType: String
        /// The pin name shown on the block.
        public var name: String
        /// `(Hidden)` parameters exist in the protocol but are not drawn as pins.
        public var isHidden: Bool

        public init(dataType: String, name: String, isHidden: Bool) {
            self.dataType = dataType
            self.name = name
            self.isHidden = isHidden
        }
    }
}

/// A PLC hardware profile from `Profiles.ini`.
public struct PLCProfile: Identifiable, Sendable, Codable, Equatable {
    public var id: String { name }
    public var name: String
    /// `Alias=` if present — the name Dirigo displays.
    public var alias: String?
    /// `BaseProfile=` if present; properties not set locally are inherited from it.
    public var baseProfile: String?
    /// `true` when the profile carries `Default=Yes`.
    public var isDefault: Bool
    /// `Cpu=32` for 32-bit targets; absent means 8-bit.
    public var cpuBits: Int
    public var intRamSize: Int
    public var longRamSize: Int
    public var floatRamSize: Int
    public var intRomSize: Int
    public var longRomSize: Int
    public var floatRomSize: Int
    public var eepromOffset: Int
    public var eepromDataSize: Int
    public var eepromWriteBlock: Int
    public var programDataSize: Int?
    public var threads: [PLCThreadConfig]

    /// Limits for a constant typed directly onto a pin (as opposed to a named constant).
    public var directConstMin: Int
    public var directConstMax: Int
    public var constantDataTypes: [String]
    public var constantDataTypeAliases: [String]

    /// Mnemonics from `SystemCommands=`; empty means "the whole catalogue is available".
    public var systemCommandMnemonics: [String]
    /// Every property of the section, in file order, including inherited ones.
    public var rawProperties: AttributeBag

    public init(
        name: String,
        alias: String? = nil,
        baseProfile: String? = nil,
        isDefault: Bool = false,
        cpuBits: Int = 8,
        intRamSize: Int = 512,
        longRamSize: Int = 128,
        floatRamSize: Int = 32,
        intRomSize: Int = 512,
        longRomSize: Int = 512,
        floatRomSize: Int = 512,
        eepromOffset: Int = 16,
        eepromDataSize: Int = 256,
        eepromWriteBlock: Int = 8,
        programDataSize: Int? = nil,
        threads: [PLCThreadConfig] = [],
        directConstMin: Int = -2047,
        directConstMax: Int = 2047,
        constantDataTypes: [String] = ["I16", "I32", "I64", "Single"],
        constantDataTypeAliases: [String] = ["Int", "Long", "Int64", "Float"],
        systemCommandMnemonics: [String] = [],
        rawProperties: AttributeBag = [:]
    ) {
        self.name = name
        self.alias = alias
        self.baseProfile = baseProfile
        self.isDefault = isDefault
        self.cpuBits = cpuBits
        self.intRamSize = intRamSize
        self.longRamSize = longRamSize
        self.floatRamSize = floatRamSize
        self.intRomSize = intRomSize
        self.longRomSize = longRomSize
        self.floatRomSize = floatRomSize
        self.eepromOffset = eepromOffset
        self.eepromDataSize = eepromDataSize
        self.eepromWriteBlock = eepromWriteBlock
        self.programDataSize = programDataSize
        self.threads = threads
        self.directConstMin = directConstMin
        self.directConstMax = directConstMax
        self.constantDataTypes = constantDataTypes
        self.constantDataTypeAliases = constantDataTypeAliases
        self.systemCommandMnemonics = systemCommandMnemonics
        self.rawProperties = rawProperties
    }

    /// The thread with the given 1-based `THREAD_ID`, if the profile declares one.
    public func thread(id: Int) -> PLCThreadConfig? {
        threads.first { $0.id == id }
    }
}

/// Everything `Profiles.ini` contains.
public struct ProfileDatabase: Sendable, Equatable {
    public var profiles: [String: PLCProfile]
    /// The `[@SystemCommands]` catalogue, keyed by mnemonic.
    public var systemCommands: [String: SystemCommandInfo]

    public init(profiles: [String: PLCProfile] = [:], systemCommands: [String: SystemCommandInfo] = [:]) {
        self.profiles = profiles
        self.systemCommands = systemCommands
    }

    /// The profile named `Default=Yes`, falling back to "Sybas P3" and then to any profile.
    public var defaultProfile: PLCProfile? {
        profiles.values.first { $0.isDefault }
            ?? profiles["Sybas P3"]
            ?? profiles.values.sorted { $0.name < $1.name }.first
    }

    public func profile(named name: String) -> PLCProfile? {
        if let exact = profiles[name] { return exact }
        let lowered = name.lowercased()
        return profiles.values.first { $0.name.lowercased() == lowered || $0.alias?.lowercased() == lowered }
    }

    /// The commands available on a profile. A profile with no `SystemCommands=` key supports the
    /// whole catalogue.
    public func systemCommands(for profile: PLCProfile) -> [SystemCommandInfo] {
        guard !profile.systemCommandMnemonics.isEmpty else {
            return systemCommands.values.sorted { $0.mnemonic < $1.mnemonic }
        }
        return profile.systemCommandMnemonics.compactMap { systemCommands[$0] }
    }
}

/// Parses `Profiles.ini` — the hardware profile and `SystemCmd` catalogue shipped next to
/// `Dirigo.exe`.
///
/// The format is INI with three wrinkles:
///
/// * sections may inherit with `BaseProfile=<name>`, forming a chain that must be flattened;
/// * `[@SystemCommands]` holds a fixed-width-ish table of command definitions rather than
///   settings;
/// * `SystemCommands=` is a comma-separated list of mnemonics limiting what a profile supports.
public final class ProfilesParser: @unchecked Sendable {
    public static let systemCommandsSection = "@SystemCommands"

    public init() {}

    public func parse(fileAt url: URL) throws -> ProfileDatabase {
        let data = try Data(contentsOf: url)
        return parse(data: data)
    }

    public func parse(data: Data) -> ProfileDatabase {
        // Profiles.ini is CP1250/ASCII; only the keys are read, so a lossy decode is fine.
        let text = String(data: data, encoding: .windowsCP1250)
            ?? String(decoding: data, as: UTF8.self)
        return parse(iniString: text)
    }

    public func parse(iniString: String) -> ProfileDatabase {
        var sections: [(name: String, props: AttributeBag)] = []
        var currentName: String?
        var currentPairs: [(String, String)] = []

        func flush() {
            if let name = currentName {
                sections.append((name, AttributeBag(currentPairs)))
            }
            currentPairs = []
        }

        for rawLine in iniString.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                flush()
                currentName = String(line.dropFirst().dropLast())
                continue
            }
            guard currentName != nil, let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            currentPairs.append((key, value))
        }
        flush()

        return Self.database(sections: sections)
    }

    /// Builds the database from sections that are already read: the profiles and the `[@SystemCommands]` table, as `(name, properties)` pairs.
    /// The app's own data (`BuiltInProfiles`) and an `.ini` text both come through here.
    static func database(sections: [(name: String, props: AttributeBag)]) -> ProfileDatabase {
        var commandTable: [String: SystemCommandInfo] = [:]
        var rawProfiles: [(String, AttributeBag)] = []
        for section in sections {
            if section.name == Self.systemCommandsSection {
                for (mnemonic, definition) in section.props {
                    if let info = Self.parseSystemCommand(mnemonic: mnemonic, definition: definition) {
                        commandTable[mnemonic] = info
                    }
                }
            } else {
                rawProfiles.append((section.name, section.props))
            }
        }

        // Flatten `BaseProfile` chains (children override parents).
        let byName = Dictionary(rawProfiles, uniquingKeysWith: { first, _ in first })
        var resolved: [String: AttributeBag] = [:]
        var inProgress: Set<String> = []

        func flatten(_ name: String) -> AttributeBag {
            if let done = resolved[name] { return done }
            guard let own = byName[name] else { return [:] }
            guard !inProgress.contains(name) else { return own }  // cycle guard
            inProgress.insert(name)
            var merged = AttributeBag()
            // Only recurse when the named base actually exists; otherwise this profile simply
            // inherits nothing.
            if let base = own["BaseProfile"], byName[base] != nil {
                merged = flatten(base)
            }
            for (key, value) in own {
                merged[key] = value
            }
            // These describe the profile itself, not the hardware, so they must never be
            // inherited: `Sybas D-DISP` derives from `Sybas P3` but is not the default profile.
            for key in ["Default", "Alias", "BaseProfile"] {
                if let ownValue = own[key] {
                    merged[key] = ownValue
                } else {
                    merged.removeValue(forKey: key)
                }
            }
            inProgress.remove(name)
            resolved[name] = merged
            return merged
        }

        var profiles: [String: PLCProfile] = [:]
        for (name, _) in rawProfiles {
            let props = flatten(name)
            profiles[name] = Self.buildProfile(name: name, props: props)
        }
        return ProfileDatabase(profiles: profiles, systemCommands: commandTable)
    }

    private static func buildProfile(name: String, props: AttributeBag) -> PLCProfile {
        func int(_ key: String, _ fallback: Int) -> Int {
            props[key].flatMap { Int($0) } ?? fallback
        }
        func intList(_ key: String) -> [String] {
            guard let raw = props[key], !raw.isEmpty else { return [] }
            return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        let threadCount = int("Threads", 0)
        var threads: [PLCThreadConfig] = []
        for i in 1...max(threadCount, 1) {
            guard let threadName = props["Thread\(i)Name"] else { continue }
            threads.append(PLCThreadConfig(
                id: i,
                name: threadName,
                intervalMs: int("Thread\(i)Interval", 0),
                programSize: int("Thread\(i)ProgramSize", 0)
            ))
        }

        // Profiles omit `Cpu=` when they are 8-bit, and inherit it otherwise.
        let cpuBits = props["Cpu"].flatMap { Int($0) } ?? 8

        return PLCProfile(
            name: name,
            alias: props["Alias"],
            baseProfile: props["BaseProfile"],
            isDefault: (props["Default"]?.lowercased() == "yes"),
            cpuBits: cpuBits,
            intRamSize: int("IntRamDataSize", 512),
            longRamSize: int("LongRamDataSize", 128),
            floatRamSize: int("FloatRamDataSize", 32),
            intRomSize: int("IntRomDataSize", 512),
            longRomSize: int("LongRomDataSize", 512),
            floatRomSize: int("FloatRomDataSize", 512),
            eepromOffset: int("EepromOffset", 16),
            eepromDataSize: int("EepromDataSize", 256),
            eepromWriteBlock: int("EepromWriteBlock", 8),
            programDataSize: props["ProgramDataSize"].flatMap { Int($0) },
            threads: threads,
            directConstMin: int("DirectConstMin", -2047),
            directConstMax: int("DirectConstMax", 2047),
            constantDataTypes: intList("ConstantDataTypes"),
            constantDataTypeAliases: intList("ConstantDataTypeAliases"),
            systemCommandMnemonics: intList("SystemCommands"),
            rawProperties: props
        )
    }

    /// Parses one `[@SystemCommands]` line:
    /// `FWT_0000=Firmware Type, TXT=FW, CMD=0x0000, I1=(Int)(Hidden)Par1, I2=(Int)(Hidden)Par2, O1=(Int)Fw`
    static func parseSystemCommand(mnemonic: String, definition: String) -> SystemCommandInfo? {
        let text = definition.components(separatedBy: ",")[0].trimmingCharacters(in: .whitespaces)

        let fields = definition.components(separatedBy: ",")
        func field(_ key: String) -> String? {
            let prefix = key.uppercased() + "="
            guard let part = fields.first(where: { $0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix(prefix) })
            else { return nil }
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let value = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }

        guard let cmdText = field("CMD"), let command = parseCommandWord(cmdText) else { return nil }

        // `(Int)(Hidden)Par1` or `(Long)BitNr`
        func pin(_ value: String?) -> SystemCommandInfo.PinSchema {
            guard let value else {
                return SystemCommandInfo.PinSchema(dataType: "Int", name: "-", isHidden: true)
            }
            var remainder = value
            var dataType = "Int"
            if remainder.hasPrefix("("), let close = remainder.firstIndex(of: ")") {
                dataType = String(remainder[remainder.index(after: remainder.startIndex)..<close])
                remainder = String(remainder[remainder.index(after: close)...])
            }
            var isHidden = false
            if remainder.hasPrefix("(Hidden)") {
                isHidden = true
                remainder = String(remainder.dropFirst("(Hidden)".count))
            }
            return SystemCommandInfo.PinSchema(
                dataType: dataType,
                name: remainder.trimmingCharacters(in: .whitespaces),
                isHidden: isHidden
            )
        }

        return SystemCommandInfo(
            mnemonic: mnemonic,
            title: text,
            text: field("TXT") ?? mnemonic,
            command: command,
            input1: pin(field("I1")),
            input2: pin(field("I2")),
            output: pin(field("O1"))
        )
    }

    /// A `SystemCmd` module's own `DEFINITION="TXT=Pwm, CMD=0x0303, I1=(Int)PwmCH, I2=(Int)Value, O1=(Int)Out"`:
    /// the variant the configuration dialog chose, in the same syntax as a `[@SystemCommands]` line.
    public static func systemCommand(fromDefinition definition: String) -> SystemCommandInfo? {
        parseSystemCommand(mnemonic: "DEFINITION", definition: definition)
    }

    /// `0x0301` or `769`.
    static func parseCommandWord(_ raw: String) -> UInt16? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("0x") {
            return UInt16(trimmed.dropFirst(2), radix: 16)
        }
        if trimmed.hasPrefix("$") {
            return UInt16(trimmed.dropFirst(), radix: 16)
        }
        return UInt16(trimmed)
    }
}

private extension String {
    /// `String.Encoding.windowsCP1250` is not exposed by Foundation on all platforms, so the
    /// raw value is used directly. `Profiles.ini` is plain ASCII in practice.
    static let windowsCP1250 = String.Encoding(rawValue: 0x0501)
}

/// The hardware profiles and the `SystemCmd` command table, compiled in (`BuiltInProfiles`, generated by `tools/gen_profiles.py` from Dirigo's `Profiles.ini`).
/// The app does not read that file.
public enum ProfileRegistry {
    public static let builtIn: ProfileDatabase = {
        var sections: [(name: String, props: AttributeBag)] = BuiltInProfiles.profiles.map { ($0.name, AttributeBag($0.properties)) }
        sections.append((ProfilesParser.systemCommandsSection, AttributeBag(BuiltInProfiles.commands.map { ($0.mnemonic, $0.definition) })))
        return ProfilesParser.database(sections: sections)
    }()

    /// The profile a project asks for, falling back to the database default.
    public static func profile(for project: PCCProject, in database: ProfileDatabase) -> PLCProfile? {
        database.profile(named: project.profile) ?? database.defaultProfile
    }
}

/// What a `SystemCmd` block answers in the simulation.
///
/// The firmware is not here, so the commands that *ask the unit something* (firmware type and version, ROM id,
/// timers, analogue inputs) read 0, as before. The commands that are arithmetic are computed — square root,
/// hypotenuse, perpendicular — and the ones that *set* something (DO, Tris, PWM, Vref, addresses, menu item,
/// watchdog, thread period) answer with the value they set, the way a unit that accepted it would. The C++ core
/// (`WirebenchSimCore.cpp`) mirrors this function exactly, which `compareBothEngines` relies on.
public enum SystemCommandSimulation {
    /// - Parameters: `command` is the command word, `par1`/`par2` the two parameters (`I1`, `I2`).
    public static func result(command: Int, par1: Int, par2: Int) -> Int {
        func isqrt(_ value: UInt64) -> Int {
            if value < 2 { return Int(value) }
            var x = UInt64(Double(value).squareRoot())
            while x * x > value { x -= 1 }
            while (x + 1) * (x + 1) <= value { x += 1 }
            return Int(x)
        }
        switch command {
        case 0x0022:   // SQT: (Long)Lo, (Long)Hi → Y = floor(sqrt(Hi·2³² + Lo))
            return isqrt((UInt64(UInt32(truncatingIfNeeded: par2)) << 32) | UInt64(UInt32(truncatingIfNeeded: par1)))
        case 0x0023:   // HYP: C = floor(sqrt(A² + B²))
            let a = UInt64(abs(par1)), b = UInt64(abs(par2))
            return isqrt(a &* a &+ b &* b)
        case 0x0024:   // PER: (Long)C, (Long)B → A = floor(sqrt(C² − B²))
            let c = UInt64(abs(par1)), b = UInt64(abs(par2))
            return c * c >= b * b ? isqrt(c * c - b * b) : 0
        case 0x0101, 0x0201, 0x0301, 0x0302, 0x0400, 0x0402:
            return par1    // Set RNet address / menu item / DO / Tris / watchdog / start thread
        case 0x0303, 0x0304, 0x0401:
            return par2    // PWM value / Vref / thread period
        default:
            return 0
        }
    }
}

extension SystemCommandInfo {
    /// The `DEFINITION=` a module carries once this variant is chosen: the `[@SystemCommands]` syntax without the
    /// mnemonic, e.g. `TXT=Pwm, CMD=0x0303, I1=(Int)PwmCH, I2=(Int)Value, O1=(Int)Out`.
    public var definitionString: String {
        func pin(_ schema: PinSchema) -> String {
            "(\(schema.dataType))" + (schema.isHidden ? "(Hidden)" : "") + schema.name
        }
        let word = String(format: "0x%04X", command)
        return "TXT=\(text), CMD=\(word), I1=\(pin(input1)), I2=\(pin(input2)), O1=\(pin(output))"
    }
}
