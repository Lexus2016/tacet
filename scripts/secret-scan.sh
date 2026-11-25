#!/bin/bash
# Blocks credentials and signing material from entering the repository.
# Usage: scripts/secret-scan.sh [--staged]
#   --staged  scan only files staged for commit (used by .githooks/pre-commit)
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

if [ "${1:-}" = "--staged" ]; then
  files=$(git diff --cached --name-only --diff-filter=ACMR)
else
  files=$(git ls-files --cached --others --exclude-standard)
fi

[ -z "$files" ] && exit 0

fail=0

# 1. Forbidden file types.
blocked=$(printf '%s\n' "$files" | grep -Ei '(\.p8|\.p12|\.pfx|\.cer|\.cert|\.key|\.pem|\.mobileprovision|\.provisionprofile|(^|/)\.env(\.[^/]+)?|local\.xcconfig|Secrets\.plist)$' || true)
if [ -n "$blocked" ]; then
  echo "secret-scan: forbidden file type:" >&2
  printf '%s\n' "$blocked" | sed 's/^/  /' >&2
  fail=1
fi

# 2. Credential shapes. grep -I skips binary files.
patterns=(
  'gsk_[A-Za-z0-9]{20,}'
  'sk-[A-Za-z0-9_-]{20,}'
  'sk-ant-[A-Za-z0-9_-]{20,}'
  'xai-[A-Za-z0-9]{20,}'
  'gh[pousr]_[A-Za-z0-9]{30,}'
  're_[A-Za-z0-9_]{18,}'
  'AKIA[0-9A-Z]{16}'
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  "(^|[^[:alnum:]_])(api[_-]?key|secret|token|password)[\"']?[[:space:]]*[:=][[:space:]]*[\"'][[:alnum:]_+./=-]{24,}[\"']"
  '^[[:space:]]*(export[[:space:]]+)?[[:alnum:]_]*(API[_-]?KEY|SECRET|TOKEN|PASSWORD)[[:space:]]*=[[:space:]]*[[:alnum:]_+./=-]{24,}[[:space:]]*($|#)'
)

args=()
for pattern in "${patterns[@]}"; do
  args+=(-e "$pattern")
done

hits=$(printf '%s\n' "$files" | while IFS= read -r f; do
  if [ "${1:-}" = "--staged" ]; then
    git show ":$f" 2>/dev/null | grep -nEI "${args[@]}" | cut -d: -f1 | awk -v file="$f" '{print file ":" $0}'
  elif [ -f "$f" ]; then
    grep -nEI "${args[@]}" "$f" 2>/dev/null | cut -d: -f1 | awk -v file="$f" '{print file ":" $0}'
  fi
done)

if [ -n "$hits" ]; then
  echo "secret-scan: possible credential found:" >&2
  printf '%s\n' "$hits" | head -40 >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "Commit blocked. Keep keys in the Keychain at runtime, or add the file to .gitignore." >&2
  exit 1
fi

exit 0
