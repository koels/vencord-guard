#!/bin/bash
# Removes the LaunchAgent, the app bundle, and (optionally) logs and state.
# It never touches Discord or Vencord: your Vencord install is left exactly as it is.
set -uo pipefail

LABEL="dev.vencordguard.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$HOME/Applications/VencordGuard.app"
BIN_LINK="$HOME/.local/bin/vencord-guard"

echo "==> Stopping agent"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "    unloaded" || echo "    was not loaded"

echo "==> Removing files"
rm -f  "$PLIST"    && echo "    removed $PLIST"
rm -rf "$APP"      && echo "    removed $APP"
rm -f  "$BIN_LINK" "$HOME/.local/bin/vencord-guard-bootcheck" && echo "    removed CLI symlinks"

read -r -p "Also delete logs and state? [y/N] " reply
if [[ "$reply" =~ ^[Yy]$ ]]; then
    rm -rf "$HOME/Library/Logs/VencordGuard" "$HOME/Library/Application Support/VencordGuard"
    echo "    removed logs and state"
else
    echo "    kept ~/Library/Logs/VencordGuard and ~/Library/Application Support/VencordGuard"
fi

echo
echo "Note: install.sh may have added a ~/.local/bin PATH block to ~/.zprofile."
echo "      Remove it by hand if you want (look for 'Added by vencord-guard install')."
echo
echo "Done. Vencord and Discord were not modified."
echo "You may also remove the stale 'VencordGuard' entry from"
echo "  System Settings > Privacy & Security > App Management"
echo "To remove Vencord itself, use VencordInstaller.app -> Uninstall."
