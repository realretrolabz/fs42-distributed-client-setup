#!/usr/bin/env bash
set -euo pipefail

prompt_default() {
  local name="$1"
  local prompt="$2"
  local default="$3"
  local current="${!name:-}"
  if [ -z "$current" ]; then
    read -r -p "$prompt [$default]: " current
    current="${current:-$default}"
    printf -v "$name" '%s' "$current"
  fi
}

detect_fs42_dir() {
  local candidates=(
    "$PWD"
    "$PWD/FieldStation42"
    "$HOME/FieldStation42"
    "$HOME/src/FieldStation42"
    "/opt/FieldStation42"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [ -f "$candidate/station_42.py" ] && [ -f "$candidate/field_player.py" ]; then
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

detect_media_root_from_db() {
  local db_path="$1"
  if [ ! -f "$db_path" ]; then
    return 1
  fi

  python3 - "$db_path" <<'PY'
import sqlite3
import sys

db_path = sys.argv[1]
try:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    rows = conn.execute(
        "SELECT realpath FROM catalog_entries "
        "WHERE realpath IS NOT NULL AND realpath LIKE '%/catalog/%' "
        "LIMIT 50"
    ).fetchall()
finally:
    try:
        conn.close()
    except Exception:
        pass

roots = []
for (path,) in rows:
    marker = "/catalog/"
    if path and marker in path:
        roots.append(path.split(marker, 1)[0])

if roots:
    print(max(set(roots), key=roots.count))
PY
}

need_file() {
  if [ ! -e "$1" ]; then
    echo "Missing required path: $1" >&2
    exit 1
  fi
}

FS42_EXPORTS_BEGIN="# BEGIN FieldStation42 distributed nodes"
FS42_EXPORTS_END="# END FieldStation42 distributed nodes"

desired_exports_block() {
  cat <<EOF
$FS42_EXPORTS_BEGIN
$HEADEND_MEDIA_ROOT $HEADEND_LAN_CIDR(ro,sync,no_subtree_check)
$HEADEND_CONFS_DIR $HEADEND_LAN_CIDR(ro,sync,no_subtree_check)
$HEADEND_RUNTIME_DIR $HEADEND_LAN_CIDR(ro,sync,no_subtree_check)
$FS42_EXPORTS_END
EOF
}

current_managed_exports_block() {
  sudo awk -v begin="$FS42_EXPORTS_BEGIN" -v end="$FS42_EXPORTS_END" '
    $0 == begin { in_block = 1 }
    in_block { print }
    $0 == end { in_block = 0 }
  ' /etc/exports
}

remove_managed_exports_block() {
  sudo awk -v begin="$FS42_EXPORTS_BEGIN" -v end="$FS42_EXPORTS_END" '
    $0 == begin { in_block = 1; next }
    $0 == end { in_block = 0; next }
    !in_block { print }
  ' /etc/exports | sudo tee /etc/exports.tmp.fs42 >/dev/null
  sudo mv /etc/exports.tmp.fs42 /etc/exports
}

legacy_exports_exist() {
  sudo awk '
    $0 ~ /^[[:space:]]*#/ { next }
    ($1 ~ /\/FieldStation42\/(confs|runtime)$/) || ($1 == "/media/FS42DB/fs42") {
      found = 1
    }
    END { exit found ? 0 : 1 }
  ' /etc/exports
}

append_managed_exports_block() {
  desired="$(desired_exports_block)"
  current="$(current_managed_exports_block)"

  if [ -n "$current" ]; then
    if [ "$current" = "$desired" ]; then
      echo "Managed FS42 exports block already matches; skipping."
      return 0
    fi

    echo "Existing managed FS42 exports block differs from selected export settings:"
    echo
    echo "$current"
    echo
    echo "New selected block would be:"
    echo
    echo "$desired"
    echo
    read -r -p "Replace the old managed FS42 exports block? [y/N]: " replace_block
    if [[ ! "$replace_block" =~ ^[Yy]$ ]]; then
      echo "Keeping existing managed exports block."
      return 0
    fi
    remove_managed_exports_block
  elif legacy_exports_exist; then
    echo "Existing FS42-looking exports were found outside a managed block."
    echo "Review /etc/exports if you previously changed export paths manually."
    read -r -p "Append a new managed block anyway? [y/N]: " append_anyway
    if [[ ! "$append_anyway" =~ ^[Yy]$ ]]; then
      echo "Skipped adding managed exports block."
      return 0
    fi
  fi

  {
    echo ""
    desired_exports_block
  } | sudo tee -a /etc/exports >/dev/null
  echo "Added managed FS42 exports block."
}

CHRONY_CONF="${CHRONY_CONF:-/etc/chrony/chrony.conf}"
FS42_CHRONY_BEGIN="# BEGIN FieldStation42 distributed time server"
FS42_CHRONY_END="# END FieldStation42 distributed time server"

desired_chrony_server_block() {
  cat <<EOF
$FS42_CHRONY_BEGIN
allow $HEADEND_LAN_CIDR
local stratum 10
$FS42_CHRONY_END
EOF
}

current_managed_chrony_block() {
  sudo awk -v begin="$FS42_CHRONY_BEGIN" -v end="$FS42_CHRONY_END" '
    $0 == begin { in_block = 1 }
    in_block { print }
    $0 == end { in_block = 0 }
  ' "$CHRONY_CONF"
}

remove_managed_chrony_block() {
  sudo awk -v begin="$FS42_CHRONY_BEGIN" -v end="$FS42_CHRONY_END" '
    $0 == begin { in_block = 1; next }
    $0 == end { in_block = 0; next }
    !in_block { print }
  ' "$CHRONY_CONF" | sudo tee "$CHRONY_CONF.tmp.fs42" >/dev/null
  sudo mv "$CHRONY_CONF.tmp.fs42" "$CHRONY_CONF"
}

install_chrony_if_needed() {
  if command -v chronyd >/dev/null 2>&1 || command -v chronyc >/dev/null 2>&1; then
    return 0
  fi
  command -v apt-get >/dev/null 2>&1 || {
    echo "chrony not found and apt-get is unavailable; install chrony manually." >&2
    return 1
  }
  sudo apt-get update
  sudo apt-get install -y chrony
}

restart_chrony() {
  if systemctl list-unit-files chrony.service >/dev/null 2>&1; then
    sudo systemctl restart chrony
  elif systemctl list-unit-files chronyd.service >/dev/null 2>&1; then
    sudo systemctl restart chronyd
  else
    echo "Could not find chrony/chronyd systemd service; restart chrony manually." >&2
    return 1
  fi
}

apply_chrony_server_config() {
  install_chrony_if_needed
  need_file "$CHRONY_CONF"

  desired="$(desired_chrony_server_block)"
  current="$(current_managed_chrony_block)"

  if [ -n "$current" ]; then
    if [ "$current" = "$desired" ]; then
      echo "Managed FS42 Chrony server block already matches; skipping."
    else
      echo "Existing managed FS42 Chrony server block differs:"
      echo
      echo "$current"
      echo
      echo "New selected block would be:"
      echo
      echo "$desired"
      echo
      read -r -p "Replace the old managed FS42 Chrony server block? [y/N]: " replace_block
      if [[ "$replace_block" =~ ^[Yy]$ ]]; then
        remove_managed_chrony_block
        {
          echo ""
          desired_chrony_server_block
        } | sudo tee -a "$CHRONY_CONF" >/dev/null
      else
        echo "Keeping existing managed Chrony server block."
      fi
    fi
  else
    {
      echo ""
      desired_chrony_server_block
    } | sudo tee -a "$CHRONY_CONF" >/dev/null
    echo "Added managed FS42 Chrony server block."
  fi

  restart_chrony
  echo "Chrony server config applied. Clients may use this host as their LAN time source."
}

detected_fs42_dir="$(detect_fs42_dir)"

prompt_default FS42_DIR "FieldStation42 directory" "$detected_fs42_dir"
HEADEND_CONFS_DIR="${HEADEND_CONFS_DIR:-$FS42_DIR/confs}"
HEADEND_RUNTIME_DIR="${HEADEND_RUNTIME_DIR:-$FS42_DIR/runtime}"

detected_media_root="$(detect_media_root_from_db "$HEADEND_RUNTIME_DIR/fs42_fluid.db" || true)"
prompt_default HEADEND_MEDIA_ROOT "Headend media root to export" "${detected_media_root:-/media/FS42DB/fs42}"
prompt_default HEADEND_LAN_CIDR "LAN CIDR allowed to mount exports" "10.0.0.0/24"

need_file "$FS42_DIR/station_42.py"
need_file "$HEADEND_MEDIA_ROOT"
need_file "$HEADEND_CONFS_DIR"
need_file "$HEADEND_RUNTIME_DIR/fs42_fluid.db"

echo
echo "Host setup will prepare read-only NFS export lines for:"
echo "  media:   $HEADEND_MEDIA_ROOT"
echo "  confs:   $HEADEND_CONFS_DIR"
echo "  runtime: $HEADEND_RUNTIME_DIR"
echo
echo "Suggested /etc/exports entries:"
echo "$HEADEND_MEDIA_ROOT $HEADEND_LAN_CIDR(ro,sync,no_subtree_check)"
echo "$HEADEND_CONFS_DIR $HEADEND_LAN_CIDR(ro,sync,no_subtree_check)"
echo "$HEADEND_RUNTIME_DIR $HEADEND_LAN_CIDR(ro,sync,no_subtree_check)"
echo

read -r -p "Append these entries to /etc/exports now? [y/N]: " apply_exports
if [[ "$apply_exports" =~ ^[Yy]$ ]]; then
  append_managed_exports_block

  sudo exportfs -ra
  echo "NFS exports reloaded."
else
  echo "Skipped /etc/exports changes."
fi

echo
read -r -p "Configure this host as an offline Chrony/NTP time source for $HEADEND_LAN_CIDR? [y/N]: " apply_chrony
if [[ "$apply_chrony" =~ ^[Yy]$ ]]; then
  apply_chrony_server_config
else
  echo "Skipped Chrony/NTP host setup."
fi

echo
echo "Host schedule maintenance:"
echo "  Prefer FS42's Live Schedule Agent if configured in main_config.json."
echo "  Manual commands remain:"
echo "    cd '$FS42_DIR'"
echo "    source env/bin/activate"
echo "    python3 station_42.py --rebuild_catalog"
echo "    python3 station_42.py --add_week"
echo
echo "Host setup check complete."
