import Foundation

/// Small persisted record, one entry per Discord install. Survives logout/reboot so that
/// cooldowns and failure backoff are not reset by simply restarting the agent.
struct InstallState: Codable {
    var lastRepairAttempt: Date?
    var lastRepairSuccess: Date?
    var consecutiveFailures: Int = 0
    var lastKnownHealth: String = "unknown"
    var lastKnownDiscordVersion: String?
    var hadOpenAsar: Bool = false
    var totalRepairs: Int = 0
    /// Whether the *agent process* could modify this bundle, recorded by the agent itself.
    /// TCC permissions are attributed to the running process, so a check made from a terminal
    /// measures the terminal, not the agent. Only this field answers the real question.
    var agentCanModifyBundle: Bool?
    var agentPermissionCheckedAt: Date?
}

final class StateStore {
    static let shared = StateStore()
    private var installs: [String: InstallState] = [:]
    private let queue = DispatchQueue(label: "dev.vencordguard.state")

    private init() {
        try? FileManager.default.createDirectory(at: Paths.stateDir, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: Paths.stateFile),
           let s = try? JSONDecoder().decode([String: InstallState].self, from: d) {
            installs = s
        }
    }

    func get(_ key: String) -> InstallState {
        queue.sync { installs[key] ?? InstallState() }
    }

    func update(_ key: String, _ mutate: (inout InstallState) -> Void) {
        queue.sync {
            var s = installs[key] ?? InstallState()
            mutate(&s)
            installs[key] = s
            persist()
        }
    }

    func all() -> [String: InstallState] { queue.sync { installs } }

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(installs) else { return }
        try? d.write(to: Paths.stateFile, options: .atomic)
    }
}
