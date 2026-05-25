#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install-fs42client-service.sh [options]

Installs a systemd user service that starts FieldStation42 field_player.py for
an FS42 distributed client/node.

Options:
  --fs42-dir PATH       Local FieldStation42 checkout (default: auto-detect)
  --display VALUE       DISPLAY value for GUI playback (default: $DISPLAY or :0)
  --enable-linger       Enable systemd user service startup before login
  --start               Start the service after installing it
  -h, --help            Show this help
EOF
}

detect_fs42_dir() {
  local candidates=(
    "$PWD"
    "$PWD/FieldStation42"
    "$HOME/FieldStation42"
    "$HOME/Projects/FieldStation42"
    "$HOME/src/FieldStation42"
    "/opt/FieldStation42"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [ -f "$candidate/field_player.py" ] && [ -f "$candidate/station_42.py" ]; then
      echo "$candidate"
      return 0
    fi
  done

  local search_root found
  for search_root in "$HOME/Projects" "$HOME/src" "$HOME"; do
    [ -d "$search_root" ] || continue
    found="$(
      find "$search_root" -maxdepth 4 -type f -name field_player.py -path '*/FieldStation42/field_player.py' -print -quit 2>/dev/null || true
    )"
    if [ -n "$found" ]; then
      candidate="$(dirname "$found")"
      if [ -f "$candidate/station_42.py" ]; then
        echo "$candidate"
        return 0
      fi
    fi
  done

  echo "$HOME/FieldStation42"
}

detect_display() {
  if [ -n "${DISPLAY:-}" ]; then
    echo "$DISPLAY"
  else
    echo ":0"
  fi
}

FS42_DIR="${FS42_DIR:-$(detect_fs42_dir)}"
DISPLAY_VALUE="${DISPLAY_VALUE:-$(detect_display)}"
ENABLE_LINGER=0
START_SERVICE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --fs42-dir)
      FS42_DIR="$2"
      shift 2
      ;;
    --display)
      DISPLAY_VALUE="$2"
      shift 2
      ;;
    --enable-linger)
      ENABLE_LINGER=1
      shift
      ;;
    --start)
      START_SERVICE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ ! -f "$FS42_DIR/field_player.py" ]; then
  echo "FieldStation42 field_player.py not found: $FS42_DIR" >&2
  exit 1
fi

if [ ! -x "$FS42_DIR/env/bin/python" ]; then
  echo "FieldStation42 venv python not found: $FS42_DIR/env/bin/python" >&2
  echo "Run the upstream FieldStation42 install.sh first." >&2
  exit 1
fi

mkdir -p "$HOME/.config/systemd/user"
sed \
  -e "s|@FS42_DIR@|$FS42_DIR|g" \
  -e "s|@DISPLAY_VALUE@|$DISPLAY_VALUE|g" \
  systemd/fs42-node-player.user.service.in > "$HOME/.config/systemd/user/fs42-node-player.service"

systemctl --user daemon-reload
systemctl --user enable fs42-node-player.service

if [ "$ENABLE_LINGER" -eq 1 ]; then
  sudo loginctl enable-linger "$USER"
fi

if [ "$START_SERVICE" -eq 1 ]; then
  systemctl --user restart fs42-node-player.service
fi

echo "Installed systemd user service:"
echo "  ~/.config/systemd/user/fs42-node-player.service"
echo
echo "Useful commands:"
echo "  systemctl --user start fs42-node-player.service"
echo "  systemctl --user stop fs42-node-player.service"
echo "  systemctl --user status fs42-node-player.service"
echo "  journalctl --user -u fs42-node-player.service -f"
