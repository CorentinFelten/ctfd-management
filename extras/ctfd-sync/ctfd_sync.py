#!/usr/bin/env python3
"""Sync a challenge repository into CTFd through its admin API.

For every challenge.yml / challenge-*.yml under CHALLENGE_DIR (directories
named "example" are skipped), create or update the CTFd challenge (matched by
name), then add missing flags, hints and tags, delete tags no longer listed,
and set prerequisites from `requirements` (by challenge name). Challenges
with `type: zync` stay zync (Galvanize instances); anything else is created
as `standard`.

Bilingual fields are supported: `description: {fr: ..., en: ...}` and hints
with `{fr, en}` content are merged into one text.

Challenge files are not uploaded here. A manifest of the files to attach is
written to MANIFEST_PATH; upload them with ctfd_upload_inside.py.

Configuration (environment):
  CTFD_URL            Base URL to reach CTFd (default: http://127.0.0.1)
  CTFD_HOST           Host header to send, when CTFD_URL is Traefik on the
                      same machine (e.g. ctf.example.com). Optional.
  CTFD_ADMIN_NAME     Admin user name (default: admin)
  CTFD_ADMIN_PASSWORD Admin password (required)
  CHALLENGE_DIR       Challenge repository root (required, or first argument)
  MANIFEST_PATH       Where to write the file manifest
                      (default: ./upload-manifest.json)
  CTFD_CONFIGS_JSON   Optional JSON file PATCHed to /api/v1/configs first
                      (ctf_name, user_mode, start, end, ...)
"""
import http.cookiejar
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import yaml

BASE = os.environ.get("CTFD_URL", "http://127.0.0.1").rstrip("/")
HOST = os.environ.get("CTFD_HOST", "").strip()
ADMIN_NAME = os.environ.get("CTFD_ADMIN_NAME", "admin")
ADMIN_PASSWORD = os.environ.get("CTFD_ADMIN_PASSWORD", "")
_CHALL_ROOT_ARG = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("CHALLENGE_DIR", "")
CHALL_ROOT = Path(_CHALL_ROOT_ARG)
MANIFEST_PATH = Path(os.environ.get("MANIFEST_PATH", "upload-manifest.json"))
CONFIGS_JSON = os.environ.get("CTFD_CONFIGS_JSON", "").strip()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def make_opener():
    cj = http.cookiejar.CookieJar()
    return urllib.request.build_opener(NoRedirect, urllib.request.HTTPCookieProcessor(cj)), cj


def req(opener, method, path, data=None, headers=None, json_body=None):
    h = {"User-Agent": "ctfd-sync"}
    if HOST:
        h["Host"] = HOST
    if headers:
        h.update(headers)
    body = None
    if json_body is not None:
        body = json.dumps(json_body).encode()
        h["Content-Type"] = "application/json"
    elif data is not None:
        body = urllib.parse.urlencode(data).encode()
        h["Content-Type"] = "application/x-www-form-urlencoded"
    r = urllib.request.Request(BASE + path, data=body, headers=h, method=method)
    try:
        with opener.open(r, timeout=60) as resp:
            return resp.getcode(), resp.read().decode("utf-8", "replace"), resp.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace"), e.headers


def login():
    opener, _cj = make_opener()
    code, html, _ = req(opener, "GET", "/login")
    nonce = re.search(r'name="nonce"[^>]*value="([^"]+)"', html)
    if not nonce:
        raise SystemExit("login nonce missing")
    code, body, _ = req(
        opener,
        "POST",
        "/login",
        data={"nonce": nonce.group(1), "name": ADMIN_NAME, "password": ADMIN_PASSWORD},
    )
    print("login", code)
    if code not in (200, 302, 303):
        raise SystemExit("login failed")
    code, html, _ = req(opener, "GET", "/admin/config")
    csrf = re.search(r"'csrfNonce':\s*\"([^\"]+)\"", html)
    if not csrf:
        raise SystemExit(f"csrf missing after admin config {code}")
    return opener, csrf.group(1)


def api(opener, token, method, path, json_body=None):
    return req(opener, method, path, headers={"CSRF-Token": token}, json_body=json_body)


def first_flag(raw):
    if raw is None:
        return None
    if isinstance(raw, str):
        return raw
    if isinstance(raw, dict):
        return raw.get("content") or raw.get("flag")
    return None


