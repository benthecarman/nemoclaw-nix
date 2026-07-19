import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import uuid
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path, PurePosixPath

from .common import (
    NixClawError, append_audit, atomic_json, candidate_id, canonical,
    generation_id, load_json, now, require_fields, require_uuid,
)


PROFILE_SPECS = {
    "gpuMemoryUtilization": {"type": "number", "minimumExclusive": 0.0, "maximum": 1.0, "step": 0.01, "nullable": False},
    "maxModelLen": {"type": "integer", "minimum": 1, "maximum": 1048576, "step": 1, "nullable": False},
    "maxNumSeqs": {"type": "integer", "minimum": 1, "maximum": 4096, "step": 1, "nullable": True},
    "maxNumBatchedTokens": {"type": "integer", "minimum": 1, "maximum": 1048576, "step": 1, "nullable": True},
    "tensorParallelSize": {"type": "integer", "minimum": 1, "maximum": 64, "step": 1, "nullable": False},
    "pipelineParallelSize": {"type": "integer", "minimum": 1, "maximum": 64, "step": 1, "nullable": False},
    "enablePrefixCaching": {"type": "boolean", "nullable": False},
    "enableChunkedPrefill": {"type": "boolean", "nullable": True},
    "enforceEager": {"type": "boolean", "nullable": False},
    "kvCacheDtype": {"type": "string", "enum": ["auto", "fp8", "fp8_e4m3", "fp8_e5m2"], "nullable": True},
}
PROTECTED = {"flake.nix", "flake.lock", "nix/module.nix", "nix/nixclaw-module.nix"}
PROTECTED_FRAGMENTS = (
    "boot.", "fileSystems.", "users.users.", "users.groups.", "security.sudo",
    "services.openshell", "networking.firewall", "nix.settings.substituters",
    "nix.settings.trusted-public-keys", "nix.settings.trusted-users",
)
WORKLOAD_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")


def nix_string(value):
    return json.dumps(value, ensure_ascii=False).replace("${", "\\${")


def nix_value(value):
    if value is None: return "null"
    if value is True: return "true"
    if value is False: return "false"
    if isinstance(value, (int, float)) and not isinstance(value, bool): return str(value).lower()
    if isinstance(value, str): return nix_string(value)
    if isinstance(value, list): return "[ " + " ".join(nix_value(item) for item in value) + " ]"
    if isinstance(value, dict): return "{ " + " ".join(f"{nix_string(key)} = {nix_value(item)};" for key, item in sorted(value.items())) + " }"
    raise NixClawError("profile contains an unsupported JSON value")


def profile_hash(profile):
    return "sha256:" + hashlib.sha256(canonical(profile).encode()).hexdigest()


