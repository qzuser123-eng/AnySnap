#!/bin/bash
# Build, install ~/Applications/AnySnap.app, link the CLI, point Claude Desktop's MCP
# config at it and (re)start the app.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

DEST="$HOME/Applications"
mkdir -p "$DEST"
pkill -x AnySnap 2>/dev/null || true
pkill -x AppSnap 2>/dev/null || true            # the app's old name
rm -rf "$DEST/AnySnap.app" "$DEST/AppSnap.app"
cp -R build/AnySnap.app "$DEST/"

# Data folder used to be called AppSnap
SUP="$HOME/Library/Application Support"
if [ -d "$SUP/AppSnap" ] && [ ! -d "$SUP/AnySnap" ]; then mv "$SUP/AppSnap" "$SUP/AnySnap"; fi

CLI="$DEST/AnySnap.app/Contents/Helpers/anysnap"
mkdir -p "$HOME/.local/bin"
rm -f "$HOME/.local/bin/appsnap"
ln -sf "$CLI" "$HOME/.local/bin/anysnap"

# Claude Desktop: if an AnySnap (or old "appsnap") MCP entry already exists, keep it
# pointing at the installed helper. Nothing is added otherwise (see README to set it up,
# or run with ANYSNAP_ADD_CLAUDE_MCP=1). A backup is made before the first change.
CFG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
if [ -f "$CFG" ]; then
  ANYSNAP_ADD_CLAUDE_MCP="${ANYSNAP_ADD_CLAUDE_MCP:-0}" python3 - "$CFG" "$CLI" <<'PY' || echo "⚠️  Could not update $CFG"
import json, shutil, sys, os
path, cli = sys.argv[1], sys.argv[2]
cfg = json.load(open(path))
servers = cfg.setdefault("mcpServers", {})
want = {"command": cli, "args": ["mcp"]}
had_old = servers.pop("appsnap", None) is not None
add_new = os.environ.get("ANYSNAP_ADD_CLAUDE_MCP") == "1"
if not (had_old or "anysnap" in servers or add_new):
    print("ℹ️  Claude Desktop is not set up for AnySnap yet: see README (or rerun with ANYSNAP_ADD_CLAUDE_MCP=1)")
    sys.exit(0)
if had_old or servers.get("anysnap") != want:
    backup = path + ".bak-anysnap"
    if not os.path.exists(backup):
        shutil.copy(path, backup)
    servers["anysnap"] = want
    json.dump(cfg, open(path, "w"), indent=2, ensure_ascii=False)
    print("✅ Claude Desktop MCP config updated → restart Claude (⌘Q) to apply")
PY
fi

open "$DEST/AnySnap.app"

cat <<MSG

✅ Installed $DEST/AnySnap.app (menu bar camera icon)
   CLI linked at ~/.local/bin/anysnap  (add ~/.local/bin to PATH if needed)

Other agents:
  Claude Code → claude mcp add -s user anysnap -- "$CLI" mcp
  Codex CLI   → codex mcp add anysnap -- "$CLI" mcp
MSG
