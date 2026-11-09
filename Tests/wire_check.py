"""What goes over the wire, run by Tests/Python-Test.ps1.

Puts a TCP proxy between the client (BakaShrot_Client.dll, through
Interactors/Python/bakashrot.py) and the server, recording every byte, then
checks that:
  - a pushed message, the client's identity and its topic never show up in
    plain text, either way, handshake included;
  - the message still makes it through and back;
  - a byte flipped by the proxy after the handshake drops the connection;
  - a client given another server's public key can't connect.

Usage: wire_check.py <BakaShrot_Client.dll> <client.ini> <proxy port> <other public key>
Exits with 0 if every check passed, 1 otherwise.
"""

import os
import socket
import sys
import threading

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Interactors", "Python"))
from bakashrot import BakaShrotError, Client  # noqa: E402

dll_path, ini_path, proxy_port, other_key = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
fails = 0


def check(what, ok, detail=""):
    global fails
    print(("PASS " if ok else "FAIL ") + what)
    if detail:
        print("      -> " + detail)
    if not ok:
        fails += 1


class Proxy:
    """Forwards one connection at a time to the server, keeping what passed.
    tamper: flips a bit in the next chunk the client sends."""

    def __init__(self, listen_port, server_host, server_port):
        self.server = (server_host, server_port)
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", listen_port))
        self.listener.listen(4)
        self.to_server = bytearray()
        self.to_client = bytearray()
        self.tamper = False
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self):
        while True:
            try:
                client, _ = self.listener.accept()
            except OSError:
                return
            upstream = socket.create_connection(self.server)
            threading.Thread(target=self._pump, args=(client, upstream, True), daemon=True).start()
            threading.Thread(target=self._pump, args=(upstream, client, False), daemon=True).start()

    def _pump(self, source, target, from_client):
        try:
            while True:
                data = source.recv(65536)
                if not data:
                    break
                data = bytearray(data)
                if from_client and self.tamper:
                    self.tamper = False
                    data[-1] ^= 0x01
                (self.to_server if from_client else self.to_client).extend(data)
                target.sendall(data)
        except OSError:
            pass
        for s in (source, target):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            s.close()


base = Client.from_ini(ini_path, dll_path)
proxy = Proxy(proxy_port, base.host, base.port)
marker = "wire-marker-7f3a91"
# The client's DefaultTopic in Python-Test.ps1's server config: its pushes
# land there, and it reads them back from there.
topic = "logs"

client = Client(base.private_key, base.public_key, base.server_public_key, base.node,
                "127.0.0.1", proxy_port, dll_path)

# Through the proxy, all of it recorded.
try:
    client.connect()
    message_id = client.push({"note": marker})
    latest = client.latest(topic, base.node)
    check("Pushed and read back through the proxy", latest is not None and marker in latest.data,
          latest.data if latest else "nothing")
    pages = client.get_messages(topic, base.node, after=message_id - 1, limit=10)
    check("Read as a run of messages too", any(marker in m.data for m in pages.messages))
    client.close()
except BakaShrotError as error:
    check("Pushed and read back through the proxy", False, str(error))

wire_up, wire_down = bytes(proxy.to_server), bytes(proxy.to_client)
check("Something went through both ways", len(wire_up) > 200 and len(wire_down) > 200,
      f"{len(wire_up)} bytes up, {len(wire_down)} down")
for needle in (marker, str(base.node), topic, base.public_key):
    shown = needle.encode("utf-8")
    check(f"'{needle[:20]}' never in plain text on the wire", shown not in wire_up and shown not in wire_down)

# A bit flipped after the handshake: the server drops the connection.
try:
    client.connect()
    proxy.tamper = True
    try:
        client.push({"note": "tampered"})
        check("A tampered request drops the connection", False, "the push went through")
    except BakaShrotError as error:
        check("A tampered request drops the connection", not client.connected, str(error))
    client.close()
except BakaShrotError as error:
    check("A tampered request drops the connection", False, "couldn't connect: " + str(error))

# Another server's key: the server can't open the Hello, nor sign for it.
impostor = Client(base.private_key, base.public_key, other_key, base.node,
                  base.host, base.port, dll_path)
try:
    impostor.connect()
    check("Another server's public key can't connect", False, "it connected")
    impostor.close()
except BakaShrotError as error:
    check("Another server's public key can't connect", True, str(error))

# And the right one still can, straight to the server.
try:
    base.connect()
    check("The right key still connects", base.connected)
    base.close()
except BakaShrotError as error:
    check("The right key still connects", False, str(error))

print()
print("All checks passed" if not fails else f"{fails} check(s) failed")
sys.exit(1 if fails else 0)
