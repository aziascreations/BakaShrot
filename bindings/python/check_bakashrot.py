"""Checks bakashrot.py and the DLL against a running server, run by
crates/bakashrot-capi/tests/python.rs (which starts the server and writes
the certificates and client.toml files).

Usage: python check_bakashrot.py <DllPath> <Folder>
  Folder/kitchen.toml  node kitchen: may push to logs and secret, read everything, query.
  Folder/lounge.toml   node lounge: may read logs only.
  Folder/guest.toml    node guest: none of its roles is the server's.
Expects an empty database. Prints PASS/FAIL per check, exits 1 if any failed.
"""

import hashlib
import os
import sys
import threading
import time

import bakashrot
from bakashrot import AuthError, BakaShrotError, Client, ConnectionLostError, ErrorCode, RefusedError

dll_path, folder = sys.argv[1:3]
fails = 0


def check(what, ok, detail=""):
    global fails
    if not ok:
        fails += 1
    detail = str(detail)
    if len(detail) > 300:
        detail = detail[:300] + f"... ({len(detail)} chars)"
    print(f"{'PASS' if ok else 'FAIL'} {what}\n      -> {detail}", flush=True)


def raises(function, error_type, contains="", code=None):
    try:
        function()
    except error_type as error:
        got = getattr(error, "code", None)
        return contains in str(error) and (code is None or got == code), f"{type(error).__name__} [{got!r}]: {error}"
    except Exception as error:  # noqa: BLE001 - reported as a failure
        return False, f"{type(error).__name__}: {error}"
    return False, "no exception"


kitchen = Client.from_file(os.path.join(folder, "kitchen.toml"), dll_path)
lounge = Client.from_file(os.path.join(folder, "lounge.toml"), dll_path)

