import Foundation

enum RepairOutcome {
    case notNeeded
    /// Not acting right now. `retryAfter` is non-nil when the reason is *transient* — a
    /// settling bundle, an update in flight, a cooldown — in which case the caller must
    /// come back on its own. Dropping these on the floor would mean a repair is silently
    /// forgotten whenever the deciding event happens to arrive too early.
    case skipped(String, retryAfter: Double?)
    case succeeded
    case failed(String)
}

/// Reimplements the official installer's patch/unpatch steps (patcher.go) rather than
/// shelling out to it, because the shipped macOS artifact is the GUI build
/// (`//go:build !cli`), which ignores `-install`/`-repair` entirely and would open a window.
/// Upstream publishes `VencordInstallerCli` only for Linux and Windows.
///
/// The file layout produced here is identical to the installer's, so VencordInstaller.app
/// remains the tool of record for install/uninstall/OpenAsar; this only restores what it did.
final class Repairer {

    private let install: DiscordInstall
    private var key: String { install.appURL.path }

    init(install: DiscordInstall) { self.install = install }

    /// How long the bundle must sit unchanged before we treat it as settled. A host update
    /// writes the new .app over several seconds; acting inside that window risks patching a
    /// half-written bundle.
    private let settleSeconds: Double = 15

    // MARK: - Gating

