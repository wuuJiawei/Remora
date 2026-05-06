#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WEB_DIR="$ROOT_DIR/WebEditor"
DEST_DIR="$ROOT_DIR/Sources/RemoraApp/Resources/WebEditor"

cd "$WEB_DIR"

if [[ -f package-lock.json ]]; then
  npm ci
else
  npm install
fi

npm run build

rm -rf "$DEST_DIR"
mkdir -p "$DEST_DIR"
cp -R "$WEB_DIR"/dist/. "$DEST_DIR"/
