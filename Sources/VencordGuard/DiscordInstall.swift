import Foundation

struct Branch {
    let name: String        // stable / ptb / canary / dev
    let appName: String     // Discord Canary.app
    let bundleID: String    // com.hnc.DiscordCanary
    let supportDir: String  // ~/Library/Application Support/<supportDir>

    static let all: [Branch] = [
        Branch(name: "stable", appName: "Discord.app",
               bundleID: "com.hnc.Discord", supportDir: "discord"),
        Branch(name: "ptb", appName: "Discord PTB.app",
               bundleID: "com.hnc.DiscordPTB", supportDir: "discordptb"),
        Branch(name: "canary", appName: "Discord Canary.app",
               bundleID: "com.hnc.DiscordCanary", supportDir: "discordcanary"),
        Branch(name: "dev", appName: "Discord Development.app",
               bundleID: "com.hnc.DiscordDevelopment", supportDir: "discorddevelopment"),
    ]

    static func byBundleID(_ id: String) -> Branch? { all.first { $0.bundleID == id } }
}

/// What the guard believes about one Discord install right now.
enum Health: Equatable {
    /// app.asar is our stub, _app.asar backup is present, dist looks complete.
    case patched
    /// Stock Discord: real app.asar, no _app.asar.
    case unpatched
    /// Patched, but something is wrong (missing backup, missing/short dist files).
    case brokenPatch(String)
    /// app.asar is a stub, but it requires a patcher that isn't the Vencord dir we manage.
    case foreignPatch(String)
    /// The bundle is mid-swap or otherwise not readable. Never act on this.
    case indeterminate(String)

    var isHealthy: Bool { self == .patched }

    var describe: String {
        switch self {
        case .patched: return "patched"
        case .unpatched: return "unpatched"
        case .brokenPatch(let r): return "brokenPatch(\(r))"
        case .foreignPatch(let r): return "foreignPatch(\(r))"
        case .indeterminate(let r): return "indeterminate(\(r))"
        }
    }
}

struct DiscordInstall {
    let branch: Branch
    let appURL: URL

    var resources: URL { appURL.appendingPathComponent("Contents/Resources") }
    var appAsar: URL { resources.appendingPathComponent("app.asar") }
    var backupAsar: URL { resources.appendingPathComponent("_app.asar") }
    var openAsarBackup: URL { resources.appendingPathComponent("app.asar.backup") }
    var buildInfo: URL { resources.appendingPathComponent("build_info.json") }

    var supportURL: URL {
        Paths.home.appendingPathComponent("Library/Application Support/\(branch.supportDir)")
    }
    var logsURL: URL { supportURL.appendingPathComponent("logs") }
    var rendererLog: URL { logsURL.appendingPathComponent("renderer_js.log") }
    var updaterLog: URL {
        // "Discord Canary_updater_rCURRENT.log" — derived from the bundle's display name.
        let display = appURL.deletingPathExtension().lastPathComponent
        return logsURL.appendingPathComponent("\(display)_updater_rCURRENT.log")
    }

    var version: String? {
        guard let d = try? Data(contentsOf: buildInfo),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return j["version"] as? String
    }

    static func discover(branches wanted: [String]) -> [DiscordInstall] {
        let bases = ["/Applications", Paths.home.appendingPathComponent("Applications").path]
        let auto = wanted.contains("auto") || wanted.isEmpty
        var found: [DiscordInstall] = []
        for branch in Branch.all where auto || wanted.contains(branch.name) {
            for base in bases {
                let url = URL(fileURLWithPath: base).appendingPathComponent(branch.appName)
                // Mirrors ParseDiscord() in find_discord_darwin.go: an install is anything
                // with a Contents/Resources directory.
                if fileExists(url) && fileExists(url.appendingPathComponent("Contents/Resources")) {
                    found.append(DiscordInstall(branch: branch, appURL: url))
                }
            }
        }
        return found
    }

    // MARK: - Health check
    //
    // This is the *entire* per-event cost of the guard: about six stat() calls plus one
    // ~220-byte read. No directory walk, no subprocess, no network.

