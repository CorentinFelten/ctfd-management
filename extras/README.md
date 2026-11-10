# Extras

Optional tools used to run UnitedCTF 2026 on this stack (CTFd + Zync + Galvanize). None of them is installed by `setup.sh`; each one is opt-in.

In the steps below, `deploy/` means `<working-folder>/deploy`, the folder `setup.sh` creates and runs Docker Compose from. Running `setup.sh` again replaces `deploy/docker-compose.yml`; the previous version is backed up next to it, so re-apply your edits afterwards.

| Folder | What it does |
|---|---|
| [`real_ip/`](#real_ip-ctfd-plugin) | CTFd plugin: record the player's real IP when CTFd is behind Cloudflare |
| [`solve-bot/`](#solve-bot) | Posts every solve to Discord, with first bloods, skipping staff |
| [`ctfd-sync/`](#ctfd-sync) | Python sync of a challenge repository into CTFd (challenges, flags, hints, tags, prerequisites, files) |

---

## `real_ip` CTFd plugin

With Cloudflare proxying the CTFd domain (orange cloud), the IP that reaches the server is a Cloudflare edge. CTFd's `get_ip()` skips the addresses listed in `TRUSTED_PROXIES`, which by default covers only private ranges. As a result, **Admin → Tracking**, the access logs and the IP-based rate limits all record Cloudflare addresses (`172.69.*`, `162.158.*`, `108.162.*`, …) instead of the players' IPs.

The plugin adds Cloudflare's published IP ranges to `TRUSTED_PROXIES` when CTFd starts. Its list was last synced with <https://www.cloudflare.com/ips/> in October 2026; keep it up to date.

**This only works together with Traefik.** Traefik must trust the same ranges, otherwise it replaces `X-Forwarded-For` with the Cloudflare edge address before CTFd ever sees it. Do **not** use `forwardedHeaders.insecure: true`: the origin is reachable directly, so anyone could then forge their IP.

1. Copy the plugin next to Zync and mount it into CTFd the same way (`deploy/docker-compose.yml`, `ctfd` service):
   ```bash
   cp -r extras/real_ip deploy/ctfd/plugins/real_ip
   ```
   ```yaml
   volumes:
     - ./ctfd/plugins/real_ip:/opt/CTFd/CTFd/plugins/real_ip:ro
   ```
2. Trust Cloudflare in Traefik (`deploy/traefik-config/traefik.yml`), on both `web` and `websecure`:
   ```yaml
   entryPoints:
     websecure:
       forwardedHeaders:
         trustedIPs:
           - 173.245.48.0/20
           - 103.21.244.0/22
           # ... every range from https://www.cloudflare.com/ips-v4 and /ips-v6
   ```
3. Optional: so that gunicorn's access log also shows the client, set the number of proxy hops, e.g. `REVERSE_PROXY=2,1,1,1,1` (Cloudflare → Traefik → CTFd) instead of `true`.

Only enable this when CTFd really sits behind Cloudflare. Without Cloudflare in front, a request coming from a Cloudflare IP (a Worker, for instance) could set any `X-Forwarded-For` it likes.

---

## Solve bot

Posts every correct submission to a Discord channel, in French and English:

> 🩸 **FIRST BLOOD** — **alice** a résolu / solved **Baby Pwn**
> 🎉 Bravo ! Tu es le premier à résoudre ce défi. / Congrats! You're the first to solve this challenge.
>
> ✅ **bob** a résolu / solved **Baby Pwn**
> 🎉 Bravo ! Tu es le 2e à résoudre ce défi. / Congrats! You're the 2nd to solve this challenge.

- **Staff are never announced or counted.** That covers admins, hidden users, and names listed in `SKIP_USERS`. CTFd's API returns 404 for hidden and admin users, and the bot treats a 404 as staff, so a staff test solve can't take first blood.
- **Restarts don't repeat announcements.** The last seen submission id and each challenge's solve count are saved in `STATE_PATH`. On its very first start, the bot catches up on existing solves without posting them.
- **Discord setup:** use either a webhook (`DISCORD_WEBHOOK_URL`) or a bot token plus a channel id. The bot always sends a `User-Agent` header; Discord rejects requests made with Python's default one.

Copy it with `cp -r extras/solve-bot deploy/solve-bot` and add it to `deploy/docker-compose.yml`:

```yaml
  solve-bot:
    build: ./solve-bot
    container_name: solve-bot
    restart: unless-stopped
    environment:
      CTFD_URL: http://ctfd:8000
      CTFD_TOKEN: ${CTFD_TOKEN:?admin API token}      # Settings → Access Tokens, as an admin
      DISCORD_WEBHOOK_URL: ${DISCORD_WEBHOOK_URL:-}
      # or: DISCORD_BOT_TOKEN / DISCORD_CHANNEL_ID
      BOT_USERNAME: "My CTF Solves"
      SKIP_USERS: admin                                # comma-separated, case-insensitive
      SKIP_CHALLENGES: ""                              # e.g. a "Rules" flag
      POLL_SECONDS: "8"
      STATE_PATH: /data/state.json
    volumes:
      - solvebot_state:/data
    networks:
      - internal
```

Add `solvebot_state:` under `volumes:`, and make sure the `internal` network can reach `ctfd`. Start it with `docker compose up -d --no-deps --build solve-bot`. The `--no-deps` flag matters: without it, Compose can rebuild and recreate CTFd at the same time.

If you wipe the scoreboard, or add a hidden admin who has already solved challenges, stop the bot, delete its state volume and start it again so the counts are rebuilt.

---

## ctfd-sync

`ctfd_sync.py` reads a challenge repository and brings CTFd in line with it through the admin API. You can run it as many times as you like; each run only adds what's missing.

- **What it reads:** every `challenge.yml` and numbered `challenge-*.yml` under the repository (so one folder can hold several parts). Folders named `example` are skipped.
- **Challenges:** matched by **name**. A challenge already in CTFd is updated (description, value, category, type, state); a new one is created.
- **Challenge type:** `type: zync` challenges stay `zync`, so they get Galvanize instances. Everything else becomes `standard`.
- **Category:** stored in lowercase. Galvanize matches categories case-insensitively.
- **Flags, hints and tags:** missing ones are added. Tags no longer listed in the YAML are removed, but on some CTFd versions the API refuses tag deletion with 403. If so, remove them in the admin panel.
- **Bilingual text:** `description: {fr: ..., en: ...}` is turned into two headed sections, and bilingual hints are merged into one text.
- **Prerequisites:** `requirements: [<challenge name>, ...]` becomes CTFd prerequisites.
- **Files:** not uploaded by this script. It writes the list of files to attach to `upload-manifest.json`, for `ctfd_upload_inside.py`.

```bash
pip install pyyaml
export CTFD_URL=http://127.0.0.1 CTFD_HOST=ctf.example.com   # through the local Traefik
export CTFD_ADMIN_NAME=admin CTFD_ADMIN_PASSWORD='...'
export CTFD_CONFIGS_JSON=event.json                          # optional, see below
python3 extras/ctfd-sync/ctfd_sync.py /path/to/challenges
```

`event.json` is optional. It is sent to `PATCH /api/v1/configs` before anything else:

```json
{ "ctf_name": "My CTF", "user_mode": "users", "ctf_theme": "core-beta",
  "start": "1791583200", "end": "1792101600", "verify_emails": false }
```

Then attach the challenge files from inside the CTFd container. This uses CTFd's own upload code, so there's no request size limit and no reverse proxy in the way:

```bash
docker cp /path/to/challenges ctfd:/tmp/chall-files
docker cp upload-manifest.json ctfd:/tmp/upload-manifest.json
docker cp extras/ctfd-sync/ctfd_upload_inside.py ctfd:/tmp/
docker exec -w /opt/CTFd ctfd python /tmp/ctfd_upload_inside.py
```

Files that are already attached (same file name) are skipped. When `ctfd_sync.py` builds the manifest, a file listed in the YAML that isn't at its stated path is looked up by name anywhere in the challenge folder. For `{name: ...}` entries, files inside a `solution` folder are ignored.

> The challenge `name` and `category` in CTFd must match the Galvanize `challenge.yml` (category ignoring case). Otherwise the Zync spawn button returns 400 "Invalid challenge".
