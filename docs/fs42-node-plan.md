# FieldStation42 Node Plan

This project is pivoting toward using FieldStation42 itself for playback on
each node. The companion repo should provide deployment glue, not a replacement
player or scheduler.

## Roles

Headend:

- Owns catalog and schedule generation.
- Writes `runtime/fs42_fluid.db`.
- Exports media, station configs, and the runtime DB read-only to nodes.
- May run FS42 Live Schedule Agent or manual `station_42.py --add_week`.

Node:

- Runs a normal local FieldStation42 install for FS42 playback/rendering.
- Runs `field_player.py` in normal mode so FS42's own local web/API server is
  available for that node.
- Keeps `runtime/channel.socket`, `runtime/play_status.socket`, and player
  state local.
- Symlinks only `runtime/fs42_fluid.db` to the read-only headend runtime mount.
- Uses node-local `confs/main_config.json` with `schedule_agent` removed.
- Symlinks station JSON files from the headend config mount.
- Does not run catalog rebuilds or schedule extension jobs.

## Shared Versus Local

Shared/read-only from headend:

- Media root, preferably mounted at the same absolute path as the headend.
- Station JSON files, excluding node-local `main_config.json`.
- `runtime/fs42_fluid.db`.

Local per node:

- `runtime/channel.socket`
- `runtime/play_status.socket`
- `runtime/player_state.bin`
- Local FS42 web/API server, normally on port `4242`
- Display/audio/player process state

## Setup Detection

The setup scripts should prefer detection with editable defaults:

- Host setup detects the local FS42 checkout from common paths.
- Host setup inspects `runtime/fs42_fluid.db` and suggests the media root from
  catalog `realpath` values.
- Node setup asks for the headend host/IP, then uses `showmount -e` to detect
  exported media, `confs`, and `runtime` paths.
- Node setup mounts media at the same absolute path as the headend when
  possible.
- After mounting the shared runtime export, node setup inspects
  `fs42_fluid.db` and warns if the DB's catalog realpaths do not match the
  selected node media mount.
- Host setup can optionally configure Chrony as an offline LAN time source.
- Node setup can optionally configure Chrony to sync from the headend IP.

## Channel Control

Use FS42's original player API on the node itself:

```bash
curl http://NODE_IP:4242/player/channels/66
curl http://NODE_IP:4242/player/channels/up
curl http://NODE_IP:4242/player/channels/down
curl -X POST http://NODE_IP:4242/player/channels/guide
```

This works because each node has its own local `field_player.py`, local
`runtime/channel.socket`, and local player state. Sending a channel request to
one node changes only that node.

Do not send node tuning commands to the headend unless you are intentionally
controlling the headend's own local player.

## Why This Works

`fs42_fluid.db` contains catalog rows and generated `liquid_blocks` schedule
rows. Nodes need the same DB to agree on what each station should be playing at
a given wall-clock time.

`field_player.py` still needs station configs on startup for channel numbers,
network types, web URLs, guide config, hidden flags, and fallback media. The DB
alone is not enough.

## Guardrails

- Only the headend should run `--rebuild_catalog`, `--add_day`, `--add_week`,
  `--add_month`, or the web console build endpoints.
- Nodes should mount the shared DB read-only.
- The headend should keep schedules extended far enough ahead that nodes do not
  hit FS42's schedule panic path.
- Node web/API servers expose FS42's normal player API. Avoid using their build
  endpoints; build operations belong on the headend.
- A future FS42 patch could add an explicit `disable_schedule_panic` config for
  kiosk nodes.
