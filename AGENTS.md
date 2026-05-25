# AGENTS.md - FieldStation42 Distributed FS42 Client Setup

## Project Purpose

This companion project turns a normal FieldStation42 installation into a
distributed, offline-capable playout system by using FieldStation42 itself as
much as possible.

The goal is not to replace FieldStation42, not to rewrite its scheduler, and not
to maintain a separate node player. The current direction is:

```text
Headend PC:
  normal FieldStation42 authority
  catalog generation
  schedule generation
  media storage/export

FS42 clients/nodes:
  normal FieldStation42 install
  local field_player.py playback
  local channel state
  shared read-only schedule/catalog DB
  shared read-only station configs
  shared read-only media
```

Target use case:

- Offline LAN with no internet requirement
- Festival/camp/desert/private event deployment
- One PC acting as the FieldStation42 headend
- Ethernet-connected Raspberry Pi or small-PC playback clients
- Shared media over NFS/NAS
- Local time synchronization from the headend PC
- Independent channel changing on each client
- Reuse of FieldStation42's own media, guide, web, streaming, and player logic

Core design sentence:

```text
Use FieldStation42 for FieldStation42 behavior.
Use this repo for setup scripts, mounts, symlinks, services, and checks.
```

## Current Architecture

```text
                    Headend PC
                    10.0.0.99
              +--------------------+
              | FieldStation42     |
              | catalog builder    |
              | schedule builder   |
              | fs42_fluid.db      |
              | station configs    |
              | media library      |
              | NFS exports        |
              +---------+----------+
                        |
                  read-only LAN
                        |
          +-------------+-------------+
          |                           |
   FS42 client 1               FS42 client 2
   field_player.py             field_player.py
   local channel 66            local channel 42
   local API :4242             local API :4242
```

Shared from the headend:

- Media root, preferably mounted at the same absolute path as the headend
- Station JSON configs from `confs/`, excluding client-local `main_config.json`
- `runtime/fs42_fluid.db`

Local on each client:

- `runtime/channel.socket`
- `runtime/play_status.socket`
- `runtime/player_state.bin`
- local `confs/main_config.json`
- local `field_player.py` process
- local display/audio/player state
- local FS42 player API, usually on port `4242`

## Repository Strategy

This repo is now deployment glue first.

Active folders should be focused on:

```text
docs/
examples/
scripts/
systemd/
backups/
```

Older experimental custom player/helper work was backed up under:

```text
backups/native-fs42-pivot-2026-05-25/
```

Do not reintroduce `node-agent/` or `helper-api/` as the primary direction unless
the user explicitly asks to revive that older prototype.

## Headend Responsibilities

The headend is the only schedule/catalog authority.

The headend may run:

```bash
python3 station_42.py --rebuild_catalog
python3 station_42.py --add_day
python3 station_42.py --add_week
python3 station_42.py --add_month
```

The headend may also use FieldStation42's web console build endpoints or Live
Schedule Agent.

The headend should export read-only NFS paths for clients:

```text
media root
FieldStation42/confs
FieldStation42/runtime
```

The runtime export is used so clients can read:

```text
runtime/fs42_fluid.db
```

## Client Responsibilities

Each FS42 client runs FieldStation42's own `field_player.py`.

The client setup should:

- Install or verify a normal FieldStation42 checkout/env
- Mount headend media read-only
- Mount headend `confs` read-only
- Mount headend `runtime` read-only
- Symlink only local `runtime/fs42_fluid.db` to the shared headend DB
- Symlink station config JSON files from the headend config mount
- Keep `confs/main_config.json` local to the client
- Remove/avoid `schedule_agent` in client `main_config.json`
- Start `field_player.py` in normal mode, not `--no_server`, by default

The client should not run catalog rebuilds or schedule extension jobs.

## Channel Control

Use FieldStation42's original local player API on each client.

Examples:

