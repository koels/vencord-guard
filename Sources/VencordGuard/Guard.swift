import Foundation
import AppKit

/// One of these per Discord install found on disk.
private final class Guarded {
    let install: DiscordInstall
    var resourcesWatcher: VnodeWatcher?
    var rendererTail: LogTailer?
    var updaterTail: LogTailer?

    /// Set while Discord's updater reports an install in progress. Suppresses all repairs.
    var updateInFlight = false
    var updateInFlightSince: Date?

    /// Set once we see Vencord announce itself in this Discord session's renderer log.
    var vencordConfirmedThisSession = false
    var sessionStarted: Date?
    var confirmDeadline: DispatchWorkItem?

    var isRunning = false

    /// Bounds self-scheduled re-checks so a permanently odd state can't turn into a timer
    /// loop. Reset whenever a genuine external event arrives.
    var retryBudget = 0

    init(install: DiscordInstall) { self.install = install }

    var key: String { install.appURL.path }
}

/// The event loop. It owns no timers except short, self-cancelling debounce items, so at rest
/// the process is parked in `NSRunLoop` with a handful of kqueue descriptors and zero wakeups.
final class GuardService {

    private let queue = DispatchQueue(label: "dev.vencordguard.main")
    private var guarded: [String: Guarded] = [:]      // keyed by app bundle path
    private var byBundleID: [String: [Guarded]] = [:]
    private var debounce: [String: DispatchWorkItem] = [:]

    // MARK: - Lifecycle

    func start() {
        let installs = DiscordInstall.discover(branches: Config.current.branches)
        guard !installs.isEmpty else {
            logWarn("no Discord install found in /Applications or ~/Applications; nothing to guard")
            logWarn("the guard will stay resident and pick one up when it appears")
            watchApplicationsFolders()
            observeWorkspace()
            return
        }

        for install in installs {
            let g = Guarded(install: install)
            guarded[g.key] = g
            byBundleID[install.branch.bundleID, default: []].append(g)
            logInfo("guarding \(install.branch.name): \(install.appURL.path) (Discord \(install.version ?? "?"))")
            armResourcesWatcher(g)
        }

        watchApplicationsFolders()
        observeWorkspace()

        // One check at startup covers the case where Vencord vanished while the agent
        // wasn't running (e.g. an update applied during a reboot).
        queue.async {
            for g in self.guarded.values {
                // Record our own bundle-write capability up front, so `doctor` can report the
                // agent's permission rather than the permission of whoever runs the command.
                let (canModify, why) = g.install.canModifyBundle()
                StateStore.shared.update(g.key) {
                    $0.agentCanModifyBundle = canModify
                    $0.agentPermissionCheckedAt = Date()
                }
                if canModify {
                    logInfo("permission check: agent can modify \(g.install.branch.appName)")
                } else {
                    logWarn("permission check: agent CANNOT modify \(g.install.branch.appName) — \(why ?? "unknown")")
                    logWarn("grant App Management to VencordGuard.app in System Settings > Privacy & Security")
                }

                g.isRunning = self.isDiscordRunning(g.install.branch.bundleID)
                if g.isRunning { self.beginSession(g) }
                self.evaluate(g, trigger: "agent start")
            }
        }
    }

