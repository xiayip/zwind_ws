#!/usr/bin/env python3
"""Merge enrollment credentials into the host Docker env file without printing secrets."""

import argparse
import os
from pathlib import Path
import re
import shlex
import stat
import tempfile
import urllib.parse


FIELDS = ("ROBOT_ID", "ROBOT_API_KEY", "ROBOT_BACKEND_URL")


def read_credentials(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o077:
        raise ValueError("credential source must be a regular private file (mode 600)")
    values = {}
    for line in path.read_text().splitlines():
        line = line.strip().removeprefix("export ")
        if not line or line.startswith("#"):
            continue
        name, sep, value = line.partition("=")
        if not sep or name.strip() not in FIELDS:
            raise ValueError("credential source contains an unexpected variable")
        name = name.strip()
        if name in values:
            raise ValueError("credential source contains a duplicate variable")
        words = shlex.split(value)
        if len(words) != 1:
            raise ValueError("invalid credential value")
        values[name] = words[0]
    if set(values) != set(FIELDS):
        raise ValueError("credential source must contain all three robot variables")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", values["ROBOT_ID"]):
        raise ValueError("invalid robot ID")
    if not re.fullmatch(r"zrk1\.[a-f0-9]{32}\.[A-Za-z0-9_-]{43}", values["ROBOT_API_KEY"]):
        raise ValueError("expected an independent robot API key")
    url = urllib.parse.urlsplit(values["ROBOT_BACKEND_URL"])
    if (url.scheme != "https" or not url.hostname or url.username or url.password
            or url.query or url.fragment or any(c.isspace() for c in values["ROBOT_BACKEND_URL"])):
        raise ValueError("backend URL must be HTTPS without credentials, query or fragment")
    return values


def install_credentials(source, target, reader_gid, owner_uid=0):
    values = read_credentials(source)
    if target.is_symlink():
        raise ValueError("refusing to replace a symlink")
    if target.exists() and not target.is_file():
        raise ValueError("target must be a regular file")
    lines = target.read_text().splitlines() if target.exists() else []
    kept = []
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            kept.append(line)
            continue
        name, sep, _ = line.partition("=")
        if not sep or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
            raise ValueError("host config must use Docker KEY=value format, without export")
        if name not in FIELDS:
            kept.append(line)
    # Docker --env-file treats quotes and 'export' literally; values here are
    # validated simple strings, so emit unquoted KEY=value lines.
    content = "\n".join(kept + [f"{name}={values[name]}" for name in FIELDS]) + "\n"
    target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".robot.env.", dir=target.parent)
    try:
        with os.fdopen(descriptor, "w") as output:
            os.fchown(output.fileno(), owner_uid, reader_gid)
            os.fchmod(output.fileno(), 0o640)
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, target)
        directory = os.open(target.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--credentials", type=Path, required=True)
    parser.add_argument("--reader-gid", type=int, required=True,
                        help="Host group ID of the operator who launches Docker")
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("run this installer as root")
    if args.reader_gid < 0:
        parser.error("reader group ID must be nonnegative")
    try:
        install_credentials(args.credentials, Path("/etc/zephyr/robot.env"), args.reader_gid)
    except (OSError, ValueError):
        raise SystemExit("Credential install failed; check file permissions, format and paths.") from None
    print("Installed /etc/zephyr/robot.env (root:reader-group, 640); other device settings preserved.")


if __name__ == "__main__":
    main()
