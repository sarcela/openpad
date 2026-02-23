#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

MSG="${1:-chore: auto-sync $(date -Iseconds)}"

# Trae cambios remotos primero (con autostash para evitar choques simples)
git pull --rebase --autostash origin main || true

# Si hay cambios locales, comitea y empuja
git add -A
if ! git diff --cached --quiet; then
  git commit -m "$MSG"
  git push origin main
  echo "✅ Cambios sincronizados con GitHub"
else
  echo "ℹ️ No hay cambios locales para sincronizar"
fi
