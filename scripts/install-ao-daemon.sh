#!/usr/bin/env bash
# Install the fork's AO daemon into a local Agent Orchestrator install.
#
# The fork's changes are entirely in the Go daemon, so upgrading means replacing
# one binary inside the app rather than reinstalling it. The stock daemon is
# preserved on first run so the change is reversible.
#
#   install-ao-daemon.sh                      # fetch the latest CI build and install
#   install-ao-daemon.sh --local <path>       # install a binary you built yourself
#   install-ao-daemon.sh --revert             # restore the stock daemon
#   install-ao-daemon.sh --status             # show what is installed
#
# AO_APP_DIR overrides where the app lives (default: the extracted AppImage
# under the scratch dir, which is how ws01 is set up).

set -euo pipefail

REPO="${AO_FORK_REPO:-johnkattenhorn/agent-orchestrator}"
APP_DIR="${AO_APP_DIR:-}"
DEST=""
MODE="install"
LOCAL_BIN=""

die() { printf 'install-ao-daemon: %s\n' "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --local)  MODE="local"; LOCAL_BIN="${2:-}"; shift 2 ;;
    --revert) MODE="revert"; shift ;;
    --status) MODE="status"; shift ;;
    --app-dir) APP_DIR="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Locate the app. Prefer an explicit dir, else look for the daemon next to a
# running AO, else give up with something actionable rather than guessing.
if [ -z "$APP_DIR" ]; then
  for c in \
    "$HOME/Applications/squashfs-root" \
    "/opt/agent-orchestrator" \
    "$(dirname "$(command -v ao 2>/dev/null || echo /nonexistent)")/.."
  do
    if [ -f "$c/resources/daemon/ao" ]; then APP_DIR="$c"; break; fi
  done
fi
[ -n "$APP_DIR" ] || die "cannot find the AO app. Pass --app-dir <dir> or set AO_APP_DIR (the dir containing resources/daemon/ao)."
DEST="$APP_DIR/resources/daemon/ao"
[ -f "$DEST" ] || die "no daemon at $DEST — is --app-dir right?"
BACKUP="$DEST.stock-backup"

show_status() {
  note "app dir:  $APP_DIR"
  note "daemon:   $DEST"
  if [ -f "$BACKUP" ]; then note "stock backup present (revert is available)"; else note "no stock backup — this looks like an untouched install"; fi
  if "$DEST" doctor 2>/dev/null | grep -qi '^OneDev'; then
    note "OneDev support: PRESENT"
  else
    note "OneDev support: ABSENT (stock daemon, or the fork build was overwritten by an app update)"
  fi
}

case "$MODE" in
  status) show_status; exit 0 ;;
  revert)
    [ -f "$BACKUP" ] || die "no stock backup at $BACKUP — nothing to revert to."
    cp -f "$BACKUP" "$DEST"
    note "restored the stock daemon"; show_status; exit 0 ;;
esac

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

if [ "$MODE" = "local" ]; then
  [ -n "$LOCAL_BIN" ] && [ -f "$LOCAL_BIN" ] || die "--local needs a path to a built daemon binary"
  cp "$LOCAL_BIN" "$TMP/ao"
else
  command -v gh >/dev/null || die "gh is required to fetch the release (or use --local <path>)"
  note "fetching daemon-latest from $REPO"
  gh release download daemon-latest --repo "$REPO" --pattern 'ao*' --dir "$TMP" --clobber \
    || die "could not download the daemon-latest release from $REPO"
  if [ -f "$TMP/ao.sha256" ]; then
    ( cd "$TMP" && sha256sum -c ao.sha256 >/dev/null ) || die "checksum mismatch — refusing to install"
    note "checksum verified"
  fi
  [ -f "$TMP/ao.provenance" ] && sed 's/^/  /' "$TMP/ao.provenance"
fi

chmod +x "$TMP/ao"
# Refuse to install something that is not actually the fork build, otherwise a
# silent no-op looks like a successful upgrade.
"$TMP/ao" doctor 2>/dev/null | grep -qi '^OneDev' \
  || die "the binary has no OneDev section in 'ao doctor' — that is not the fork build, refusing to install"

if [ ! -f "$BACKUP" ]; then
  cp "$DEST" "$BACKUP"
  note "preserved the stock daemon as $(basename "$BACKUP")"
fi

if pgrep -f "$APP_DIR/agent-orchestrator" >/dev/null 2>&1; then
  note "NOTE: the AO app is running — stop it before the new daemon takes effect"
fi

cp -f "$TMP/ao" "$DEST"
note "installed"
show_status

cat <<'EOF'

  Remember: OneDev observation needs these in the app's environment, or it goes
  quiet with no error —

    export AO_ONEDEV_ALLOWED_HOSTS="http://192.168.1.30:6610"
    export AO_ONEDEV_TOKEN="$(secret-tool lookup service onedev-ao-adapter user johnkattenhorn)"

  Verify with: ao doctor   (expect three PASS lines under OneDev)
EOF
