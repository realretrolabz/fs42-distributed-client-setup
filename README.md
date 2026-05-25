# FieldStation42 Distributed Client Setup

Companion setup scripts for running FieldStation42 across a headend PC and one
or more playback clients.

This project does **not** replace FieldStation42. It uses FieldStation42 itself
for cataloging, scheduling, guide/web rendering, playback, and channel control.
This repo only helps wire together the distributed deployment pieces:

- NFS exports and mounts
- optional offline LAN time sync with Chrony/NTP
- shared media/catalog access
- shared `fs42_fluid.db`
- shared station configs
- client-local runtime sockets/state
- systemd client player service
- health checks

## Model

```text
Headend PC
  FieldStation42 install
  owns catalog and schedule generation
  writes runtime/fs42_fluid.db
  exports media, confs, and runtime read-only

FS42 client/node
  FieldStation42 install
  runs local field_player.py
  reads shared media/config/DB
  keeps local channel socket and player state
  exposes its own local FS42 API on port 4242
```

Channel changing uses FieldStation42's original player API on each client:

```bash
curl http://CLIENT_IP:4242/player/channels/66
curl http://CLIENT_IP:4242/player/channels/up
curl http://CLIENT_IP:4242/player/channels/down
```

## Why

The goal is to simulate independent cable-box-style tuners on an offline LAN.
All clients share the same FieldStation42 schedule universe and media library,
but each client chooses its own channel locally.

## Important Rule

Only the headend should build catalogs and schedules.

Clients should not run:

```bash
python3 station_42.py --rebuild_catalog
python3 station_42.py --add_day
python3 station_42.py --add_week
python3 station_42.py --add_month
```

Clients are playback appliances. They read the headend-generated DB and keep
their own local player state.

## Scripts

```text
scripts/setup-host.sh
  Prepares headend NFS exports for media, confs, and runtime. The headend
  remains responsible for FieldStation42 catalog/schedule generation. Can also
  optionally configure the headend as an offline Chrony/NTP time source.

scripts/setup-node.sh
  Mounts headend exports, links shared DB/config/media/runtime assets, and keeps
  local client sockets/state separate. Can also optionally configure the client
  to sync time from the headend.

scripts/install-fs42client-service.sh
  Installs a systemd user service for client field_player.py.

scripts/fs42client-health-check.py
  Checks client readiness and schedule/catalog DB visibility.
```

## Basic Flow

On the headend:

```bash
cd ~/FieldStation42
source env/bin/activate
python3 station_42.py --rebuild_catalog
python3 station_42.py --add_week
```

Then from this companion repo:

```bash
scripts/setup-host.sh
```

The host setup script does not replace FieldStation42's scheduler. It prepares
read-only exports so clients can see the headend's media, station configs, and
runtime DB. For schedule maintenance, use FieldStation42's own tools:

```bash
python3 station_42.py --add_day
python3 station_42.py --add_week
python3 station_42.py --add_month
```

Or configure FieldStation42's Live Schedule Agent on the headend so schedules
are extended before they expire. Clients should not enable that agent.

For offline deployments, `setup-host.sh` can optionally configure Chrony so the
headend acts as the LAN time source:

```text
allow 10.0.0.0/24
local stratum 10
```

`setup-node.sh` can optionally configure each client to sync to the headend:

```text
server 10.0.0.99 iburst prefer
```

This is not required for a quick test, but it is recommended when multiple
clients should stay aligned to the same schedule clock without internet access.

On each client:

```bash
scripts/setup-node.sh
scripts/fs42client-health-check.py --fs42-dir ~/FieldStation42 --media-root /media/FS42DB/fs42
```

This assumes FieldStation42 has already been installed on the client using the
upstream FieldStation42 installer:

```bash
cd ~/FieldStation42
bash install.sh
```

Test manually:

```bash
cd ~/FieldStation42
source env/bin/activate
python3 field_player.py
```

Then test channel control:

```bash
curl http://127.0.0.1:4242/player/channels/66
```

After manual playback works, install the client service:

```bash
scripts/install-fs42client-service.sh --fs42-dir ~/FieldStation42 --enable-linger --start
```

## Notes

- Mount media on clients at the same absolute path used by the headend when
  possible. For example: `/media/FS42DB/fs42`.
- The host exports media, `confs`, and `runtime` read-only to clients.
- Client symlinks point at read-only NFS mounts where possible. A symlink itself
  is not what makes data read-only; the NFS export/mount permissions do that.
- The client keeps `runtime/channel.socket`, `runtime/play_status.socket`, and
  `runtime/player_state.bin` local.
- The client symlinks `runtime/fs42_fluid.db` to the headend runtime mount.
- The client symlinks station configs from the headend, but keeps
  `confs/main_config.json` local.
- The client links shared runtime assets such as `runtime/guide`,
  `runtime/logo_images`, and default standby/off-air media.
- FieldStation42 currently stores both shared assets/data and local player state
  under `runtime/`. A cleaner upstream layout for distributed setups would split
  runtime into shared and local areas, for example:

```text
runtime/shared/
  fs42_fluid.db
  guide/
  logo_images/
  standby.png
  brb.png
  off_air_pattern.mp4
  signoff.mp4

runtime/local/
  channel.socket
  play_status.socket
  player_state.bin
```

Until FieldStation42 has a split like that, this companion setup links only the
specific shared runtime files/assets needed by the client and leaves sockets and
player state local.

## Attribution

This project is an unofficial companion/deployment helper for
[FieldStation42](https://github.com/shane-mason/FieldStation42) by Shane Mason.

FieldStation42 is the upstream application. This repository does not include or
replace FieldStation42; it provides setup scripts for distributed client
deployments using a normal FieldStation42 install.

Please see the upstream project for FieldStation42 source code, license,
documentation, and support:
```
https://github.com/shane-mason/FieldStation42

https://fieldstation42.com
```
