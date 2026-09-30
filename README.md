# CTFd Infrastructure

The purpose of this repository is to propose a simple setup and challenge management tool for CTFd infrastructures. It has been tested and validated on  [PolyCyber](polycyber.io)'s CTFd infrastructures (PolyPwn2025, PolyPwn2026, as well as the internal CTFd for PolyCyber).

## Available Scripts

### 1. CTFd Installation Script (`setup.sh`)

Bash script that automates the installation and configuration of a CTFd server using the [Zync](https://github.com/28Pollux28/zync) plugin and its dedicated instancer [Galvanize](https://github.com/28Pollux28/galvanize).

### 2. Challenge Management Tool (`challenges.sh`)

Bash script for building, ingesting, and synchronizing CTF challenges with support for Docker containers and Docker Compose.

# Prerequisites

## For the CTFd installation script

- **Operating System**: Tested and verified on:
  - Ubuntu Server 24
  - Ubuntu Server 25
  - Debian 12
- **Privileges**: The script must be executed as root (automatically uses sudo if necessary)

## For the challenge management tool

- **Docker**: Installed and functional
- **curl, jq, yq**: For API calls and YAML/JSON processing (automatically verified)
- **Challenge repository**: Folder structure with `challenge.yml` files

# CTFd Server Installation

1. **Clone this repository**:
   ```bash
   git clone https://github.com/CorentinFelten/infra
   cd infra
   ```

2. **Run the installation script and follow the instructions**:
   ```bash
   ./setup.sh --domain <your-domain.com>
   ```

3. **Go to the configured server URL**
   - Configure the CTF event
   - Navigate to the admin configuration panel: `Admin Panel` --> `Plugins` --> `Zync Config`
   - Check the Galvanize instancer URL and JWT secret (both are pre-filled by the setup, see below)

   > **Instancer URL and JWT secret**: with the provided setup workflow, both are injected automatically into the CTFd container from `deploy/.env`: `ZYNC_DEPLOYER_URL` (`https://instancer.<domain>` for the bundled instancer) and `ZYNC_JWT_SECRET`. The same secret is written to the Galvanize config. You therefore do not need to enter either value manually in the Zync Config panel.

## Installation Script Options

| Option                   | Description                                                                      | Required |
|--------------------------|----------------------------------------------------------------------------------|----------|
| `--domain domain/IP`     | URL/domain of your CTFd server                                                   | ✅ Yes   |
| `--working-folder DIR`   | Working directory (default: your home directory, `/root` when run as root)     | ❌ No    |
| `--theme DIR/URL`        | Enables the use of a personalised theme                                          | ❌ No    |
| `--backup-schedule TYPE` | Database backup frequency (`daily` (default), `hourly`, `10min`)                 | ❌ No    |
| `--instancer-url URL`    | Use an external Galvanize instancer instead of deploying one locally             | ❌ No    |
| `--no-instancer`         | Skip Galvanize setup entirely (deploy it separately later)                       | ❌ No    |
| `--dns-provider NAME`    | DNS provider for wildcard TLS certs (default: `cloudflare`)                      | ❌ No    |
| `--acme-email EMAIL`     | Email address for Let's Encrypt certificates (required for HTTPS)                | ✅ HTTPS |
| `--no-https`             | Deployment without HTTPS (automatically enabled for IP addresses)                | ❌ No    |
| `--help`                 | Display help                                                                     | ❌ No    |

> `--instancer-url` and `--no-instancer` are mutually exclusive.

## Installation Examples

```bash
# Basic installation with domain (includes local Galvanize instancer by default)
./setup.sh --domain example.com --acme-email admin@example.com

# Basic installation with IP address - automatically uses the --no-https option
./setup.sh --domain 192.168.123.123

# Installation with custom directory
./setup.sh --domain example.com --working-folder /opt/ctfd

# Installation with custom theme
./setup.sh --domain example.com --theme /home/user/my-custom-theme

# Installation with custom theme downloading a theme directly from github
./setup.sh --domain example.com --theme https://github.com/user/theme.git

# Custom ACME email for Let's Encrypt
./setup.sh --domain example.com --acme-email admin@example.com

# Hourly backup
./setup.sh --domain example.com --backup-schedule hourly

# Backup every 10 minutes
./setup.sh --domain example.com --backup-schedule 10min

# Use an external Galvanize instancer
./setup.sh --domain example.com --instancer-url https://instancer.example.com

# Skip Galvanize entirely (deploy it independently later)
./setup.sh --domain example.com --no-instancer

# Display help
./setup.sh --help
```

## Custom theme configuration

If you use the `--theme` option, the script will automatically mount the custom theme folder in the `docker-compose.yml`.

## Galvanize Instancer Deployment

By default, `setup.sh` deploys Galvanize as part of the CTFd Docker Compose stack. Two alternatives are available:

- **`--instancer-url URL`** — point CTFd at an already-running Galvanize instance; no local container is started.
- **`--no-instancer`** — skip Galvanize entirely during setup. You can deploy it independently later with its own config (see `config/galvanize/config.yaml` for the config template and `config/galvanize/playbooks/` for the Ansible playbooks). `ZYNC_DEPLOYER_URL` defaults to `https://instancer.<domain>`; update it in `deploy/.env` if your instancer lives elsewhere.

`setup.sh` records the choice in `deploy/.env` as `COMPOSE_PROFILES` (`instancer` for the bundled instancer, empty otherwise), so plain `docker compose up -d`, `down` or `pull` run from `deploy/` start and manage the instancer only when it is hosted locally. Switching away from the bundled instancer stops and removes its container on the next setup run.

### Galvanize configuration

The template `config/galvanize/config.yaml` is copied to `deploy/data/galvanize/config.yaml` on **every** run of `setup.sh`, so make lasting changes in the template rather than in the deployed copy. The setup then fills in:

| Key | Value |
|-----|-------|
| `auth.jwt_secret` | Generated secret (shared with CTFd as `ZYNC_JWT_SECRET`) |
| `instancer.ansible.user` / `inventory` | `ansible-user` on the `--domain` host |
| `instancer.instancer_host` | `--domain`, or `<ip>.sslip.io` for IP deployments (wildcard DNS) |
| `instancer.redis.addr` / `db` | `redis:6379`, db `1` (CTFd uses db `0` on the same Redis) |
| `instancer.extra_deployment_parameters.traefik_network` | `<COMPOSE_PROJECT_NAME>_challenges` (see [Network isolation](#network-isolation)) |

Other defaults: TCP host ports are randomized per team (`randomize_published_ports: true`), and every challenge container is limited to 1 CPU, 512 MB of RAM and 256 PIDs unless the challenge overrides `resource_limits`.

### Galvanize playbooks

The Ansible playbooks (`http`, `tcp`, `custom_compose`) are shipped in `config/galvanize/playbooks/` and copied to `deploy/data/galvanize/playbooks/` on every setup run. They are copies of Galvanize's upstream [`data/playbooks/`](https://github.com/28Pollux28/galvanize/tree/master/data/playbooks) (v0.7.1): the `data/` bind mount hides the playbooks baked into the Galvanize image, so they must live on the host. When upgrading Galvanize, refresh these files from upstream.

### Network isolation

The stack uses separate Docker networks so that player-controlled challenge containers cannot reach the platform:

| Network | Members | Purpose |
|---------|---------|---------|
| `proxy` | Traefik, CTFd, instancer | Public ingress (ports 80/443), instancer outbound SSH to the Ansible target host |
| `internal` (no internet access) | CTFd, MariaDB, Redis, instancer | Backend traffic (database, Redis) |
| `challenges` | Traefik, challenge instances | Traefik routing to `http` challenges |

- The Galvanize API must be publicly reachable: Zync calls it directly from players' browsers (and from the admin dashboard), which is also what lets Galvanize run on a separate machine (`--instancer-url`). The bundled instancer is published by Traefik on its own subdomain, `https://instancer.<domain>` (`http://instancer.<ip>.sslip.io` for IP deployments), on port 443. No extra port (such as 8080) is opened, and its Prometheus `/metrics` endpoint is not routed. This subdomain needs DNS pointing to the server; the wildcard record used for challenge subdomains (`*.<domain>`) already covers it.
- Challenge instances cannot reach CTFd, MariaDB, Redis or the instancer directly; they only see the same public endpoints as players. They can still reach Traefik, other challenge instances on the `challenges` network, and the internet. TCP challenges run on Docker's default bridge network.
- Traefik's Docker provider uses the `challenges` network by default, because containers deployed by Galvanize carry no `traefik.docker.network` label. Core services routed by Traefik (CTFd) must set `traefik.docker.network=<COMPOSE_PROJECT_NAME>_proxy` explicitly.

> **Upgrading an existing deployment**: terminate running challenge instances first (they are attached to the old network), then re-run `setup.sh`. This rewrites `docker-compose.yml`, the Traefik configs, the Galvanize config and playbooks, and resets `ZYNC_DEPLOYER_URL` to `https://instancer.<domain>` (unless `--instancer-url` is given). Zync caches the instancer URL in each player's browser (`localStorage`), so upgrade between events: players who already opened a challenge with the old `:8080` URL keep using it until their site data is cleared.

## Deployment Directory Structure

After running `setup.sh`, the following layout is created under `<working-folder>/deploy/`:

```
deploy/
├── docker-compose.yml          # Active compose file (copied from repo)
├── .env                        # Environment variables and generated secrets
├── .secrets                    # Plaintext copy of generated secrets (chmod 600)
├── traefik.env                 # DNS provider credentials, the only env Traefik gets (chmod 600)
├── traefik-config/             # Traefik static & dynamic configs, letsencrypt storage
├── ctfd/                       # CTFd Dockerfile and custom entrypoint
│   └── plugins/zync/           # CTFd instancer plugin clone
├── ansible-ssh/                # Ansible SSH key pair (local instancer only)
├── data/                       # Runtime data (database, uploads, galvanize)
│   ├── CTFd/
│   ├── mysql/
│   ├── redis/
│   └── galvanize/              # Galvanize data (local instancer only)
│       ├── config.yaml         # Galvanize config (from config/galvanize/config.yaml)
│       ├── playbooks/          # Ansible playbooks (from config/galvanize/playbooks/)
│       ├── challenges/         # Challenge repositories indexed by Galvanize
│       └── deployer.sqlite     # Galvanize deployment database
└── cron_backup.log             # Backup cron job log
```

# Challenge Management Tool

## `challenge.yml`: the ctfcli standard, without the tool

Challenges are described with the same `challenge.yml` format used by CTFd's
official [`ctfcli`](https://github.com/CTFd/ctfcli). Existing ctfcli-compatible
challenge repositories therefore work here unchanged, and challenges authored
for this tool stay portable back to ctfcli.

What this tool does **not** do is wrap or depend on `ctfcli`. Ingestion and
synchronization are implemented natively in Bash against the CTFd REST API
(`curl` + `jq`). This keeps the tool dependency-light (no Python/pip environment
to manage) and lets a single run build the Docker images, register the
challenge in CTFd, and wire up the [Galvanize](https://github.com/28Pollux28/galvanize)/[Zync](https://github.com/28Pollux28/zync)
deployment together.

The following `challenge.yml` fields are honored: `name`, `category`,
`description`, `value`, `type` (ctfcli's `standard`/`dynamic`, plus the
Galvanize-specific `zync` extension), `state`, `connection_info`, `attempts`,
`attribution`, the dynamic-scoring `initial`/`minimum`/`decay` values, `flags`,
`files`, `hints` (including `title`, `cost`, and `key`-based prerequisite
gating), `tags`, `topics`, `requirements` (either a bare list of prerequisites
or the `{prerequisites, anonymize}` object form), and an `extra` map passed
through verbatim for CTFd plugin fields.

## Authentication

The first time you run an action that talks to CTFd (`ingest`, `sync`, or the
default `all`), the tool prompts for your CTFd instance URL and an **admin
Access Token**. Generate this token beforehand from the CTFd web UI, logged in
as an administrator: **Settings → Access Tokens → Generate**. The account must
have admin rights, since ingesting and managing challenges uses admin-only API
endpoints.

The URL and token are saved to `<working-folder>/.ctfd/config` and reused on
subsequent runs, so you are only prompted once.

## Available Actions

| Action    | Description                     |
|-----------|---------------------------------|
| `all`     | Build + ingest (default)        |
| `build`   | Build Docker images only        |
| `ingest`  | Ingest challenges into CTFd     |
| `sync`    | Synchronize existing challenges |
| `status`  | Display status and statistics   |
| `cleanup` | Stop compose stacks and clean up Docker images (respects `--categories`/`--challenges` filters) |

## Main Options

| Option                 | Description                                                             | Required |
|------------------------|-------------------------------------------------------------------------|----------|
| `--repo REPO`          | Name of the challenge repository present in the working directory       | ✅ Yes   |
| `--action ACTION`      | Action to perform (all (default), build, ingest, sync, status, cleanup) | ❌ No    |
| `--working-folder DIR` | Working directory (default: your home directory)                        | ❌ No    |
| `--config FILE`        | Load configuration from a file                                          | ❌ No    |

## Filtering Options

| Option              | Description                                              |
|---------------------|----------------------------------------------------------|
| `--categories LIST` | List of categories to process (comma-separated)          |
| `--challenges LIST` | List of specific challenges to process (comma-separated) |

## Behavior Options

| Option                | Description                                            |
|-----------------------|--------------------------------------------------------|
| `--dry-run`           | Simulation mode (shows actions without executing them) |
| `--force`             | Force operations (rebuild, overwrite)                  |
| `--parallel-builds N` | Number of parallel builds (default: 4)                 |
| `--build-images MODE` | Build challenge images: `auto` (default), `yes`, `no`  |

## Debug Options

| Option                | Description                 |
|-----------------------|-----------------------------|
| `--debug`             | Enable debug output         |
| `--skip-docker-check` | Skip Docker daemon check    |
| `--help`              | Display help                |
| `--version`           | Display version information |

## Challenge Management Examples

```bash
# Full configuration (build + ingest)
./challenges.sh --repo challenge_repo

# Build only for certain categories
./challenges.sh --action build --repo challenge_repo --categories "web,crypto"

# Synchronization with forced update
./challenges.sh --action sync --repo challenge_repo --force

# Simulation mode to see planned actions
./challenges.sh --repo challenge_repo --dry-run

# Processing specific challenges
./challenges.sh --action build --repo challenge_repo --challenges "web-challenge-1,crypto-rsa"

# Parallel build with 8 threads
./challenges.sh --action build --repo challenge_repo --parallel-builds 8

# Display status
./challenges.sh --action status --repo challenge_repo

# Clean up Docker images
./challenges.sh --action cleanup --repo challenge_repo
```

### Configuration File

Create a `.env` file with `KEY=VALUE` pairs:

```bash
REPO=challenge_repo
WORKING_DIR=/opt/ctf
PARALLEL_BUILDS=8
FORCE=true
DEBUG=false
```

Usage:
```bash
./challenges.sh --config .env
```

# Script Functionality

## CTFd Installation Script

### 1. System Update
- Update system packages
- Install dependencies

### 2. Docker Installation
- Add official Docker repository
- Install Docker CE, Docker Compose, etc.
- Enable Docker service to start on boot
- Configure user groups

### 3. Theme configuration (optional)
If the `--theme` flag is used:
- Mounts the `theme/custom/` folder in the CTFd container
- Enables the use of custom themes

## Challenge Management Tool

### 1. Dependency Check
- Verify Docker and daemon availability
- Check for required system tools (curl, jq, yq)

### 2. Challenge Discovery
- Analyze the challenge repository structure
- Identify Docker and static challenges

### 3. Docker Image Building
- Only runs when the Galvanize instancer is hosted on this machine: Galvanize deploys images from its own Docker host, so images built elsewhere are never used. Detection (`--build-images auto`) reads `INSTANCER_MODE` from `<working-folder>/deploy/.env` (written by `setup.sh`: `local`, `external` or `none`), falls back to a local `GALVANIZE_CONFIG_PATH` for older deployments, then to a running `galvanize-instancer` container. When no local instancer is found, `all` goes straight to ingestion and `build` does nothing. Override with `--build-images yes` or `--build-images no`.
- Sequential or parallel image building
- Support for `--force` mode for complete rebuild
- Error handling with detailed reports

### 4. Challenge Ingestion
- Installation via the CTFd REST API into the CTFd instance
- Challenges are installed in **dependency order**: `requirements` are topologically sorted so a prerequisite is always created before the challenge that needs it. Circular dependencies are detected and reported.
- **Atomic install with rollback**: if attaching flags, files, hints, tags, topics, or requirements fails, the partially-created challenge is removed so a failed ingest leaves no half-registered challenge behind.
- Docker Compose image tag validation before ingest, and duplicate detection (existing challenges are skipped — use `sync` to update them).

### 5. Synchronization
- Updates existing challenges **in place**: the challenge is PATCHed, so its CTFd ID never changes.
- **Propagates edits to owned sub-resources** without losing player state:
  - **Hints are updated in place**, so players keep the hints they already unlocked (CTFd tracks unlocks by hint ID). The Nth hint in `challenge.yml` updates the Nth existing hint: keep hint order stable and append new hints at the end. Hints removed from `challenge.yml` are deleted, and players lose access to them.
  - **Flags are diffed**: new flags are added before removed ones are deleted, so the challenge is never left without a valid flag.
  - **Files are diffed** by content (SHA-1) and name: unchanged files are left alone and keep their download URL; new or changed files are uploaded, stale ones deleted.
  - Tags and topics, which carry no player state, are cleared and recreated.
- **Requirements are resolved in a second pass**, after every challenge has been synced, so a prerequisite referenced by name resolves correctly regardless of processing order.
- Option to backup before synchronization, and `--force` mode for overwriting.

### 6. Dependency-safe deletion
- CTFd stores requirement prerequisites as raw challenge IDs and does not cascade-clean them: deleting and recreating a challenge would give it a new ID and silently orphan every challenge that required it.
- To avoid this, sync never deletes-and-recreates a challenge (it patches in place), and the tool **refuses to delete a challenge that other challenges list as a prerequisite** unless explicitly forced.

### 7. Cleanup
- Remove Docker images associated with challenges
- Dry-run mode available

# Challenge Structure

## Expected Challenge Repository

```
challenge_repo/
├── challenges/                    # (optional, detected automatically)
│   ├── web/
│   │   ├── challenge-1/
│   │   │   ├── challenge.yml      # Challenge configuration
│   │   │   ├── Dockerfile         # Docker image (for type: zync)
│   │   │   ├── src/               # Source code
│   │   │   └── files/             # Challenge files
│   │   └── challenge-2/
│   ├── crypto/
│   └── pwn/
```

### Format of the `challenge.yml` File

```yaml
name: "MyChallenge"
author: Challenge_Author
category: AI

description: |-
  ## Description (French)

  Petite description en français

  ## Description (English)

  Short description in English

flags:
  - flag{flag_to_find}

tags:
  - AI
  - A:Challenge_Author

# Prerequisites: a bare list of challenge names/IDs...
requirements:
  - "Rules"
# ...or the object form, to show locked challenges as "???" instead of hiding them:
# requirements:
#   prerequisites:
#     - "Rules"
#   anonymize: true

# If files needed
files:
  - "files/hello_world.txt"

# If hints needed, choose the cost
hints:
  - Interesting hint
  - {
    cost: 10,
    content: "Interesting payed hint"
  }
  # Gated hint: stays hidden until the player unlocks the hints it requires.
  # Give the prerequisite hints a `key` and reference those keys in `requirements`.
  - key: step1
    cost: 5
    content: "First step"
  - cost: 20
    content: "Second step (only revealed after step1 is unlocked)"
    requirements:
      - step1

value: 5
type: zync                            # or type: dynamic / static

# Following options are for type: zync only. See https://github.com/28Pollux28/galvanize/tree/master/data/challenges/example for up-to-date examples (http, tcp, custom_compose)

playbook_name: http                   # 'http' (single container behind Traefik, HTTPS subdomain), 'tcp' (published ports), or 'custom_compose' (see below)
deploy_parameters:
  image: nginx:alpine                 # Docker image to deploy ('http' and 'tcp' playbooks)
  unique: false                       # Set to true if there needs to be a unique instance for all players
  http_port: 80                       # Container port Traefik forwards to (Only for 'http' playbooks, default: 80)
  published_ports:                    # Ports to expose from the container (Only for 'tcp' playbooks)
    - 1337                            # Random host port per team; "22/ssh" adds a URL scheme hint, "8080:80/http" is a fixed mapping
  env:                                # Environment variables passed to the container
    FLAG: "flag{flag_to_find_in_env}"
    TZ: Europe/Zurich
  resource_limits:                    # Override default resource limits (optional)
    cpus: "1"
    memory: "512M"
    pids_limit: 256
```

### Multi-service challenges (Docker Compose)

For challenges that need several containers, put a standard Compose file (`compose.yaml`, `compose.yml`, `docker-compose.yaml` or `docker-compose.yml`) next to `challenge.yml`. Galvanize detects it and defaults `playbook_name` to `custom_compose`. Declare which services players reach with an `expose` block instead of hand-writing Traefik labels, networks or host ports:

```yaml
type: zync
deploy_parameters:
  unique: false
  expose:
    - service: web      # routed through Traefik -> https://<instance>.<domain>/
      port: 80
      type: http
    - service: ssh      # published on a random host port per team
      port: 22
      type: tcp
      scheme: ssh       # optional, only changes the displayed connection URL
```

Notes:

- `challenges.sh` builds every service that has a `build:` key and, if it has no `image:`, tags it `<challenge>_<service>:latest` in the compose file so Galvanize can deploy the locally built image. With a remote instancer nothing is built: give each `build:` service a tagged `image:` that the instancer's Docker host can pull (ingestion rejects built services without one).
- Do not set `container_name` or publish `ports:` yourself: Galvanize names each project per team and wires the networking from `expose`.
- `build:` contexts and bind mounts are resolved on the deploy host, so prefer pre-built images.

## Generated Configuration

The setup script automatically generates:
- **CTFd secret key** (32 characters)
- **Database password** (16 characters)
- **Database root password** (16 characters)
- **Galvanize JWT secret** (48 characters)

All secrets are written to `<deploy-dir>/.secrets` (chmod 600) and to `.env`.

DNS provider credentials (for wildcard TLS certificates) are written to `<deploy-dir>/traefik.env` (chmod 600) instead. It is the only env file passed to the Traefik container, so Traefik never sees the database passwords, CTFd's `SECRET_KEY` or the Zync JWT secret. Deployments made before this change kept their DNS credentials in `.env`: re-running `setup.sh` copies them to `traefik.env`, after which they can be removed from `.env`.

> **Re-running setup is safe**: if secrets already exist in `.env`, they are preserved. Only missing secrets are generated, so running `setup.sh` again will not break existing containers.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

These scripts were initially developed for the PolyCyber team to automate the installation and management of CTFd servers. They were built to work specifically with the [Galvanize](https://github.com/28Pollux28/galvanize) instancer and [Zync](https://github.com/28Pollux28/zync) plugin.
