import argparse
import grp
import json
import os
import shlex
import socketserver
import subprocess
import threading
import time
import urllib.request
from pathlib import Path

from .common import NixClawError, append_audit, atomic_json, generation_id, load_json, now, validate_candidate_id, validate_store_path

BENCHMARK_FIELDS = {
    "environmentFingerprint", "nodeId", "workloadId", "servedModel", "generation", "profileHash",
    "warmupCount", "measuredRunCount", "samples", "requestsAttempted", "requestsSucceeded",
    "inputTokens", "outputTokens", "outputTokensPerSecond", "ttftMs", "interTokenLatencyMs",
    "structuredOutputCorrect", "toolCallCorrect", "healthFailures", "restarts", "ooms",
    "ncclErrors", "criticalMemoryPressure",
}
DECISION_FIELDS = {
    "accepted", "baseline", "candidate", "percentageDeltas", "passedGates", "failedGates",
    "explanations",
}
DECISION_GATES = {
    "throughput_improvement", "request_success", "correctness", "ttft_regression",
    "inter_token_regression", "runtime_health",
}


def require_exact_keys(value, expected, name):
    if not isinstance(value, dict): raise NixClawError(f"{name} must be a JSON object")
    missing = expected - value.keys(); unknown = value.keys() - expected
    if missing: raise NixClawError(f"{name} is missing fields: {', '.join(sorted(missing))}")
    if unknown: raise NixClawError(f"{name} has unknown fields: {', '.join(sorted(unknown))}")


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

    def operate(self, operation, identifier, request=None):
        validate_candidate_id(identifier)
        if operation not in {"review", "approve", "record-results", "confirm", "rollback"}:
            raise NixClawError("unknown operation")
        with self.lock:
            record = self._record(identifier)
            if operation == "review": return self._review(record)
            if operation == "approve": return self._approve(record)
            if operation == "record-results": return self._record_results(record, request or {})
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
        nodes = self._record_nodes(record)
        activated = []
        previous = {}
        drained = False
        try:
            for node in nodes:
                previous[node["id"]] = self._current_generation(node)
                if generation_id(previous[node["id"]]) != record["baseGeneration"]:
                    raise NixClawError(f"node {node['id']} has a stale base generation")
            if record.get("kind") == "experiment":
                self._run_hook("canaryDrainCommand")
                drained = True
            for node in nodes:
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
            if drained:
                try: self._run_hook("canaryRestoreCommand")
                except Exception: pass
            record["state"] = "rolledBack"; record["rollbackReason"] = f"activation failed: {error}"; self._save(record)
            raise

    def _confirm(self, record):
        if record.get("state") not in {"active", "measuring"}: raise NixClawError("candidate is not active")
        if record.get("kind") == "experiment" and not record.get("decision", {}).get("accepted"):
            raise NixClawError("candidate requires an accepted benchmark decision before confirmation")
        generation = validate_store_path(record.get("generationPath"))
        targets = self._record_nodes(record)
        promotions = self._nodes_by_id(record.get("promotionNodes", []))
        previous = record.get("previousGenerations", {})
        changed = []
        try:
            for node in targets:
                self._health(node)
                self._persist(node, generation)
                changed.append(node)
            for node in promotions:
                old = self._current_generation(node)
                if generation_id(old) != record["baseGeneration"]:
                    raise NixClawError(f"node {node['id']} has a stale base generation")
                previous[node["id"]] = old
                self._prepare(node, generation)
                self._switch(node, generation, "test")
                changed.append(node)
                self._health(node)
                self._persist(node, generation)
            if record.get("kind") == "experiment":
                self._run_hook("canaryRestoreCommand")
            record["previousGenerations"] = previous
            record["state"] = "accepted"; record.pop("leaseExpiresAt", None); self._save(record)
            (self.leases / f"{record['id']}.json").unlink(missing_ok=True)
            return self._review(record)
        except Exception as error:
            for node in reversed(changed):
                old = previous.get(node["id"])
                if old:
                    try:
                        self._switch(node, old, "test")
                        self._persist(node, old)
                    except Exception: pass
            if record.get("kind") == "experiment":
                try: self._run_hook("canaryRestoreCommand")
                except Exception: pass
            record["state"] = "rolledBack"; record["rollbackReason"] = f"promotion failed: {error}"; record.pop("leaseExpiresAt", None); self._save(record)
            (self.leases / f"{record['id']}.json").unlink(missing_ok=True)
            raise

    def _record_results(self, record, request):
        if record.get("kind") != "experiment":
            raise NixClawError("benchmark results can only be attached to experiments")
        if record.get("state") not in {"active", "measuring", "accepted"}:
            raise NixClawError("candidate is not active, measuring, or accepted")
        require_exact_keys(
            request,
            {"operation", "id", "baselineBenchmark", "candidateBenchmark", "decision"},
            "record-results request",
        )
        baseline = request["baselineBenchmark"]
        candidate = request["candidateBenchmark"]
        decision = request["decision"]
        require_exact_keys(baseline, BENCHMARK_FIELDS, "baseline benchmark")
        require_exact_keys(candidate, BENCHMARK_FIELDS, "candidate benchmark")
        require_exact_keys(decision, DECISION_FIELDS, "experiment decision")
        self._validate_results(record, baseline, candidate, decision)

        attached = (record.get("baselineBenchmark"), record.get("candidateBenchmark"), record.get("decision"))
        incoming = (baseline, candidate, decision)
        if any(value is not None for value in attached):
            if attached != incoming: raise NixClawError("experiment results are already attached with different content")
            return self._review(record)
        if record["state"] == "accepted" and not decision["accepted"]:
            raise NixClawError("an accepted experiment requires an accepted benchmark decision")
        record["baselineBenchmark"] = baseline
        record["candidateBenchmark"] = candidate
        record["decision"] = decision
        if record["state"] == "active": record["state"] = "measuring"
        self._save(record)
        return self._review(record)

    def _validate_results(self, record, baseline, candidate, decision):
        expected = [
            (baseline, "workloadId", record["workloadId"], "baseline workload"),
            (candidate, "workloadId", record["workloadId"], "candidate workload"),
            (baseline, "generation", record["baseGeneration"], "baseline generation"),
            (candidate, "generation", record["candidateGeneration"], "candidate generation"),
            (baseline, "profileHash", record["originalProfileHash"], "baseline profile hash"),
            (candidate, "profileHash", record["candidateProfileHash"], "candidate profile hash"),
        ]
        for value, key, wanted, name in expected:
            if value.get(key) != wanted: raise NixClawError(f"{name} does not match the experiment")
        if baseline.get("environmentFingerprint") != candidate.get("environmentFingerprint"):
            raise NixClawError("benchmark environment fingerprints do not match")
        baseline_nodes = set(record.get("promotionNodes") or record.get("targetNodes", []))
        if baseline.get("nodeId") not in baseline_nodes:
            raise NixClawError("baseline benchmark node is not a stable replica")
        if candidate.get("nodeId") not in set(record.get("targetNodes", [])):
            raise NixClawError("candidate benchmark node is not an experiment target")
        if baseline.get("servedModel") != candidate.get("servedModel"):
            raise NixClawError("benchmark served models do not match")

        for name, result in (("baseline", baseline), ("candidate", candidate)):
            for field in ("outputTokensPerSecond", "ttftMs", "interTokenLatencyMs"):
                require_exact_keys(result.get(field), {"median", "p95"}, f"{name} {field}")
        require_exact_keys(decision.get("baseline"), {"outputTokensPerSecond", "ttftMs", "interTokenLatencyMs"}, "decision baseline")
        require_exact_keys(decision.get("candidate"), {"outputTokensPerSecond", "ttftMs", "interTokenLatencyMs"}, "decision candidate")
        expected_summary = lambda result: {
            "outputTokensPerSecond": result["outputTokensPerSecond"]["median"],
            "ttftMs": result["ttftMs"]["p95"],
            "interTokenLatencyMs": result["interTokenLatencyMs"]["p95"],
        }
        if decision["baseline"] != expected_summary(baseline):
            raise NixClawError("decision baseline metrics do not match the benchmark")
        if decision["candidate"] != expected_summary(candidate):
            raise NixClawError("decision candidate metrics do not match the benchmark")
        changes = {
            name: ((decision["candidate"][name] - decision["baseline"][name]) / decision["baseline"][name]) * 100
            for name in decision["baseline"]
            if decision["baseline"][name] != 0
        }
        supplied_changes = decision.get("percentageDeltas")
        if not isinstance(supplied_changes, dict) or supplied_changes.keys() != changes.keys():
            raise NixClawError("decision percentage deltas do not match the benchmark")
        if any(abs(supplied_changes[name] - value) > 1e-6 for name, value in changes.items()):
            raise NixClawError("decision percentage deltas do not match the benchmark")

        healthy = (
            candidate["healthFailures"] == 0
            and candidate["restarts"] == 0
            and candidate["ooms"] == 0
            and candidate["ncclErrors"] == 0
            and not candidate["criticalMemoryPressure"]
        )
        gate_results = {
            "throughput_improvement": changes.get("outputTokensPerSecond", float("-inf")) >= 3,
            "request_success": candidate["requestsAttempted"] > 0 and candidate["requestsSucceeded"] == candidate["requestsAttempted"],
            "correctness": candidate["structuredOutputCorrect"] and candidate["toolCallCorrect"],
            "ttft_regression": changes.get("ttftMs", float("inf")) <= 10,
            "inter_token_regression": changes.get("interTokenLatencyMs", float("inf")) <= 10,
            "runtime_health": healthy,
        }
        passed = decision.get("passedGates"); failed = decision.get("failedGates")
        if not isinstance(passed, list) or not isinstance(failed, list):
            raise NixClawError("decision gates must be arrays")
        if set(passed) | set(failed) != DECISION_GATES or set(passed) & set(failed):
            raise NixClawError("decision gates do not form the required partition")
        expected_passed = {name for name, value in gate_results.items() if value}
        if set(passed) != expected_passed:
            raise NixClawError("decision gate outcomes do not match the benchmarks")
        if decision.get("accepted") != (not failed):
            raise NixClawError("decision acceptance does not match its failed gates")

    def _rollback(self, record, reason):
        if record.get("state") not in {"active", "measuring", "accepted"}: raise NixClawError("candidate is not active or accepted")
        previous = record.get("previousGenerations", {})
        for node in reversed(self._nodes_by_id(previous)):
            old = previous.get(node["id"])
            if old:
                self._switch(node, old, "test")
                self._persist(node, old)
        if record.get("kind") == "experiment":
            self._run_hook("canaryRestoreCommand")
        record["state"] = "rolledBack"; record["rollbackReason"] = reason; record.pop("leaseExpiresAt", None); self._save(record)
        (self.leases / f"{record['id']}.json").unlink(missing_ok=True)
        return self._review(record)

    def _activation_order(self):
        return sorted(self.config["nodes"], key=lambda node: (node["role"] == "head", node["rank"]))

    def _nodes_by_id(self, identifiers):
        wanted = set(identifiers)
        nodes = [node for node in self._activation_order() if node["id"] in wanted]
        found = {node["id"] for node in nodes}
        unknown = wanted - found
        if unknown:
            raise NixClawError(f"unknown cluster nodes: {', '.join(sorted(unknown))}")
        return nodes

    def _record_nodes(self, record):
        identifiers = record.get("targetNodes")
        nodes = self._nodes_by_id(identifiers) if identifiers is not None else self._activation_order()
        if not nodes:
            raise NixClawError("candidate has no activation targets")
        return nodes

    def _run_hook(self, name):
        command = self.config.get(name, [])
        if command:
            subprocess.run(command, check=True, capture_output=True, text=True, timeout=self.config["commandTimeoutSeconds"])

    def _remote(self, node, command):
        if node["local"]: return subprocess.run(command, check=True, capture_output=True, text=True, timeout=self.config["commandTimeoutSeconds"])
        remote = node["sshTarget"]
        ssh = ["ssh", *self.config.get("sshOptions", []), "-oBatchMode=yes", "--", remote]
        return subprocess.run([*ssh, *command], check=True, capture_output=True, text=True, timeout=self.config["commandTimeoutSeconds"])

    def _current_generation(self, node):
        result = self._remote(node, ["readlink", "-f", "/run/current-system"])
        return result.stdout.strip()

    def _prepare(self, node, generation):
        if not node["local"]:
            environment = os.environ.copy()
            ssh_options = [*self.config.get("sshOptions", []), "-oBatchMode=yes"]
            environment["NIX_SSHOPTS"] = shlex.join(ssh_options)
            subprocess.run(["nix", "copy", "--to", "ssh-ng://" + node["sshTarget"], generation], check=True, timeout=self.config["commandTimeoutSeconds"], env=environment)

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
            if "Failed to run activate script" in details:
                raise NixClawError(f"NixOS activation script failed: {details}") from error
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
            maximum = self.server.activator.config["maxResultBytes"]
            raw = self.rfile.readline(maximum + 1)
            if len(raw) > maximum: raise NixClawError("request is too large")
            request = json.loads(raw)
            if not isinstance(request, dict): raise NixClawError("request must be a JSON object")
            operation = request.get("operation")
            expected = (
                {"operation", "id", "baselineBenchmark", "candidateBenchmark", "decision"}
                if operation == "record-results"
                else {"operation", "id"}
            )
            require_exact_keys(request, expected, "activator request")
            data = self.server.activator.operate(operation, request["id"], request)
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
