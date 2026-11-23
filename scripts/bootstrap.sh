#!/bin/bash
# Writes Configuration/Signing.local.xcconfig (gitignored) from a keychain identity.
# Without a real certificate the app is ad-hoc signed, and macOS resets Microphone and
# Accessibility permissions on every rebuild, so prefer a stable identity.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p Configuration
target=Configuration/Signing.local.xcconfig

if [ "${1:-}" != "--force" ] && [ -f "$target" ]; then
  echo "Signing already configured: $target"
  exit 0
fi

identity_line=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Developer ID Application" || true)
identity_name="Developer ID Application"

if [ -z "$identity_line" ]; then
  identity_line=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" || true)
  identity_name="Apple Development"
fi

if [ -z "$identity_line" ]; then
  echo "No code signing identity found. Falling back to ad-hoc signing."
  echo "Permission prompts will reappear after every rebuild."
  cat > "$target" <<'EOF'
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = -
DEVELOPMENT_TEAM =
EOF
  exit 0
fi

team=$(printf '%s' "$identity_line" | sed -n 's/.*(\([A-Z0-9]\{10\}\))".*/\1/p')
if [ -z "$team" ]; then
  echo "Could not read the team identifier from: $identity_line" >&2
  exit 1
fi

cat > "$target" <<EOF
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = $identity_name
DEVELOPMENT_TEAM = $team
EOF

echo "Signing configured: $identity_name, team $team"
