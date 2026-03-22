#!/bin/bash
# Build the standalone Python server binary with PyInstaller.
# Run this once before building the .app for distribution.
#
# Usage:
#   ./scripts/build_server_binary.sh
#
# Output:
#   dist/transcribe_server/   ← copy of this is bundled inside the .app

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Building Python server binary with PyInstaller..."
uv run pyinstaller server.spec --clean --noconfirm

echo ""
echo "==> Done! Binary at: dist/transcribe_server/transcribe_server"
echo "==> Now build the Xcode project — it will automatically bundle this binary."
