import argparse
import json
import socket
import sys


def main():
    parser = argparse.ArgumentParser(prog="nixclawctl")
    parser.add_argument("--socket", default="/run/nixclaw/activator.sock")
    parser.add_argument("operation", choices=["review", "approve", "confirm", "rollback"])
    parser.add_argument("id")
    arguments = parser.parse_args()
    request = json.dumps({"operation": arguments.operation, "id": arguments.id}).encode() + b"\n"
    with socket.socket(socket.AF_UNIX) as client:
        client.connect(arguments.socket); client.sendall(request)
        response = json.loads(client.makefile("rb").readline())
    print(json.dumps(response.get("data") if response.get("ok") else response, indent=2, sort_keys=True))
    if not response.get("ok"): sys.exit(1)
