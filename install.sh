#!/bin/sh
# macOS / Linux installer: needs PowerShell 7 (`brew install powershell` on macOS).
# Usage: ./install.sh [-Names "1a2b3c4d=alice,5e6f7a8b=bob"] [-Uninstall]
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
if ! command -v pwsh >/dev/null 2>&1; then
  echo "PowerShell 7 (pwsh) is required. On macOS: brew install powershell" >&2
  exit 1
fi
exec pwsh -NoLogo -NoProfile -File "$DIR/install.ps1" "$@"
