import Foundation

/// Asks Finder (via Apple Events) for the front window's folder and the selected items.
/// The first call triggers macOS's "AnySnap wants to control Finder" prompt.
public enum FinderInfo {
    public struct Result {
        public var folder: String?
        public var selection: [String]
    }

    static let script = """
    tell application "Finder"
        set out to ""
        try
            set out to POSIX path of (target of front Finder window as alias)
        end try
        try
            repeat with f in (get selection)
                set out to out & linefeed & "SEL:" & POSIX path of (f as alias)
            end repeat
        end try
        return out
    end tell
    """

    /// Must run on the main thread (NSAppleScript is not thread-safe).
    public static func query() -> Result? {
        var error: NSDictionary?
        guard let output = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue,
              error == nil else { return nil }
        var result = Result(folder: nil, selection: [])
        for line in output.components(separatedBy: .newlines) where !line.isEmpty {
            if line.hasPrefix("SEL:") {
                result.selection.append(String(line.dropFirst(4)))
            } else if result.folder == nil {
                result.folder = line
            }
        }
        return result
    }
}