with kitchen:
    check("Connects from kitchen.toml, the node from its certificate", kitchen.connected and kitchen.node == "kitchen",
          f"{kitchen.node!r}, {kitchen._dll.path}")

    # --- Nothing yet ---------------------------------------------------------
    check("latest() with no messages: None", kitchen.latest("logs", "kitchen") is None)
    page = kitchen.get_messages("logs", "kitchen")
    check("get_messages() with no messages: empty, no more", len(page) == 0 and not page.more and page.last_id is None, page)

    # --- Pushes --------------------------------------------------------------
    started = time.perf_counter()
    ids = [kitchen.push({"i": i}, "logs") for i in range(1, 251)]
    elapsed = time.perf_counter() - started
    check("250 pushes on one connection, ids 1-250", ids == list(range(1, 251)),
          f"{elapsed * 1000:.0f} ms, {250 / elapsed:.0f} msg/s")

    latest = kitchen.latest("logs", "kitchen")
    check("latest(): #250", latest is not None and latest.id == 250 and latest.json() == {"i": 250}, latest)
    now_ms = int(time.time() * 1000)
    check("latest().pushed_at: just now, UTC ms", latest is not None and now_ms - 60000 < latest.pushed_at <= now_ms + 1000,
          f"{latest.pushed_at if latest else None} vs {now_ms}")
    check("latest().pushed: the same, an aware datetime in UTC",
          latest is not None and latest.pushed.tzinfo is not None and latest.pushed.utcoffset().total_seconds() == 0
          and int(latest.pushed.timestamp() * 1000) == latest.pushed_at, latest.pushed if latest else None)

    # --- Pages ---------------------------------------------------------------
    page = kitchen.get_messages("logs", "kitchen", after=0, limit=100)
    check("First page: 1-100, more", [m.id for m in page] == list(range(1, 101)) and page.more and page.last_id == 100,
          f"{len(page)} messages, more={page.more}")
    first = page.messages[0]
    check("A message's fields", (first.topic, first.node, first.data, first.json(), first.attachment_size)
          == ("logs", "kitchen", '{"i":1}', {"i": 1}, 0), first)
    stamps = [m.pushed_at for m in page]
    check("Each message of a page has its pushed_at, in push order", all(stamps) and stamps == sorted(stamps),
          f"{stamps[0]} .. {stamps[-1]}")

    page = kitchen.get_messages("logs", "kitchen", after=200, limit=100)
    check("Last page: 201-250, no more", [m.id for m in page] == list(range(201, 251)) and not page.more,
          f"{len(page)} messages, more={page.more}")

    page = kitchen.get_messages("logs", "kitchen", after=150, limit=100)
    check("Exactly up to the last one: 151-250, no more", [m.id for m in page] == list(range(151, 251)) and not page.more,
          f"{len(page)} messages, more={page.more}")

    page = kitchen.get_messages("LOGS", "Kitchen", after=250)
    check("After the last one, names in another case: empty, no more", len(page) == 0 and not page.more, page)

    every = list(kitchen.iter_messages("logs", "kitchen", batch=37))
    check("iter_messages(batch=37): all 250 in order", [m.id for m in every] == list(range(1, 251)), f"{len(every)} messages")

    # --- Data ----------------------------------------------------------------
    text_id = kitchen.push("plain text, not JSON", "logs")
    unicode_id = kitchen.push("héllo wörld, 🌍, 日本語", "logs")
    empty_id = kitchen.push("", "logs")
    page = kitchen.get_messages("logs", "kitchen", after=250)
    data = [m.data for m in page]
    check("Non-JSON, non-ASCII and empty data read back as pushed",
          data == ["plain text, not JSON", "héllo wörld, 🌍, 日本語", ""] and [m.id for m in page] == [text_id, unicode_id, empty_id],
          data)
    ok, detail = raises(lambda: page.messages[0].json(), ValueError)
    check("json() on non-JSON data raises ValueError", ok, detail)

    rows = kitchen.query("SELECT is_json, COUNT(*) AS n FROM data GROUP BY is_json ORDER BY is_json")
    check("query(): is_json flags 3 non-JSON, 250 JSON", rows == [{"is_json": "0", "n": "3"}, {"is_json": "1", "n": "250"}], rows)
    ok, detail = raises(lambda: kitchen.query("SELECT nope FROM data"), RefusedError, "nope", ErrorCode.QUERY_FAILED)
    check("A query that fails: RefusedError, QUERY_FAILED", ok, detail)

    # --- Answers split at ~1 MB ----------------------------------------------
    big = "x" * (700 * 1024)
    big_ids = [kitchen.push(big, "logs") for _ in range(3)]
    page = kitchen.get_messages("logs", "kitchen", after=empty_id, limit=10)
    check("3 x 700 KB: one per answer, more", [m.id for m in page] == big_ids[:1] and page.more and page.messages[0].data == big,
          f"{len(page)} messages, more={page.more}")
    every = list(kitchen.iter_messages("logs", "kitchen", after=empty_id))
    check("iter_messages() over them: all 3, whole", [m.id for m in every] == big_ids and all(m.data == big for m in every),
          [len(m.data) for m in every])

    # --- Refusals ------------------------------------------------------------
    ok, detail = raises(lambda: kitchen.get_messages("logs", "nobody"), RefusedError, "unknown node 'nobody'", ErrorCode.UNKNOWN_NAME)
    check("Unknown node: RefusedError, UNKNOWN_NAME", ok, detail)
    check("Still connected after a refusal", kitchen.connected and kitchen.latest("logs", "kitchen").id == big_ids[-1])
    ok, detail = raises(lambda: kitchen.get_messages("logs", "kitchen", limit=0), ValueError)
    check("limit 0: ValueError, before asking", ok, detail)
    ok, detail = raises(lambda: kitchen.get_messages("logs", "kitchen", after=-1), ValueError)
    check("after -1: ValueError", ok, detail)
    ok, detail = raises(lambda: kitchen.push("x", "nothing"), RefusedError, "may not push to 'nothing'", ErrorCode.NOT_ALLOWED)
    check("Push to a topic not in its push_topics: RefusedError, NOT_ALLOWED", ok, detail)
    ok, detail = raises(lambda: kitchen.push("x", "a b"), BakaShrotError, "isn't a topic name", ErrorCode.INVALID_ARGUMENT)
    check("A topic that isn't a name: refused before sending", ok, detail)
    ok, detail = raises(lambda: kitchen.push("x" * (bakashrot.MAX_MESSAGE_SIZE + 1), "logs"), BakaShrotError, "too big",
                        ErrorCode.INVALID_ARGUMENT)
    check("A message over the limit: refused before sending", ok, detail)
    secret_id = kitchen.push({"s": 1}, "secret")
    check("Push to another allowed topic", secret_id == 1, secret_id)
    ok, detail = raises(lambda: lounge.connect(), BakaShrotError, "one connection", ErrorCode.ALREADY_CONNECTED)
    check("A second Client can't connect while one is", ok and not lounge.connected, detail)

    topics = kitchen.list_topics()
    check("list_topics()", topics.kind == "topic" and topics.names == ["logs", "secret"] and not topics.truncated, topics)
    nodes = kitchen.list_nodes()
    check("list_nodes()", nodes.kind == "node" and nodes.names == ["kitchen"], nodes)

    # --- follow() ------------------------------------------------------------
    followed = []
    errors = []

    def follower():
        try:
            for message in kitchen.follow("logs", "kitchen", after="latest", interval=0.05):
                followed.append(message)
                if len(followed) == 5:
                    return
        except Exception as error:  # noqa: BLE001 - reported below
            errors.append(error)

    thread = threading.Thread(target=follower, daemon=True)
    thread.start()
    time.sleep(0.5)
    new_ids = [kitchen.push({"f": i}, "logs") for i in range(5)]
    thread.join(10)
    check("follow(after='latest') from another thread: only the 5 new ones",
          not thread.is_alive() and not errors and [m.id for m in followed] == new_ids,
          f"{[m.id for m in followed]} vs {new_ids}, errors {errors}")

    # --- Attachments (in secret, the other checks count logs) ----------------
    blob = os.urandom(3 * 1024 * 1024 + 7)
    started = time.perf_counter()
    blob_id = kitchen.push({"kind": "blob"}, "secret", attachment=blob)
    up = time.perf_counter() - started
    message = kitchen.latest("secret", "kitchen")
    check("push(attachment=bytes): the message has it, ready",
          message is not None and message.id == blob_id and message.attachment_size == len(blob) and message.attachment_ready,
          message)
    started = time.perf_counter()
    data = kitchen.get_attachment("secret", "kitchen", blob_id)
    down = time.perf_counter() - started
    check("get_attachment(): the same bytes", data == blob, f"{len(data)} bytes, {up * 1000:.0f} ms up, {down * 1000:.0f} ms down")

    source = os.path.join(folder, "source.bin")
    with open(source, "wb") as file:
        file.write(os.urandom(1500 * 1024))
    file_id = kitchen.push("from a file", "secret", attachment=source)
    copy = os.path.join(folder, "copy.bin")
    size = kitchen.save_attachment("secret", "kitchen", file_id, copy)
    with open(source, "rb") as a, open(copy, "rb") as b:
        same = hashlib.sha256(a.read()).digest() == hashlib.sha256(b.read()).digest()
    check("push(attachment=path), save_attachment(): the same file", size == os.path.getsize(source) and same, size)

    plain_id = kitchen.push("no attachment", "secret")
    page = kitchen.get_messages("secret", "kitchen", after=blob_id - 1)
    sizes = [(m.id, m.attachment_size, m.attachment_ready) for m in page]
    check("get_messages(): each message's attachment",
          sizes == [(blob_id, len(blob), True), (file_id, os.path.getsize(source), True), (plain_id, 0, False)], sizes)
    ok, detail = raises(lambda: kitchen.get_attachment("secret", "kitchen", plain_id), RefusedError, "no attachment", ErrorCode.NOT_FOUND)
    check("get_attachment() of a message without: RefusedError, NOT_FOUND", ok, detail)
    none = os.path.join(folder, "none.bin")
    ok, detail = raises(lambda: kitchen.save_attachment("secret", "kitchen", plain_id, none), RefusedError, code=ErrorCode.NOT_FOUND)
    check("save_attachment() refused: no file left", ok and not os.path.exists(none), detail)
    ok, detail = raises(lambda: kitchen.push("x", "secret", attachment=b""), BakaShrotError, "0 bytes", ErrorCode.INVALID_ARGUMENT)
    check("An empty attachment: refused before sending", ok, detail)
    ok, detail = raises(lambda: kitchen.push("x", "secret", attachment=os.path.join(folder, "missing.bin")), BakaShrotError,
                        "missing.bin", ErrorCode.FILE_ERROR)
    check("A missing file: refused before sending", ok, detail)
    check("Still connected", kitchen.connected)

