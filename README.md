# ceph-lab

[![CI](https://github.com/HarryKodden/ceph-lab/actions/workflows/ci.yml/badge.svg)](https://github.com/HarryKodden/ceph-lab/actions/workflows/ci.yml)
[![Release](https://github.com/HarryKodden/ceph-lab/actions/workflows/release.yml/badge.svg)](https://github.com/HarryKodden/ceph-lab/actions/workflows/release.yml)
[![Latest Release](https://img.shields.io/github/v/release/HarryKodden/ceph-lab?sort=semver)](https://github.com/HarryKodden/ceph-lab/releases/latest)
[![Ceph](https://img.shields.io/badge/Ceph-Reef%20v18.2.7-ef5c55?logo=ceph&logoColor=white)](https://docs.ceph.com/en/reef/)
[![Docker](https://img.shields.io/badge/Docker-Compose-2496ed?logo=docker&logoColor=white)](https://docs.docker.com/compose/)
[![License](https://img.shields.io/github/license/HarryKodden/ceph-lab)](LICENSE)

A single-node [Ceph](https://ceph.io/) reef (v18.2.7) cluster running in Docker Compose, exposing an S3-compatible RADOS Gateway (RGW), IAM/STS support, and the Ceph Dashboard. Designed to sit behind a [Traefik](https://traefik.io/) reverse proxy for TLS termination and hostname-based routing.

---

## Architecture

```
Internet
   │
   ▼
Traefik (external Docker network)
   │  TLS termination, Let's Encrypt certs
   ├──► dashboard.<RGW_DNS_NAME>  →  mgr:8080  (Ceph Dashboard, HTTP internally)
   └──► ceph.<RGW_DNS_NAME>       →  rgw:7480  (S3 / RGW, HTTP internally)

Internal Docker network: ceph-net (172.20.0.0/24)
   ├── mon   172.20.0.10   Ceph Monitor
   ├── mgr   172.20.0.11   Ceph Manager + Dashboard module
   ├── osd   172.20.0.12   Ceph OSD (10 GiB BlueStore block file)
   └── rgw   172.20.0.13   RADOS Gateway (S3 / IAM / STS / Admin API)
```

### Service startup order

```
bootstrap → mon → mgr ──┐
                         ├──► (healthy) → setup  (one-shot finalisation)
           mon → osd     │
           mon → rgw ────┘ (healthy)
```

1. **bootstrap** — one-shot; creates `ceph.conf`, keyrings, and the monitor data directory. Skipped on subsequent starts (guarded by `.bootstrapped` flag).
2. **mon** — Ceph monitor daemon.
3. **mgr** — Ceph manager daemon; installs and pre-enables the dashboard module.
4. **osd** — Single BlueStore OSD (10 GiB virtual block device).
5. **rgw** — RADOS Gateway; creates the realm/zonegroup/zone hierarchy, registers the endpoint, commits the period, then starts `radosgw`.
6. **setup** — one-shot; runs after both `mgr` and `rgw` are healthy. Configures S3 users, IAM users, IAM roles, dashboard credentials, and links RGW to the dashboard.

---

## Prerequisites

- Docker Engine ≥ 24 with Compose v2 (`docker compose`)
- A running **Traefik** instance attached to a Docker network named `external` with:
  - An `https` entrypoint (port 443)
  - A Let's Encrypt cert resolver named `le`
  - `--providers.docker=true` and `--providers.docker.exposedbydefault=false`

> **Without Traefik**: the services are still reachable directly on the host — see [Direct access (no Traefik)](#direct-access-no-traefik) below.

---

## Configuration

Copy `.env.example` to `.env` and edit as needed:

```bash
cp .env.example .env
```

| Variable | Default | Description |
|---|---|---|
| `CEPH_IMAGE` | `quay.io/ceph/ceph:v18.2.7` | Ceph container image |
| `RGW_PORT` | `7480` | Internal RGW port |
| `RGW_DNS_NAME` | `localhost` | Public hostname for S3 virtual-hosted bucket URLs and Traefik routing rule |
| `RGW_STS_KEY` | `s3cretSTSkey1234` | AES-128 STS signing key — **must be exactly 16 bytes** |
| `DASHBOARD_PORT` | `8080` | Internal dashboard port (HTTP; TLS is handled by Traefik) |
| `DASHBOARD_PASSWORD` | `admin` | Password for the `admin` dashboard user |
| `S3_USER` | `s3user` | UID of the demo S3 user |
| `S3_ACCESS_KEY` | `s3accesskey12345` | Access key for the demo S3 user |
| `S3_SECRET_KEY` | `s3secretkey12345` | Secret key for the demo S3 user |
| `IAM_UID` | `iamadmin` | UID of the IAM admin user |
| `IAM_ACCESS_KEY` | `iamaccess123456` | Access key for the IAM admin user |
| `IAM_SECRET_KEY` | `iamsecret1234567` | Secret key for the IAM admin user |

> Change all credentials before deploying to a non-local environment.

---

## Usage

### Start the cluster

```bash
docker compose up -d
```

Compose waits for `mgr` and `rgw` to become healthy before starting `setup`. On a fresh host this takes roughly 60–90 seconds.

### Watch progress

```bash
docker compose logs -f setup        # one-shot finalisation output
docker compose logs -f rgw          # RGW startup (realm/period commit)
docker compose ps                   # service health at a glance
```

### Run the setup step again (e.g. after changing credentials in .env)

```bash
docker compose up setup
```

### Stop and remove everything (including volumes)

```bash
docker compose down -v
```

---

## Endpoints

| Service | Internal URL | Public URL (via Traefik) |
|---|---|---|
| Ceph Dashboard | `http://mgr:8080` | `https://dashboard.<RGW_DNS_NAME>` |
| S3 / RGW | `http://rgw:7480` | `https://ceph.<RGW_DNS_NAME>` |
| Prometheus metrics | `http://mgr:9283` | — |

Dashboard login: `admin` / `<DASHBOARD_PASSWORD>`

---

## Traefik integration

The `mgr` and `rgw` containers carry Traefik labels that are picked up automatically when Traefik's Docker provider is active:

```
dashboard.<RGW_DNS_NAME>  →  mgr:8080  (HTTP, TLS terminated by Traefik)
ceph.<RGW_DNS_NAME>       →  rgw:7480  (HTTP, TLS terminated by Traefik)
```

Both routers use the `le` cert resolver (Let's Encrypt). The `external` Docker network must exist and Traefik must be attached to it:

```bash
docker network create external   # if it doesn't exist yet
```

The `rgw` container joins both `ceph-net` (internal cluster communication) and `external` (Traefik side-car routing).

---

## Direct access (no Traefik)

Uncomment the `ports:` sections in `docker-compose.yml` for `mgr` and `rgw`:

```yaml
# mgr
ports:
  - "8080:8080"

# rgw
ports:
  - "7480:7480"
```

Then access:
- Dashboard: `http://localhost:8080`
- S3 endpoint: `http://localhost:7480`

---

## S3 access

```bash
aws configure --profile ceph
# Access key: <S3_ACCESS_KEY>
# Secret key: <S3_SECRET_KEY>
# Region:     us-east-1
# Output:     json

aws --profile ceph \
    --endpoint-url https://ceph.<RGW_DNS_NAME> \
    s3 ls
```

---

## IAM / STS

The `iamadmin` user has caps for `users`, `roles`, and `oidc-provider`. The demo IAM role `demo-role` allows `s3user` to call `sts:AssumeRole`.

The following APIs are enabled on RGW: `s3`, `iam`, `sts`, `admin`, `swift`.

---

## Caveats

- **Single OSD, replica size 1** — data is not replicated. This is intentional for a lab/dev setup.
- **BlueStore block file** — the OSD uses a 10 GiB sparse file inside the `osd0-data` volume. Adjust `bluestore block size` in the bootstrap command to change the size.
- **`pg_autoscale_mode = warn`** — autoscaling is disabled to prevent pool creation failures caused by `pgp_num > pg_num` (ERANGE / errno 34). PG counts are managed manually.
- **`privileged: true` on osd** — BlueStore requires elevated kernel capabilities (AIO, mmap). Only the OSD container runs privileged.
- **amd64 forced** — recent Reef arm64 builds segfault on Apple Silicon under Rosetta 2. The `platform: linux/amd64` override makes emulation explicit and reliable.
