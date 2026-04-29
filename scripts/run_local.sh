#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

echo "Remora repo: ${REPO_ROOT}"
echo "Git branch: $(git branch --show-current)"

exec swift run RemoraApp "$@"
