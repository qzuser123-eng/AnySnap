# AGENTS.md — notes for coding agents working on AnySnap

AnySnap is a Swift Package (macOS 14+, Swift 5 language mode, no dependencies).

## Layout
- `Sources/AnySnapCore` — shared logic
  - `AXReader.swift` — Accessibility tree walk (full text incl. off-screen, selection, URL)
  - `WindowCapture.swift` — CGWindowList ordering + ScreenCaptureKit single-window capture
  - `Snapshotter.swift` — picks the target window, writes the snapshot, host-app detection
  - `SnapshotStore.swift` — on-disk store (`~/Library/Application Support/AnySnap/snapshots`, override with `APPSNAP_HOME`)
  - `Delivery.swift` — clipboard formats, activate + ⌘V paste
- `Sources/AnySnapBar` — menu bar app (hotkeys, settings in UserDefaults, menu)
- `Sources/anysnap` — CLI and stdio MCP server (hand-written JSON-RPC, newline-delimited)
- `scripts/build-app.sh` — builds `build/AnySnap.app`; `scripts/install.sh` installs to ~/Applications

## Build / test loop
```bash
swift build                      # compile check
./scripts/build-app.sh && open build/AnySnap.app
.build/debug/anysnap capture --context        # test capture from the terminal
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | .build/debug/anysnap mcp
```
Permissions (Accessibility, Screen Recording) are tied to the code signature. With ad-hoc
signing they must be re-granted after each rebuild; `scripts/make-dev-cert.sh` avoids that.

## Status
Builds cleanly with Swift 6.4 / macOS 27.3 (Swift 5 language mode). Tested: hotkey capture,
Chrome full-page text incl. off-screen, Finder paths, Terminal cwd, browser tabs, MCP in Claude Desktop.
Not yet tested on real windows: PDF page numbers, Office (Word/Excel/PowerPoint) details, editor cursor line.
Ideas: settings window, per-app exclude list, OCR fallback (Vision) for apps with poor AX support,
"Mini" floating composer like Codex.
