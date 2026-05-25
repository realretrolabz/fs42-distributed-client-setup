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
    "$HOME/Projects/FieldStation42"
    "$HOME/Projects/fs42-nodes/FieldStation42"
    "/opt/FieldStation42"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [ -f "$candidate/field_player.py" ]; then
      echo "$candidate"
      return 0
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

list_nfs_exports() {
  local host="$1"
  if ! command -v showmount >/dev/null 2>&1; then
    return 0
  fi

  showmount -e "$host" 2>/dev/null | awk 'NR > 1 {print $1}'
}

pick_export() {
  local kind="$1"
  shift
  local export_path

  case "$kind" in
    runtime)
      for export_path in "$@"; do
        [[ "$export_path" == */runtime ]] && echo "$export_path" && return 0
      done
      ;;
    confs)
      for export_path in "$@"; do
        [[ "$export_path" == */confs ]] && echo "$export_path" && return 0
      done
      ;;
    media)
      for export_path in "$@"; do
        [[ "$export_path" == */runtime ]] && continue
        [[ "$export_path" == */confs ]] && continue
        [[ "$export_path" == *FS42* || "$export_path" == *fs42* || "$export_path" == */media/* || "$export_path" == */srv/* ]] && echo "$export_path" && return 0
      done
      ;;
  esac

  return 1
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

FS42_FSTAB_BEGIN="# BEGIN FieldStation42 distributed node"
FS42_FSTAB_END="# END FieldStation42 distributed node"

desired_fstab_block() {
  cat <<EOF
$FS42_FSTAB_BEGIN
$MEDIA_NFS_SOURCE $NODE_MEDIA_MOUNT nfs ro,nofail,_netdev,x-systemd.automount 0 0
$CONFS_NFS_SOURCE $NODE_CONFS_MOUNT nfs ro,nofail,_netdev,x-systemd.automount 0 0
$RUNTIME_NFS_SOURCE $NODE_RUNTIME_MOUNT nfs ro,nofail,_netdev,x-systemd.automount 0 0
$FS42_FSTAB_END
EOF
}

current_managed_fstab_block() {
  awk -v begin="$FS42_FSTAB_BEGIN" -v end="$FS42_FSTAB_END" '
    $0 == begin { in_block = 1 }
    in_block { print }
    $0 == end { in_block = 0 }
  ' /etc/fstab
}

remove_managed_fstab_block() {
  sudo awk -v begin="$FS42_FSTAB_BEGIN" -v end="$FS42_FSTAB_END" '
    $0 == begin { in_block = 1; next }
    $0 == end { in_block = 0; next }
    !in_block { print }
  ' /etc/fstab | sudo tee /etc/fstab.tmp.fs42 >/dev/null
  sudo mv /etc/fstab.tmp.fs42 /etc/fstab
}

legacy_fstab_entries_exist() {
  awk '
    $0 ~ /^[[:space:]]*#/ { next }
    ($1 ~ /:\/.*FieldStation42\/(confs|runtime)$/) || ($2 ~ /fs42-headend-(confs|runtime)$/) || ($2 == "/media/FS42DB/fs42" && $3 == "nfs") {
      found = 1
    }
    END { exit found ? 0 : 1 }
  ' /etc/fstab
}

append_managed_fstab_block() {
  desired="$(desired_fstab_block)"
  current="$(current_managed_fstab_block)"

  if [ -n "$current" ]; then
    if [ "$current" = "$desired" ]; then
      echo "Managed FS42 fstab block already matches; skipping."
      return 0
    fi

    echo "Existing managed FS42 fstab block differs from selected mount settings:"
    echo
    echo "$current"
    echo
    echo "New selected block would be:"
    echo
    echo "$desired"
    echo
    read -r -p "Replace the old managed FS42 fstab block? [y/N]: " replace_block
    if [[ ! "$replace_block" =~ ^[Yy]$ ]]; then
      echo "Keeping existing managed fstab block."
      return 0
    fi
    remove_managed_fstab_block
  elif legacy_fstab_entries_exist; then
    echo "Existing FS42-looking fstab entries were found outside a managed block."
    echo "Review /etc/fstab if you previously changed mount points manually."
    read -r -p "Append a new managed block anyway? [y/N]: " append_anyway
    if [[ ! "$append_anyway" =~ ^[Yy]$ ]]; then
      echo "Skipped adding managed fstab block."
      return 0
    fi
  fi

  {
    echo ""
    desired_fstab_block
  } | sudo tee -a /etc/fstab >/dev/null
  echo "Added managed FS42 fstab block."
}

CHRONY_CONF="${CHRONY_CONF:-/etc/chrony/chrony.conf}"
FS42_CHRONY_BEGIN="# BEGIN FieldStation42 distributed time client"
FS42_CHRONY_END="# END FieldStation42 distributed time client"

desired_chrony_client_block() {
  cat <<EOF
$FS42_CHRONY_BEGIN
server $HEADEND_HOST iburst prefer
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

apply_chrony_client_config() {
  install_chrony_if_needed
  need_file "$CHRONY_CONF"

  desired="$(desired_chrony_client_block)"
  current="$(current_managed_chrony_block)"

  if [ -n "$current" ]; then
    if [ "$current" = "$desired" ]; then
      echo "Managed FS42 Chrony client block already matches; skipping."
    else
      echo "Existing managed FS42 Chrony client block differs:"
      echo
      echo "$current"
      echo
      echo "New selected block would be:"
      echo
      echo "$desired"
      echo
      read -r -p "Replace the old managed FS42 Chrony client block? [y/N]: " replace_block
      if [[ "$replace_block" =~ ^[Yy]$ ]]; then
        remove_managed_chrony_block
        {
          echo ""
          desired_chrony_client_block
        } | sudo tee -a "$CHRONY_CONF" >/dev/null
      else
        echo "Keeping existing managed Chrony client block."
      fi
    fi
  else
    {
      echo ""
      desired_chrony_client_block
    } | sudo tee -a "$CHRONY_CONF" >/dev/null
    echo "Added managed FS42 Chrony client block."
  fi

  restart_chrony
  echo "Chrony client config applied. Current sources:"
  chronyc sources || true
}

timestamp="$(date +%Y%m%d-%H%M%S)"

detected_fs42_dir="$(detect_fs42_dir)"
DISPLAY_VALUE="${DISPLAY_VALUE:-$(detect_display)}"

prompt_default FS42_DIR "Local FieldStation42 directory" "$detected_fs42_dir"
prompt_default HEADEND_HOST "Headend host/IP" "10.0.0.99"

mapfile -t detected_exports < <(list_nfs_exports "$HEADEND_HOST")
if [ "${#detected_exports[@]}" -gt 0 ]; then
  echo
  echo "Detected NFS exports from $HEADEND_HOST:"
  printf '  %s\n' "${detected_exports[@]}"
fi

detected_media_export="$(pick_export media "${detected_exports[@]}" || true)"
detected_confs_export="$(pick_export confs "${detected_exports[@]}" || true)"
detected_runtime_export="$(pick_export runtime "${detected_exports[@]}" || true)"

MEDIA_NFS_SOURCE="${MEDIA_NFS_SOURCE:-$HEADEND_HOST:${detected_media_export:-/media/FS42DB/fs42}}"
CONFS_NFS_SOURCE="${CONFS_NFS_SOURCE:-$HEADEND_HOST:${detected_confs_export:-/home/cableguy/FieldStation42/confs}}"
RUNTIME_NFS_SOURCE="${RUNTIME_NFS_SOURCE:-$HEADEND_HOST:${detected_runtime_export:-/home/cableguy/FieldStation42/runtime}}"

default_media_mount="${detected_media_export:-/media/FS42DB/fs42}"
prompt_default NODE_MEDIA_MOUNT "Node media mount path" "$default_media_mount"
prompt_default NODE_CONFS_MOUNT "Node headend confs mount path" "/mnt/fs42-headend-confs"
prompt_default NODE_RUNTIME_MOUNT "Node headend runtime mount path" "/mnt/fs42-headend-runtime"

need_file "$FS42_DIR/field_player.py"

echo
echo "Node setup will mount read-only NFS shares:"
echo "  $MEDIA_NFS_SOURCE   -> $NODE_MEDIA_MOUNT"
echo "  $CONFS_NFS_SOURCE   -> $NODE_CONFS_MOUNT"
echo "  $RUNTIME_NFS_SOURCE -> $NODE_RUNTIME_MOUNT"
echo

read -r -p "Create mount points and add /etc/fstab entries? [y/N]: " apply_fstab
if [[ "$apply_fstab" =~ ^[Yy]$ ]]; then
  sudo mkdir -p "$NODE_MEDIA_MOUNT" "$NODE_CONFS_MOUNT" "$NODE_RUNTIME_MOUNT"
  append_managed_fstab_block

  sudo mount "$NODE_MEDIA_MOUNT" || true
  sudo mount "$NODE_CONFS_MOUNT" || true
  sudo mount "$NODE_RUNTIME_MOUNT" || true
else
  echo "Skipped fstab changes. Make sure the mounts exist before running the player."
fi

echo
read -r -p "Configure this client to sync time from headend $HEADEND_HOST with Chrony/NTP? [y/N]: " apply_chrony
if [[ "$apply_chrony" =~ ^[Yy]$ ]]; then
  apply_chrony_client_config
else
  echo "Skipped Chrony/NTP client setup."
fi

need_file "$NODE_CONFS_MOUNT"
need_file "$NODE_RUNTIME_MOUNT/fs42_fluid.db"
need_file "$NODE_MEDIA_MOUNT/catalog"

detected_db_media_root="$(detect_media_root_from_db "$NODE_RUNTIME_MOUNT/fs42_fluid.db" || true)"
if [ -n "$detected_db_media_root" ] && [ "$detected_db_media_root" != "$NODE_MEDIA_MOUNT" ]; then
  echo
  echo "The shared DB contains catalog realpaths under:"
  echo "  $detected_db_media_root"
  echo "but this node is mounting media at:"
  echo "  $NODE_MEDIA_MOUNT"
  echo
  echo "FS42 playback is most reliable when those paths match."
  read -r -p "Continue with this media mount path anyway? [y/N]: " continue_mismatch
  if [[ ! "$continue_mismatch" =~ ^[Yy]$ ]]; then
    echo "Re-run setup with NODE_MEDIA_MOUNT='$detected_db_media_root' or adjust your NFS mount."
    exit 1
  fi
fi

mkdir -p "$FS42_DIR/runtime" "$FS42_DIR/confs"

echo
echo "Linking shared media catalog:"
if [ -e "$FS42_DIR/catalog" ] && [ ! -L "$FS42_DIR/catalog" ]; then
  mv "$FS42_DIR/catalog" "$FS42_DIR/catalog.local.bak.$timestamp"
fi
ln -sfn "$NODE_MEDIA_MOUNT/catalog" "$FS42_DIR/catalog"
echo "  catalog -> $NODE_MEDIA_MOUNT/catalog"

echo
echo "Linking shared runtime assets:"
runtime_asset_count=0
for runtime_asset in guide logo_images static.mp4 standby.png brb.png off_air_pattern.mp4 signoff.mp4; do
  if [ ! -e "$NODE_RUNTIME_MOUNT/$runtime_asset" ]; then
    continue
  fi
  if [ -e "$FS42_DIR/runtime/$runtime_asset" ] && [ ! -L "$FS42_DIR/runtime/$runtime_asset" ]; then
    mv "$FS42_DIR/runtime/$runtime_asset" "$FS42_DIR/runtime/$runtime_asset.local.bak.$timestamp"
  fi
  ln -sfn "$NODE_RUNTIME_MOUNT/$runtime_asset" "$FS42_DIR/runtime/$runtime_asset"
  runtime_asset_count=$((runtime_asset_count + 1))
  echo "  runtime/$runtime_asset -> $NODE_RUNTIME_MOUNT/$runtime_asset"
done
if [ "$runtime_asset_count" -eq 0 ]; then
  echo "  No shared runtime assets found to link."
fi

echo
echo "Linking shared FS42 database:"
if [ -e "$FS42_DIR/runtime/fs42_fluid.db" ] && [ ! -L "$FS42_DIR/runtime/fs42_fluid.db" ]; then
  mv "$FS42_DIR/runtime/fs42_fluid.db" "$FS42_DIR/runtime/fs42_fluid.db.local.bak.$timestamp"
fi
ln -sfn "$NODE_RUNTIME_MOUNT/fs42_fluid.db" "$FS42_DIR/runtime/fs42_fluid.db"

echo
echo "Linking station configs from host:"
linked_station_configs=0
for station_conf in "$NODE_CONFS_MOUNT"/*.json; do
  [ -e "$station_conf" ] || continue
  base="$(basename "$station_conf")"
  [ "$base" = "main_config.json" ] && continue
  if [ -e "$FS42_DIR/confs/$base" ] && [ ! -L "$FS42_DIR/confs/$base" ]; then
    mv "$FS42_DIR/confs/$base" "$FS42_DIR/confs/$base.local.bak.$timestamp"
  fi
  ln -sfn "$station_conf" "$FS42_DIR/confs/$base"
  linked_station_configs=$((linked_station_configs + 1))
  echo "  $base -> $station_conf"
done

if [ "$linked_station_configs" -eq 0 ]; then
  echo "No station configs were found in $NODE_CONFS_MOUNT" >&2
  echo "The host confs export should contain station JSON files such as strk.json, pbs.json, etc." >&2
  exit 1
fi

echo "Linked $linked_station_configs station config(s)."

echo
echo "Writing client-local main_config.json:"
python3 - "$NODE_CONFS_MOUNT/main_config.json" "$FS42_DIR/confs/main_config.json" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
dest = Path(sys.argv[2])

data = {}
if source.exists():
    data.update(json.loads(source.read_text()))
if dest.exists() and not dest.is_symlink():
    try:
        existing = json.loads(dest.read_text())
        data.update(existing)
    except Exception:
        pass

data["db_path"] = "runtime/fs42_fluid.db"
data.setdefault("channel_socket", "runtime/channel.socket")
data.setdefault("status_socket", "runtime/play_status.socket")
data.setdefault("recall_last_channel", True)
data.setdefault("server_host", "0.0.0.0")
data.setdefault("server_port", 4242)
data.pop("schedule_agent", None)

dest.write_text(json.dumps(data, indent=2) + "\n")
PY

echo
echo "DB symlink:"
ls -l "$FS42_DIR/runtime/fs42_fluid.db"
echo
echo "Station config links:"
find "$FS42_DIR/confs" -maxdepth 1 -type l -name '*.json' -printf '  %f -> %l\n' | sort

read -r -p "Install systemd user service for field_player.py? [y/N]: " install_service
if [[ "$install_service" =~ ^[Yy]$ ]]; then
  scripts/install-fs42client-service.sh --fs42-dir "$FS42_DIR" --display "$DISPLAY_VALUE"
else
  echo "Skipped service install."
  echo "You can install it later with:"
  echo "  scripts/install-fs42client-service.sh --fs42-dir '$FS42_DIR' --display '$DISPLAY_VALUE'"
fi

echo
echo "Run a health check:"
echo "  scripts/fs42client-health-check.py --fs42-dir '$FS42_DIR' --media-root '$NODE_MEDIA_MOUNT'"
echo
echo "After field_player.py is running, use FS42's node API for channel control:"
echo "  curl http://<node-ip>:4242/player/channels/66"
echo "  curl http://<node-ip>:4242/player/channels/up"
echo "  curl http://<node-ip>:4242/player/channels/down"
