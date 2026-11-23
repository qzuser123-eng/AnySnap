#if os(macOS)
import AppKit

/// Lets the CLI / MCP server ask the running AnySnap.app to take the capture.
///
/// macOS attributes privacy permissions to the *responsible* app: an MCP server started by
/// Claude Desktop runs with Claude's permissions, which on macOS 27.3+ cannot include
/// Accessibility. AnySnap.app holds the permissions, so it should do the capture.
///
/// Protocol (plain files, no IPC dependencies):
///   client writes   requests/<id>.request.json   (atomically)
///   app writes      requests/<id>.response.json  { snapshotID | error }
public enum CaptureBroker {
    public static let appBundleID = "com.anysnap.AnySnap"

    public struct Request: Codable {
        public var id: String
        public var appName: String?
        public var excludePIDs: [Int32]
        public var includeScreenshot: Bool
    }

    struct Response: Codable {
        var snapshotID: String?
        var error: String?
    }

    public enum BrokerError: Error, CustomStringConvertible {
        case failed(String)
        public var description: String {
            switch self { case .failed(let s): return s }
        }
    }

    public static var requestsDir: URL {
        SnapshotStore.root.deletingLastPathComponent().appendingPathComponent("requests", isDirectory: true)
    }

    public static func isAppRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID).isEmpty
    }

    // MARK: client side

    /// Ask AnySnap.app to capture. Returns nil when the app is not running or did not answer
    /// in time, so the caller can fall back to capturing in-process. The timeout is generous
    /// because the first capture of an app may wait on macOS's "allow AnySnap to control …" prompt.
    public static func requestCapture(_ o: CaptureOptions, timeout: TimeInterval = 45) -> Result<SnapshotMeta, Error>? {
        guard isAppRunning() else { return nil }
        let fm = FileManager.default
        try? fm.createDirectory(at: requestsDir, withIntermediateDirectories: true)

        let id = UUID().uuidString
        let req = Request(id: id, appName: o.appName, excludePIDs: Array(o.excludePIDs), includeScreenshot: o.includeScreenshot)
        guard let data = try? JSONEncoder().encode(req) else { return nil }
        let reqURL = requestsDir.appendingPathComponent("\(id).request.json")
        let tmpURL = requestsDir.appendingPathComponent(".\(id).tmp")
        do {
            try data.write(to: tmpURL)
            try fm.moveItem(at: tmpURL, to: reqURL)
        } catch {
            return nil
        }

        let respURL = requestsDir.appendingPathComponent("\(id).response.json")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let d = try? Data(contentsOf: respURL), let r = try? JSONDecoder().decode(Response.self, from: d) {
                try? fm.removeItem(at: respURL)
                if let sid = r.snapshotID, let meta = SnapshotStore.load(id: sid) {
                    return .success(meta)
                }
                return .failure(BrokerError.failed(r.error ?? "AnySnap could not capture the window."))
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try? fm.removeItem(at: reqURL) // nobody picked it up
        return nil
    }

    // MARK: app side

    /// Oldest pending request; stale ones (> 30 s) are discarded. The returned request file is
    /// removed (claimed) before returning.
    public static func claimNextRequest() -> Request? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: requestsDir.path) else { return nil }
        var candidates: [(Date, URL)] = []
        for n in names where n.hasSuffix(".request.json") {
            let url = requestsDir.appendingPathComponent(n)
            let date = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
            if Date().timeIntervalSince(date) > 30 {
                try? fm.removeItem(at: url)
                continue
            }
            candidates.append((date, url))
        }
        for (_, url) in candidates.sorted(by: { $0.0 < $1.0 }) {
            let data = try? Data(contentsOf: url)
            try? fm.removeItem(at: url)
            if let data, let req = try? JSONDecoder().decode(Request.self, from: data) {
                return req
            }
        }
        return nil
    }

    public static func respond(to requestID: String, snapshotID: String?, error: String?) {
        let url = requestsDir.appendingPathComponent("\(requestID).response.json")
        if let data = try? JSONEncoder().encode(Response(snapshotID: snapshotID, error: error)) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
#endif
