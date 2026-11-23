import AppKit
import Darwin

public struct CaptureOptions {
    public var includeScreenshot = true
    public var includeText = true
    public var maxImageEdge = 1800
    public var maxChars = 150_000
    /// Processes whose windows must be skipped (e.g. the AI client calling us).
    public var excludePIDs: Set<pid_t> = []
    public var excludeBundleIDs: Set<String> = []
    /// Capture a specific app (name or bundle id substring) instead of the frontmost one.
    public var appName: String?
    /// How many snapshots to keep on disk.
    public var keep = 100
    public init() {}
}

public enum SnapshotError: Error, CustomStringConvertible {
    case noTargetWindow(String?)
    case sensitiveApp(String)
    public var description: String {
        switch self {
        case .sensitiveApp(let name):
            return "AnySnap does not capture password managers (\(name)), to keep secrets out of snapshots."
        case .noTargetWindow(let name):
            if let name { return "No on-screen window found for app matching \"\(name)\"." }
            return "No suitable app window found to capture."
        }
    }
}

public enum Snapshotter {
    /// Never captured: password managers and keychain tools.
    public static let sensitiveBundleIDs: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "org.keepassxc.keepassxc", "com.dashlane.dashlanephonefinal",
        "com.apple.keychainaccess", "com.apple.Passwords", "in.sinew.Enpass-Desktop",
        "com.lastpass.LastPass", "com.nordpass.macos.NordPass", "com.proton.pass.electron",
    ]

    struct Target {
        let pid: pid_t
        let app: NSRunningApplication?
    }

    static func isExcluded(_ app: NSRunningApplication?, pid: pid_t, _ o: CaptureOptions, _ excluded: Set<pid_t>) -> Bool {
        if excluded.contains(pid) { return true }
        if let b = app?.bundleIdentifier, o.excludeBundleIDs.contains(b) { return true }
        return false
    }

    static func matches(_ app: NSRunningApplication?, name: String) -> Bool {
        (app?.localizedName?.localizedCaseInsensitiveContains(name) ?? false)
            || (app?.bundleIdentifier?.localizedCaseInsensitiveContains(name) ?? false)
    }

    static func findTarget(_ o: CaptureOptions, windows: [OnScreenWindow]) -> Target? {
        var excluded = o.excludePIDs
        excluded.insert(getpid())

        // 1. The frontmost app (hotkey case), unless excluded / filtered out.
        //    (Password managers are refused in capture(), not silently skipped here.)
        if o.appName == nil, let front = NSWorkspace.shared.frontmostApplication,
           !isExcluded(front, pid: front.processIdentifier, o, excluded),
           windows.contains(where: { $0.pid == front.processIdentifier }) {
            return Target(pid: front.processIdentifier, app: front)
        }
        // 2. Otherwise the top-most normal window that isn't excluded
        //    (MCP / CLI case: the AI client or terminal is in front).
        for w in windows {
            let app = NSRunningApplication(processIdentifier: w.pid)
            if isExcluded(app, pid: w.pid, o, excluded) { continue }
            guard app?.activationPolicy == .regular else { continue }
            if let b = app?.bundleIdentifier, sensitiveBundleIDs.contains(b) { continue }
            if let name = o.appName, !matches(app, name: name) { continue }
            return Target(pid: w.pid, app: app)
        }
        return nil
    }

    static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    /// Capture screenshot + accessibility text of the target window and store it.
    public static func capture(_ o: CaptureOptions) async throws -> SnapshotMeta {
        let windows = WindowCapture.orderedWindows()
        guard let target = findTarget(o, windows: windows) else {
            throw SnapshotError.noTargetWindow(o.appName)
        }
        let appName = target.app?.localizedName ?? "pid \(target.pid)"
        let bundleID = target.app?.bundleIdentifier
        if let b = bundleID, sensitiveBundleIDs.contains(b) {
            throw SnapshotError.sensitiveApp(appName)
        }
        var warnings: [String] = []

        // Text via Accessibility
        var ax: AXSnapshot?
        if o.includeText, AXReader.isTrusted() {
            ax = AXReader.snapshot(pid: target.pid, bundleID: bundleID, maxChars: o.maxChars)
        }
        let axHasText = !(ax?.text.isEmpty ?? true)

        // Finder: real paths of the folder and the selected files.
        var finder: FinderInfo.Result?
        // Only inside AnySnap.app: the MCP server blocks its main thread while capturing,
        // and Apple Events permission belongs to the app anyway.
        if bundleID == "com.apple.finder", Bundle.main.bundleIdentifier == CaptureBroker.appBundleID {
            finder = await MainActor.run { FinderInfo.query() }
        }

        // App-specific extras (terminal cwd, browser tabs, Office position, PDF page).
        var extras = ContextEnrichers.Result()
        if let bid = bundleID, Bundle.main.bundleIdentifier == CaptureBroker.appBundleID {
            let docPath = ax?.url.flatMap { $0.hasPrefix("file://") ? URL(string: $0)?.path : nil }
            let title = ax?.windowTitle
            let text = ax?.text ?? ""
            extras = await MainActor.run {
                ContextEnrichers.collect(bundleID: bid, documentPath: docPath, title: title, text: text)
            }
        }
        if let line = ax?.cursorLine, ContextEnrichers.showsCursorLine(bundleID) {
            extras.lines.append("Cursor line: \(line)")
        }
        warnings.append(contentsOf: extras.notes)
        let needOCR = o.includeText && !axHasText

        // Pick the CG window matching the AX focused window (fallback: front-most window of the app)
        let appWindows = windows.filter { $0.pid == target.pid }
        var chosen = appWindows.first
        if let f = ax?.windowFrame,
           let best = appWindows.min(by: { distance($0.bounds, f) < distance($1.bounds, f) }) {
            chosen = best
        }

        let (id, dir) = try SnapshotStore.newSnapshotDirectory(appName: appName)

        var shotPath: String?
        var ocrText: String?
        if o.includeScreenshot || needOCR {
            if let win = chosen {
                do {
                    // Full resolution for OCR; downscaled copy for the saved screenshot.
                    let full = try await WindowCapture.capture(windowID: win.id, maxEdge: 0)
                    if needOCR {
                        ocrText = OCR.recognize(full)
                        warnings.append("Accessibility is not available, so the window text was read with OCR from the screenshot. Only visible text is included (nothing scrolled off-screen).")
                    }
                    if o.includeScreenshot,
                       let data = WindowCapture.pngData(WindowCapture.scaled(full, maxEdge: o.maxImageEdge)) {
                        let url = dir.appendingPathComponent("screenshot.png")
                        try data.write(to: url)
                        shotPath = url.path
                    }
                } catch {
                    warnings.append("Screenshot failed (\(error.localizedDescription)). Check Screen Recording permission.")
                }
            } else {
                warnings.append("No on-screen window found for the screenshot.")
            }
        }
        if needOCR && ocrText == nil {
            warnings.append("No window text captured: Accessibility is not available and OCR needs a screenshot.")
        }
        let textSource: String? = axHasText ? "accessibility" : (ocrText.map { _ in "ocr" })
        var bodyText = axHasText ? (ax?.text ?? "") : (ocrText ?? "")
        if bodyText.count > o.maxChars { bodyText = String(bodyText.prefix(o.maxChars)) }

        let createdAt = Date()
        let contextURL = dir.appendingPathComponent("context.md")
        let frame = ax?.windowFrame ?? chosen?.bounds
        let meta = SnapshotMeta(
            id: id,
            createdAt: createdAt,
            appName: appName,
            bundleID: bundleID,
            pid: target.pid,
            windowTitle: ax?.windowTitle,
            url: ContextEnrichers.showsDocument(bundleID) ? ax?.url : nil,
            frame: frame.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] },
            screenshotPath: shotPath,
            contextPath: contextURL.path,
            textCharacters: bodyText.count,
            textTruncated: axHasText ? (ax?.truncated ?? false) : false,
            folderPath: finder?.folder,
            selectedPaths: (finder?.selection.isEmpty ?? true) ? nil : finder?.selection,
            details: extras.lines.isEmpty ? nil : extras.lines,
            browserTabs: extras.tabs.isEmpty ? nil : extras.tabs,
            textSource: textSource,
            warnings: warnings
        )
        try renderMarkdown(meta: meta, ax: ax, text: bodyText).write(to: contextURL, atomically: true, encoding: .utf8)
        try SnapshotStore.save(meta)
        SnapshotStore.prune(keep: o.keep)
        SnapshotStore.pruneExpired()
        return meta
    }

    static func renderMarkdown(meta: SnapshotMeta, ax: AXSnapshot?, text: String) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"

        var s = "# App snapshot: \(meta.appName)"
        if let t = meta.windowTitle, !t.isEmpty { s += " — \(t)" }
        s += "\n\n"
        s += "- App: \(meta.appName)\(meta.bundleID.map { " (`\($0)`)" } ?? "")\n"
        if let t = meta.windowTitle, !t.isEmpty { s += "- Window: \(t)\n" }
        if let u = meta.url {
            if u.hasPrefix("file://"), let path = URL(string: u)?.path, !path.isEmpty {
                s += "- File: `\(path)`\n"
            } else {
                s += "- URL: \(u)\n"
            }
        }
        if let f = meta.folderPath { s += "- Folder: `\(f)`\n" }
        for d in meta.details ?? [] { s += "- \(d)\n" }
        s += "- Captured: \(df.string(from: meta.createdAt))\n"
        s += "- Screenshot: \(meta.screenshotPath.map { "`\($0)`" } ?? "none")\n"
        s += "- Snapshot ID: `\(meta.id)`\n\n"
        if meta.textSource == "ocr" {
            s += "> The window text below was recognized (OCR) from the screenshot, so it only covers what is visible on screen and may contain recognition errors."
        } else {
            s += "> The window text below was read from the macOS accessibility tree. It includes content that is scrolled out of view, so it can be longer than what is visible in the screenshot."
        }
        if meta.textTruncated { s += " The text was truncated." }
        s += "\n"

        if !meta.warnings.isEmpty {
            s += "\n## Warnings\n\n" + meta.warnings.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        if let paths = meta.selectedPaths, !paths.isEmpty {
            s += "\n## Selected files\n\n" + paths.map { p in
                "- `\(p)`" + (ContextEnrichers.fileSummary(p).map { " — \($0)" } ?? "")
            }.joined(separator: "\n") + "\n"
        }
        if let tabs = meta.browserTabs, !tabs.isEmpty {
            s += "\n## Tabs in this browser window\n\n" + tabs.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        if let sel = ax?.selectedText {
            s += "\n## Selected text\n\n\(sel)\n"
        }
        s += "\n## Window text\n\n"
        s += text.isEmpty ? "(no text captured)\n" : text + "\n"
        return s
    }

    // MARK: host app detection

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 1 ? ppid : nil
    }

    /// The GUI app that (indirectly) launched this process, e.g. Claude Desktop for an MCP
    /// server or Terminal/iTerm for a CLI call. Its windows are skipped when capturing.
    public static func hostApplicationPID() -> pid_t? {
        var pid = getppid()
        var hops = 0
        while pid > 1 && hops < 25 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                return pid
            }
            guard let parent = parentPID(of: pid) else { return nil }
            pid = parent
            hops += 1
        }
        return nil
    }
}
