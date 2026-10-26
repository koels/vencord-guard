import Foundation

/// Fetches the four Vencord dist files from the official release, matching
/// `installLatestBuilds()` in the installer's github_downloader.go — same asset names,
/// same destination, same empty package.json marker.
///
/// This is the *only* code in the guard that touches the network, and it runs only when the
/// dist directory is missing or corrupt. A healthy machine never makes a request.
enum VencordDownloader {

    static let releaseURL = URL(string: "https://api.github.com/repos/Vendicated/Vencord/releases/latest")!
    static let fallbackURL = URL(string: "https://vencord.dev/releases/vencord")!
    static let userAgent = "VencordGuard (+https://github.com/Vencord/Installer)"
    static let wanted = ["patcher.js", "preload.js", "renderer.js", "renderer.css"]

    struct DownloadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func installLatestBuilds() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Paths.vencordDistDir, withIntermediateDirectories: true)

        // Without this, node walks up the tree looking for a package.json and can pick up an
        // unrelated one with "type": "module". Same reasoning as upstream.
        try? Data("{}".utf8).write(to: Paths.vencordDistDir.appendingPathComponent("package.json"))

        let release = try fetchRelease()
        guard let assets = release["assets"] as? [[String: Any]] else {
            throw DownloadError(message: "release JSON had no assets")
        }

        var downloaded = 0
        for asset in assets {
            guard let name = asset["name"] as? String,
                  wanted.contains(where: { name.hasPrefix($0) }),
                  let urlString = asset["browser_download_url"] as? String,
                  let url = URL(string: urlString) else { continue }

            let dest = Paths.vencordDistDir.appendingPathComponent(name)
            let (data, response) = try get(url)
            if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
                throw DownloadError(message: "\(name): HTTP \(http.statusCode)")
            }
            // Upstream's truncation check: compare what we read against Content-Length.
            if let http = response as? HTTPURLResponse,
               let declared = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
               declared != data.count {
                throw DownloadError(message: "\(name): expected \(declared) bytes, got \(data.count)")
            }
            try data.write(to: dest, options: .atomic)
            downloaded += 1
            logDebug("downloaded \(name) (\(data.count) bytes)")
        }

        guard downloaded > 0 else {
            throw DownloadError(message: "release contained none of \(wanted.joined(separator: ", "))")
        }
    }

    private static func fetchRelease() throws -> [String: Any] {
        for url in [releaseURL, fallbackURL] {
            do {
                let (data, response) = try get(url)
                if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
                    // GitHub's unauthenticated limit is 60/h, and some ISPs block it outright;
                    // upstream falls back to vencord.dev for exactly this case.
                    logWarn("\(url.host ?? "?") returned \(http.statusCode); trying fallback")
                    continue
                }
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return json
                }
            } catch {
                logWarn("release fetch from \(url.host ?? "?") failed: \(error)")
            }
        }
        throw DownloadError(message: "could not fetch Vencord release metadata")
    }

    /// Synchronous GET. The caller already runs on a background queue, and doing it this way
    /// keeps no URLSession alive between repairs.
    private static func get(_ url: URL) throws -> (Data, URLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        var result: Result<(Data, URLResponse), Error>!
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            if let error { result = .failure(error) }
            else if let data, let response { result = .success((data, response)) }
            else { result = .failure(DownloadError(message: "empty response from \(url)")) }
            sem.signal()
        }.resume()

        if sem.wait(timeout: .now() + 60) == .timedOut {
            throw DownloadError(message: "timed out fetching \(url)")
        }
        return try result.get()
    }
}
