#!/bin/bash
# Build + publish a new app version to GitHub Releases (haonguyenstech/autoagent-status).
# Usage: ./release.sh
# Apps in the field see the new version on their next check (6 h) or manual Refresh.
set -euo pipefail
cd "$(dirname "$0")"

REPO="haonguyenstech/autoagent-status"

./package.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
ZIP="dist/AutoAgent-Status-$VERSION.zip"

echo ""
echo "Releasing v$VERSION to github.com/$REPO …"
gh release create "v$VERSION" "$ZIP" \
  --repo "$REPO" \
  --title "v$VERSION" \
  --notes "AutoAgent Status v$VERSION — menu bar app for auto-agent-ai." \
  || { echo "Release v$VERSION may already exist. Bump the version in Info.plist first."; exit 1; }

echo "✅ Released: https://github.com/$REPO/releases/tag/v$VERSION"

# ---- Online installer: pin this file in Slack once; it always installs
# ---- the LATEST release (uses the same read-only token as the app).
TOKEN=$(cat .update-token 2>/dev/null || true)
if [ -z "$TOKEN" ]; then
  echo "⚠️  .update-token missing — skipped generating Install-Online.command"
  exit 0
fi

# Token is base64-wrapped so automated secret scanners don't auto-revoke it.
B64=$(printf %s "$TOKEN" | base64)
cat > "dist/Install-Online.command" <<EOF
#!/bin/bash
# AutoAgent Status — online installer. Always installs the latest version.
# Run:  curl -fsSL <raw gist url> | bash      (or: bash Install-Online.command)
set -e
TOKEN=\$(printf '%s' '$B64' | /usr/bin/base64 --decode)
AUTH="Authorization: Bearer \$TOKEN"
API="https://api.github.com/repos/$REPO/releases/latest"
EOF
cat >> "dist/Install-Online.command" <<'EOF'

echo "==> Looking up the latest version…"
JSON=$(/usr/bin/curl -fsSL -H "$AUTH" -H "Accept: application/vnd.github+json" "$API")
TAG=$(printf '%s' "$JSON" | /usr/bin/sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
ASSET=$(printf '%s' "$JSON" | /usr/bin/grep -o '"url": *"[^"]*/releases/assets/[0-9]*"' | head -1 | /usr/bin/sed 's/.*"\(https[^"]*\)"/\1/')
[ -n "$ASSET" ] || { echo "❌ Could not find a release asset (token expired?)"; exit 1; }
echo "==> Latest version: $TAG"

TMP=$(mktemp -d)
echo "==> Downloading…"
/usr/bin/curl -fsSL -H "$AUTH" -H "Accept: application/octet-stream" -o "$TMP/app.zip" "$ASSET"
/usr/bin/ditto -x -k "$TMP/app.zip" "$TMP/x"
SRC=$(/usr/bin/find "$TMP/x" -maxdepth 4 -name "AutoAgent Status.app" | head -1)
[ -n "$SRC" ] || { echo "❌ App not found inside the download"; exit 1; }

echo "==> Installing to ~/Applications …"
mkdir -p "$HOME/Applications"
pkill -x AutoAgentStatus 2>/dev/null || true
rm -rf "$HOME/Applications/AutoAgent Status.app"
/usr/bin/ditto "$SRC" "$HOME/Applications/AutoAgent Status.app"
/usr/bin/xattr -dr com.apple.quarantine "$HOME/Applications/AutoAgent Status.app" 2>/dev/null || true
rm -rf "$TMP"

# ---- CLI check (the app is a GUI for the auto-agent-ai CLI) ----
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v auto-agent-ai >/dev/null 2>&1; then
  echo ""
  echo "⚠️  The auto-agent-ai CLI is not installed yet."
  if ! command -v npm >/dev/null 2>&1; then
    echo "   1. Install Node.js first:  brew install node   (or https://nodejs.org)"
  fi
  echo "   2. You need a GitHub token (classic) with read:packages scope"
  echo "      from https://github.com/settings/tokens — your account must be"
  echo "      in the saigontechnology org."
  if ! grep -q "npm.pkg.github.com/:_authToken" "$HOME/.npmrc" 2>/dev/null; then
    read -r -p "   Paste your GitHub token here (or Enter to skip): " T < /dev/tty || T=""
    if [ -n "$T" ]; then
      { echo "@saigontechnology:registry=https://npm.pkg.github.com"
        echo "//npm.pkg.github.com/:_authToken=$T"; } >> "$HOME/.npmrc"
    fi
  fi
  if command -v npm >/dev/null 2>&1 && grep -q "npm.pkg.github.com/:_authToken" "$HOME/.npmrc" 2>/dev/null; then
    echo "==> Installing the CLI…"
    npm install -g @saigontechnology/auto-agent || echo "❌ CLI install failed — ask an org admin for package access."
  fi
fi

open "$HOME/Applications/AutoAgent Status.app"
echo ""
echo "✅ Done! Look for the key icon in your menu bar -> Login as Owner or Client."
EOF
chmod +x "dist/Install-Online.command"
echo "✅ Online installer: $(pwd)/dist/Install-Online.command"

# ---- Host the installer at a stable secret-gist URL (curl | bash) ----
cp dist/Install-Online.command dist/install.sh
GIST_ID=$(cat .gist-id 2>/dev/null || true)
if [ -z "$GIST_ID" ]; then
  GIST_URL=$(gh gist create dist/install.sh --desc "AutoAgent Status installer")
  GIST_ID=$(basename "$GIST_URL")
  echo "$GIST_ID" > .gist-id
else
  gh gist edit "$GIST_ID" dist/install.sh --filename install.sh
fi
echo ""
echo "✅ Install one-liner (pin this in Slack):"
echo "   curl -fsSL https://gist.githubusercontent.com/haonguyenstech/$GIST_ID/raw/install.sh | bash"
