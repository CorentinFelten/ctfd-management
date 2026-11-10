#!/usr/bin/env python3
"""Attach challenge files listed by ctfd_sync.py, from inside the CTFd container.

Runs CTFd's own upload_file(), so files land in CTFd's upload storage
exactly as an admin upload would, without going through the HTTP API (no
request size limit, no reverse proxy). Files already attached to a challenge
(same file name) are skipped.

  docker cp <challenge-repo> ctfd:/tmp/chall-files
  docker cp upload-manifest.json ctfd:/tmp/upload-manifest.json
  docker cp ctfd_upload_inside.py ctfd:/tmp/ctfd_upload_inside.py
  docker exec -w /opt/CTFd ctfd python /tmp/ctfd_upload_inside.py

Environment: CHALL_FILES_ROOT (default /tmp/chall-files),
MANIFEST_PATH (default /tmp/upload-manifest.json).
"""
import json
import os
from pathlib import Path

from werkzeug.datastructures import FileStorage

from CTFd import create_app
from CTFd.models import Challenges
from CTFd.utils.uploads import upload_file

ROOT = Path(os.environ.get("CHALL_FILES_ROOT", "/tmp/chall-files"))
MANIFEST = Path(os.environ.get("MANIFEST_PATH", "/tmp/upload-manifest.json"))


def main():
    items = json.loads(MANIFEST.read_text())
    app = create_app()
    with app.app_context():
        for item in items:
            chal = Challenges.query.filter_by(name=item["name"]).first()
            if not chal:
                print("no challenge", item["name"])
                continue
            have = {Path(f.location).name for f in (chal.files or [])}
            for rel_file in item["files"]:
                path = ROOT / item["rel"] / rel_file
                if not path.is_file():
                    print("missing", item["rel"], rel_file)
                    continue
                if path.name in have:
                    print("have", item["name"], path.name)
                    continue
                with path.open("rb") as fh:
                    fs = FileStorage(stream=fh, filename=path.name)
                    upload_file(file=fs, challenge=chal.id, type="challenge")
                print("uploaded", item["name"], path.name)


if __name__ == "__main__":
    main()
