import AppKit
import ApplicationServices

/// Result of reading a window through the macOS Accessibility API.
public struct AXSnapshot {
    public var windowTitle: String?
    public var windowFrame: CGRect?
    public var url: String?
    public var selectedText: String?
    /// 1-based line of the text cursor in the focused editor, if the app reports it
    public var cursorLine: Int?
    public var text: String
    public var truncated: Bool
    public var nodeCount: Int
}

/// Reads the visible *and off-screen* text of a window from its accessibility tree.
/// Text areas report their full value (not only what is scrolled into view),
/// and web views expose the whole DOM, which is how we get "text scrolled off-screen".
public enum AXReader {
    public static func isTrusted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Chromium browsers only build their accessibility tree when asked.
    static let chromiumLike: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta",
        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium",
    ]

    // MARK: attribute helpers

    static func copy(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func element(_ v: AnyObject?) -> AXUIElement? {
        guard let v = v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func string(_ v: AnyObject?) -> String? {
        if let s = v as? String { return s }
        if let a = v as? NSAttributedString { return a.string }
        return nil
    }

    static func point(_ v: AnyObject?) -> CGPoint? {
        guard let v = v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ v: AnyObject?) -> CGSize? {
        guard let v = v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    static func isElectron(pid: pid_t) -> Bool {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
        let fw = url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path
        return FileManager.default.fileExists(atPath: fw)
    }

    /// Ask Electron / Chromium apps to expose their full accessibility tree.
    static func prepare(app: AXUIElement, pid: pid_t, bundleID: String?) -> Bool {
        AXUIElementSetMessagingTimeout(app, 1.0)
        var needsWarmup = false
        if isElectron(pid: pid) {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue as CFTypeRef)
            needsWarmup = true
        }
        if let b = bundleID, chromiumLike.contains(b) {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue as CFTypeRef)
            needsWarmup = true
        }
        return needsWarmup
    }

    // MARK: inline / layout-aware merging

    /// Containers whose text may be merged into visual lines.
    static let inlineContainers: Set<String> = [
        "AXGroup", "AXLink", "AXCell", "AXRow", "AXHeading", "AXListItem", "AXParagraph", "AXGenericElement",
    ]

    struct Leaf {
        let text: String
        let frame: CGRect
    }

    /// Collects the static-text leaves of a small container. Returns false (give up) when the
    /// subtree is too deep, too big or contains anything other than text containers.
    static func inlineLeaves(_ el: AXUIElement, depth: Int, into out: inout [Leaf]) -> Bool {
        let names = [kAXRoleAttribute, kAXValueAttribute, kAXChildrenAttribute,
                     kAXPositionAttribute, kAXSizeAttribute] as CFArray
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, names, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
              let v = raw as? [AnyObject], v.count == 5 else { return false }
        let role = v[0] as? String ?? ""
        if role == "AXStaticText" {
            let t = string(v[1]) ?? ""
            if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            let p = point(v[3]) ?? .zero
            let sz = size(v[4]) ?? .zero
            // Off-screen text may have no usable geometry (zero size): keep it, frame = .zero
            let frame = (sz.width < 1 || sz.height < 1) ? CGRect.zero : CGRect(origin: p, size: sz)
            out.append(Leaf(text: t, frame: frame))
            return out.count <= 40
        }
        guard depth < 3, inlineContainers.contains(role),
              let kids = v[2] as? [AXUIElement], !kids.isEmpty, kids.count <= 20 else { return false }
        for k in kids {
            if !inlineLeaves(k, depth: depth + 1, into: &out) { return false }
        }
        return true
    }

    /// Text of a small container laid out by position: spans on the same visual line are
    /// joined (e.g. a table row or "Life science" + "(480)"), different lines stay separate
    /// (e.g. a heading above its subtitle).
    static func layoutText(_ el: AXUIElement) -> String? {
        var leaves: [Leaf] = []
        guard inlineLeaves(el, depth: 0, into: &leaves), leaves.count >= 2 else { return nil }

        // No geometry (scrolled out of view): only merge tiny groups such as a table cell
        // "数学" + "(119)"; anything bigger is left to the normal line-per-element walk.
        if leaves.contains(where: { $0.frame == .zero }) {
            guard leaves.count <= 3, leaves.map({ $0.text.count }).reduce(0, +) <= 80 else { return nil }
            let text = leaves.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        // A wrapping paragraph (some span is taller than one line): keep document order and
        // join the spans directly, so bold/inline-code/link pieces stay inside the sentence.
        let lineHeight = leaves.map { $0.frame.height }.min() ?? 0
        // (A big heading above a small subtitle is also "taller", so require that the tall span
        // actually shares lines with another span.)
        let wraps = leaves.contains { tall in
            tall.frame.height > lineHeight * 1.6 && leaves.contains { other in
                other.frame != tall.frame && other.frame.midY > tall.frame.minY && other.frame.midY < tall.frame.maxY
            }
        }
        if wraps {
            let text = leaves.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty || text.count > 3000 ? nil : text
        }

        var rows: [[Leaf]] = []
        for leaf in leaves.sorted(by: { $0.frame.midY < $1.frame.midY }) {
            if let ref = rows.last?.first,
               abs(ref.frame.midY - leaf.frame.midY) < max(2, min(ref.frame.height, leaf.frame.height) * 0.6) {
                rows[rows.count - 1].append(leaf)
            } else {
                rows.append([leaf])
            }
        }
        let lines: [String] = rows.map { row in
            var line = ""
            var prev: CGRect?
            for l in row.sorted(by: { $0.frame.minX < $1.frame.minX }) {
                if let p = prev, !line.hasSuffix(" "), !l.text.hasPrefix(" "),
                   l.frame.minX - p.maxX > max(2, l.frame.height * 0.25) {
                    line += " "
                }
                line += l.text
                prev = l.frame
            }
            return line.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        let text = lines.joined(separator: "\n")
        return text.isEmpty || text.count > 3000 ? nil : text
    }

    // MARK: snapshot

    public static func snapshot(pid: pid_t,
                                bundleID: String?,
                                maxNodes: Int = 15_000,
                                maxChars: Int = 150_000,
                                timeBudget: TimeInterval = 4.0) -> AXSnapshot? {
        let app = AXUIElementCreateApplication(pid)
        if prepare(app: app, pid: pid, bundleID: bundleID) {
            Thread.sleep(forTimeInterval: 0.25)
        }

        let windows = copy(app, kAXWindowsAttribute) as? [AXUIElement]
        guard let win = element(copy(app, kAXFocusedWindowAttribute))
                ?? element(copy(app, kAXMainWindowAttribute))
                ?? windows?.first else {
            return nil
        }
        AXUIElementSetMessagingTimeout(win, 0.5)

        var snap = AXSnapshot(windowTitle: string(copy(win, kAXTitleAttribute)),
                              windowFrame: nil, url: nil, selectedText: nil, cursorLine: nil,
                              text: "", truncated: false, nodeCount: 0)
        if let p = point(copy(win, kAXPositionAttribute)), let s = size(copy(win, kAXSizeAttribute)) {
            snap.windowFrame = CGRect(origin: p, size: s)
        }
        if let doc = string(copy(win, kAXDocumentAttribute)), !doc.isEmpty {
            snap.url = doc
        }
        if let focused = element(copy(app, kAXFocusedUIElementAttribute)) {
            if let sel = string(copy(focused, kAXSelectedTextAttribute)),
               !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                snap.selectedText = sel
            }
            // Apps report NSNotFound (Int.max) when there is no caret: ignore anything odd.
            if let n = copy(focused, kAXInsertionPointLineNumberAttribute) as? NSNumber,
               n.intValue >= 0, n.intValue < 10_000_000 {
                snap.cursorLine = n.intValue + 1
            }
        }

        // Depth-first walk in document order, batching attribute reads per element.
        let names = [kAXRoleAttribute, kAXValueAttribute, kAXTitleAttribute,
                     kAXDescriptionAttribute, kAXChildrenAttribute, "AXURL", kAXSizeAttribute] as CFArray
        var stack: [(AXUIElement, Int)] = [(win, 0)]
        var lines: [String] = []
        var chars = 0
        var lastLine = ""
        // Items already shown inside a merged row ("生命科学(480) 医药科学(230) ...").
        // Pages often repeat them elsewhere (other layouts / hidden tabs); skip those repeats.
        var rowItems = Set<String>()
        let deadline = Date().addingTimeInterval(timeBudget)

        while let item = stack.popLast() {
            let (el, depth) = item
            snap.nodeCount += 1
            if snap.nodeCount > maxNodes || chars > maxChars || Date() > deadline {
                snap.truncated = true
                break
            }
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(el, names, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
                  let vals = raw as? [AnyObject], vals.count == 7 else { continue }

            let role = vals[0] as? String ?? ""
            // NOTE: never skip by size. Chrome reports a zero size for text scrolled out of
            // view, and CSS float layouts give visible containers a height of 0.
            var text: String?
            var descend = true

            switch role {
            case "AXStaticText":
                text = string(vals[1]) ?? string(vals[2])
            case "AXTextArea":
                // Full contents, including text scrolled out of view.
                text = string(vals[1])
                descend = (text ?? "").isEmpty
            case "AXTextField", "AXSearchField", "AXComboBox":
                if let v = string(vals[1]), !v.isEmpty {
                    let label = string(vals[3]) ?? string(vals[2]) ?? ""
                    text = label.isEmpty ? "[field] \(v)" : "[field: \(label)] \(v)"
                    descend = false
                }
            case "AXImage":
                if let d = string(vals[3]), !d.isEmpty {
                    text = "[image: \(d)]"
                } else if let t = string(vals[2]), !t.isEmpty {
                    text = t // e.g. file names in Finder's icon view
                }
            case "AXWebArea":
                if snap.url == nil, let u = vals[5] as? URL { snap.url = u.absoluteString }
            default:
                break
            }

            // Inline runs: a container whose children are all static text (syntax-highlighted
            // code, links inside a sentence, ...) becomes ONE line instead of one line per span.
            var fromLayout = false
            if text == nil, descend, inlineContainers.contains(role), let kids = vals[4] as? [AXUIElement],
               kids.count >= 2, kids.count <= 20, let joined = layoutText(el) {
                text = joined
                descend = false
                fromLayout = true
            }

            if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                // Skip exact repeats and lines already contained in the previous line
                // (web apps often repeat a message in an aria label, e.g. "You said: X" then "X").
                let duplicate = t == lastLine || lastLine.hasSuffix(t) || (t.count >= 6 && lastLine.contains(t))
                    || (t.count >= 4 && !t.contains("\n") && rowItems.contains(t))
                if !duplicate {
                    // The reverse case: previous line was just a fragment of this one.
                    if !lastLine.isEmpty, t.count > lastLine.count, t.hasPrefix(lastLine) || t.hasSuffix(lastLine), let last = lines.last, last == lastLine {
                        chars -= last.count
                        lines.removeLast()
                    }
                    lines.append(t)
                    chars += t.count
                    lastLine = t
                    if fromLayout {
                        for line in t.split(separator: "\n") {
                            // merged pieces such as "数学(119)" or a row "A(1) B(2) C(3)"
                            rowItems.insert(String(line))
                            for item in line.split(separator: " ") where item.count >= 4 {
                                rowItems.insert(String(item))
                            }
                        }
                    }
                }
            }

            if descend, depth < 80, let kids = vals[4] as? [AXUIElement] {
                for k in kids.reversed() { stack.append((k, depth + 1)) }
            }
        }

        var joined = lines.joined(separator: "\n")
        if joined.count > maxChars {
            joined = String(joined.prefix(maxChars))
            snap.truncated = true
        }
        snap.text = joined
        return snap
    }
}
