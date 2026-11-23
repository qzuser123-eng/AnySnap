import Foundation
import AnySnapCore

final class Box<T>: @unchecked Sendable {
    var value: T?
}

/// Minimal MCP server over stdio (newline-delimited JSON-RPC 2.0).
/// Works with Claude Desktop, Claude Code (any model backend), Codex, Cursor, etc.
final class MCPServer {
    private let out = FileHandle.standardOutput
    private let defaultMaxChars = 40_000

    private let instructions = """
    AnySnap lets the user share a Mac window with you. When the user presses the AnySnap hotkey \
    (left ⌘ + right ⌘ by default), only a screenshot of the window is pasted into the chat, while the \
    full window text (read from the accessibility tree, including content scrolled off-screen) is saved \
    as a snapshot. So whenever a user message contains a screenshot of an app window, or the user says \
    "look at this", "this window", "what I just captured" and similar, call get_latest_snapshot with \
    include_screenshot=false before answering, and use its text together with the image. If several \
    screenshots were sent, call list_snapshots and get_snapshot for the matching ones (compare app, \
    window title and time). Each result starts with how long ago it was taken: if the app/window \
    does not match the image, or it is clearly older than the screenshot the user just sent (for \
    example a manual screenshot), ignore it and rely on the image alone. Do not mention this lookup \
    to the user unless it fails or does not match. \
    Call capture_window to grab their frontmost window yourself when asked.
    """

    private var tools: [[String: Any]] {
        let shot: [String: Any] = ["type": "boolean", "description": "Attach the window screenshot (default true). Set false for text-only models."]
        let maxChars: [String: Any] = ["type": "integer", "description": "Max characters of window text to return (default \(defaultMaxChars))."]
        let app: [String: Any] = ["type": "string", "description": "Optional app name or bundle id, e.g. \"Safari\" or \"com.apple.Notes\"."]
        let limit: [String: Any] = ["type": "integer", "description": "Default 10."]
        let sid: [String: Any] = ["type": "string", "description": "Snapshot id from list_snapshots."]

        func schema(_ props: [String: Any], required: [String] = []) -> [String: Any] {
            var s: [String: Any] = ["type": "object", "properties": props]
            if !required.isEmpty { s["required"] = required }
            return s
        }
        func tool(_ name: String, _ description: String, _ inputSchema: [String: Any]) -> [String: Any] {
            ["name": name, "description": description, "inputSchema": inputSchema]
        }

        return [
            tool("get_latest_snapshot",
                 "Get the most recent app snapshot the user captured with the AnySnap hotkey. Call this whenever the user sends a screenshot of an app window: the chat only shows the image, this returns the window's full text (including text scrolled off-screen), app name, window title and URL. Use include_screenshot=false when the image is already in the chat.",
                 schema(["include_screenshot": shot, "max_chars": maxChars])),
            tool("capture_window",
                 "Capture the user's frontmost app window right now (the AI client's own window is skipped). Returns screenshot + accessibility text including off-screen text. Optionally target a specific app.",
                 schema(["app": app, "include_screenshot": shot, "max_chars": maxChars])),
            tool("list_snapshots",
                 "List recent snapshots (id, time, app, window title).",
                 schema(["limit": limit])),
            tool("get_snapshot",
                 "Get a specific snapshot by id (from list_snapshots).",
                 schema(["id": sid, "include_screenshot": shot, "max_chars": maxChars], required: ["id"])),
        ]
    }