    // MARK: - Signal 1: process lifecycle
    //
    // NSWorkspace app notifications come from the window server over Mach ports. They cost
    // nothing when nothing launches, and they fire the instant Discord appears — including
    // the relaunch Discord performs after it updates itself.

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                       object: nil, queue: nil) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier else { return }
            self?.queue.async { self?.discordLaunched(id) }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                       object: nil, queue: nil) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier else { return }
            self?.queue.async { self?.discordTerminated(id) }
        }
        logDebug("subscribed to NSWorkspace launch/terminate notifications")
    }

    private func discordLaunched(_ bundleID: String) {
        // A Discord we aren't guarding yet just started. That is the strongest possible proof
        // the install exists, so it doubles as the backstop for an /Applications vnode event
        // we missed (a copy from the installer DMG preserves mtimes and can slip past it).
        if byBundleID[bundleID] == nil, Branch.byBundleID(bundleID) != nil {
            rescanApplications()
        }
        guard let gs = byBundleID[bundleID] else { return }
        for g in gs {
            guard !g.isRunning else { continue }
            g.isRunning = true
            logInfo("\(g.install.branch.appName) launched")
            beginSession(g)
            evaluate(g, trigger: "Discord launched")
        }
    }

    private func discordTerminated(_ bundleID: String) {
        guard let gs = byBundleID[bundleID] else { return }
        for g in gs {
            guard g.isRunning else { continue }
            g.isRunning = false
            logInfo("\(g.install.branch.appName) exited")
            endSession(g)
            // Discord quitting is the safest possible moment to repair, and it is also the
            // moment right after an update finishes rewriting the bundle.
            evaluate(g, trigger: "Discord exited")
        }
    }

    private func isDiscordRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    // MARK: - Signal 2: the bundle's Resources directory
    //
    // A kqueue watch on exactly one directory — Contents/Resources — not a recursive scan.
    // Discord's updater swapping the bundle, or a manual VencordInstaller run, both land here.

    private func armResourcesWatcher(_ g: Guarded) {
        g.resourcesWatcher = VnodeWatcher(url: g.install.resources, queue: queue) { [weak self, weak g] event in
            guard let self, let g else { return }
            logDebug("fs event on \(g.install.branch.name)/Resources: \(event)")
            self.evaluate(g, trigger: "Contents/Resources changed", debounceSeconds: 5)
        }
        g.resourcesWatcher?.start()
    }

    /// A host update replaces the whole `.app`, which also invalidates the Resources watch.
    /// Watching the containing folder lets us notice the replacement bundle and re-arm, and
    /// lets us pick up a Discord install that appears after the agent started.
    private func watchApplicationsFolders() {
        for base in ["/Applications", Paths.home.appendingPathComponent("Applications").path]
        where fileExists(URL(fileURLWithPath: base)) {
            let w = VnodeWatcher(url: URL(fileURLWithPath: base),
                                 mask: [.write, .rename, .delete, .revoke],
                                 queue: queue) { [weak self] _ in
                self?.rescanApplications()
            }
            w.start()
            appFolderWatchers.append(w)
        }
    }
    private var appFolderWatchers: [VnodeWatcher] = []

    private func rescanApplications() {
        for g in guarded.values where !(g.resourcesWatcher?.isArmed ?? false) {
            g.resourcesWatcher?.rearmNow()
        }
        // A branch we've never seen before (fresh Discord install).
        for install in DiscordInstall.discover(branches: Config.current.branches)
        where guarded[install.appURL.path] == nil {
            let g = Guarded(install: install)
            guarded[g.key] = g
            byBundleID[install.branch.bundleID, default: []].append(g)
            logInfo("new Discord install appeared: \(install.appURL.path)")
            armResourcesWatcher(g)
            evaluate(g, trigger: "new install detected", debounceSeconds: 10)
        }
    }

    // MARK: - Signal 3: Discord's own logs, tailed only while it runs
    //
    // Two independent things come out of here:
    //   • the updater log tells us an update is *in progress* (so: do not repair yet)
    //   • the renderer log tells us Vencord actually *loaded* (so: the patch really works)

    private func beginSession(_ g: Guarded) {
        g.sessionStarted = Date()
        g.vencordConfirmedThisSession = false

        g.updaterTail = LogTailer(url: g.install.updaterLog, queue: queue) { [weak self, weak g] line in
            guard let self, let g else { return }
            self.handleUpdaterLine(g, line)
        }
        g.updaterTail?.start(fromEnd: true)

        guard Config.current.confirmViaRendererLog else { return }
        g.rendererTail = LogTailer(url: g.install.rendererLog, queue: queue) { [weak self, weak g] line in
            guard let self, let g else { return }
            self.handleRendererLine(g, line)
        }
        g.rendererTail?.start(fromEnd: true)

        // If Vencord hasn't announced itself within the window, the patch isn't doing its job
        // even though the files look right — check again with that knowledge.
        let deadline = DispatchWorkItem { [weak self, weak g] in
            guard let self, let g, g.isRunning, !g.vencordConfirmedThisSession else { return }
            if g.updateInFlight {
                logDebug("no Vencord banner yet, but an update is in flight; not concluding anything")
                return
            }
            logWarn("\(g.install.branch.appName) has been running for \(Int(Config.current.rendererConfirmTimeoutSeconds))s with no Vencord log output")
            self.evaluate(g, trigger: "no Vencord activity in renderer log")
        }
        g.confirmDeadline = deadline
        queue.asyncAfter(deadline: .now() + Config.current.rendererConfirmTimeoutSeconds, execute: deadline)
    }

    private func endSession(_ g: Guarded) {
        g.confirmDeadline?.cancel()
        g.confirmDeadline = nil
        g.rendererTail?.stop(); g.rendererTail = nil
        g.updaterTail?.stop();  g.updaterTail = nil
        g.updateInFlight = false
        g.updateInFlightSince = nil
    }

    private func handleRendererLine(_ g: Guarded, _ line: String) {
        // Vencord prefixes every log line with "Vencord" and a CSS badge. Seeing any of them
        // is proof the patcher ran, the renderer bundle loaded, and plugins started.
        if !g.vencordConfirmedThisSession, line.contains("Vencord") {
            g.vencordConfirmedThisSession = true
            g.confirmDeadline?.cancel()
            logInfo("Vencord confirmed live in \(g.install.branch.appName) (\(DiscordInstall.installedVencordHash() ?? "?"))")
            StateStore.shared.update(g.key) {
                $0.lastKnownHealth = "patched+confirmed"
                $0.consecutiveFailures = 0
            }
            return
        }
        // The splash screen reports update progress before the updater log is even opened.
        if line.contains("\"status\":\"downloading-updates\"") || line.contains("\"status\":\"installing-updates\"") {
            markUpdateInFlight(g, because: "splash screen reports an update")
        }
    }

    private func handleUpdaterLine(_ g: Guarded, _ line: String) {
        // These are the exact messages Discord's Rust updater emits. "Host to be installed"
        // is the one that matters on macOS: it precedes a full .app replacement pulled from
        // .../full.distro, and that replacement is what removes Vencord's patch.
        if line.contains("Host to be installed") {
            markUpdateInFlight(g, because: "host update queued (the .app bundle is about to be replaced)")
            if let v = line.range(of: "HostVersionTriple(") {
                logInfo("incoming host version: \(line[v.upperBound...].prefix(20))")
            }
            return
        }
        if line.contains("Executing host install tasks") {
            markUpdateInFlight(g, because: "host install started")
            return
        }
        if line.contains("Update to latest complete") || line.contains("Already up to date. Nothing to do.") {
            if g.updateInFlight {
                logInfo("Discord updater finished; re-checking Vencord")
                g.updateInFlight = false
                g.updateInFlightSince = nil
                evaluate(g, trigger: "Discord update finished", debounceSeconds: 5)
            }
            return
        }
    }

    private func markUpdateInFlight(_ g: Guarded, because reason: String) {
        if !g.updateInFlight {
            logInfo("update in flight for \(g.install.branch.name): \(reason) — repairs suspended")
        }
        g.updateInFlight = true
        g.updateInFlightSince = Date()

        // Safety valve: if the updater dies without a completion line, don't stay suspended
        // forever. One deferred item, not a repeating timer.
        queue.asyncAfter(deadline: .now() + 300) { [weak g] in
            guard let g, g.updateInFlight, let since = g.updateInFlightSince,
                  Date().timeIntervalSince(since) >= 300 else { return }
            logWarn("update-in-flight flag expired after 5 minutes without a completion line")
            g.updateInFlight = false
            g.updateInFlightSince = nil
            self.evaluate(g, trigger: "update flag expired")
        }
    }

    // MARK: - Evaluate & repair

    /// Coalesces bursts of events (a bundle swap produces dozens) into one health check.
    private func evaluate(_ g: Guarded, trigger: String, debounceSeconds: Double = 1.5) {
        if trigger != "scheduled re-check" { g.retryBudget = 20 }
        debounce[g.key]?.cancel()
        let work = DispatchWorkItem { [weak self, weak g] in
            guard let self, let g else { return }
            self.evaluateNow(g, trigger: trigger)
        }
        debounce[g.key] = work
        queue.asyncAfter(deadline: .now() + debounceSeconds, execute: work)
    }

    private func evaluateNow(_ g: Guarded, trigger: String) {
        let health = g.install.checkHealth()
        let version = g.install.version

        let previous = StateStore.shared.get(g.key)
        if previous.lastKnownDiscordVersion != version, let version {
            if let old = previous.lastKnownDiscordVersion {
                logInfo("\(g.install.branch.appName) version changed \(old) -> \(version)")
            }
        }
        StateStore.shared.update(g.key) {
            $0.lastKnownHealth = health.describe
            $0.lastKnownDiscordVersion = version
            if health.isHealthy { $0.hadOpenAsar = g.install.isOpenAsarInstalled }
        }

        // A confirmed-live session plus healthy files means there is genuinely nothing to do.
        if health.isHealthy {
            logDebug("check [\(trigger)] \(g.install.branch.name): healthy, no action")
            return
        }

        logInfo("check [\(trigger)] \(g.install.branch.name): \(health.describe)")

        let repairer = Repairer(install: g.install)
        switch repairer.gate(health: health, updateInFlight: g.updateInFlight, discordRunning: g.isRunning) {
        case .notNeeded:
            return
        case .skipped(let why, let retryAfter):
            logInfo("not repairing \(g.install.branch.name): \(why)")
            // A transient "no" must not lose the finding. Come back once, on a one-shot
            // deferred item — still no repeating timer.
            if let delay = retryAfter {
                if g.retryBudget > 0 {
                    g.retryBudget -= 1
                    logDebug("re-checking \(g.install.branch.name) in \(Int(delay))s (\(g.retryBudget) retries left)")
                    self.evaluate(g, trigger: "scheduled re-check", debounceSeconds: delay)
                } else {
                    logWarn("retry budget exhausted for \(g.install.branch.name); waiting for the next Discord launch or bundle change")
                }
            }
            return
        case .failed(let why):
            logError("gate error: \(why)")
            return
        case .succeeded:
            break   // allowed
        }

        _ = repairer.run(health: health, discordRunning: g.isRunning)

        // Re-arm the Resources watch: our own rename may have invalidated it.
        if !(g.resourcesWatcher?.isArmed ?? false) { g.resourcesWatcher?.rearmNow() }
    }

    // MARK: - One-shot modes (used by `vencord-guard status` / `check`)

    func statusReport() -> String {
        var out: [String] = []
        let installs = DiscordInstall.discover(branches: Config.current.branches)
        if installs.isEmpty { return "No Discord install found in /Applications or ~/Applications.\n" }
        out.append("Vencord dist: \(Paths.vencordDistDir.path)")
        out.append("  build: \(DiscordInstall.installedVencordHash() ?? "unknown")")
        out.append("  problem: \(installs[0].distProblem() ?? "none")")
        for i in installs {
            let s = StateStore.shared.get(i.appURL.path)
            out.append("")
            out.append("\(i.branch.appName) — \(i.appURL.path)")
            out.append("  Discord version : \(i.version ?? "?")")
            out.append("  running         : \(isDiscordRunning(i.branch.bundleID))")
            out.append("  health          : \(i.checkHealth().describe)")
            out.append("  OpenAsar        : \(i.isOpenAsarInstalled)")
            out.append("  repairs total   : \(s.totalRepairs)")
            out.append("  last success    : \(s.lastRepairSuccess.map(String.init(describing:)) ?? "never")")
            out.append("  last attempt    : \(s.lastRepairAttempt.map(String.init(describing:)) ?? "never")")
            out.append("  failures in row : \(s.consecutiveFailures)")
        }
        return out.joined(separator: "\n") + "\n"
    }

    func checkOnce(force: Bool) -> Int32 {
        var bad = 0
        for install in DiscordInstall.discover(branches: Config.current.branches) {
            let health = install.checkHealth()
            print("\(install.branch.appName): \(health.describe)")
            if health.isHealthy { continue }
            bad += 1
            guard force else { continue }
            let running = !NSRunningApplication.runningApplications(
                withBundleIdentifier: install.branch.bundleID).isEmpty
            let r = Repairer(install: install)
            switch r.gate(health: health, updateInFlight: false, discordRunning: running) {
            case .succeeded:
                if case .succeeded = r.run(health: health, discordRunning: running) { bad -= 1 }
            case .skipped(let why, _): print("  skipped: \(why)")
            default: break
            }
        }
        return bad == 0 ? 0 : 1
    }
}