def tag_value(raw):
    if raw is None:
        return None
    if isinstance(raw, str):
        value = raw.strip()
        return value or None
    if isinstance(raw, dict):
        value = raw.get("value") or raw.get("tag") or raw.get("name")
        if value is None:
            return None
        value = str(value).strip()
        return value or None
    value = str(raw).strip()
    return value or None


def hint_content(raw):
    if raw is None:
        return None
    if isinstance(raw, str):
        value = raw.strip()
        return value or None
    if isinstance(raw, dict):
        if "content" in raw and not any(k in raw for k in ("fr", "en")):
            return hint_content(raw.get("content"))
        fr = (raw.get("fr") or "").strip()
        en = (raw.get("en") or "").strip()
        if fr and en:
            return f"{fr}\n\n{en}"
        return en or fr or None
    value = str(raw).strip()
    return value or None


def parse_hints(raw_list):
    out = []
    for item in raw_list or []:
        if isinstance(item, str):
            content = item.strip()
            if content:
                out.append({"content": content, "cost": 0})
            continue
        if not isinstance(item, dict):
            continue
        content = hint_content(item.get("content", item))
        if not content:
            continue
        try:
            cost = int(item.get("cost") or 0)
        except (TypeError, ValueError):
            cost = 0
        out.append({"content": content, "cost": cost})
    return out


def description_text(desc):
    if desc is None:
        return ""
    if isinstance(desc, str):
        return desc
    if isinstance(desc, dict):
        fr = (desc.get("fr") or "").strip()
        en = (desc.get("en") or "").strip()
        if fr and en:
            return f"## Description (français)\n\n{fr}\n\n## Description (english)\n\n{en}"
        return en or fr or next(iter(desc.values()), "")
    return str(desc)


def resolve_files(chal_dir, files):
    out = []
    for f in files or []:
        if isinstance(f, str):
            p = chal_dir / f
            if p.is_file():
                out.append(str(Path(f)))
                continue
            hits = list(chal_dir.rglob(Path(f).name))
            if hits:
                out.append(str(hits[0].relative_to(chal_dir)))
            continue
        if isinstance(f, dict):
            name = f.get("name") or f.get("path") or f.get("file")
            if not name:
                continue
            p = chal_dir / name
            if p.is_file():
                out.append(name)
                continue
            hits = [h for h in chal_dir.rglob(Path(name).name) if "solution" not in h.parts]
            if hits:
                out.append(str(hits[0].relative_to(chal_dir)))
    return out


def is_challenge_file(path):
    name = path.name
    if name in ("challenge.yml", "challenge.yaml"):
        return True
    return name.startswith("challenge-") and name.endswith((".yml", ".yaml"))


def load_all():
    specs = []
    ymls = [p for p in CHALL_ROOT.rglob("challenge*.y*ml") if is_challenge_file(p)]
    for yml in sorted(ymls):
        if "example" in yml.parts:
            continue
        data = yaml.safe_load(yml.read_text()) or {}
        name = data.get("name")
        cat = data.get("category")
        if not name or not cat:
            print("skip incomplete", yml)
            continue
        flags = []
        for f in data.get("flags") or []:
            content = first_flag(f)
            if content:
                flags.append(content)
        chal_type = data.get("type")
        if chal_type != "zync":
            chal_type = "standard"
        rel = str(yml.parent.relative_to(CHALL_ROOT))
        specs.append(
            {
                "rel": rel,
                "name": name,
                "category": str(cat).lower(),
                "description": description_text(data.get("description")),
                "value": int(data.get("value") or 100),
                "type": chal_type,
                "state": "visible",
                "flags": flags,
                "tags": [t for t in (tag_value(x) for x in (data.get("tags") or [])) if t],
                "hints": parse_hints(data.get("hints") or []),
                "requirements": [str(r) for r in (data.get("requirements") or [])],
                "files": resolve_files(yml.parent, data.get("files") or []),
            }
        )
    return specs


