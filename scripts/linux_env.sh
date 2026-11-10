#!/usr/bin/env bash
# Runs a command with the VS Code *snap* environment removed.
#
# VS Code installed as a snap leaks GTK_PATH, GSETTINGS_SCHEMA_DIR,
# GIO_MODULE_DIR, … into every process started from its terminal. GTK apps
# (including CamStation on Linux) then load the snap's GTK/GIO bits and abort
# with errors like:
#   GLib-GIO-ERROR: Settings schema 'org.gnome.settings-daemon.plugins.xsettings'
#   does not contain a key named 'antialiasing'
#
# Usage:
#   scripts/linux_env.sh flutter run -d linux
#   scripts/linux_env.sh build/linux/x64/debug/bundle/camstation
#
# Not needed from a normal terminal, or if VS Code is installed from the .deb.
set -euo pipefail

if [ -n "${SNAP:-}" ] || [ -n "${XDG_DATA_DIRS_VSCODE_SNAP_ORIG:-}" ]; then
  unset GTK_PATH GTK_EXE_PREFIX GTK_IM_MODULE_FILE GTK_MODULES \
        GIO_MODULE_DIR GSETTINGS_SCHEMA_DIR GDK_PIXBUF_MODULE_FILE \
        GDK_PIXBUF_MODULEDIR LOCPATH GIO_LAUNCHED_DESKTOP_FILE \
        GIO_LAUNCHED_DESKTOP_FILE_PID
  if [ -n "${XDG_DATA_DIRS_VSCODE_SNAP_ORIG:-}" ]; then
    export XDG_DATA_DIRS="$XDG_DATA_DIRS_VSCODE_SNAP_ORIG"
  else
    export XDG_DATA_DIRS="/usr/local/share:/usr/share"
  fi
  for v in $(env | grep -oE '^SNAP[A-Z_]*' || true); do unset "$v"; done
fi

exec "$@"
