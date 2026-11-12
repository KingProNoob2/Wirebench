#if WIREBENCH_AI
import Foundation
#if canImport(Security)
import Security
#endif

/// Somewhere safe for an API key. Never a file the app writes itself, and never `UserDefaults`: both are plain text on disk.
public protocol SecretStore: Sendable {
    /// What to call it on screen: "the macOS Keychain".
    var name: String { get }
    /// False where there is nowhere safe to put a key (a Linux machine with no keyring).
    var isAvailable: Bool { get }
    func read(account: String) -> String?
    /// Whether a secret is stored, without reading it. Where the system asks the user's permission to hand a secret over (the macOS
    /// Keychain), this must not: asking whether it is *there* is not asking for it.
    func exists(account: String) -> Bool
    /// Whether it was stored.
    func write(_ secret: String, account: String) -> Bool
    func delete(account: String)
}

extension SecretStore {
    /// For a store that has no cheaper way to know than to read it.
    public func exists(account: String) -> Bool { read(account: account) != nil }
}

/// The operating system's own: the Keychain on macOS, the Secret Service (GNOME Keyring, KWallet) through `secret-tool` on Linux.
/// Where that is not there (a Linux machine with no keyring) `isAvailable` is false and the key is kept for the session only.
public struct SystemSecretStore: SecretStore {
    public static let service = "com.wirebench.agent"
    public init() {}

    #if canImport(Security)
    public var name: String { "the macOS Keychain" }
    public var isAvailable: Bool { true }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: account]
    }

    public func read(account: String) -> String? {
        var found = query(account)
        found[kSecReturnData as String] = true
        found[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(found as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Attributes only, no data: the Keychain asks the user for permission when the secret itself is read, not to say that an item exists.
    public func exists(account: String) -> Bool {
        var found = query(account)
        found[kSecReturnAttributes as String] = true
        found[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(found as CFDictionary, nil) == errSecSuccess
    }

    public func write(_ secret: String, account: String) -> Bool {
        delete(account: account)
        var add = query(account)
        add[kSecValueData as String] = Data(secret.utf8)
        // Readable only while the Mac is unlocked, and never copied to another device.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
    #else
    public var name: String { "the system keyring" }

    /// `secret-tool` is libsecret's command-line client (`libsecret-tools` on Debian and Ubuntu, `libsecret` on Arch and Fedora).
    private static let tool: String? = ["/usr/bin/secret-tool", "/usr/local/bin/secret-tool", "/bin/secret-tool"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    public var isAvailable: Bool { Self.tool != nil }

    /// Runs `secret-tool`, feeding it `input` on stdin (so a key is never on a command line, where `ps` would show it), and gives up
    /// after `seconds` so a keyring that is waiting for an unlock does not hang the app.
    private func run(_ arguments: [String], input: String? = nil, seconds: TimeInterval = 20) -> (status: Int32, output: String)? {
        guard let tool = Self.tool else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe(), inPipe = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = inPipe
        do { try process.run() } catch { return nil }
        if let input { inPipe.fileHandleForWriting.write(Data(input.utf8)) }
        try? inPipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    public func read(account: String) -> String? {
        guard let result = run(["lookup", "service", Self.service, "account", account]), result.status == 0, !result.output.isEmpty else { return nil }
        return result.output
    }

    public func write(_ secret: String, account: String) -> Bool {
        run(["store", "--label", "Wirebench agent (\(account))", "service", Self.service, "account", account], input: secret)?.status == 0
    }

    public func delete(account: String) {
        _ = run(["clear", "service", Self.service, "account", account])
    }
    #endif
}

/// Keeps keys in memory only. For tests, and for the machine with nowhere safe to put one.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]
    public let name = "this session only"
    public var isAvailable: Bool { true }
    public init() {}
    public func read(account: String) -> String? { lock.withLock { secrets[account] } }
    public func write(_ secret: String, account: String) -> Bool { lock.withLock { secrets[account] = secret }; return true }
    public func delete(account: String) { lock.withLock { _ = secrets.removeValue(forKey: account) } }
}
#endif
