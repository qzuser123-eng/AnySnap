#if os(macOS)
import AppKit
import CoreGraphics

public enum ClipboardFormat: String, CaseIterable {
    /// Text reference for terminals, files for everything else.
    case auto
    /// screenshot.png + context.md as file attachments (Claude Desktop, ChatGPT, Finder ...)
    case files
    /// A short text block with paths; best for terminal agents that can read files.
    case reference
    /// Only the screenshot image.
    case image
}

public enum Delivery {
    public static let claudeBundleID = "com.anthropic.claudefordesktop"

    static let terminalBundles: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "io.alacritty", "org.alacritty",
        "com.github.wez.wezterm", "co.zeit.hyper", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
    ]

    public static func referenceText(_ m: SnapshotMeta) -> String {
        var s = "[AnySnap] \(m.appName)"
        if let t = m.windowTitle, !t.isEmpty { s += " — \(t)" }
        s += "\ncontext: \(m.contextPath)"
        if let p = m.screenshotPath { s += "\nscreenshot: \(p)" }
        return s
    }

    public static func resolve(_ format: ClipboardFormat, forApp bundleID: String?) -> ClipboardFormat {
        guard format == .auto else { return format }
        if let b = bundleID, terminalBundles.contains(b) { return .reference }
        return .files
    }

    public static func copy(_ m: SnapshotMeta, format: ClipboardFormat, forApp bundleID: String?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch resolve(format, forApp: bundleID) {
        case .reference, .auto:
            pb.setString(referenceText(m), forType: .string)
        case .image:
            if let p = m.screenshotPath, let img = NSImage(contentsOfFile: p) {
                pb.writeObjects([img])
            } else {
                pb.setString(referenceText(m), forType: .string)
            }
        case .files:
            var urls: [NSURL] = []
            if let p = m.screenshotPath { urls.append(NSURL(fileURLWithPath: p)) }
            urls.append(NSURL(fileURLWithPath: m.contextPath))
            pb.writeObjects(urls)
        }
    }

    /// Bring an app to the front (launching it if needed) and press ⌘V.
    public static func activateAndPaste(bundleID: String) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { sendPaste() }
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { sendPaste() }
            }
        }
    }

    static func sendPaste() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
#endif
