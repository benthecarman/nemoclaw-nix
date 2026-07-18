import argparse
import grp
import json
import os
import socketserver
import subprocess
import threading
import time
import urllib.request
from pathlib import Path

from .common import NixClawError, append_audit, atomic_json, generation_id, load_json, now, validate_candidate_id, validate_store_path


class Activator:
    def __init__(self, config):
        self.config = config
        self.candidates = Path(config["brokerStateDirectory"]) / "candidates"
        self.state = Path(config["stateDirectory"])
        self.audit = self.state / "audit.jsonl"
        self.leases = self.state / "leases"
        self.leases.mkdir(parents=True, exist_ok=True)
        self.lock = threading.Lock()
        threading.Thread(target=self._lease_monitor, daemon=True).start()

    def operate(self, operation, identifier):
        validate_candidate_id(identifier)
        if operation not in {"review", "approve", "confirm", "rollback"}:
            raise NixClawError("unknown operation")
        with self.lock:
            record = self._record(identifier)
            if operation == "review": return self._review(record)
            if operation == "approve": return self._approve(record)
            if operation == "confirm": return self._confirm(record)
            return self._rollback(record, "operator requested rollback")

    def _record_path(self, identifier): return self.candidates / f"{identifier}.json"

    def _record(self, identifier):
        path = self._record_path(identifier)
        if not path.is_file(): raise NixClawError("candidate does not exist")
        return load_json(path)

    def _save(self, record):
        record["updatedAt"] = now()
        atomic_json(self._record_path(record["id"]), record, 0o640)
        os.chown(self._record_path(record["id"]), 0, __import__("grp").getgrnam(self.config["brokerGroup"]).gr_gid)
        append_audit(self.audit, {"at": record["updatedAt"], "event": record["state"], "id": record["id"]})

    def _review(self, record):
        return {key: value for key, value in record.items() if key not in {"requestDigest"}}

    def _approve(self, record):
        if record.get("state") != "awaitingApproval": raise NixClawError("candidate is not awaiting approval")
        generation = validate_store_path(record.get("generationPath"))
        if record["baseGeneration"] != self.config["baseGeneration"]():
            raise NixClawError("candidate base generation is stale")
        activated = []
        previous = {}
        try:
            for node in self._activation_order():
                previous[node["id"]] = self._current_generation(node)
                if generation_id(previous[node["id"]]) != record["baseGeneration"]:
                    raise NixClawError(f"node {node['id']} has a stale base generation")
                self._prepare(node, generation)
                activated.append(node)
                self._switch(node, generation, "test")
                self._health(node)
            record["previousGenerations"] = previous
            record["state"] = "active"
            deadline = int(time.time()) + self.config["leaseSeconds"]
            record["leaseExpiresAt"] = deadline
            self._save(record)
            atomic_json(self.leases / f"{record['id']}.json", {"id": record["id"], "deadline": deadline}, 0o600)
            return self._review(record)
        except Exception as error:
            for node in reversed(activated):
                try: self._switch(node, previous[node["id"]], "test")
                except Exception: pass
            record["state"] = "rolledBack"; record["rollbackReason"] = f"activation failed: {error}"; self._save(record)
            raise

    def _confirm(self, record):
        if record.get("state") not in {"active", "measuring"}: raise NixClawError("candidate is not active")
        generation = validate_store_path(record.get("generationPath"))
        for node in self._activation_order():
            self._health(node)
            self._persist(node, generation)
        record["state"] = "accepted"; record.pop("leaseExpiresAt", None); self._save(record)
        (self.leases / f"{record['id']}.json").unlink(missing_ok=True)
        return self._review(record)

    def _rollback(self, record, reason):
        if record.get("state") not in {"active", "measuring", "accepted"}: raise NixClawError("candidate is not active or accepted")
        previous = record.get("previousGenerations", {})
        for node in reversed(self._activation_order()):
            old = previous.get(node["id"])
            if old:
                self._switch(node, old, "test")
                self._persist(node, old)
        record["state"] = "rolledBack"; record["rollbackReason"] = reason; record.pop("leaseExpiresAt", None); self._save(record)
        (self.leases / f"{record['id']}.json").unlink(missing_ok=True)
        return self._review(record)

    def _activation_order(self):
        return sorted(self.config["nodes"], key=lambda node: (node["role"] == "head", node["rank"]))

    def _remote(self, node, command):
        if node["local"]: return subprocess.run(command, check=True, capture_output=True, text=True, timeout=self.config["commandTimeoutSeconds"])
        remote = node["sshTarget"]
        return subprocess.run(["ssh", "-oBatchMode=yes", "--", remote, *command], check=True, capture_output=True, text=True, timeout=self.config["commandTimeoutSeconds"])

    def _current_generation(self, node):
        result = self._remote(node, ["readlink", "-f", "/run/current-system"])
        return result.stdout.strip()

    def _prepare(self, node, generation):
        if not node["local"]:
            subprocess.run(["nix", "copy", "--to", "ssh-ng://" + node["sshTarget"], generation], check=True, timeout=self.config["commandTimeoutSeconds"])

    def _switch(self, node, generation, mode):
        if not generation.startswith("/nix/store/"): raise NixClawError("unsafe generation path")
        command = [generation + "/bin/switch-to-configuration", mode]
        if not node["local"]: command.insert(0, "sudo")
        try:
            self._remote(node, command)
        except subprocess.CalledProcessError as error:
            if error.returncode != 4:
                raise
            details = (error.stderr or error.stdout or str(error))[-4000:]
            append_audit(self.audit, {
                "at": now(), "event": "switchReportedFailedUnits",
                "node": node["id"], "details": details,
            })

    def _persist(self, node, generation):
        command = ["nix-env", "--profile", "/nix/var/nix/profiles/system", "--set", generation]
        if not node["local"]: command.insert(0, "sudo")
        self._remote(node, command)
        self._switch(node, generation, "boot")

    def _health(self, node):
        deadline = time.monotonic() + self.config["healthTimeoutSeconds"]
        last_error = None
        while time.monotonic() < deadline:
            try:
                for service in self.config["healthServices"]:
                    self._remote(node, ["systemctl", "is-active", "--quiet", service])
                for url in self.config["healthUrls"] if node["role"] == "head" else []:
                    if node["local"]:
                        with urllib.request.urlopen(url, timeout=5) as response:
                            if response.status >= 400: raise NixClawError(f"health check failed: {url}")
                    else:
                        self._remote(node, ["curl", "--fail", "--silent", "--show-error", "--max-time", "5", url])
                failed = self._remote(node, ["systemctl", "--failed", "--no-legend", "--plain"])
                if failed.stdout.strip(): raise NixClawError(f"failed systemd units: {failed.stdout.strip()}")
                return
            except Exception as error:
                last_error = error
                time.sleep(1)
        raise NixClawError(f"health checks did not pass before the deadline: {last_error}") from last_error

    def _lease_monitor(self):
        while True:
            time.sleep(2)
            for path in self.leases.glob("*.json"):
                try:
                    lease = load_json(path)
                    if int(lease["deadline"]) <= int(time.time()):
                        with self.lock:
                            record = self._record(lease["id"])
                            if record.get("state") in {"active", "measuring"}:
                                self._rollback(record, "activation lease expired")
                            else: path.unlink(missing_ok=True)
                except Exception as error:
                    append_audit(self.audit, {"at": now(), "event": "leaseMonitorError", "error": str(error)})


class RequestHandler(socketserver.StreamRequestHandler):
    def handle(self):
        try:
            raw = self.rfile.readline(4097)
            if len(raw) > 4096: raise NixClawError("request is too large")
            request = json.loads(raw)
            if set(request) != {"operation", "id"}: raise NixClawError("request must contain only operation and id")
            data = self.server.activator.operate(request["operation"], request["id"])
            response = {"ok": True, "data": data}
        except Exception as error:
            response = {"ok": False, "error": str(error)}
        self.wfile.write((json.dumps(response, sort_keys=True) + "\n").encode())


class UnixServer(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--config", required=True); arguments = parser.parse_args()
    config = load_json(arguments.config)
    config["baseGeneration"] = lambda: "nixos-" + __import__("hashlib").sha256(os.path.realpath("/run/current-system").encode()).hexdigest()[:20]
    socket_path = config["socketPath"]
    Path(socket_path).unlink(missing_ok=True)
    server = UnixServer(socket_path, RequestHandler); server.activator = Activator(config)
    os.chmod(socket_path, 0o660)
    os.chown(socket_path, 0, grp.getgrnam(config["socketGroup"]).gr_gid)
    server.serve_forever()
