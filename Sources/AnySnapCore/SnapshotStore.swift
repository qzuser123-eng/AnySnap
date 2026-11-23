import Foundation

public let AnySnapVersion = "0.1.0"

/// Metadata written next to every snapshot as meta.json.
public struct SnapshotMeta: Codable {
    public var id: String
    public var createdAt: Date
    public var appName: String
    public var bundleID: String?
    public var pid: Int32
    public var windowTitle: String?
    public var url: String?
    /// x, y, width, height in global screen points (top-left origin)
    public var frame: [Double]?
    public var screenshotPath: String?
    public var contextPath: String
    public var textCharacters: Int
    public var textTruncated: Bool
    /// Finder: folder of the front window and the selected items (POSIX paths)
    public var folderPath: String?
    public var selectedPaths: [String]?
    /// App-specific extras ("Working directory: …", "Excel sheet: …", "PDF page: 3 / 10")
    public var details: [String]?
    /// Other tabs of the browser window ("title — url")
    public var browserTabs: [String]?
    /// "accessibility" (full text incl. off-screen) or "ocr" (visible text only)
    public var textSource: String?
    public var warnings: [String]
}

/// Snapshots live in ~/Library/Application Support/AnySnap/snapshots/<id>/
///   screenshot.png  – window image
///   context.md      – app/window info + accessibility text (what agents read)
///   meta.json       – SnapshotMeta
/// Override the location with the APPSNAP_HOME environment variable.
public enum SnapshotStore {
    public static var root: URL {
        let env = ProcessInfo.processInfo.environment
        if let custom = env["ANYSNAP_HOME"] ?? env["APPSNAP_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        _ = migrateOldFolder
        return supportDir.appendingPathComponent("AnySnap/snapshots", isDirectory: true)
    }

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// The app used to be called AppSnap: move its data folder over once.
    static let migrateOldFolder: Void = {
        let fm = FileManager.default
        let old = supportDir.appendingPathComponent("AppSnap", isDirectory: true)
        let new = supportDir.appendingPathComponent("AnySnap", isDirectory: true)
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
            try? fm.moveItem(at: old, to: new)
        }
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func json(_ meta: SnapshotMeta) -> String {
        guard let data = try? encoder.encode(meta) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func newSnapshotDirectory(appName: String, date: Date = Date()) throws -> (id: String, url: URL) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let safe = appName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let id = "\(f.string(from: date))-\(safe.isEmpty ? "app" : String(safe.prefix(40)))"
        let url = directory(for: id)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (id, url)
    }

    public static func directory(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    public static func save(_ meta: SnapshotMeta) throws {
        let dir = directory(for: meta.id)
        try encoder.encode(meta).write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        try meta.id.write(to: root.appendingPathComponent("latest"), atomically: true, encoding: .utf8)
    }

    public static func load(id: String) -> SnapshotMeta? {
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else { return nil }
        let url = directory(for: id).appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(SnapshotMeta.self, from: data)
    }

    public static func latest() -> SnapshotMeta? {
        if let id = try? String(contentsOf: root.appendingPathComponent("latest"), encoding: .utf8),
           let meta = load(id: id.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return meta
        }
        return list(limit: 1).first
    }

    static func allIDs() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0 != "latest" && !$0.hasPrefix(".") }.sorted(by: >)
    }

    public static func list(limit: Int = 20) -> [SnapshotMeta] {
        var out: [SnapshotMeta] = []
        for id in allIDs() {
            if let m = load(id: id) {
                out.append(m)
                if out.count >= limit { break }
            }
        }
        return out
    }

    public static func prune(keep: Int) {
        guard keep > 0 else { return }
        for id in allIDs().dropFirst(keep) {
            try? FileManager.default.removeItem(at: directory(for: id))
        }
    }

    // MARK: retention

    /// Days to keep snapshots (0 = forever). Stored as a small file next to the snapshots
    /// folder so the menu bar app, the CLI and the MCP server all see the same value.
    public static var retentionDays: Int {
        get {
            guard let s = try? String(contentsOf: retentionURL, encoding: .utf8),
                  let v = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)), v >= 0 else { return 3 }
            return v
        }
        set {
            try? FileManager.default.createDirectory(at: retentionURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? String(max(0, newValue)).write(to: retentionURL, atomically: true, encoding: .utf8)
        }
    }

    static var retentionURL: URL {
        root.deletingLastPathComponent().appendingPathComponent("retention-days")
    }

    /// Delete snapshots older than `retentionDays`.
    public static func pruneExpired(now: Date = Date()) {
        let days = retentionDays
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let fm = FileManager.default
        for id in allIDs() {
            let dir = directory(for: id)
            let attrs = try? fm.attributesOfItem(atPath: dir.path)
            let created = (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date) ?? now
            if created < cutoff {
                try? fm.removeItem(at: dir)
            }
        }
    }

    /// Delete every stored snapshot.
    public static func removeAll() {
        for id in allIDs() { try? FileManager.default.removeItem(at: directory(for: id)) }
        try? FileManager.default.removeItem(at: root.appendingPathComponent("latest"))
    }

    public static func context(of meta: SnapshotMeta) -> String {
        (try? String(contentsOfFile: meta.contextPath, encoding: .utf8)) ?? ""
    }
}
