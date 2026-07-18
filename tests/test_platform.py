import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

from nixclaw_platform.activator import Activator
from nixclaw_platform.broker import Broker
from nixclaw_platform.common import NixClawError, atomic_json, candidate_id, generation_id, now, require_uuid


class BrokerContractTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.config = {
            "stateDirectory": self.temporary.name,
            "activeProfile": {"gpuMemoryUtilization": 0.8, "maxModelLen": 4096},
            "activeProfileName": "baseline",
            "servedModel": "model",
            "workloadIds": ["interactive"],
            "tunableFields": ["gpuMemoryUtilization", "maxModelLen", "enableChunkedPrefill"],
            "configurationName": "host",
            "maxProposalBytes": 65536,
            "editablePaths": ["nixclaw/agent-managed.nix"],
        }
        self.broker = Broker(self.config)
        self.broker.generation = lambda: "nixos-current"

    def tearDown(self): self.temporary.cleanup()

    def request(self, patch=None):
        return {
            "baseGeneration": "nixos-current", "workloadId": "interactive",
            "hypothesis": "Smaller batches should reduce latency.",
            "profilePatch": patch or {"gpuMemoryUtilization": 0.75},
            "clientRequestId": "b2fd9b1c-dd20-4b45-91ba-d777c78baa5d",
        }

    def test_valid_experiment(self): self.broker._validate_experiment(self.request())

    def test_stale_generation_rejected(self):
        value = self.request(); value["baseGeneration"] = "nixos-old"
        with self.assertRaisesRegex(NixClawError, "stale"): self.broker._validate_experiment(value)

    def test_unknown_field_rejected(self):
        with self.assertRaisesRegex(NixClawError, "unsupported"): self.broker._validate_experiment(self.request({"toolCallParser": "x"}))

    def test_out_of_bounds_rejected(self):
        with self.assertRaisesRegex(NixClawError, "maximum"): self.broker._validate_experiment(self.request({"gpuMemoryUtilization": 1.1}))

    def test_nullable_field(self): self.broker._validate_experiment(self.request({"enableChunkedPrefill": None}))

    def test_protected_proposal_rejected(self):
        patch = "--- a/nixclaw/agent-managed.nix\n+++ b/nixclaw/agent-managed.nix\n@@ -0,0 +1 @@\n+users.users.root = {};\n"
        with self.assertRaisesRegex(NixClawError, "protected"): self.broker._validate_patch(patch)

    def test_traversal_rejected(self):
        patch = "--- a/../flake.nix\n+++ b/../flake.nix\n@@ -1 +1 @@\n-a\n+b\n"
        with self.assertRaisesRegex(NixClawError, "unsafe"): self.broker._validate_patch(patch)


class CommonTests(unittest.TestCase):
    def test_ids_are_stable_uuids(self):
        first = candidate_id({"clientRequestId": "one"})
        self.assertEqual(first, candidate_id({"clientRequestId": "one"}))
        self.assertEqual(first, require_uuid(first))

    def test_generation_is_opaque(self):
        self.assertTrue(generation_id("/nix/store/example").startswith("nixos-"))
        self.assertNotIn("/nix/store", generation_id("/nix/store/example"))


class FakeActivator(Activator):
    def __init__(self, config):
        self.actions = []
        with patch("threading.Thread.start"):
            super().__init__(config)

    def _current_generation(self, node): return "/nix/store/old-generation"
    def _prepare(self, node, generation): self.actions.append(("prepare", node["id"], generation))
    def _switch(self, node, generation, mode): self.actions.append(("switch", node["id"], generation, mode))
    def _health(self, node): self.actions.append(("health", node["id"]))
    def _persist(self, node, generation): self.actions.append(("persist", node["id"], generation))


class ActivatorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        (root / "broker/candidates").mkdir(parents=True)
        self.identifier = "7a938cb2-7181-4df6-84cc-86bc474d083e"
        self.record_path = root / "broker/candidates" / f"{self.identifier}.json"
        atomic_json(self.record_path, {
            "id": self.identifier, "state": "awaitingApproval",
            "baseGeneration": generation_id("/nix/store/old-generation"),
            "generationPath": "/nix/store/new-generation", "createdAt": now(), "updatedAt": now(),
        })
        import grp, os
        self.config = {
            "brokerStateDirectory": str(root / "broker"), "stateDirectory": str(root / "activator"),
            "brokerGroup": grp.getgrgid(os.getgid()).gr_name, "leaseSeconds": 300,
            "commandTimeoutSeconds": 10, "healthTimeoutSeconds": 1,
            "healthServices": [], "healthUrls": [],
            "nodes": [{"id": "worker", "role": "worker", "rank": 1, "local": False, "sshTarget": "worker"}, {"id": "head", "role": "head", "rank": 0, "local": True, "sshTarget": ""}],
            "baseGeneration": lambda: generation_id("/nix/store/old-generation"),
        }
        self.activator = FakeActivator(self.config)

    def tearDown(self): self.temporary.cleanup()

    @patch("nixclaw_platform.activator.os.chown")
    @patch("nixclaw_platform.activator.validate_store_path", return_value="/nix/store/new-generation")
    def test_approve_workers_first_and_confirm(self, _validate, _chown):
        approved = self.activator.operate("approve", self.identifier)
        self.assertEqual(approved["state"], "active")
        prepares = [action[1] for action in self.activator.actions if action[0] == "prepare"]
        self.assertEqual(prepares, ["worker", "head"])
        confirmed = self.activator.operate("confirm", self.identifier)
        self.assertEqual(confirmed["state"], "accepted")
        self.assertEqual([action[1] for action in self.activator.actions if action[0] == "persist"], ["worker", "head"])


class SchemaTests(unittest.TestCase):
    def test_all_schemas_are_json(self):
        import json
        root = Path(__file__).parents[1] / "schemas/nixclaw/v1"
        schemas = list(root.glob("*.json"))
        self.assertGreaterEqual(len(schemas), 9)
        for schema in schemas:
            with self.subTest(schema=schema.name):
                value = json.loads(schema.read_text())
                self.assertEqual(value["$schema"], "https://json-schema.org/draft/2020-12/schema")


if __name__ == "__main__": unittest.main()
