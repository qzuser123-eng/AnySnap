import Foundation
import AnySnapCore

#if os(macOS)
let usage = """
anysnap \(AnySnapVersion) — app snapshots for AI agents

USAGE
  anysnap capture [--app NAME] [--no-screenshot] [--include-host] [--in-process] [--json|--context] [--copy]
      Capture the frontmost window. When run from a terminal, the terminal itself is skipped,
      so you get the window behind it. --app targets a specific app instead.
  anysnap latest [--json|--context]     Show the latest snapshot (taken with the hotkey)
  anysnap list [N]                      List recent snapshots
  anysnap show ID [--json|--context]    Show one snapshot
  anysnap mcp                           Run as an MCP server over stdio
  anysnap doctor                        Check permissions

Output defaults to a short reference with file paths; --context prints the full markdown,
--json prints metadata. Snapshots are stored in \(SnapshotStore.root.path)
"""

let args = Array(CommandLine.arguments.dropFirst())

func flag(_ name: String) -> Bool { args.contains(name) }

func value(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func printErr(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func output(_ m: SnapshotMeta) {
    if flag("--json") {
        print(SnapshotStore.json(m))
    } else if flag("--context") {
        print(SnapshotStore.context(of: m))
    } else {
        print(Delivery.referenceText(m))
    }
    if flag("--copy") {
        Delivery.copy(m, format: .files, forApp: nil)
    }
}

switch args.first ?? "help" {
case "capture":
    var o = CaptureOptions()
    o.includeScreenshot = !flag("--no-screenshot")
    o.appName = value("--app")
    if !flag("--include-host"), let host = Snapshotter.hostApplicationPID() {
        o.excludePIDs.insert(host)
    }
    do {
        if !flag("--in-process"), let viaApp = CaptureBroker.requestCapture(o) {
            output(try viaApp.get())
        } else {
            output(try await Snapshotter.capture(o))
        }
    } catch {
        printErr("capture failed: \(error)")
        exit(1)
    }

case "latest":
    guard let m = SnapshotStore.latest() else {
        printErr("no snapshots yet")
        exit(1)
    }
    output(m)

case "list":
    let n = args.count > 1 ? Int(args[1]) ?? 20 : 20
    let df = ISO8601DateFormatter()
    for m in SnapshotStore.list(limit: n) {
        print("\(m.id)\t\(df.string(from: m.createdAt))\t\(m.appName)\t\(m.windowTitle ?? "")")
    }

case "show":
    guard args.count > 1, let m = SnapshotStore.load(id: args[1]) else {
        printErr("snapshot not found")
        exit(1)
    }
    output(m)

case "mcp":
    MCPServer().run()

case "doctor":
    let host = Snapshotter.hostApplicationPID()
    print("anysnap \(AnySnapVersion)")
    print("Accessibility:    \(AXReader.isTrusted() ? "granted" : "NOT granted")")
    print("Screen Recording: \(WindowCapture.hasPermission() ? "granted" : "NOT granted")")
    print("Host app pid:     \(host.map(String.init) ?? "none")")
    print("Snapshot folder:  \(SnapshotStore.root.path)")
    print("")
    print("Note: macOS attributes these permissions to the app that launched anysnap")
    print("(Terminal, Claude Desktop, ...). Grant them to that app in System Settings → Privacy & Security.")

default:
    print(usage)
}
#else
// Linux/other builds: only the MCP server (tools report that AnySnap needs macOS).
switch CommandLine.arguments.dropFirst().first ?? "help" {
case "mcp":
    MCPServer().run()
default:
    print("anysnap \(AnySnapVersion) — AnySnap captures Mac windows and only works on macOS.\nUSAGE: anysnap mcp   (MCP server over stdio)")
}
#endif
