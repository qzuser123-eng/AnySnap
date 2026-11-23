import Foundation
import AnySnapCore

enum HotkeyKind: String {
    case leftRightCommand   // left ⌘ + right ⌘ (default, like Codex)
    case leftRightOption    // left ⌥ + right ⌥
    case doubleCommand      // tap ⌘ twice
    case custom             // any key combo, e.g. ⌃⌥⌘S
}

enum Destination: String {
    case clipboard  // copy, user pastes wherever they want
    case claude     // copy + bring Claude Desktop forward + ⌘V
    case saveOnly   // just store it; agents read it via MCP / CLI
}

struct CustomHotkey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt
    var label: String
}

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        // The bundle id used to be com.appsnap.AppSnap: copy its settings over once.
        guard !d.bool(forKey: "migratedFromAppSnap") else { return }
        if let old = UserDefaults(suiteName: "com.appsnap.AppSnap") {
            for key in ["hotkeyKind", "customHotkey", "destination", "clipboardFormat", "playSound", "includeScreenshot"] {
                if d.object(forKey: key) == nil, let v = old.object(forKey: key) { d.set(v, forKey: key) }
            }
        }
        d.set(true, forKey: "migratedFromAppSnap")
    }

    var hotkeyKind: HotkeyKind {
        get { HotkeyKind(rawValue: d.string(forKey: "hotkeyKind") ?? "") ?? .leftRightCommand }
        set { d.set(newValue.rawValue, forKey: "hotkeyKind") }
    }

    var customHotkey: CustomHotkey? {
        get {
            guard let data = d.data(forKey: "customHotkey") else { return nil }
            return try? JSONDecoder().decode(CustomHotkey.self, from: data)
        }
        set {
            if let v = newValue, let data = try? JSONEncoder().encode(v) {
                d.set(data, forKey: "customHotkey")
            } else {
                d.removeObject(forKey: "customHotkey")
            }
        }
    }

    var destination: Destination {
        get { Destination(rawValue: d.string(forKey: "destination") ?? "") ?? .claude }
        set { d.set(newValue.rawValue, forKey: "destination") }
    }

    var clipboardFormat: ClipboardFormat {
        get { ClipboardFormat(rawValue: d.string(forKey: "clipboardFormat") ?? "") ?? .auto }
        set { d.set(newValue.rawValue, forKey: "clipboardFormat") }
    }

    var playSound: Bool {
        get { d.object(forKey: "playSound") as? Bool ?? true }
        set { d.set(newValue, forKey: "playSound") }
    }

    var includeScreenshot: Bool {
        get { d.object(forKey: "includeScreenshot") as? Bool ?? true }
        set { d.set(newValue, forKey: "includeScreenshot") }
    }

    var hotkeyLabel: String {
        switch hotkeyKind {
        case .leftRightCommand: return "左⌘ + 右⌘"
        case .leftRightOption: return "左⌥ + 右⌥"
        case .doubleCommand: return "双击 ⌘"
        case .custom: return customHotkey?.label ?? "左⌘ + 右⌘"
        }
    }
}
