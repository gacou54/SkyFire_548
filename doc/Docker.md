# Running SkyFire with Docker

`docker-compose.yml` runs three containers:

| Service       | Image          | Ports (host)                              |
|---------------|----------------|-------------------------------------------|
| `db`          | `mysql:8.4`    | `127.0.0.1:3306`                          |
| `authserver`  | `skyfire548`   | `3724`                                    |
| `worldserver` | `skyfire548`   | `8085`, RA `127.0.0.1:3443`, SOAP `127.0.0.1:7878` |

A fourth service, `extractor` (profile `tools`), extracts client data.

The `skyfire548` image is built from the repository `Dockerfile`. It compiles
Boost 1.91 (headers only), OpenSSL 4 with the legacy provider, and the server
with GCC 14 on Ubuntu 24.04. Rebuilds use a BuildKit ccache mount, so a source
change does not recompile everything.

## Quick start

```bash
cp .env.example .env          # optional; every value has a default
docker compose build

# Once: extract dbc/maps/vmaps from a 5.4.8 client into ./docker/data
WOW_CLIENT_DIR="/path/to/World of Warcraft" docker compose run --rm extractor

docker compose up -d
docker compose logs -f worldserver
```

On the first start:

1. `db` creates the `auth`, `characters` and `world` databases and the
   `skyfire` user (`docker/mysql/init/01-skyfire.sh`).
2. `authserver` imports `sql/base/auth_database.sql` and `sql/updates/auth`
   (`LoginDatabase.AutoSetup`).
3. `worldserver` downloads the world database release from `WORLD_DB_URL` into
   the `dbdump` volume, then imports it with `sql/base/characters_database.sql`
   and the `sql/updates` folders (`WorldDatabase.AutoSetup`,
   `CharacterDatabase.AutoSetup`). The world import takes several minutes.
   It also sets `auth.realmlist` from `REALM_NAME`, `REALM_ADDRESS` and
   `WORLD_PORT`.

Later starts only apply new files from `sql/updates`. The image contains the
`sql/` folder from build time, so rebuild the image after pulling SQL updates.

## GM console and accounts

The worldserver console is attached to the container's TTY:

```bash
docker attach skyfire-worldserver
SF> account create admin admin
SF> account set gmlevel admin 3 -1
# detach with Ctrl-p Ctrl-q (Ctrl-c stops the server)
```

## Client data

The worldserver needs `dbc/`, `maps/` and `vmaps/` in `SKYFIRE_DATA_DIR`
(default `./docker/data`), and `mmaps/` if `mmap.enablePathFinding = 1`. If
you already have extracted data, point `SKYFIRE_DATA_DIR` at it. Otherwise:

```bash
docker compose run --rm extractor              # maps + vmaps
docker compose run --rm extractor mmaps        # mmaps, takes hours
```

The container runs as uid/gid `SKYFIRE_UID`/`SKYFIRE_GID` (default 1000).
Set these to your host user's ids so the extractor can write to the data
folder.

## Configuration

At each start, the entrypoint (`docker/entrypoint.sh`) renders the config into
`/opt/skyfire/run/<server>.conf`:

1. It starts from `/opt/skyfire/etc/<server>.conf` if you mount one, or from
   the `.conf.dist` otherwise.
2. It sets the container paths and database connection strings.
3. It applies every `SFCONF_*` environment variable. Write `.` in the key
   as `__`:

```yaml
    environment:
      SFCONF_Rate__XP__Kill: "5"            # Rate.XP.Kill = "5"
      SFCONF_mmap__enablePathFinding: "1"
```

To manage a full config file instead, mount it:

```yaml
    volumes:
      - ./my-worldserver.conf:/opt/skyfire/etc/worldserver.conf:ro
```

### Module configs

Module `*.conf.dist` files (from `modules/<mod>/conf/`) are rendered into
`/opt/skyfire/run/` next to `worldserver.conf`, from a mounted
`/opt/skyfire/etc/<mod>.conf` if present. An `SFCONF_*` override goes to the
file that defines the key. A key that no file defines goes to the module config
that defines keys with the same first segment (`SFCONF_Playerbots__Foo` →
`playerbots.conf`), and to `worldserver.conf` otherwise.

## Out-of-tree modules

Modules that live in their own repository can be built into the image without
copying them into `modules/`. Pass the module as the `extra_modules` build
context, either a local folder or a git URL:

```bash
docker buildx build \
    --build-context extra_modules=../mod-playerbots \
    --build-arg EXTRA_MODULE_NAME=mod-playerbots \
    -t skyfire548:playerbots .
```

In a compose file:

```yaml
    build:
      context: .
      additional_contexts:
        extra_modules: https://github.com/<owner>/mod-playerbots.git#main
      args:
        EXTRA_MODULE_NAME: mod-playerbots
```

`EXTRA_MODULE_NAME` is the folder name under `modules/`, which also sets the
loader function name (`Addmod_playerbotsScripts()`). Without it, the context
must contain module folders, laid out like `modules/`.

## Connecting from another machine

Set `REALM_ADDRESS` in `.env` to the host's LAN or public IP and restart
`worldserver`. The client's `realmlist.wtf` should point to the same address.
Keep `WORLD_PORT` identical on both sides of the port mapping. The compose file
already does this, because the realm's `realmlist.port` must match the port the
worldserver listens on.

## Troubleshooting

- **The first world import was interrupted.** AutoSetup only installs the base
  dump into an *empty* schema. Recreate the database and restart:

  ```bash
  docker compose stop worldserver
  docker compose exec db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot \
      -e "DROP DATABASE world; CREATE DATABASE world DEFAULT CHARACTER SET utf8mb4"'
  docker compose start worldserver
  ```

- **Changes to `docker/mysql/init` have no effect.** The script only runs when
  the `db-data` volume is empty (`docker compose down -v` resets it).

## Development

- `IMPORT_PENDING_UPDATES=1` also imports `sql/pending_updates/{world,characters}`
  at startup.
- `docker compose build` after code changes, then `docker compose up -d`.
- `docker compose exec db mysql -uskyfire -pskyfire world` opens a SQL shell.
- `docker compose down -v` deletes the databases, the cached world dump and
  the logs.
