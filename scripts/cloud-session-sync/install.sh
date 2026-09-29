#!/usr/bin/env bash
# Installs the PokeTokenBar cloud-session sync hook at user level (~/.claude), so every
# Claude Code on the web session in this environment reports its token usage — whichever
# repository it works on. Meant for the cloud environment's setup script:
#
#   curl -fsSL https://raw.githubusercontent.com/cte13/PokeTokenBar-iOS/main/scripts/cloud-session-sync/install.sh | bash
#
# Idempotent: re-running replaces the script and leaves one hook entry per event.
set -euo pipefail

REPO_RAW="${PTB_SYNC_RAW_BASE:-https://raw.githubusercontent.com/cte13/PokeTokenBar-iOS/main}"
HOOK_DIR="$HOME/.claude/hooks"
HOOK="$HOOK_DIR/ptb-cloud-sync.mjs"
SETTINGS="$HOME/.claude/settings.json"

mkdir -p "$HOOK_DIR"
LOCAL_SRC=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  LOCAL_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ptb-cloud-sync.mjs"
fi
if [ -n "$LOCAL_SRC" ] && [ -f "$LOCAL_SRC" ]; then
  cp "$LOCAL_SRC" "$HOOK"
else
  curl -fsSL "$REPO_RAW/scripts/cloud-session-sync/ptb-cloud-sync.mjs" -o "$HOOK"
fi

node - "$SETTINGS" "$HOOK" <<'EOF'
const fs = require('fs');
const [settingsPath, hookPath] = process.argv.slice(2);
let settings = {};
try { settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8')); } catch {}
settings.hooks ??= {};
const command = `node "${hookPath}"`;
for (const event of ['Stop', 'SubagentStop', 'SessionEnd']) {
  const groups = (settings.hooks[event] ??= []);
  const present = groups.some((g) => (g.hooks ?? []).some((h) => String(h.command ?? '').includes('ptb-cloud-sync')));
  if (!present) groups.push({ hooks: [{ type: 'command', command, timeout: 60 }] });
}
fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n');
EOF

echo "PokeTokenBar cloud-session sync hook installed at $HOOK"
