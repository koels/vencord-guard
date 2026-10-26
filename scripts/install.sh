#!/bin/bash
# Builds VencordGuard.app, installs it to ~/Applications, and loads it as a LaunchAgent.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="dev.vencordguard.agent"
APP="$HOME/Applications/VencordGuard.app"
EXEC="$APP/Contents/MacOS/VencordGuard"
BIN_LINK="$HOME/.local/bin/vencord-guard"
LOG_DIR="$HOME/Library/Logs/VencordGuard"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"

echo "==> Building (release)"
cd "$REPO"
swift build -c release
BUILT="$REPO/.build/release/VencordGuard"
[ -x "$BUILT" ] || { echo "build produced no binary"; exit 1; }

echo "==> Verifying the asar generator against your real install"
"$BUILT" selftest

# The app bundle is not cosmetic. macOS attributes TCC permissions (App Management, which is
# what lets anything modify Discord.app) to a signed bundle identity. A bare executable
# launched by launchd can neither hold that permission nor prompt for it.
#
# Re-signing changes that identity. Since this is an ad-hoc signature, every rebuild produces
# a new cdhash and macOS forgets the App Management grant. So: if the built binary is
# byte-identical to the installed one, leave the bundle completely alone. Re-running
# install.sh must not silently cost you your permission.
mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents" "$HOME/.local/bin"

BUILT_SHA="$(shasum -a 256 "$BUILT" | awk '{print $1}')"
STAMP="$APP/Contents/Resources/.build-sha256"

# Compare against a stamp of the *pre-signing* binary: codesign rewrites the executable in
# place to embed the signature, so $EXEC never hashes equal to $BUILT.
NEED_REINSTALL=1
if [ -x "$EXEC" ] && [ -f "$STAMP" ] && codesign --verify --strict "$APP" 2>/dev/null; then
    [ "$BUILT_SHA" = "$(cat "$STAMP")" ] && NEED_REINSTALL=0
fi

if [ "$NEED_REINSTALL" -eq 0 ]; then
    echo "==> $APP is already up to date — leaving it (and your App Management grant) untouched"
    launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
else
    if [ -d "$APP" ]; then
        echo
        echo "  !! Replacing $APP with a changed build."
        echo "  !! macOS ties App Management to the app's signature, so this WILL clear that"
        echo "  !! permission and you will need to re-grant it below."
        echo
    fi
    echo "==> Assembling $APP"
    launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp "$REPO/launchd/Info.plist" "$APP/Contents/Info.plist"
    cp "$BUILT" "$EXEC"
    chmod 755 "$EXEC"

    # Write the stamp BEFORE signing: anything added to the bundle afterwards breaks the seal,
    # which would make the "is it unchanged?" check fail forever and re-sign on every run.
    printf '%s' "$BUILT_SHA" > "$STAMP"

    echo "==> Signing (ad-hoc)"
    codesign --force --deep --sign - "$APP"
    codesign --verify --strict "$APP" && echo "    signature ok"
fi

ln -sf "$EXEC" "$BIN_LINK"
echo "    cli available as $BIN_LINK"

# ~/.local/bin is not on the default macOS PATH. Without this, `vencord-guard` is
# "command not found" in a normal login shell even though it installed fine.
if ! /bin/zsh -l -c 'command -v vencord-guard' >/dev/null 2>&1; then
    SHELL_RC="$HOME/.zprofile"
    if ! grep -q 'Added by vencord-guard install' "$SHELL_RC" 2>/dev/null; then
        cat >> "$SHELL_RC" <<'PATHBLOCK'

# Added by vencord-guard install: user-local binaries
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
PATHBLOCK
        echo "    added ~/.local/bin to PATH in $SHELL_RC (open a new terminal to pick it up)"
    fi
fi

echo "==> Writing LaunchAgent $PLIST"
sed -e "s|__BINARY__|$EXEC|g" -e "s|__LOGDIR__|$LOG_DIR|g" \
    "$REPO/launchd/$LABEL.plist" > "$PLIST"
plutil -lint "$PLIST" >/dev/null

echo "==> Loading agent"
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
launchctl enable "gui/$UID_NUM/$LABEL"
sleep 2

launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || {
    echo "Agent did not come up. Check $LOG_DIR/launchd.err.log"; exit 1; }

echo
echo "==> Checking permissions (as recorded by the agent itself, not by this shell)"
for _ in 1 2 3 4 5; do
    "$EXEC" doctor 2>/dev/null | grep -q "agent can modify bundle: \(yes\|NO\)" && break
    sleep 1
done
if ! "$EXEC" doctor | grep -q "agent can modify bundle: yes"; then
    cat <<EOF

  ────────────────────────────────────────────────────────────────────────
   ONE MANUAL STEP IS REQUIRED

   macOS blocks modifying another app's bundle unless you allow it:

     System Settings > Privacy & Security > App Management
       -> turn ON "VencordGuard"

   If VencordGuard is not listed, drag it in from:
     $APP

   Then run:
     launchctl kickstart -k gui/$UID_NUM/$LABEL
     $BIN_LINK doctor

   (Re-run this after any rebuild: ad-hoc signatures change, and macOS
    treats the rebuilt app as a new program.)
  ────────────────────────────────────────────────────────────────────────
EOF
else
    echo "  Permissions look good."
fi

echo
"$EXEC" status
echo
echo "Log:       tail -f $LOG_DIR/vencord-guard.log"
echo "Diagnose:  $BIN_LINK doctor"
echo "Uninstall: $REPO/scripts/uninstall.sh"