class Broker:
    def __init__(self, config):
        self.config = config
        self.state = Path(config["stateDirectory"])
        self.candidates = self.state / "candidates"
        self.audit = self.state / "audit.jsonl"
        self.candidates.mkdir(parents=True, exist_ok=True)
        self._threads = set()
        self._lock = threading.Lock()

    def generation_path(self):
        return os.path.realpath("/run/current-system")

    def generation(self):
        return generation_id(self.generation_path())

    def public_config(self):
        active = self.config["activeProfile"]
        return {
            "baseGeneration": self.generation(),
            "activeProfileName": self.config["activeProfileName"],
            "activeProfileHash": profile_hash(active),
            "servedModel": self.config["servedModel"],
            "activeProfile": active,
            "workloadIds": self.config["workloadIds"],
            "tunableFields": {key: PROFILE_SPECS[key] for key in self.config["tunableFields"]},
            "baselineNodes": self.config["baselineNodes"],
            "experimentTargets": self.config["experimentTargets"],
        }

    def facts(self):
        memory_kib = 0
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemTotal:"):
                memory_kib = int(line.split()[1])
        cpu_count = os.cpu_count() or 1
        return {
            "generation": self.generation(),
            "nixosRevision": self.config["nixosRevision"],
            "architecture": os.uname().machine,
            "gpu": self.config["gpuFacts"],
            "cpu": {"logicalCores": cpu_count},
            "memory": {"totalBytes": memory_kib * 1024},
            "clusterNodes": self.config["clusterNodes"],
            "vllmVersion": "0.25.1",
            "servedModel": self.config["servedModel"],
            "activeProfileHash": profile_hash(self.config["activeProfile"]),
            "services": self._service_health(),
        }

    def _service_health(self):
        results = []
        for name in self.config["healthServices"]:
            active = subprocess.run(["systemctl", "is-active", "--quiet", name], timeout=5).returncode == 0
            results.append({"name": name, "healthy": active})
        for url in self.config["healthUrls"]:
            healthy = False
            try:
                with urllib.request.urlopen(url, timeout=5) as response: healthy = response.status < 400
            except Exception: pass
            results.append({"name": url, "healthy": healthy})
        return results

    def get_internal(self, identifier):
        require_uuid(identifier, "experiment ID")
        path = self.candidates / f"{identifier}.json"
        if not path.is_file(): raise FileNotFoundError(identifier)
        return load_json(path)

    def public_experiment(self, record):
        allowed = {
            "id", "state", "baseGeneration", "candidateGeneration", "workloadId",
            "hypothesis", "profilePatch", "originalProfileHash", "candidateProfileHash",
            "targetNodes", "promotionNodes",
            "validationFindings", "baselineBenchmark", "candidateBenchmark", "decision",
            "rollbackReason", "error", "createdAt", "updatedAt",
        }
        return {key: value for key, value in record.items() if key in allowed}

    def list_experiments(self):
        return [self.public_experiment(load_json(path)) for path in sorted(self.candidates.glob("*.json")) if load_json(path).get("kind") == "experiment"]

    def submit_proposal(self, body, idempotency_key):
        require_fields(body, ["baseGeneration", "clientRequestId", "summary", "patch"])
        require_uuid(body["clientRequestId"], "clientRequestId")
        require_uuid(idempotency_key, "Idempotency-Key")
        if idempotency_key != body["clientRequestId"]: raise NixClawError("Idempotency-Key must equal clientRequestId")
        if body["baseGeneration"] != self.generation(): raise NixClawError("stale base generation")
        if not isinstance(body["summary"], str) or not 1 <= len(body["summary"]) <= 2000: raise NixClawError("summary must contain 1 to 2000 characters")
        self._validate_patch(body["patch"])
        identifier = candidate_id({"clientRequestId": body["clientRequestId"]})
        path = self.candidates / f"{identifier}.json"
        digest = hashlib.sha256(canonical(body).encode()).hexdigest()
        if path.exists():
            record = load_json(path)
            if record.get("requestDigest") != digest: raise NixClawError("idempotency key was already used with a different request")
            return self._public_proposal(record)
        timestamp = now()
        record = {"id": identifier, "kind": "proposal", "state": "submitted", "baseGeneration": body["baseGeneration"], "summary": body["summary"], "patch": body["patch"], "createdAt": timestamp, "updatedAt": timestamp, "requestDigest": digest}
        atomic_json(path, record); append_audit(self.audit, {"at": timestamp, "event": "submitted", "id": identifier})
        thread = threading.Thread(target=self._process_proposal, args=(identifier,), daemon=True)
        with self._lock: self._threads.add(thread)
        thread.start()
        return self._public_proposal(record)

    def _public_proposal(self, record):
        return {key: value for key, value in record.items() if key in {"id", "state", "baseGeneration", "summary", "patch", "candidateGeneration", "validationFindings", "error", "createdAt", "updatedAt"}}

    def _patch_paths(self, patch):
        paths = []
        for line in patch.splitlines():
            if line.startswith(("+++ ", "--- ")):
                raw = line[4:].split("\t", 1)[0]
                if raw == "/dev/null": continue
                if raw.startswith(("a/", "b/")): raw = raw[2:]
                path = PurePosixPath(raw)
                if path.is_absolute() or ".." in path.parts or not path.parts: raise NixClawError("patch contains an unsafe path")
                paths.append(str(path))
        if not paths: raise NixClawError("patch has no file paths")
        return paths

    def _validate_patch(self, patch):
        if not isinstance(patch, str) or not patch.strip() or len(patch.encode()) > self.config["maxProposalBytes"]: raise NixClawError("patch must be non-empty and within the size limit")
        if "GIT binary patch" in patch or "Binary files " in patch or "\x00" in patch: raise NixClawError("binary patches are forbidden")
        for fragment in PROTECTED_FRAGMENTS:
            if fragment in patch: raise NixClawError(f"patch contains protected option: {fragment}")
        editable = set(self.config["editablePaths"])
        for path in self._patch_paths(patch):
            if path in PROTECTED or path not in editable: raise NixClawError(f"path is not editable: {path}")

    def submit_experiment(self, body, idempotency_key):
        require_fields(body, ["baseGeneration", "workloadId", "hypothesis", "profilePatch", "targetNodes", "clientRequestId"])
        require_uuid(body["clientRequestId"], "clientRequestId")
        require_uuid(idempotency_key, "Idempotency-Key")
        if idempotency_key != body["clientRequestId"]:
            raise NixClawError("Idempotency-Key must equal clientRequestId")
        self._validate_experiment(body)
        identifier = candidate_id({"clientRequestId": body["clientRequestId"]})
        path = self.candidates / f"{identifier}.json"
        if path.exists():
            existing = load_json(path)
            if existing.get("requestDigest") != hashlib.sha256(canonical(body).encode()).hexdigest():
                raise NixClawError("idempotency key was already used with a different request")
            return self.public_experiment(existing)
        timestamp = now()
        record = {
            "id": identifier, "kind": "experiment", "state": "submitted",
            "baseGeneration": body["baseGeneration"], "workloadId": body["workloadId"],
            "hypothesis": body["hypothesis"], "profilePatch": body["profilePatch"],
            "targetNodes": body["targetNodes"],
            "promotionNodes": self.config["baselineNodes"],
            "originalProfileHash": profile_hash(self.config["activeProfile"]),
            "createdAt": timestamp, "updatedAt": timestamp,
            "requestDigest": hashlib.sha256(canonical(body).encode()).hexdigest(),
        }
        atomic_json(path, record)
        append_audit(self.audit, {"at": timestamp, "event": "submitted", "id": identifier})
        thread = threading.Thread(target=self._process_experiment, args=(identifier,), daemon=True)
        with self._lock: self._threads.add(thread)
        thread.start()
        return self.public_experiment(record)

    def _validate_experiment(self, body):
        if body["baseGeneration"] != self.generation(): raise NixClawError("stale base generation")
        if body["workloadId"] not in self.config["workloadIds"] or not WORKLOAD_ID.fullmatch(body["workloadId"]): raise NixClawError("unknown workloadId")
        if not isinstance(body["hypothesis"], str) or not 1 <= len(body["hypothesis"]) <= 2000: raise NixClawError("hypothesis must contain 1 to 2000 characters")
        targets = body["targetNodes"]
        if not isinstance(targets, list) or not targets or not all(isinstance(node, str) for node in targets):
            raise NixClawError("targetNodes must be a non-empty array of node IDs")
        if len(targets) != len(set(targets)):
            raise NixClawError("targetNodes must contain unique node IDs")
        unknown_targets = set(targets) - set(self.config["experimentTargets"])
        if unknown_targets:
            raise NixClawError(f"unsupported experiment targets: {', '.join(sorted(unknown_targets))}")
        patch = body["profilePatch"]
        if not isinstance(patch, dict) or not patch: raise NixClawError("profilePatch must be a non-empty object")
        unknown = patch.keys() - set(self.config["tunableFields"])
        if unknown: raise NixClawError(f"unsupported profile fields: {', '.join(sorted(unknown))}")
        for name, value in patch.items(): self._validate_value(name, value)

    def _validate_value(self, name, value):
        spec = PROFILE_SPECS[name]
        if value is None:
            if not spec["nullable"]: raise NixClawError(f"{name} does not accept null")
            return
        expected = spec["type"]
        valid = (expected == "boolean" and type(value) is bool) or (expected == "integer" and type(value) is int) or (expected == "number" and type(value) in (int, float)) or (expected == "string" and isinstance(value, str))
        if not valid: raise NixClawError(f"{name} must be {expected}")
        if "minimum" in spec and value < spec["minimum"]: raise NixClawError(f"{name} is below its minimum")
        if "minimumExclusive" in spec and value <= spec["minimumExclusive"]: raise NixClawError(f"{name} is below its exclusive minimum")
        if "maximum" in spec and value > spec["maximum"]: raise NixClawError(f"{name} is above its maximum")
        if "enum" in spec and value not in spec["enum"]: raise NixClawError(f"{name} is not an allowed value")

    def _process_experiment(self, identifier):
        path = self.candidates / f"{identifier}.json"
        record = load_json(path)
        try:
            self._transition(record, path, "validating")
            merged = self.config["activeProfile"] | record["profilePatch"]
            record["candidateProfileHash"] = profile_hash(merged)
            record["validationFindings"] = ["schema", "bounds", "nix-evaluation"]
            generation_path = self._build(identifier, record["profilePatch"])
            record["generationPath"] = generation_path
            record["candidateGeneration"] = generation_id(generation_path)
            self._transition(record, path, "built")
            self._transition(record, path, "awaitingApproval")
        except Exception as error:
            record["error"] = str(error)[-4000:]
            self._transition(record, path, "failed")
        finally:
            with self._lock: self._threads.discard(threading.current_thread())

    def _process_proposal(self, identifier):
        path = self.candidates / f"{identifier}.json"; record = load_json(path)
        try:
            self._transition(record, path, "validating")
            generation_path = self._build_proposal(identifier, record["patch"])
            record["generationPath"] = generation_path; record["candidateGeneration"] = generation_id(generation_path)
            record["validationFindings"] = ["path-allowlist", "protected-options", "nix-evaluation"]
            self._transition(record, path, "built"); self._transition(record, path, "awaitingApproval")
        except Exception as error:
            record["error"] = str(error)[-4000:]; self._transition(record, path, "failed")
        finally:
            with self._lock: self._threads.discard(threading.current_thread())

    def _transition(self, record, path, state):
        record["state"] = state; record["updatedAt"] = now(); atomic_json(path, record)
        append_audit(self.audit, {"at": record["updatedAt"], "event": state, "id": record["id"]})

    def _copy_source(self, destination):
        source = Path(self.config["source"]).resolve()
        shutil.copytree(source, destination, symlinks=True, ignore=shutil.ignore_patterns(".git", "result", "result-*"))

    def _build_proposal(self, identifier, patch):
        work_root = Path(self.config["workDirectory"]); work_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=f"proposal-{identifier}-", dir=work_root) as temporary:
            source = Path(temporary) / "source"; self._copy_source(source)
            subprocess.run(["patch", "--batch", "--forward", "--strip=1", "--directory", source], input=patch, text=True, check=True, capture_output=True, timeout=60)
            for relative in self._patch_paths(patch):
                target = source / relative
                if target.is_symlink(): raise NixClawError(f"patched path is a symlink: {relative}")
            expression = "let f = builtins.getFlake " + nix_string(f"path:{source}") + "; in f.nixosConfigurations." + nix_string(self.config["configurationName"]) + ".config.system.build.toplevel"
            result = subprocess.run(["nix", "build", "--no-link", "--print-out-paths", "--impure", "--expr", expression], check=True, capture_output=True, text=True, timeout=self.config["buildTimeoutSeconds"])
            paths = [line for line in result.stdout.splitlines() if line.startswith("/nix/store/")]
            if len(paths) != 1: raise NixClawError("build did not return exactly one generation")
            return paths[0]

    def _build(self, identifier, patch):
        work_root = Path(self.config["workDirectory"]); work_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=f"candidate-{identifier}-", dir=work_root) as temporary:
            source = Path(temporary) / "source"; self._copy_source(source)
            profile_name = "nixclaw-candidate-" + identifier[:8]
            candidate_profile = self.config["activeProfile"] | patch
            assignments = "\n".join(f"services.nemoclawVllm.profiles.{nix_string(profile_name)}.{key} = {nix_value(value)};" for key, value in sorted(candidate_profile.items()))
            module_path = Path(temporary) / "candidate.nix"
            module_path.write_text("{\n services.nemoclawVllm.activeProfile = " + nix_string(profile_name) + ";\n " + assignments + "\n}\n")
            expression = "let f = builtins.getFlake " + nix_string(f"path:{source}") + "; base = f.nixosConfigurations." + nix_string(self.config["configurationName"]) + "; in (base.extendModules { modules = [ " + str(module_path) + " ]; }).config.system.build.toplevel"
            result = subprocess.run(["nix", "build", "--no-link", "--print-out-paths", "--impure", "--expr", expression], check=True, capture_output=True, text=True, timeout=self.config["buildTimeoutSeconds"])
            paths = [line for line in result.stdout.splitlines() if line.startswith("/nix/store/")]
            if len(paths) != 1: raise NixClawError("build did not return exactly one generation")
            return paths[0]


