#!/usr/bin/env python3
"""Announce CTFd solves on Discord, with first bloods.

Polls /api/v1/submissions?type=correct and posts every new solve to a
Discord webhook (or a channel through a bot token) with its rank on that
challenge. Admins, hidden users and SKIP_USERS are never announced nor
counted, so a staff test solve does not steal first blood. The last seen
submission id and per-challenge solve counts are kept in STATE_PATH, so
restarts do not re-announce; on first start it catches up silently.
"""
import json
import logging
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("solve-bot")

CTFD_URL = os.environ.get("CTFD_URL", "http://ctfd:8000").rstrip("/")
CTFD_TOKEN = os.environ.get("CTFD_TOKEN", "").strip()
DISCORD_WEBHOOK_URL = os.environ.get("DISCORD_WEBHOOK_URL", "").strip()
DISCORD_BOT_TOKEN = os.environ.get("DISCORD_BOT_TOKEN", "").strip()
DISCORD_CHANNEL_ID = os.environ.get("DISCORD_CHANNEL_ID", "").strip()
POLL_SECONDS = max(3, int(os.environ.get("POLL_SECONDS", "8")))
STATE_PATH = Path(os.environ.get("STATE_PATH", "/data/state.json"))
SKIP_USERS = {
    name.strip().lower()
    for name in os.environ.get("SKIP_USERS", "admin").split(",")
    if name.strip()
}
BOT_USERNAME = os.environ.get("BOT_USERNAME", "CTF Solves").strip() or "CTF Solves"
SKIP_CHALLENGES = {
    name.strip().lower()
    for name in os.environ.get("SKIP_CHALLENGES", "").split(",")
    if name.strip()
}


def ctfd(path):
    req = urllib.request.Request(
        CTFD_URL + path,
        headers={
            "Authorization": f"Token {CTFD_TOKEN}",
            "Content-Type": "application/json",
            "User-Agent": "ctfd-solve-bot/1.0",
        },
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        raise RuntimeError(f"CTFd {e.code} {path}: {body[:300]}") from e


def fetch_page(page, per_page=100):
    qs = urllib.parse.urlencode(
        {"type": "correct", "per_page": per_page, "page": page}
    )
    data = ctfd(f"/api/v1/submissions?{qs}")
    if not data.get("success", True):
        raise RuntimeError(f"CTFd submissions error: {data}")
    return data


def fetch_since(last_id):
    first = fetch_page(1, per_page=100)
    pages = int(((first.get("meta") or {}).get("pagination") or {}).get("pages") or 1)
    found = []
    for page in range(pages, 0, -1):
        payload = first if page == 1 else fetch_page(page, per_page=100)
        rows = payload.get("data") or []
        newer = [row for row in rows if int(row.get("id") or 0) > last_id]
        found = newer + found
        if rows and min(int(row.get("id") or 0) for row in rows) <= last_id:
            break
    return found


def load_state():
    if not STATE_PATH.is_file():
        return None
    try:
        return json.loads(STATE_PATH.read_text())
    except Exception:
        return None


def save_state(state):
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2))
    tmp.replace(STATE_PATH)


def discord_ready():
    if DISCORD_WEBHOOK_URL:
        return True
    return bool(DISCORD_BOT_TOKEN and DISCORD_CHANNEL_ID)


def post_discord(payload):
    if DISCORD_WEBHOOK_URL:
        url = DISCORD_WEBHOOK_URL
        headers = {
            "Content-Type": "application/json",
            "User-Agent": "ctfd-solve-bot/1.0",
        }
    else:
        url = f"https://discord.com/api/v10/channels/{DISCORD_CHANNEL_ID}/messages"
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bot {DISCORD_BOT_TOKEN}",
            "User-Agent": "ctfd-solve-bot/1.0",
        }
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp.read()
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        raise RuntimeError(f"Discord {e.code}: {body[:300]}") from e


