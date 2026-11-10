"""Pushes as fast as the server acknowledges, for Tests/Restart-Test.ps1.

Usage: restart_pusher.py <BakaShrot_Client.dll> <client.ini> <stop file> <out file> <tag>
Pushes {"by": tag, "seq": n} to the client's DefaultTopic until the stop
file exists, writing "<message id> <seq>" to the out file once each push is
acknowledged. Ends with "STOPPED", or "ERR <code> <why>" when the server
goes away (the test kills it; code 104, ConnectionLost, during a push, or
100, NotConnected, between two): what was
acknowledged before is what must survive.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Interactors", "Python"))
from bakashrot import BakaShrotError, Client  # noqa: E402

dll_path, ini_path, stop_path, out_path, tag = sys.argv[1:6]

client = Client.from_ini(ini_path, dll_path)
with open(out_path, "a", buffering=1) as out:
    try:
        client.connect()
        seq = 0
        while not os.path.exists(stop_path):
            seq += 1
            message_id = client.push({"by": tag, "seq": seq})
            out.write(f"{message_id} {seq}\n")
        out.write("STOPPED\n")
    except BakaShrotError as error:
        out.write(f"ERR {int(error.code)} {type(error).__name__}: {error}\n")
    finally:
        try:
            client.close()
        except BakaShrotError:
            pass
