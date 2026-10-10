# TrinityCore-docker

A ready-to-run [TrinityCore](https://github.com/TrinityCore/TrinityCore) server: one
`docker compose up` gives MySQL, the worldserver and the login server, with the databases created
and filled on the first start.

| Branch | Client | Image |
|---|---|---|
| `cata_classic` | Cataclysm Classic 4.4.2.60895 | `ghcr.io/xian55/trinitycore:cata_classic` |
| `3.3.5` | Wrath of the Lich King 3.3.5a.12340 | `ghcr.io/xian55/trinitycore:3.3.5` |
| `4.3.4` | Cataclysm 4.3.4.15595 | `ghcr.io/xian55/trinitycore:4.3.4` |

Each branch is also tagged `<branch>-<upstream commit>`, e.g. `cata_classic-cf0cdb6abd7a`.

The binaries are TrinityCore's own images
([trinitycore/trinitycore](https://hub.docker.com/r/trinitycore/trinitycore)), which their CI
pushes for every commit. This repository adds what it takes to run them: the config files of that
commit, the matching [TDB](https://github.com/TrinityCore/TrinityCore/releases) world database
release, and an entrypoint that sets up the databases and the realm. A daily workflow picks up
new commits.

`4.3.4` is not a TrinityCore branch: it is the `master` of
[the Cataclysm Preservation Project's fork](https://github.com/The-Cataclysm-Preservation-Project/TrinityCore),
the maintained server for the original Cataclysm client. That project publishes no image, so this
one is compiled here, with its own TDB release.

The images are multi-arch, amd64 and arm64. TrinityCore publishes amd64 only, so the arm64 image
compiles the same commit into the same layout; Apple silicon and ARM servers run it natively.
No game data is in the image: you extract it from your own client, once.

## Quick start

```sh
git clone https://github.com/Xian55/TrinityCore-docker && cd TrinityCore-docker
cp .env.example .env        # set TC_BRANCH, REALM_ADDRESS (this host's LAN address), CLIENT_DIR
```

### 1. Extract the server data from a client

`CLIENT_DIR` is the client install folder, the one holding `Data/`. For `cata_classic` that is a
CASC install with its `.build.info` next to `Data/`; for 3.3.5 and 4.3.4 the folder with `Data/*.MPQ`.
The folder is mounted writable, because the CASC library opens some of its files read-write
(it only reads them). With Docker Desktop or colima, it has to be in a folder shared with the VM.

```sh
docker compose --profile tools run --rm extract
```

This writes dbc/db2, maps, cameras and game tables and, with `EXTRACT_VMAPS=1` (default), vmaps
into the `data` volume. Movement maps take hours, so they are off by default; set
`EXTRACT_MMAPS=1` and then `ENABLE_MMAPS=1` to have them.

### 2. Start the servers

```sh
docker compose up -d
docker compose logs -f worldserver
```

The first start fills the databases from the TDB dump, a minute or two. The login server starts
once the worldserver is up, and points the realm at `REALM_ADDRESS:WORLD_PORT`.

### 3. Create an account

The worldserver console is attached to the container's terminal:

```sh
docker attach tc-cata-worldserver-1     # <COMPOSE_PROJECT_NAME>-worldserver-1
```

```text
# cata_classic: a Battle.net account, its game account is <id>#1
bnetaccount create player@example.com secret
account set seclevel 1#1 3 -1

# 3.3.5
account create player secret
account set seclevel player 3 -1

# 4.3.4
account create player secret
account set gmlevel player 3 -1
```

Detach with `Ctrl-P Ctrl-Q`. `Ctrl-C` or end-of-input stops the worldserver.

### 4. Connect

- **3.3.5:** `set realmlist <REALM_ADDRESS>` in `realmlist.wtf` (with `LOGIN_PORT` other than 3724,
  `<REALM_ADDRESS>:<LOGIN_PORT>`).
- **4.3.4:** the same line, as `SET realmlist "<REALM_ADDRESS>"` in `WTF/Config.wtf`.
- **cata_classic:** the client has to be pointed at `<REALM_ADDRESS>:<LOGIN_PORT>` as its portal and
  accept the server's certificate, which needs a launcher such as
  [Arctium](https://arctium.io/). Log in with the e-mail address of the Battle.net account.

## Configuration

`.env` sets ports, passwords, the branch and the realm address; see [.env.example](.env.example).

Any key of `worldserver.conf`, `bnetserver.conf` or `authserver.conf` can be overridden with an
environment variable, `TC_` plus the key in upper snake case. Put them in `tc.env` (optional, see
[tc.env.example](tc.env.example)):

```sh
TC_RATE_XP_KILL=3            # Rate.XP.Kill
TC_GM_LOGIN_STATE=1          # GM.LoginState
```

Whole config files can also be mounted into
`/home/circleci/project/bin/check_install/etc/<server>.conf.d/`.

The 4.3.4 server reads neither environment variables nor a `conf.d` folder. There the entrypoint
writes the variables into `<server>.conf` on every start, under the same names, for each key that
`<server>.conf.dist` has.

### Packet log

`PACKET_LOG_FILE=World.pkt` makes the worldserver log every packet in plain text (before
encryption), in the format [WowPacketParser](https://github.com/TrinityCore/WowPacketParser) reads.
The worldserver truncates the file when it starts; `date` placeholders keep one file per start:

```sh
PACKET_LOG_FILE=World-%Y%m%d-%H%M%S.pkt
```

```sh
docker compose exec worldserver ls /logs
docker compose cp worldserver:/logs/World-20261010-140501.pkt .
```

### Two branches on one host

Give each its own env file with its own `COMPOSE_PROJECT_NAME` and ports (`REST_PORT` too, also
for a branch with an authserver, which does not use it):

```sh
docker compose --env-file cata.env  up -d
docker compose --env-file 3.3.5.env up -d
```

## Building the image yourself

```sh
docker build --platform linux/amd64 --build-arg TC_BRANCH=cata_classic --build-arg TC_TAG=cata_classic \
  -t ghcr.io/xian55/trinitycore:cata_classic .
```

`TC_TAG` is the tag of the official image to start from: the branch, or a full commit hash.
On amd64 nothing is compiled and the build takes about a minute. With `--platform linux/arm64`
the same commit is compiled, about an hour on four cores; `BUILD_JOBS=<n>` limits the compile
jobs, each of which needs up to ~1.5 GB of memory.

4.3.4 comes from another repository and is compiled on every architecture:

```sh
docker build \
  --build-arg TC_GITHUB=The-Cataclysm-Preservation-Project/TrinityCore --build-arg TC_BASE=compiled \
  --build-arg TC_BRANCH=master --build-arg TC_TAG=master \
  -t ghcr.io/xian55/trinitycore:4.3.4 .
```

`TC_GITHUB` is the repository the source, the config files and the TDB release are taken from,
and `TC_BASE=compiled` skips the official image. That fork has no arm64 support of its own, so on
arm64 the build leaves out its bundled jemalloc (the servers use the system allocator) and
supplies a stand-in for one x86-only header, [docker/arm64](docker/arm64). Both are applied only
while the source needs them.

## Credits

Inspired by [Byloth/cmangos-docker](https://github.com/Byloth/cmangos-docker) and
[nicolaw/trinitycore](https://gitlab.com/nicolaw/trinitycore). TrinityCore and
[the Cataclysm Preservation Project's fork](https://github.com/The-Cataclysm-Preservation-Project/TrinityCore)
are licensed under the GPL-2.0.