def en_ordinal(n):
    if 10 <= n % 100 <= 20:
        suffix = "th"
    else:
        suffix = {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
    return f"{n}{suffix}"


def fr_ordinal(n):
    if n == 1:
        return "1er"
    return f"{n}e"


def announce(row, rank):
    user = ((row.get("user") or {}).get("name") or f"user#{row.get('user_id')}").strip()
    chal = row.get("challenge") or {}
    name = (chal.get("name") or f"challenge#{row.get('challenge_id')}").strip()
    first_blood = rank == 1

    if first_blood:
        content = (
            f"🩸 **FIRST BLOOD** — **{user}** a résolu / solved **{name}**\n"
            f"🎉 Bravo ! Tu es le premier à résoudre ce défi. / Congrats! You're the first to solve this challenge."
        )
    else:
        content = (
            f"✅ **{user}** a résolu / solved **{name}**\n"
            f"🎉 Bravo ! Tu es le {fr_ordinal(rank)} à résoudre ce défi. / Congrats! You're the {en_ordinal(rank)} to solve this challenge."
        )

    post_discord(
        {
            "username": BOT_USERNAME,
            "content": content,
            "allowed_mentions": {"parse": []},
        }
    )
    log.info("posted id=%s user=%s challenge=%s rank=%s", row.get("id"), user, name, rank)


_staff_cache = {}
_STAFF_TTL = 60


def user_is_staff(uid, name=""):
    name = (name or "").strip().lower()
    if name in SKIP_USERS:
        return True
    if uid is None:
        return False
    uid = int(uid)
    now = time.time()
    cached = _staff_cache.get(uid)
    if cached and cached[1] > now:
        return cached[0]
    staff = False
    try:
        detail = (ctfd(f"/api/v1/users/{uid}?view=admin").get("data") or {})
        staff = detail.get("type") == "admin" or bool(detail.get("hidden"))
        if (detail.get("name") or "").strip().lower() in SKIP_USERS:
            staff = True
    except RuntimeError as exc:
        # Hidden/admin users 404 on /api/v1/users/<id> even with view=admin.
        if " 404 " in str(exc):
            staff = True
        else:
            log.warning("user lookup failed uid=%s: %s", uid, exc)
    _staff_cache[uid] = (staff, now + _STAFF_TTL)
    return staff


def is_staff(row):
    name = ((row.get("user") or {}).get("name") or "").strip().lower()
    return user_is_staff(row.get("user_id"), name)


def should_skip(row):
    if is_staff(row):
        return True
    name = ((row.get("challenge") or {}).get("name") or "").strip().lower()
    return name in SKIP_CHALLENGES


def bootstrap():
    first = fetch_page(1, per_page=100)
    pages = int(((first.get("meta") or {}).get("pagination") or {}).get("pages") or 1)
    last_id = 0
    counts = {}
    for page in range(1, pages + 1):
        payload = first if page == 1 else fetch_page(page, per_page=100)
        for row in payload.get("data") or []:
            last_id = max(last_id, int(row.get("id") or 0))
            cid = row.get("challenge_id")
            if cid is None or is_staff(row):
                continue
            key = str(cid)
            counts[key] = counts.get(key, 0) + 1
    state = {"last_id": last_id, "solve_counts": counts}
    save_state(state)
    log.info("catch-up complete last_id=%s challenges=%s", last_id, len(counts))
    return state


def wait_for_ctfd():
    while True:
        try:
            fetch_page(1, per_page=1)
            return
        except Exception as exc:
            log.warning("waiting for CTFd: %s", exc)
            time.sleep(5)


def main():
    if not CTFD_TOKEN:
        raise SystemExit("CTFD_TOKEN is required")
    if not discord_ready():
        log.warning("Discord is not configured yet; set DISCORD_WEBHOOK_URL or DISCORD_BOT_TOKEN+DISCORD_CHANNEL_ID")
    wait_for_ctfd()
    state = load_state()
    if state is None:
        state = bootstrap()
    last_id = int(state.get("last_id") or 0)
    counts = {str(k): int(v) for k, v in (state.get("solve_counts") or {}).items()}
    if not counts:
        state = bootstrap()
        last_id = int(state.get("last_id") or 0)
        counts = {str(k): int(v) for k, v in (state.get("solve_counts") or {}).items()}
    log.info("watching CTFd solves from id > %s", last_id)
    while True:
        if not discord_ready():
            time.sleep(POLL_SECONDS)
            continue
        try:
            rows = fetch_since(last_id)
        except Exception:
            log.exception("failed to poll CTFd")
            time.sleep(POLL_SECONDS)
            continue
        for row in rows:
            sid = int(row.get("id") or 0)
            last_id = max(last_id, sid)
            cid = row.get("challenge_id")
            rank = 0
            if should_skip(row):
                log.info("skipped id=%s", sid)
                continue
            if cid is not None:
                key = str(cid)
                counts[key] = counts.get(key, 0) + 1
                rank = counts[key]
            try:
                announce(row, rank)
                time.sleep(0.6)
            except Exception:
                log.exception("failed to post solve id=%s", sid)
        state = {"last_id": last_id, "solve_counts": counts}
        save_state(state)
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