check("close(): disconnected", not kitchen.connected)
ok, detail = raises(lambda: kitchen.push("x", "logs"), ConnectionLostError, code=ErrorCode.NOT_CONNECTED)
check("A request once closed: ConnectionLostError, NOT_CONNECTED", ok, detail)

# --- Connecting: unreachable, refused, PEM text ----------------------------------
with open(kitchen.ca) as ca, open(kitchen.certificate) as certificate, open(kitchen.key) as key:
    pem = (ca.read(), certificate.read(), key.read())
nowhere = Client("127.0.0.1:1", *pem, dll_path=dll_path)
ok, detail = raises(nowhere.connect, ConnectionLostError, code=ErrorCode.CONNECT_FAILED)
check("Nothing listening: ConnectionLostError, CONNECT_FAILED", ok, detail)
guest = Client.from_file(os.path.join(folder, "guest.toml"), dll_path)
ok, detail = raises(guest.connect, AuthError, "guest", ErrorCode.NOT_ALLOWED)
check("None of its roles allowed: AuthError, NOT_ALLOWED", ok, detail)
missing = Client(f"{kitchen.host}:{kitchen.port}", os.path.join(folder, "missing.crt"), *pem[1:], dll_path=dll_path)
ok, detail = raises(missing.connect, BakaShrotError, "missing.crt", ErrorCode.FILE_ERROR)
check("A certificate file that isn't there: FILE_ERROR", ok, detail)
with Client(f"{kitchen.host}:{kitchen.port}", *pem, dll_path=dll_path) as again:
    check("The same identity from PEM text: connected", again.connected and again.node == "kitchen", again.node)

with lounge:
    page = lounge.get_messages("logs", "kitchen", after=245, limit=3)
    check("Another identity once the first closed: reads logs", [m.id for m in page] == [246, 247, 248] and page.more,
          f"{[m.id for m in page]}, more={page.more}")
    ok, detail = raises(lambda: lounge.get_messages("secret", "kitchen"), RefusedError, "may not read 'secret'", ErrorCode.NOT_ALLOWED)
    check("A topic not in its read_topics: RefusedError, NOT_ALLOWED", ok, detail)
    ok, detail = raises(lambda: lounge.query("SELECT 1"), RefusedError, "may not run queries", ErrorCode.NOT_ALLOWED)
    check("Not allowed to query: RefusedError, NOT_ALLOWED", ok, detail)
    check("list_topics(): only what it may read", lounge.list_topics().names == ["logs"])
    ok, detail = raises(lambda: lounge.get_attachment("secret", "kitchen", blob_id), RefusedError, code=ErrorCode.NOT_ALLOWED)
    check("An attachment in a topic it may not read: RefusedError, NOT_ALLOWED", ok, detail)

print()
print("All checks passed" if fails == 0 else f"{fails} check(s) failed")
sys.exit(1 if fails else 0)