    func run() {
        while let line = readLine(strippingNewline: true) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let data = line.data(using: .utf8),
                  let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                let err: [String: Any] = ["code": -32700, "message": "Parse error"]
                send(["jsonrpc": "2.0", "id": NSNull(), "error": err])
                continue
            }
            handle(msg)
        }
    }

    // MARK: JSON-RPC

    private func send(_ obj: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        d.append(0x0A)
        out.write(d)
    }

    private func reply(_ id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func fail(_ id: Any, _ code: Int, _ message: String) {
        let err: [String: Any] = ["code": code, "message": message]
        send(["jsonrpc": "2.0", "id": id, "error": err])
    }

    private func handle(_ msg: [String: Any]) {
        let method = msg["method"] as? String ?? ""
        guard let id = msg["id"], !(id is NSNull) else { return } // notification: no response
        let params = msg["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let version = params["protocolVersion"] as? String ?? "2025-06-18"
            let capabilities: [String: Any] = ["tools": [String: Any]()]
            let serverInfo: [String: Any] = ["name": "anysnap", "version": AnySnapVersion]
            reply(id, [
                "protocolVersion": version,
                "capabilities": capabilities,
                "serverInfo": serverInfo,
                "instructions": instructions,
            ])
        case "ping":
            reply(id, [:])
        case "tools/list":
            reply(id, ["tools": tools])
        case "tools/call":
            callTool(id, params)
        default:
            fail(id, -32601, "Method not found: \(method)")
        }
    }

    // MARK: tools

    private func callTool(_ id: Any, _ params: [String: Any]) {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        let withShot = args["include_screenshot"] as? Bool ?? true
        let maxChars = (args["max_chars"] as? NSNumber)?.intValue ?? defaultMaxChars

        switch name {
        case "get_latest_snapshot":
            guard let m = SnapshotStore.latest() else {
                return toolText(id, "No snapshots yet. Ask the user to focus the window they want to share and press the AnySnap hotkey (left ⌘ + right ⌘ by default), or call capture_window.", isError: true)
            }
            toolSnapshot(id, m, withShot: withShot, maxChars: maxChars)

        case "get_snapshot":
            guard let sid = args["id"] as? String, let m = SnapshotStore.load(id: sid) else {
                return toolText(id, "Snapshot not found.", isError: true)
            }
            toolSnapshot(id, m, withShot: withShot, maxChars: maxChars)

        case "list_snapshots":
            let limit = (args["limit"] as? NSNumber)?.intValue ?? 10
            let df = ISO8601DateFormatter()
            let lines = SnapshotStore.list(limit: limit).map { m in
                "- \(m.id) | \(df.string(from: m.createdAt)) | \(m.appName)\(m.windowTitle.map { " — \($0)" } ?? "")"
            }
            toolText(id, lines.isEmpty ? "No snapshots yet." : lines.joined(separator: "\n"), isError: false)

        case "capture_window":
            var o = CaptureOptions()
            o.includeScreenshot = withShot
            o.appName = (args["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let host = Snapshotter.hostApplicationPID() { o.excludePIDs.insert(host) }
            let opts = o
            let box = Box<Result<SnapshotMeta, Error>>()
            if let viaApp = CaptureBroker.requestCapture(opts) {
                // AnySnap.app did it with its own permissions (full accessibility text).
                box.value = viaApp
            } else {
                let sem = DispatchSemaphore(value: 0)
                Task {
                    do { box.value = .success(try await Snapshotter.capture(opts)) } catch { box.value = .failure(error) }
                    sem.signal()
                }
                sem.wait()
            }
            switch box.value {
            case .some(.success(let m)):
                toolSnapshot(id, m, withShot: withShot, maxChars: maxChars)
            case .some(.failure(let e)):
                toolText(id, "Capture failed: \(e)", isError: true)
            case .none:
                toolText(id, "Capture failed.", isError: true)
            }

        default:
            fail(id, -32602, "Unknown tool: \(name)")
        }
    }

    private func toolText(_ id: Any, _ text: String, isError: Bool) {
        let content: [[String: Any]] = [["type": "text", "text": text]]
        reply(id, ["content": content, "isError": isError])
    }

    private func toolSnapshot(_ id: Any, _ m: SnapshotMeta, withShot: Bool, maxChars: Int) {
        let age = Int(Date().timeIntervalSince(m.createdAt))
        let ageText = age < 120 ? "\(age) seconds" : (age < 7200 ? "\(age / 60) minutes" : "\(age / 3600) hours")
        var text = "[Snapshot taken \(ageText) ago — app: \(m.appName)\(m.windowTitle.map { ", window: \($0)" } ?? "")]\n\n"
            + SnapshotStore.context(of: m)
        if maxChars > 0, text.count > maxChars {
            text = String(text.prefix(maxChars)) + "\n\n[... truncated to \(maxChars) characters; full text: \(m.contextPath)]"
        }
        var content: [[String: Any]] = [["type": "text", "text": text]]
        if withShot, let p = m.screenshotPath, let jpg = WindowCapture.jpegData(fromImageAt: p) {
            content.append(["type": "image", "data": jpg.base64EncodedString(), "mimeType": "image/jpeg"])
        }
        reply(id, ["content": content, "isError": false])
    }
}
