"""Example app: catches up on a topic/node's messages, then follows new ones.

Usage: python example.py <ClientIni> <Topic> <Node> [--from-start]
Run it from Build\\ (Build.ps1) while BakaShrot_Server.exe runs, e.g.:
    python ..\\Interactors\\Python\\example.py client.ini logs local
and push from another terminal:
    .\\BakaShrotPushMessage.exe @msg.json client.ini
Ctrl+C to stop.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bakashrot import Client, ConnectionLostError  # noqa: E402

if len(sys.argv) < 4:
    print(__doc__)
    sys.exit(1)

ini, topic, node = sys.argv[1:4]
after = 0 if "--from-start" in sys.argv[4:] else "latest"

# The DLL next to the ini (Build\), unless BAKASHROT_DLL says otherwise.
dll = os.environ.get("BAKASHROT_DLL") or os.path.join(os.path.dirname(os.path.abspath(ini)), "BakaShrot_Client.dll")

try:
    with Client.from_ini(ini, dll) as client:
        print(f"Connected to {client.host}:{client.port} as node {client.node}, following {topic}:{node}")
        for message in client.follow(topic, node, after=after):
            # Parsing is the app's business: the server stores anything.
            try:
                shown = json.dumps(message.json())
            except ValueError:
                shown = f"(not JSON) {message.data!r}"
            print(f"{message.topic}:{message.node}#{message.id} {shown}")
except KeyboardInterrupt:
    pass
except ConnectionLostError as error:
    print(error)
    sys.exit(1)
