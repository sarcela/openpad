#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

mkdir -p .githooks

cat > .githooks/post-commit << 'EOF'
#!/usr/bin/env bash
set -e
branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "$branch" = "main" ]; then
  git push origin main || true
fi
EOF

chmod +x .githooks/post-commit

git config core.hooksPath .githooks

echo "✅ Auto-push hook instalado (post-commit en main)."
echo "Usa ./scripts/sync-openpad.sh para pull+commit+push en un solo comando."
