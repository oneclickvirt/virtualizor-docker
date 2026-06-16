# Virtualizor inside Docker

This repository builds a Docker image for a Virtualizor master-only panel. It uses Ubuntu 24.04 LTS, s6-overlay v3, persistent host volumes, and examples for both local builds and prebuilt images.

本仓库用于构建 Virtualizor 主控面板容器镜像。当前默认使用 Ubuntu 24.04 LTS、s6-overlay v3、主机持久化目录，并提供本地构建和预构建镜像两种 compose 示例。

## Images

| Maintainer | Repository |
| :--------: | ---------- |
| ivstiv | [![Docker Pulls](https://img.shields.io/docker/pulls/ivstiv/virtualizor-docker?logo=docker&logoColor=white&style=for-the-badge)](https://hub.docker.com/r/ivstiv/virtualizor-docker "open on dockerhub") |
| Sonoran Software | [![Docker Pulls](https://img.shields.io/docker/pulls/sonoransoftware/virtualizor-docker?logo=docker&logoColor=white&style=for-the-badge)](https://hub.docker.com/r/sonoransoftware/virtualizor-docker "open on dockerhub") |

The GitHub Actions workflow builds `linux/amd64` and `linux/arm64` images and can push to GHCR plus Docker Hub when Docker Hub secrets are configured.

## Configuration

Copy the example config before using `virtualizor.sh`:

```sh
cp example-config.sh config.sh
```

| Variable | Default/example | Description |
| --- | --- | --- |
| `USER_HTTP_PORT` | `4082` | Host port for the user HTTP panel |
| `USER_HTTPS_PORT` | `4083` | Host port for the user HTTPS panel |
| `ADMIN_HTTP_PORT` | `4084` | Host port for the admin HTTP panel |
| `ADMIN_HTTPS_PORT` | `4085` | Host port for the admin HTTPS panel |
| `PUID` | `1000` | Runtime user id for EMPS files |
| `PGID` | `1000` | Runtime group id for EMPS files |
| `EMAIL` | `your@email.here` | Virtualizor admin email |
| `PANEL_DIR` | `/opt/virtualizor` | Host data directory used by `virtualizor.sh` |
| `PASSWORD` | unset for script, `changeme` in compose examples | Root password passed to the container |
| `VIRTUALIZOR_MEM_LIMIT` | `4g` | Container memory limit |
| `VIRTUALIZOR_CPUS` | `2` | Container CPU limit |
| `AUTO_RESTART_ON_UNHEALTHY` | `true` | Healthcheck restarts Virtualizor services once before reporting unhealthy |

`PUID`, `PGID`, ports, `EMAIL`, and `PASSWORD` are validated at startup. Empty passwords are rejected; the example `changeme` value prints a warning.

## Deploy With Docker Compose

Local build:

```sh
docker compose up -d --build
```

Prebuilt image:

```sh
docker compose -f dockerhub_docker-compose.yml up -d
```

Both compose files expose the same container ports:

```text
4082 -> user HTTP
4083 -> user HTTPS
4084 -> admin HTTP
4085 -> admin HTTPS
```

The panel should be available at:

```text
http://SERVER_IP:4084/
https://SERVER_IP:4085/
```

Virtualizor packages its own EMPS stack, including MySQL and web services, inside the persisted directories. There are no separate MySQL or Redis containers to declare with `depends_on`.

## Deploy With virtualizor.sh

Build the local image:

```sh
sh virtualizor.sh build
```

Install and run the panel:

```sh
sh virtualizor.sh install
```

If `PASSWORD` is not exported, the script prompts for it. When `/dev/tty` or `stty` is unavailable, it falls back to a visible stdin prompt instead of failing with an unclear TTY error.

Useful commands:

```sh
sh virtualizor.sh start
sh virtualizor.sh stop
sh virtualizor.sh shell
sh virtualizor.sh reinstall
sh virtualizor.sh uninstall
```

`reinstall` and `uninstall` are destructive and ask for confirmation. For non-interactive automation, set `VIRTUALIZOR_ASSUME_YES=1` or pass `--yes`.

## Logs And Health

Installer and runtime messages are written in English and Chinese where this image controls the output. The installer tees output to both Docker logs and `/root/virtualizor.log`.

```sh
docker logs virtualizor
docker compose logs -f virtualizor
```

The image includes a Docker `HEALTHCHECK`. It probes Virtualizor HTTP/HTTPS ports and, when `AUTO_RESTART_ON_UNHEALTHY=true`, tries `/etc/init.d/virtualizor restart` once before reporting the container unhealthy.

```sh
docker inspect --format '{{json .State.Health}}' virtualizor
```

## Persistent Data

Do not remove these host directories unless you want a fresh install:

| Host path in compose | Container path | Purpose |
| --- | --- | --- |
| `./data/emps` | `/usr/local/emps` | EMPS runtime, PHP, MySQL, web services |
| `./data/virtualizor` | `/usr/local/virtualizor` | Virtualizor panel files, config, internal data |
| `./data/init` | `/etc/init.d` | Virtualizor init scripts installed by the panel |
| `./data/cron` | `/etc/cron.d` | Virtualizor cron entries |

Backup example:

```sh
docker compose stop virtualizor
tar -czf virtualizor-data-$(date +%F).tgz data
docker compose start virtualizor
```

Restore example:

```sh
docker compose down
rm -rf data
tar -xzf virtualizor-data-YYYY-MM-DD.tgz
docker compose up -d
```

The container treats empty `/usr/local/emps` or `/usr/local/virtualizor` as a fresh or incomplete install and re-runs the installer. If you intentionally want a clean database and panel state, stop the container and delete the `data` directory first.

## Build And Publish

Local multi-arch build:

```sh
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t virtualizor-docker:local \
  .
```

The workflow in `.github/workflows/DockerHub.yml` publishes:

- `latest` on the default branch
- the Git tag when building from a tag
- a manual `workflow_dispatch` tag when provided
- `sha-<shortsha>` for every run

To push Docker Hub images, configure `DOCKER_HUB_USERNAME` and `DOCKER_HUB_ACCESS_TOKEN` repository secrets. GHCR publishing uses the built-in `GITHUB_TOKEN`.

## Notes

- The Dockerfile downloads the s6-overlay tarball matching the target architecture and verifies upstream SHA256 files.
- The Virtualizor installer downloads EMPS over HTTPS and selects the ionCube loader that matches the EMPS PHP runtime instead of hardcoding PHP 5.3.
- If EMPS ever ships an end-of-life PHP lower than `MIN_EMPS_PHP_VERSION` (`7.4` by default), installation stops unless `ALLOW_EOL_EMPS_PHP=true` is explicitly set.

## Credits And Links

- This was initially developed as a standalone installation image by [Nottt](https://github.com/Nottt?tab=repositories). Ivstiv preserved the original license.
- [s6-overlay project](https://github.com/just-containers/s6-overlay)
- [Virtualizor home page](https://www.virtualizor.com)
- [Sonoran Software Systems LLC](https://sonoran.software) uses Virtualizor day to day for their [VPS server hosting](https://sonoranservers.com/).
