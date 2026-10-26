import Foundation

// MARK: - Paths

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Same resolution order the official Vencord Installer uses (patcher.go init()).
    static var vencordBaseDir: URL {
        let env = ProcessInfo.processInfo.environment
        if let d = env["VENCORD_USER_DATA_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: d)
        }
        if let d = env["DISCORD_USER_DATA_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: d).deletingLastPathComponent()
                .appendingPathComponent("VencordData")
        }
        // go-appdir UserConfig() on darwin == ~/Library/Application Support/<name>
        return home.appendingPathComponent("Library/Application Support/Vencord")
    }

    static var vencordDistDir: URL { vencordBaseDir.appendingPathComponent("dist") }
    static var patcherJS: URL { vencordDistDir.appendingPathComponent("patcher.js") }

    static var stateDir: URL { home.appendingPathComponent("Library/Application Support/VencordGuard") }
    static var stateFile: URL { stateDir.appendingPathComponent("state.json") }
    static var configFile: URL { stateDir.appendingPathComponent("config.json") }
    static var logDir: URL { home.appendingPathComponent("Library/Logs/VencordGuard") }
    static var logFile: URL { logDir.appendingPathComponent("vencord-guard.log") }
}

func fileExists(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
}

func fileSize(_ url: URL) -> Int64? {
    guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
          let n = a[.size] as? NSNumber else { return nil }
    return n.int64Value
}

// MARK: - Logging

/// Line-oriented log with size-based rotation. The file handle is kept open (one fd,
/// no cost when idle) and every write is flushed so `tail -f` shows events live.
final class Log {
    static let shared = Log()

    private let queue = DispatchQueue(label: "dev.vencordguard.log")
    private var handle: FileHandle?
    private let maxBytes: UInt64 = 1_048_576
    private let keep = 3

    /// Also echo to stdout, which launchd captures. Useful when run in the foreground.
    var echoToStdout = false

    private init() {
        try? FileManager.default.createDirectory(at: Paths.logDir, withIntermediateDirectories: true)
        open()
    }

    private func open() {
        let path = Paths.logFile.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: Paths.logFile)
        _ = try? handle?.seekToEnd()
    }

    private func rotateIfNeeded() {
        guard let h = handle, let end = try? h.offset(), end > maxBytes else { return }
        try? h.close()
        handle = nil
        let fm = FileManager.default
        let base = Paths.logFile.path
        try? fm.removeItem(atPath: "\(base).\(keep)")
        for i in stride(from: keep - 1, through: 1, by: -1) {
            try? fm.moveItem(atPath: "\(base).\(i)", toPath: "\(base).\(i + 1)")
        }
        try? fm.moveItem(atPath: base, toPath: "\(base).1")
        open()
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSZ"
        return f
    }()

    func write(_ level: String, _ message: String) {
        let line = "[\(Log.stamp.string(from: Date()))] \(level.padding(toLength: 5, withPad: " ", startingAt: 0)) \(message)\n"
        queue.async {
            self.rotateIfNeeded()
            if let d = line.data(using: .utf8) { try? self.handle?.write(contentsOf: d) }
            if self.echoToStdout { FileHandle.standardOutput.write(line.data(using: .utf8) ?? Data()) }
        }
    }
}

func logInfo(_ m: String)  { Log.shared.write("INFO", m) }
func logWarn(_ m: String)  { Log.shared.write("WARN", m) }
func logError(_ m: String) { Log.shared.write("ERROR", m) }
func logDebug(_ m: String) { if Config.current.debug { Log.shared.write("DEBUG", m) } }

// MARK: - Notifications

/// A plain SwiftPM executable has no app bundle, so UNUserNotificationCenter is unavailable.
/// `display notification` via osascript is the supported bundle-free path. This runs only on
/// genuine state changes (a repair, or a repair that needs the user), never on a timer.
enum Notify {
    private static var lastMessage: (String, Date)?

    static func post(title: String, body: String) {
        guard Config.current.notifications else { return }
        // Collapse identical notifications fired within 10 minutes of each other.
        if let (m, t) = lastMessage, m == body, Date().timeIntervalSince(t) < 600 { return }
        lastMessage = (body, Date())

        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let script = "display notification \"\(esc(body))\" with title \"\(esc(title))\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { logWarn("could not post notification: \(error)") }
    }
}

// MARK: - Config

struct Config: Codable {
    /// Which Discord branches to guard. "auto" = every branch actually installed.
    var branches: [String] = ["auto"]
    /// Post a macOS notification when a repair happens or needs attention.
    var notifications: Bool = true
    /// Minimum seconds between two repair attempts on the same install.
    var repairCooldownSeconds: Double = 600
    /// Consecutive failures before backing off hard.
    var maxConsecutiveFailures: Int = 3
    /// Backoff applied after maxConsecutiveFailures (default 6h).
    var failureBackoffSeconds: Double = 21_600
    /// Tail renderer_js.log after launch to positively confirm Vencord actually loaded.
    var confirmViaRendererLog: Bool = true
    /// How long to wait for that confirmation before treating silence as "not loaded".
    var rendererConfirmTimeoutSeconds: Double = 120
    /// Allow downloading Vencord dist files from GitHub when they are missing or corrupt.
    var allowNetwork: Bool = true
    /// Never true by default: the guard does not kill Discord.
    var autoRestartDiscord: Bool = false
    var debug: Bool = false

    static var current: Config = (try? JSONDecoder().decode(
        Config.self, from: Data(contentsOf: Paths.configFile))) ?? Config()
}
