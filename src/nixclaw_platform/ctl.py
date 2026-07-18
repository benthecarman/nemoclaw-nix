import argparse
import json
import socket
import sys


def main():
    parser = argparse.ArgumentParser(prog="nixclawctl")
    parser.add_argument("--socket", default="/run/nixclaw/activator.sock")
    parser.add_argument("operation", choices=["review", "approve", "record-results", "confirm", "rollback"])
    parser.add_argument("id")
    parser.add_argument("--baseline", type=argparse.FileType("r"))
    parser.add_argument("--candidate", type=argparse.FileType("r"))
    parser.add_argument("--decision", type=argparse.FileType("r"))
    arguments = parser.parse_args()
    request = {"operation": arguments.operation, "id": arguments.id}
    result_files = (arguments.baseline, arguments.candidate, arguments.decision)
    if arguments.operation == "record-results":
        if any(value is None for value in result_files):
            parser.error("record-results requires --baseline, --candidate, and --decision")
        request.update({
            "baselineBenchmark": json.load(arguments.baseline),
            "candidateBenchmark": json.load(arguments.candidate),
            "decision": json.load(arguments.decision),
        })
    elif any(value is not None for value in result_files):
        parser.error("result files are only valid with record-results")
    payload = json.dumps(request, separators=(",", ":")).encode() + b"\n"
    with socket.socket(socket.AF_UNIX) as client:
        client.connect(arguments.socket); client.sendall(payload)
        response = json.loads(client.makefile("rb").readline())
    print(json.dumps(response.get("data") if response.get("ok") else response, indent=2, sort_keys=True))
    if not response.get("ok"): sys.exit(1)