    func checkHealth() -> Health {
        guard fileExists(resources) else {
            return .indeterminate("Contents/Resources missing (bundle being replaced?)")
        }

        let patcher = Paths.patcherJS.path
        let hasBackup = fileExists(backupAsar)

        guard let stub = try? Data(contentsOf: appAsar, options: [.mappedIfSafe]) else {
            return .indeterminate("app.asar unreadable")
        }

        if AsarStub.isStub(data: stub, patcherPath: patcher) {
            if !hasBackup {
                return .brokenPatch("_app.asar backup missing; Discord cannot start")
            }
            if let size = fileSize(backupAsar), size < 1_000_000 {
                return .brokenPatch("_app.asar is only \(size) bytes; backup looks truncated")
            }
            if let problem = distProblem() {
                return .brokenPatch(problem)
            }
            return .patched
        }

        if AsarStub.isForeignStub(data: stub) {
            let text = String(data: stub, encoding: .utf8) ?? ""
            return .foreignPatch("app.asar requires a different patcher: \(text.suffix(160))")
        }

        // A full, real app.asar sits here.
        if hasBackup {
            // Both a real app.asar and a backup: a half-finished unpatch, or OpenAsar's own
            // layout. Ambiguous — do not guess, let the user or the official installer decide.
            return .indeterminate("both app.asar and _app.asar are full asars; ambiguous state")
        }
        return .unpatched
    }

    /// Returns a description of the first problem with the Vencord dist directory, or nil.
    /// Size floors are deliberately generous — they catch truncated/zero-byte downloads,
    /// not version drift.
    func distProblem() -> String? {
        let required: [(String, Int64)] = [
            ("patcher.js", 1_000),
            ("preload.js", 500),
            ("renderer.js", 10_000),
            ("renderer.css", 1_000),
        ]
        for (name, floor) in required {
            let url = Paths.vencordDistDir.appendingPathComponent(name)
            guard let size = fileSize(url) else { return "dist/\(name) is missing" }
            if size < floor { return "dist/\(name) is only \(size) bytes (truncated download?)" }
        }
        guard let head = try? FileHandle(forReadingFrom: Paths.patcherJS) else {
            return "dist/patcher.js unreadable"
        }
        defer { try? head.close() }
        let first = (try? head.read(upToCount: 64)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if !first.hasPrefix("// Vencord ") {
            return "dist/patcher.js does not carry a Vencord build header"
        }
        return nil
    }

    /// The short build hash Vencord stamps on line 1 of patcher.js, e.g. "ef29bbe".
    static func installedVencordHash() -> String? {
        guard let h = try? FileHandle(forReadingFrom: Paths.patcherJS) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 64), let s = String(data: d, encoding: .utf8) else { return nil }
        guard let line = s.split(separator: "\n").first, line.hasPrefix("// Vencord ") else { return nil }
        return String(line.dropFirst("// Vencord ".count)).trimmingCharacters(in: .whitespaces)
    }

    /// Whether we can actually modify this bundle.
    ///
    /// POSIX permissions are not the real gate on modern macOS: since Sonoma, TCC's
    /// "App Management" restriction returns EPERM on writes into another app's bundle even
    /// when the user owns every byte of it. The only reliable test is to try the operation,
    /// so this creates a probe file, renames it (the exact syscall patching needs), and
    /// cleans up. Three syscalls, and only on the path where a repair is already warranted.
    func canModifyBundle() -> (ok: Bool, reason: String?) {
        let fm = FileManager.default
        let a = resources.appendingPathComponent(".vencordguard-probe")
        let b = resources.appendingPathComponent(".vencordguard-probe2")
        try? fm.removeItem(at: a); try? fm.removeItem(at: b)
        defer { try? fm.removeItem(at: a); try? fm.removeItem(at: b) }

        do { try Data("probe".utf8).write(to: a) }
        catch { return (false, "cannot create files in the bundle: \(error.localizedDescription)") }
        do { try fm.moveItem(at: a, to: b) }
        catch { return (false, "cannot rename files in the bundle: \(error.localizedDescription)") }
        return (true, nil)
    }

    var isOpenAsarInstalled: Bool {
        guard let d = try? Data(contentsOf: backupAsar, options: [.mappedIfSafe]) else { return false }
        // OpenAsar's bundle is small enough to scan only its head; the marker is in the header.
        return d.prefix(200_000).range(of: Data("OpenAsar".utf8)) != nil
    }
}
