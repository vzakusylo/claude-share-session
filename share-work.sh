#!/bin/sh
# macOS / Linux wrapper: ./share-work.sh status | sync [-DryRun] | push | brief | resume | log | name <uuid> <name>
DIR="$(cd "$(dirname "$0")" && pwd)"
exec pwsh -NoLogo -NoProfile -File "$DIR/share-work.ps1" "$@"
