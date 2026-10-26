import Foundation
import AppKit

@main
struct VencordGuardMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? "run"

        if args.contains("--debug") { Config.current.debug = true }

        switch command {
        case "run":
            run(foreground: args.contains("--foreground"))
        case "status":
            print(GuardService().statusReport(), terminator: "")
        case "check":
            exit(GuardService().checkOnce(force: false))
        case "repair":
            exit(GuardService().checkOnce(force: true))
        case "selftest":
            exit(selftest())
        case "doctor":
            exit(doctor())
        case "version", "--version", "-v":
            print("vencord-guard \(buildVersion)")
        case "help", "--help", "-h":
            printUsage()
        default:
            printUsage()
            exit(2)
        }
    }

    static let buildVersion = "1.0.0"

    static func run(foreground: Bool) {
        Log.shared.echoToStdout = foreground
        logInfo("vencord-guard \(buildVersion) starting (pid \(getpid()))")
        logInfo("Vencord data dir: \(Paths.vencordBaseDir.path)")

        // Never let two agents fight over the same app.asar.
        guard acquireSingleInstanceLock() else {
            logError("another vencord-guard is already running; exiting")
            exit(0)
        }

        let service = GuardService()
        service.start()

        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { logInfo("received signal \(sig); exiting"); exit(0) }
            src.resume()
            signalSources.append(src)
        }

        // NSWorkspace notifications are delivered on the main run loop, so we park here.
        // With no timers armed, this thread issues zero wakeups until something happens.
        RunLoop.main.run()
    }

    static var signalSources: [DispatchSourceSignal] = []
    static var lockFD: Int32 = -1

    static func acquireSingleInstanceLock() -> Bool {
        try? FileManager.default.createDirectory(at: Paths.stateDir, withIntermediateDirectories: true)
        let path = Paths.stateDir.appendingPathComponent("vencord-guard.lock").path
        lockFD = open(path, O_CREAT | O_RDWR, 0o644)
        guard lockFD >= 0 else { return true }   // can't lock: don't block the user
        return flock(lockFD, LOCK_EX | LOCK_NB) == 0
    }

    /// Verifies the asar generator against the real thing before anyone trusts it with a
    /// Discord install. Run it any time: `vencord-guard selftest`.
    static func selftest() -> Int32 {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        check("package.json stub is 43 bytes", AsarStub.packageJSON.utf8.count == 43,
              "got \(AsarStub.packageJSON.utf8.count)")

        // Reference vector: the header a real VencordInstaller-produced app.asar carries.
        let sample = AsarStub.build(patcherPath: "/Users/example/Library/Application Support/Vencord/dist/patcher.js")
        let text = String(data: sample, encoding: .utf8) ?? ""
        check("generated stub carries an asar header", text.contains("{\"files\":{\"index.js\":"))
        check("generated stub requires the patcher", text.contains("require(\"/Users/example/"))
        check("generated stub is small", sample.count < 512, "\(sample.count) bytes")

        // Header framing: first four little-endian uint32s must be 4, aligned+8, aligned+4, len.
        let words: [UInt32] = (0..<4).map { i in
            sample.subdata(in: (i * 4)..<(i * 4 + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        }
        check("asar word[0] == 4", words[0] == 4, "\(words[0])")
        check("asar headerSize == aligned+8", words[1] == words[2] + 4, "\(words[1]) vs \(words[2])")
        check("asar headerObjectSize == aligned+4", words[2] % 4 == 0, "\(words[2])")

        // The strongest check available: if this machine already has a Vencord-patched
        // Discord, regenerate its stub and compare byte for byte.
        var compared = false
        for install in DiscordInstall.discover(branches: ["auto"]) {
            guard let onDisk = try? Data(contentsOf: install.appAsar),
                  AsarStub.isStub(data: onDisk, patcherPath: Paths.patcherJS.path) else { continue }
            compared = true
            let regenerated = AsarStub.build(patcherPath: Paths.patcherJS.path)
            check("regenerated stub matches \(install.branch.appName) byte-for-byte",
                  regenerated == onDisk,
                  regenerated == onDisk ? "" : "\(regenerated.count) vs \(onDisk.count) bytes")
        }
        if !compared {
            print("SKIP  byte-for-byte comparison (no Vencord-patched Discord on this machine)")
        }

        if let anyInstall = DiscordInstall.discover(branches: ["auto"]).first {
            let problem = anyInstall.distProblem()
            check("Vencord dist is usable", problem == nil, problem ?? "ok")
        } else {
            print("SKIP  Vencord dist check (no Discord install found)")
        }

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
        return failures == 0 ? 0 : 1
    }

    /// Answers "why can't it repair?" in one command. The permission check is the whole
    /// point: it is the failure mode nothing else explains clearly.
    static func doctor() -> Int32 {
        var problems = 0
        print("vencord-guard \(buildVersion) doctor\n")

        let label = "dev.vencordguard.agent"
        let loaded = shell("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]).contains("state = running")
        print("LaunchAgent running      : \(loaded ? "yes" : "NO")")
        if !loaded { problems += 1 }

        print("Vencord dist dir         : \(Paths.vencordDistDir.path)")
        print("Vencord build            : \(DiscordInstall.installedVencordHash() ?? "unknown")")

        let installs = DiscordInstall.discover(branches: Config.current.branches)
        if installs.isEmpty {
            print("Discord installs         : NONE FOUND")
            problems += 1
        }

        for i in installs {
            print("\n\(i.branch.appName)")
            print("  path                   : \(i.appURL.path)")
            print("  Discord version        : \(i.version ?? "?")")
            print("  health                 : \(i.checkHealth().describe)")
            if let d = i.distProblem() { print("  dist problem           : \(d)"); problems += 1 }

            // The authoritative answer: what the *agent* recorded about itself.
            // macOS attributes App Management to the running process, so probing from a
            // terminal measures the terminal (which normally has no such permission) and
            // says nothing about whether the agent can do its job.
            let st = StateStore.shared.get(i.appURL.path)
            switch st.agentCanModifyBundle {
            case .some(true):
                print("  agent can modify bundle: yes\(st.agentPermissionCheckedAt.map { " (checked \(ago($0)))" } ?? "")")
            case .some(false):
                problems += 1
                print("  agent can modify bundle: NO\(st.agentPermissionCheckedAt.map { " (checked \(ago($0)))" } ?? "")")
                print("""
                    fix                  : System Settings > Privacy & Security > App Management
                                           Add (or re-add) VencordGuard.app, then:
                                             launchctl kickstart -k gui/\(getuid())/\(label)
                """)
            case .none:
                print("  agent can modify bundle: not yet recorded — run:")
                print("                           launchctl kickstart -k gui/\(getuid())/\(label)")
            }

            // Informational only. Expected to be NO from a normal terminal; that is not a fault.
            let (ok, why) = i.canModifyBundle()
            print("  this process can       : \(ok ? "yes" : "no")  (informational — TCC is per-process;")
            print("                           a plain terminal is expected to say no)")
            if !ok, Config.current.debug { print("    reason               : \(why ?? "unknown")") }
        }

        print("\nLog   : \(Paths.logFile.path)")
        print("State : \(Paths.stateFile.path)")
        print(problems == 0 ? "\nNo problems found." : "\n\(problems) problem(s) found.")
        return problems == 0 ? 0 : 1
    }

    static func ago(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        return "\(s / 86_400)d ago"
    }

    static func shell(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }

    static func printUsage() {
        print("""
        vencord-guard \(buildVersion) — keeps Vencord patched into Discord on macOS

        USAGE
          vencord-guard run [--foreground] [--debug]   Watch for Discord launches / bundle
                                                       changes and repair Vencord when needed.
                                                       This is what the LaunchAgent runs.
          vencord-guard status                         Print what the guard knows about every
                                                       Discord install, plus repair history.
          vencord-guard check                          One-shot health check. Exit 0 = healthy.
          vencord-guard repair                         One-shot check that also repairs.
          vencord-guard selftest                       Verify the asar generator and dist.
          vencord-guard doctor                         Diagnose why repairs aren't happening
                                                       (agent loaded? bundle writable?).
          vencord-guard version

        FILES
          Log      ~/Library/Logs/VencordGuard/vencord-guard.log
          State    ~/Library/Application Support/VencordGuard/state.json
          Config   ~/Library/Application Support/VencordGuard/config.json
        """)
    }
}
