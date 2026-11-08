"""Checks bakashrot.py against a running server, run by Tests/Python-Test.ps1.

Usage: python check_bakashrot.py <DllPath> <KitchenIni> <LoungeIni>
  KitchenIni  logs:kitchen, may push to logs and secret, read everything, query.
  LoungeIni   logs:lounge, may read logs only.
Expects an empty database. Prints PASS/FAIL per check, exits 1 if any failed.
"""

import sys
import threading
import time

import bakashrot
from bakashrot import BakaShrotError, Client, ConnectionLostError, RefusedError

dll_path, kitchen_ini, lounge_ini = sys.argv[1:4]
fails = 0


def check(what, ok, detail=""):
    global fails
    if not ok:
        fails += 1
    detail = str(detail)
    if len(detail) > 300:
        detail = detail[:300] + f"... ({len(detail)} chars)"
    print(f"{'PASS' if ok else 'FAIL'} {what}\n      -> {detail}", flush=True)


def raises(function, error_type, contains=""):
    try:
        function()
    except error_type as error:
        return contains in str(error), f"{type(error).__name__}: {error}"
    except Exception as error:  # noqa: BLE001 - reported as a failure
        return False, f"{type(error).__name__}: {error}"
    return False, "didn't raise"


kitchen = Client.from_ini(kitchen_ini, dll_path)
lounge = Client.from_ini(lounge_ini, dll_path)