class Handler(BaseHTTPRequestHandler):
    server_version = "NixClawBroker/1"
    request_id = None

    def _request_id(self):
        supplied = self.headers.get("X-Request-ID")
        try: return require_uuid(supplied, "X-Request-ID") if supplied else str(uuid.uuid4())
        except NixClawError: return str(uuid.uuid4())

    def _reply(self, status, data=None, error=None, code="INVALID_REQUEST", details=None):
        request_id = self.request_id or self._request_id()
        value = {"schemaVersion": "1", "requestId": request_id}
        if error is None: value["data"] = data
        else: value["error"] = {"code": code, "message": str(error), "details": details or {}}
        payload = (json.dumps(value, sort_keys=True) + "\n").encode()
        self.send_response(status); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(payload))); self.end_headers(); self.wfile.write(payload)

    def _authorized(self):
        token_file = self.server.config.get("tokenFile")
        if not token_file: return True
        expected = Path(token_file).read_text().strip()
        return bool(expected) and self.headers.get("Authorization") == f"Bearer {expected}"

    def _body(self):
        raw = self.headers.get("Content-Length")
        if raw is None or not raw.isdigit(): raise NixClawError("Content-Length is required")
        length = int(raw)
        if length > self.server.config["maxRequestBytes"]: raise NixClawError("request is too large")
        return json.loads(self.rfile.read(length))

    def do_GET(self):
        self.request_id = self._request_id()
        try:
            if not self._authorized(): return self._reply(401, error="unauthorized", code="UNAUTHORIZED")
            if self.path == "/v1/facts": return self._reply(200, self.server.broker.facts())
            if self.path == "/v1/config": return self._reply(200, self.server.broker.public_config())
            if self.path == "/v1/experiments": return self._reply(200, self.server.broker.list_experiments())
            match = re.fullmatch(r"/v1/experiments/([a-f0-9-]{36})", self.path)
            if match: return self._reply(200, self.server.broker.public_experiment(self.server.broker.get_internal(match.group(1))))
            self._reply(404, error="not found", code="NOT_FOUND")
        except FileNotFoundError: self._reply(404, error="not found", code="NOT_FOUND")
        except Exception as error: self._reply(400, error=error)

    def do_POST(self):
        self.request_id = self._request_id()
        try:
            if not self._authorized(): return self._reply(401, error="unauthorized", code="UNAUTHORIZED")
            if self.path not in {"/v1/experiments", "/v1/proposals"}: return self._reply(404, error="not found", code="NOT_FOUND")
            body = self._body()
            data = self.server.broker.submit_experiment(body, self.headers.get("Idempotency-Key")) if self.path.endswith("experiments") else self.server.broker.submit_proposal(body, self.headers.get("Idempotency-Key"))
            self._reply(202, data)
        except (NixClawError, json.JSONDecodeError) as error:
            code = "STALE_GENERATION" if "stale" in str(error) else "INVALID_REQUEST"
            self._reply(409 if code == "STALE_GENERATION" else 400, error=error, code=code)
        except Exception as error: self._reply(500, error=error, code="INTERNAL_ERROR")

    def log_message(self, fmt, *args): print("broker:", fmt % args, flush=True)


def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--config", required=True); arguments = parser.parse_args()
    config = load_json(arguments.config); server = ThreadingHTTPServer((config["listenAddress"], config["port"]), Handler)
    server.config = config; server.broker = Broker(config); server.serve_forever()