```bash
curl http://CLIENT_IP:4242/player/channels/66
curl http://CLIENT_IP:4242/player/channels/up
curl http://CLIENT_IP:4242/player/channels/down
curl -X POST http://CLIENT_IP:4242/player/channels/guide
```

This is independent per client because each client has its own local
`field_player.py`, `runtime/channel.socket`, and player state.

Do not send client tuning commands to the headend unless intentionally
controlling the headend's own local player.

## Important Guardrails

Do not treat clients as co-equal schedule writers.

Avoid this:

```text
Client A writes fs42_fluid.db
Client B writes fs42_fluid.db
Headend writes fs42_fluid.db
```

Preferred rule:

```text
Headend writes fs42_fluid.db.
Clients read fs42_fluid.db.
```

Why this matters:

- `fs42_fluid.db` contains catalog rows and generated `liquid_blocks` schedule
  rows.
- `field_player.py` can trigger schedule panic if schedules are missing or out
  of bounds.
- Schedule panic attempts to extend schedules and writes to the DB.
- Clients should therefore see a read-only DB where practical, and the headend
  should keep schedules extended far enough ahead.

## Setup Scripts

Primary scripts:

```text
scripts/setup-host.sh
scripts/setup-node.sh
scripts/fs42client-health-check.py
scripts/install-fs42client-service.sh
```

`setup-host.sh` should:

- Detect the local FieldStation42 checkout where possible
- Detect the media root from `fs42_fluid.db` catalog realpaths where possible
- Prepare NFS export lines for media, `confs`, and `runtime`
- Optionally configure Chrony as an offline LAN time source using
  `HEADEND_LAN_CIDR`
- Leave schedule generation to FieldStation42's existing commands/agent

`setup-node.sh` should:

- Detect the local FieldStation42 checkout where possible
- Ask for headend host/IP
- Use `showmount -e` to detect exported media, `confs`, and `runtime`
- Mount those exports read-only with `nofail`, `_netdev`, and automount options
- Optionally configure Chrony to sync from the headend host/IP
- Warn if DB catalog realpaths do not match the selected client media mount
- Create DB and station-config symlinks
- Generate a client-local `main_config.json`
- Install the `field_player.py` user service if requested

`fs42client-health-check.py` should:

- Check client FS42 directory
- Check station configs
- Check media mount
- Check DB symlink/path
- Open DB read-only
- Confirm catalog and schedule tables exist and contain rows
- Print schedule end times by station
- Warn if client `main_config.json` contains `schedule_agent`

`install-fs42client-service.sh` should:

- Install the FieldStation42 client player systemd user service separately
- Optionally enable user lingering
- Optionally start/restart the service

## Systemd

The client player service should start FieldStation42's own player:

```text
systemd/fs42-node-player.user.service.in
```

Default behavior should start:

```bash
field_player.py
```

Do not pass `--no_server` by default, because the local FS42 player API is useful
for per-client channel control and status.

## Media Paths

Prefer mounting media on clients at the same absolute path used by the headend.

Example:

```text
Headend realpath in DB:
  /media/FS42DB/fs42/catalog/...

Client mount:
  /media/FS42DB/fs42
```

This avoids path translation and makes FieldStation42's own catalog rows work
without custom helper logic.

## FieldStation42 Patches

Avoid patching FieldStation42 unless the need is small, focused, and clearly
better handled upstream.

Potential acceptable patch:

```text
disable_schedule_panic for kiosk/client mode
```

Avoid:

```text
rewriting the scheduler
replacing field_player.py
adding a parallel node-agent as the primary player
duplicating FS42's player/channel APIs
```

## Current First Milestone

One headend and one client:

```text
Headend:
  catalog built
  schedule built
  NFS exports available

Client:
  FieldStation42 installed
  media mounted
  confs mounted
  runtime mounted
  fs42_fluid.db symlinked
  station configs symlinked
  main_config local
  field_player.py starts
  client channel can be changed through http://CLIENT_IP:4242/player/channels/...
```

After that works, expand to multiple clients.
