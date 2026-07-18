import hashlib
import json
import os
import re
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path


CANDIDATE_ID = re.compile(r"^[a-f0-9-]{36}$")
STORE_PATH = re.compile(r"^/nix/store/[a-z0-9]{32}-[A-Za-z0-9+._?=-]+$")


class NixClawError(Exception):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def candidate_id(value):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "nixclaw:" + canonical(value)))


def generation_id(path):
    return "nixos-" + hashlib.sha256(path.encode()).hexdigest()[:20]


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def require_uuid(value, name="ID"):
    try:
        return str(uuid.UUID(value))
    except (ValueError, TypeError, AttributeError):
        raise NixClawError(f"{name} must be a UUID") from None


def load_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def atomic_json(path, value, mode=0o640):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, sort_keys=True, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def append_audit(path, event):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    line = canonical(event) + "\n"
    descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o640)
    try:
        os.write(descriptor, line.encode())
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def require_fields(value, required, optional=()):
    if not isinstance(value, dict):
        raise NixClawError("request body must be a JSON object")
    required, optional = set(required), set(optional)
    missing = required - value.keys()
    unknown = value.keys() - required - optional
    if missing:
        raise NixClawError(f"missing fields: {', '.join(sorted(missing))}")
    if unknown:
        raise NixClawError(f"unknown fields: {', '.join(sorted(unknown))}")


def validate_candidate_id(value):
    return require_uuid(value, "candidate ID")


def validate_store_path(value):
    if not isinstance(value, str) or not STORE_PATH.fullmatch(value):
        raise NixClawError("candidate generation is not a direct Nix store path")
    resolved = os.path.realpath(value)
    if resolved != value or not os.path.isdir(value):
        raise NixClawError("candidate generation does not exist or is a symlink")
    switch = Path(value) / "bin/switch-to-configuration"
    if not switch.is_file():
        raise NixClawError("candidate is not a NixOS generation")
    return value