def main():
    if not ADMIN_PASSWORD:
        raise SystemExit("CTFD_ADMIN_PASSWORD is required")
    if not _CHALL_ROOT_ARG or not CHALL_ROOT.is_dir():
        raise SystemExit("set CHALLENGE_DIR (or pass it as first argument) to the challenge repository")
    opener, token = login()
    if CONFIGS_JSON:
        configs = json.loads(Path(CONFIGS_JSON).read_text())
        code, body, _ = api(opener, token, "PATCH", "/api/v1/configs", configs)
        print("configs PATCH", code)

    code, body, _ = api(opener, token, "GET", "/api/v1/challenges?view=admin")
    existing = json.loads(body).get("data") or []
    by_name = {c.get("name"): c for c in existing}
    print("existing", len(existing))

    specs = load_all()
    print("repo", len(specs))
    for spec in specs:
        payload = {k: spec[k] for k in ("name", "category", "description", "value", "type", "state")}
        found = by_name.get(spec["name"])
        cid = None
        if found:
            cid = found["id"]
            code, body, _ = api(opener, token, "PATCH", f"/api/v1/challenges/{cid}", payload)
            print("update", spec["type"], spec["category"], spec["name"], cid, code)
        else:
            code, body, _ = api(opener, token, "POST", "/api/v1/challenges", payload)
            print("create", spec["type"], spec["category"], spec["name"], code)
            try:
                cid = json.loads(body)["data"]["id"]
            except Exception:
                print("  fail", body[:300])
                continue
            by_name[spec["name"]] = {"id": cid, "name": spec["name"]}

        if spec["flags"] and cid:
            code, fbody, _ = api(opener, token, "GET", f"/api/v1/flags?challenge_id={cid}")
            have = []
            try:
                have = [f.get("content") for f in (json.loads(fbody).get("data") or [])]
            except Exception:
                pass
            for flag in spec["flags"]:
                if flag in have:
                    continue
                code, body, _ = api(
                    opener,
                    token,
                    "POST",
                    "/api/v1/flags",
                    {"challenge_id": cid, "type": "static", "content": flag, "data": ""},
                )
                print("  flag", code, flag[:20])

        if cid:
            code, tbody, _ = api(opener, token, "GET", f"/api/v1/tags?challenge_id={cid}")
            have = []
            try:
                have = json.loads(tbody).get("data") or []
            except Exception:
                have = []
            have_by_value = {}
            for tag in have:
                value = tag.get("value")
                if value and tag.get("id") and value not in have_by_value:
                    have_by_value[value] = tag["id"]
            wanted = spec.get("tags") or []
            for tag in wanted:
                if tag in have_by_value:
                    continue
                code, body, _ = api(
                    opener,
                    token,
                    "POST",
                    "/api/v1/tags",
                    {"challenge_id": cid, "value": tag},
                )
                print("  tag", code, tag)
            wanted_set = set(wanted)
            for value, tid in have_by_value.items():
                if value in wanted_set:
                    continue
                code, body, _ = api(opener, token, "DELETE", f"/api/v1/tags/{tid}")
                print("  tag del", code, value)

        if cid:
            code, hbody, _ = api(opener, token, "GET", f"/api/v1/hints?challenge_id={cid}")
            have_hints = []
            try:
                have_hints = json.loads(hbody).get("data") or []
            except Exception:
                have_hints = []
            have_contents = {h.get("content") for h in have_hints if h.get("content")}
            for hint in spec.get("hints") or []:
                if hint["content"] in have_contents:
                    continue
                code, body, _ = api(
                    opener,
                    token,
                    "POST",
                    "/api/v1/hints",
                    {
                        "challenge_id": cid,
                        "content": hint["content"],
                        "cost": hint["cost"],
                        "type": "standard",
                    },
                )
                print("  hint", code, hint["cost"], hint["content"][:40])

    name_to_id = {n: c.get("id") for n, c in by_name.items()}
    for spec in specs:
        cid = name_to_id.get(spec["name"])
        if not cid or not spec["requirements"]:
            continue
        prereq = [name_to_id[r] for r in spec["requirements"] if r in name_to_id]
        if prereq:
            code, body, _ = api(
                opener,
                token,
                "PATCH",
                f"/api/v1/challenges/{cid}",
                {"requirements": {"prerequisites": prereq}},
            )
            print("requirements", spec["name"], prereq, code)

    manifest = [{"rel": s["rel"], "name": s["name"], "files": s["files"]} for s in specs if s["files"]]
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2))
    print("manifest", MANIFEST_PATH, len(manifest), "with files")


if __name__ == "__main__":
    main()
