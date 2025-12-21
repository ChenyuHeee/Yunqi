#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

echo "[run] Workspace: $ROOT_DIR"

# Avoid mixed logs by stopping an already running debug binary (if any).
pkill -f "$ROOT_DIR/.build/debug/YunqiMacApp" >/dev/null 2>&1 || true
pkill -f "YunqiMacApp" >/dev/null 2>&1 || true

echo "[run] Building YunqiMacApp…"
swift build --product YunqiMacApp

echo "[run] Launching .build/debug/YunqiMacApp… (Ctrl+C to quit)"
exec "$ROOT_DIR/.build/debug/YunqiMacApp"