    /// Decide whether a repair may run right now. Every "no" is logged with its reason so the
    /// log answers "why did/didn't it act" without guesswork.
    func gate(health: Health, updateInFlight: Bool, discordRunning: Bool) -> RepairOutcome {
        let cfg = Config.current
        let state = StateStore.shared.get(key)

        switch health {
        case .patched:
            return .notNeeded
        case .indeterminate(let why):
            // Usually a bundle mid-swap; look again shortly.
            return .skipped("state is indeterminate: \(why)", retryAfter: 30)
        case .foreignPatch(let why):
            // A deliberate user choice. Never retry, never overwrite.
            return .skipped("another client mod owns app.asar; refusing to overwrite it — \(why)",
                            retryAfter: nil)
        case .unpatched, .brokenPatch:
            break
        }

        if updateInFlight {
            // The updater log normally tells us when it finishes; 60s is a backstop for the
            // case where Discord exits before writing a completion line.
            return .skipped("Discord's updater is mid-install; will re-check when it settles",
                            retryAfter: 60)
        }

        // A host update leaves a brand new bundle behind. Give the updater a moment to finish
        // writing it before touching app.asar.
        if let mtime = (try? FileManager.default.attributesOfItem(atPath: install.resources.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(mtime) < settleSeconds {
            let age = Date().timeIntervalSince(mtime)
            return .skipped("Contents/Resources changed \(Int(age))s ago; letting it settle",
                            retryAfter: settleSeconds - age + 2)
        }

        if state.consecutiveFailures >= cfg.maxConsecutiveFailures {
            if let last = state.lastRepairAttempt,
               Date().timeIntervalSince(last) < cfg.failureBackoffSeconds {
                let left = cfg.failureBackoffSeconds - Date().timeIntervalSince(last)
                return .skipped("in failure backoff after \(state.consecutiveFailures) failed attempts; \(Int(left))s left",
                                retryAfter: left + 2)
            }
        } else if let last = state.lastRepairAttempt,
                  Date().timeIntervalSince(last) < cfg.repairCooldownSeconds {
            let left = cfg.repairCooldownSeconds - Date().timeIntervalSince(last)
            return .skipped("cooldown: last attempt \(Int(Date().timeIntervalSince(last)))s ago; \(Int(left))s left",
                            retryAfter: left + 2)
        }

        let (writable, why) = install.canModifyBundle()
        StateStore.shared.update(key) {
            $0.agentCanModifyBundle = writable
            $0.agentPermissionCheckedAt = Date()
        }
        if !writable {
            // Almost always TCC App Management. Won't fix itself on a timer, and re-prompting
            // in a loop would be obnoxious, so retryAfter is nil: the next real event re-checks.
            Notify.post(title: "Vencord Guard needs permission",
                        body: "Grant VencordGuard \"App Management\" in System Settings > Privacy & Security so it can repair \(install.branch.appName).")
            return .skipped("cannot modify \(install.resources.path): \(why ?? "unknown") — "
                            + "grant App Management in System Settings > Privacy & Security",
                            retryAfter: nil)
        }

        _ = discordRunning   // Renaming app.asar is safe while Discord runs; see run().
        return .succeeded    // means "allowed to proceed"
    }

    // MARK: - Run

    func run(health: Health, discordRunning: Bool) -> RepairOutcome {
        let cfg = Config.current
        StateStore.shared.update(key) { $0.lastRepairAttempt = Date() }

        logInfo("repair START \(install.branch.name) at \(install.appURL.path) — reason: \(health.describe)")

        // 1. Make sure the Vencord dist is actually usable before touching Discord. Patching
        //    against a missing patcher.js would produce a Discord that refuses to boot.
        if let problem = install.distProblem() {
            logWarn("Vencord dist is unusable: \(problem)")
            guard cfg.allowNetwork else {
                return finish(.failed("dist unusable (\(problem)) and allowNetwork is false"))
            }
            do {
                try VencordDownloader.installLatestBuilds()
            } catch {
                return finish(.failed("could not download Vencord dist: \(error)"))
            }
            if let stillBroken = install.distProblem() {
                return finish(.failed("dist still unusable after download: \(stillBroken)"))
            }
            logInfo("downloaded Vencord dist (\(DiscordInstall.installedVencordHash() ?? "unknown hash"))")
        }

        // 2. Remember whether OpenAsar was in play, so the log can tell the user it was lost.
        let hadOpenAsar = StateStore.shared.get(key).hadOpenAsar

        // 3. Clean up a broken patch first, exactly as patcher.go's patch() does.
        if case .brokenPatch(let why) = health {
            logInfo("clearing broken patch first: \(why)")
            if fileExists(install.backupAsar) {
                do { try unpatch() } catch {
                    return finish(.failed("could not undo broken patch: \(error)"))
                }
            } else {
                // Stub with no backup: Discord is unbootable. There is nothing to restore, and
                // writing another stub would not fix it — the real app.asar is gone.
                Notify.post(title: "Vencord Guard",
                            body: "\(install.branch.appName) is missing its original app.asar. Reinstall Discord, then run VencordInstaller.")
                return finish(.failed("_app.asar backup is gone; Discord itself must be reinstalled"))
            }
        }

        // 4. Patch. os.rename is atomic and does not disturb an already-running Discord,
        //    which keeps holding the old inode. That is why we never need to kill Discord.
        do {
            try patch()
        } catch {
            return finish(.failed("patch failed: \(error)"))
        }

        // 5. Verify by re-reading from disk rather than trusting the write.
        let after = install.checkHealth()
        guard after.isHealthy else {
            return finish(.failed("post-repair verification says \(after.describe)"))
        }

        StateStore.shared.update(key) { $0.totalRepairs += 1; $0.lastRepairSuccess = Date() }
        logInfo("repair OK — \(install.branch.appName) is patched again")

        if hadOpenAsar {
            logWarn("OpenAsar was installed before and did not survive; reinstall it from VencordInstaller if you want it back")
        }

        if discordRunning {
            if cfg.autoRestartDiscord {
                restartDiscord()
            } else {
                Notify.post(title: "Vencord restored",
                            body: "Vencord was reinstalled into \(install.branch.appName). Restart Discord to load it.")
            }
        } else {
            Notify.post(title: "Vencord restored",
                        body: "Vencord was reinstalled into \(install.branch.appName).")
        }
        return finish(.succeeded)
    }

    private func finish(_ outcome: RepairOutcome) -> RepairOutcome {
        switch outcome {
        case .succeeded:
            StateStore.shared.update(key) { $0.consecutiveFailures = 0 }
        case .failed(let why):
            StateStore.shared.update(key) { $0.consecutiveFailures += 1 }
            let n = StateStore.shared.get(key).consecutiveFailures
            logError("repair FAILED (\(n) in a row): \(why)")
            if n == Config.current.maxConsecutiveFailures {
                Notify.post(title: "Vencord Guard needs help",
                            body: "Could not repair \(install.branch.appName): \(why). Backing off; see ~/Library/Logs/VencordGuard.")
            }
        default: break
        }
        return outcome
    }

    // MARK: - The actual file operations (mirrors patcher.go)

    private func patch() throws {
        let fm = FileManager.default
        let appAsar = install.appAsar
        let backup = install.backupAsar

        logDebug("renaming \(appAsar.path) -> \(backup.path)")
        try fm.moveItem(at: appAsar, to: backup)

        do {
            let stub = AsarStub.build(patcherPath: Paths.patcherJS.path)
            // Write to a sibling temp file, then rename into place, so a crash mid-write can
            // never leave a half-written app.asar.
            let tmp = install.resources.appendingPathComponent("app.asar.vgtmp")
            try? fm.removeItem(at: tmp)
            try stub.write(to: tmp, options: .atomic)
            try fm.moveItem(at: tmp, to: appAsar)
            logDebug("wrote \(stub.count)-byte stub -> \(appAsar.path)")
        } catch {
            // Undo the rename so we never leave Discord unbootable.
            logError("stub write failed, undoing rename")
            try? fm.moveItem(at: backup, to: appAsar)
            throw error
        }
    }

    private func unpatch() throws {
        let fm = FileManager.default
        let tmp = install.resources.appendingPathComponent("app.asar.tmp")
        try? fm.removeItem(at: tmp)
        try fm.moveItem(at: install.appAsar, to: tmp)
        do {
            try fm.moveItem(at: install.backupAsar, to: install.appAsar)
        } catch {
            try? fm.moveItem(at: tmp, to: install.appAsar)
            throw error
        }
        try? fm.removeItem(at: tmp)
    }

    /// Off by default. Only reachable when the user explicitly opts in via config.
    private func restartDiscord() {
        logWarn("autoRestartDiscord is enabled — asking \(install.branch.appName) to quit")
        let script = "tell application id \"\(install.branch.bundleID)\" to quit"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
        p.waitUntilExit()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-a", self.install.appURL.path]
            try? open.run()
        }
    }
}
