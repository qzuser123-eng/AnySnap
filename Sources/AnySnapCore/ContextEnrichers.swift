#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// Extra, app-specific context that the screenshot can't show: a terminal's working
/// directory, the other tabs of a browser window, the Excel sheet / PowerPoint slide,
/// the PDF page, details of selected files. Runs inside AnySnap.app on the main thread
/// (NSAppleScript); each app asks once for "AnySnap wants to control …" permission.
public enum ContextEnrichers {
    public struct Result {
        public var lines: [String] = []   // "Key: value" lines for the header
        public var tabs: [String] = []    // "title — url"
        public var notes: [String] = []   // why something could not be read
    }

    static let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2"]

    /// Is the "File:" from the window's document attribute meaningful for this app?
    /// (Terminal reports the shell's home folder there, which is misleading.)
    public static func showsDocument(_ bundleID: String?) -> Bool {
        guard let b = bundleID else { return true }
        return !terminals.contains(b)
    }

    /// Cursor line only makes sense for editors, not terminals or browsers.
    public static func showsCursorLine(_ bundleID: String?) -> Bool {
        guard let b = bundleID else { return true }
        return !terminals.contains(b) && !chromeFamily.contains(b) && b != "com.apple.Safari"
    }

    static var lastError: String?

    static let chromeFamily: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
    ]
    static let pdfApps: Set<String> = [
        "com.apple.Preview", "com.adobe.Acrobat.Pro", "com.adobe.Reader", "net.sourceforge.skim-app.skim",
        "com.readdle.PDFExpert-Mac", "org.zotero.zotero",
    ]

    @MainActor
    public static func collect(bundleID: String, documentPath: String?, title: String?, text: String) -> Result {
        var r = Result()
        lastError = nil
        switch bundleID {
        case "com.apple.Terminal":
            terminal(script: "tell application id \"com.apple.Terminal\" to return tty of selected tab of front window", into: &r)
        case "com.googlecode.iterm2":
            terminal(script: "tell application id \"com.googlecode.iterm2\" to return tty of current session of current window", into: &r)
        case "com.apple.Safari":
            r.tabs = tabs(into: &r, windowTitle: title, script: """
            tell application id "com.apple.Safari"
                set out to ""
                repeat with w in windows
                    try
                        set out to out & "WIN" & (character id 9) & (name of current tab of w) & linefeed
                        set i to 0
                        repeat with t in tabs of w
                            set i to i + 1
                            if i > 40 then exit repeat
                            set out to out & (name of t) & (character id 9) & (URL of t) & linefeed
                        end repeat
                    end try
                end repeat
                return out
            end tell
            """)
        case let b where chromeFamily.contains(b):
            r.tabs = tabs(into: &r, windowTitle: title, script: """
            tell application id "\(b)"
                set out to ""
                repeat with w in windows
                    try
                        set out to out & "WIN" & (character id 9) & (title of active tab of w) & linefeed
                        set i to 0
                        repeat with t in tabs of w
                            set i to i + 1
                            if i > 40 then exit repeat
                            set out to out & (title of t) & (character id 9) & (URL of t) & linefeed
                        end repeat
                    end try
                end repeat
                return out
            end tell
            """)
        case "com.microsoft.Word":
            if documentPath == nil, let p = run("tell application id \"com.microsoft.Word\" to return POSIX path of (full name of active document)") {
                r.lines.append("File: `\(p)`")
            }
        case "com.microsoft.Excel":
            if let out = run("""
            tell application id "com.microsoft.Excel"
                set s to name of active sheet
                set p to ""
                try
                    set p to POSIX path of (full name of active workbook)
                end try
                return s & (character id 9) & p
            end tell
            """) {
                let parts = out.components(separatedBy: "\t")
                if let sheet = parts.first, !sheet.isEmpty { r.lines.append("Excel sheet: \(sheet)") }
                if documentPath == nil, parts.count > 1, parts[1].hasPrefix("/") { r.lines.append("File: `\(parts[1])`") }
            }
        case "com.microsoft.Powerpoint":
            if let out = run("""
            tell application id "com.microsoft.Powerpoint"
                set n to slide index of slide of view of active window
                set c to count of slides of active presentation
                set p to ""
                try
                    set p to POSIX path of (full name of active presentation)
                end try
                return (n as text) & (character id 9) & (c as text) & (character id 9) & p
            end tell
            """) {
                let parts = out.components(separatedBy: "\t")
                if parts.count >= 2 { r.lines.append("PowerPoint slide: \(parts[0]) / \(parts[1])") }
                if documentPath == nil, parts.count > 2, parts[2].hasPrefix("/") { r.lines.append("File: `\(parts[2])`") }
            }
        default:
            break
        }

        // PDF page ("第 3 页，共 10 页", "Page 3 of 10", "3 / 10" in a PDF viewer)
        let isPDF = (documentPath?.lowercased().hasSuffix(".pdf") ?? false) || pdfApps.contains(bundleID)
        if isPDF, let page = pdfPage(in: (title ?? "") + "\n" + String(text.prefix(4000))) {
            r.lines.append("PDF page: \(page)")
        }
        return r
    }

    // MARK: helpers

    static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let out = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            let msg = error[NSAppleScript.errorMessage] as? String ?? "unknown error"
            lastError = code == -1743
                ? "macOS did not allow AnySnap to control this app (System Settings → Privacy & Security → Automation)"
                : "\(msg) (\(code))"
            return nil
        }
        guard let s = out?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// Tabs of the browser window that was captured (matched by its active tab's title,
    /// because AppleScript's "front window" is not necessarily the captured one).
    static func tabs(into r: inout Result, windowTitle: String?, script: String) -> [String] {
        guard let out = run(script) else {
            if let e = lastError { r.notes.append("Could not list browser tabs: \(e)") }
            return []
        }
        var windows: [(active: String, tabs: [String])] = []
        for line in out.components(separatedBy: .newlines) {
            let p = line.components(separatedBy: "\t")
            if p.first == "WIN" {
                windows.append((p.count > 1 ? p[1] : "", []))
            } else if p.count >= 2, !p[1].isEmpty, !windows.isEmpty {
                windows[windows.count - 1].tabs.append("\(p[0]) — \(p[1])")
            }
        }
        let wt = windowTitle ?? ""
        let match = windows.first { !$0.active.isEmpty && wt.contains($0.active) } ?? windows.first
        guard let tabs = match?.tabs, tabs.count >= 2 else { return [] } // one tab = the window itself
        return tabs
    }

    static func pdfPage(in s: String) -> String? {
        let patterns = [
            #"第\s*(\d+)\s*页[，,\s]*共\s*(\d+)\s*页"#,
            #"第\s*(\d+)\s*/\s*(\d+)\s*页"#,
            #"[Pp]age\s+(\d+)\s+of\s+(\d+)"#,
            #"(?m)^\s*(\d+)\s*/\s*(\d+)\s*$"#,
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let a = Range(m.range(at: 1), in: s), let b = Range(m.range(at: 2), in: s) else { continue }
            return "\(s[a]) / \(s[b])"
        }
        return nil
    }

    /// Terminal / iTerm: tty → processes on it → working directory of the foreground one.
    static func terminal(script: String, into r: inout Result) {
        guard let tty = run(script), tty.hasPrefix("/dev/") else {
            if let e = lastError { r.notes.append("Could not read the terminal's directory: \(e)") }
            return
        }
        let ttyName = String(tty.dropFirst(5))
        guard let ps = shell("/bin/ps", ["-t", ttyName, "-o", "pid=,stat=,comm="]) else { return }
        var shellPID: String?
        var foreground: (pid: String, name: String)?
        for line in ps.components(separatedBy: .newlines) {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
            guard f.count == 3 else { continue }
            let comm = f[2].trimmingCharacters(in: .whitespaces)
            let name = (comm as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if ["zsh", "bash", "fish", "sh"].contains(name) { shellPID = f[0] }
            if f[1].contains("+") { foreground = (f[0], name) }
        }
        let pid = foreground?.pid ?? shellPID
        if let pid, let out = shell("/usr/sbin/lsof", ["-a", "-p", pid, "-d", "cwd", "-Fn"]),
           let line = out.components(separatedBy: .newlines).first(where: { $0.hasPrefix("n/") }) {
            r.lines.append("Working directory: `\(line.dropFirst())`")
        }
        if let fg = foreground, !["zsh", "bash", "fish", "sh", "login"].contains(fg.name) {
            r.lines.append("Running in terminal: \(fg.name)")
        }
    }

    static func shell(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// "54 KB · 2026-11-20 14:03 · JavaScript" for a selected file.
    public static func fileSummary(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey,
                                                        .contentTypeKey, .isDirectoryKey]) else { return nil }
        var parts: [String] = []
        if v.isDirectory == true {
            parts.append("folder")
        } else if let size = v.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if let d = v.contentModificationDate {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            parts.append("modified \(f.string(from: d))")
        }
        if v.isDirectory != true, let type = v.contentType?.localizedDescription { parts.append(type) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
#endif