with kitchen:
    check("Connects from client.ini", kitchen.connected, kitchen._dll.path)

    # --- Nothing yet ---------------------------------------------------------
    check("latest() with no messages: None", kitchen.latest("logs", "kitchen") is None)
    page = kitchen.get_messages("logs", "kitchen")
    check("get_messages() with no messages: empty, no more", len(page) == 0 and not page.more and page.last_id is None, page)

    # --- Pushes --------------------------------------------------------------
    started = time.perf_counter()
    ids = [kitchen.push({"i": i}) for i in range(1, 251)]
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

    topic_id, topic_name = kitchen.resolve_topic("logs")
    node_id, node_name = kitchen.resolve_node("kitchen")
    check("resolve_topic/node()", (topic_id, topic_name, node_id, node_name) == (1, "logs", 5, "kitchen"),
          (topic_id, topic_name, node_id, node_name))

    # --- Pages ---------------------------------------------------------------
    page = kitchen.get_messages("logs", "kitchen", after=0, limit=100)
    check("First page: 1-100, more", [m.id for m in page] == list(range(1, 101)) and page.more and page.last_id == 100,
          f"{len(page)} messages, more={page.more}")
    first = page.messages[0]
    check("A message's fields", (first.topic, first.node, first.topic_id, first.node_id, first.data, first.json())
          == ("logs", "kitchen", 1, 5, '{"i":1}', {"i": 1}), first)
    stamps = [m.pushed_at for m in page]
    check("Each message of a page has its pushed_at, in push order", all(stamps) and stamps == sorted(stamps),
          f"{stamps[0]} .. {stamps[-1]}")

    page = kitchen.get_messages("logs", "kitchen", after=200, limit=100)
    check("Last page: 201-250, no more", [m.id for m in page] == list(range(201, 251)) and not page.more,
          f"{len(page)} messages, more={page.more}")

    page = kitchen.get_messages("logs", "kitchen", after=150, limit=100)
    check("Exactly up to the last one: 151-250, no more", [m.id for m in page] == list(range(151, 251)) and not page.more,
          f"{len(page)} messages, more={page.more}")

    page = kitchen.get_messages("1", 5, after=250)
    check("After the last one, by ids: empty, no more", len(page) == 0 and not page.more, page)

    every = list(kitchen.iter_messages("logs", "kitchen", batch=37))
    check("iter_messages(batch=37): all 250 in order", [m.id for m in every] == list(range(1, 251)), f"{len(every)} messages")

    # --- Data ----------------------------------------------------------------
    text_id = kitchen.push("plain text, not JSON")
    unicode_id = kitchen.push("héllo wörld, 🌍, 日本語")
    empty_id = kitchen.push("")
    page = kitchen.get_messages("logs", "kitchen", after=250)
    data = [m.data for m in page]
    check("Non-JSON, non-ASCII and empty data read back as pushed",
          data == ["plain text, not JSON", "héllo wörld, 🌍, 日本語", ""] and [m.id for m in page] == [text_id, unicode_id, empty_id],
          data)
    ok, detail = raises(lambda: page.messages[0].json(), ValueError)
    check("json() on non-JSON data raises ValueError", ok, detail)

    rows = kitchen.query("SELECT is_json, COUNT(*) AS n FROM data GROUP BY is_json ORDER BY is_json")
    check("query(): is_json flags 3 non-JSON, 250 JSON", rows == [{"is_json": "0", "n": "3"}, {"is_json": "1", "n": "250"}], rows)

    # --- Answers split at ~1 MB ----------------------------------------------
    big = "x" * (700 * 1024)
    big_ids = [kitchen.push(big) for _ in range(3)]
    page = kitchen.get_messages("logs", "kitchen", after=empty_id, limit=10)
    check("3 x 700 KB: one per answer, more", [m.id for m in page] == big_ids[:1] and page.more and page.messages[0].data == big,
          f"{len(page)} messages, more={page.more}")
    every = list(kitchen.iter_messages("logs", "kitchen", after=empty_id))
    check("iter_messages() over them: all 3, whole", [m.id for m in every] == big_ids and all(m.data == big for m in every),
          [len(m.data) for m in every])

    # --- Refusals ------------------------------------------------------------
    ok, detail = raises(lambda: kitchen.get_messages("logs", "nobody"), RefusedError, "Unknown node 'nobody'")
    check("Unknown node: RefusedError", ok, detail)
    check("Still connected after a refusal", kitchen.connected and kitchen.latest("logs", "kitchen").id == big_ids[-1])
    ok, detail = raises(lambda: kitchen.get_messages("logs", "kitchen", limit=0), ValueError)
    check("limit 0: ValueError, before asking", ok, detail)
    ok, detail = raises(lambda: kitchen.get_messages("logs", "kitchen", after=-1), ValueError)
    check("after -1: ValueError", ok, detail)
    ok, detail = raises(lambda: kitchen.push("x", topic="nothing"), RefusedError, "Unknown topic")
    check("Push to an unknown topic: RefusedError", ok, detail)
    secret_id = kitchen.push({"s": 1}, topic="secret")
    check("Push to another allowed topic", secret_id == 1, secret_id)
    ok, detail = raises(lambda: lounge.connect(), BakaShrotError, "one connection")
    check("A second Client can't connect while one is", ok and not lounge.connected, detail)

    topics = kitchen.list_topics()
    check("list_topics()", topics.kind == "topic" and {"logs", "secret"} <= {t.name for t in topics.items}, topics)

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
    new_ids = [kitchen.push({"f": i}) for i in range(5)]
    thread.join(10)
    check("follow(after='latest') from another thread: only the 5 new ones",
          not thread.is_alive() and not errors and [m.id for m in followed] == new_ids,
          f"{[m.id for m in followed]} vs {new_ids}, errors {errors}")

check("close(): disconnected", not kitchen.connected)
ok, detail = raises(lambda: kitchen.push("x"), ConnectionLostError)
check("A request once closed: ConnectionLostError", ok, detail)

with lounge:
    page = lounge.get_messages("logs", "kitchen", after=245, limit=3)
    check("Another identity once the first closed: reads logs", [m.id for m in page] == [246, 247, 248] and page.more,
          f"{[m.id for m in page]}, more={page.more}")
    ok, detail = raises(lambda: lounge.get_messages("secret", "kitchen"), RefusedError, "Not allowed to read topic 'secret'")
    check("A topic not in its ReadTopics: RefusedError", ok, detail)
    ok, detail = raises(lambda: lounge.query("SELECT 1"), RefusedError, "Not allowed to query")
    check("Not allowed to query: RefusedError", ok, detail)

print()
print("All checks passed" if fails == 0 else f"{fails} check(s) failed")
sys.exit(1 if fails else 0)
