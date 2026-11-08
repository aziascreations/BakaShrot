"""BakaShrot client for Python, over BakaShrot_Client.dll.

No dependencies beyond the standard library: the DLL is loaded with ctypes
and does the connecting, authenticating and talking to the server. Messages
come back as stored, a str that may or may not be JSON: parsing them is up
to the app (Message.json() helps).

    from bakashrot import Client

    with Client.from_ini("client.ini") as client:
        message_id = client.push({"temperature": 21.5})
        for message in client.get_messages("logs", "kitchen", after=0).messages:
            print(message.id, message.data)
        for message in client.follow("logs", "kitchen"):   # until stopped
            print(message.id, message.json())

Topics and nodes are "refs": a name ("logs") or an id (12, or "12"), ids
being the server's own.

The connection only goes through to the server holding the private key of
server_public_key (client.ini's ServerPublicKey, the server logs it when it
starts), and everything on it is encrypted.

The DLL holds a single connection per process: only one Client may be
connected at a time. Calls are serialized with a lock, so a Client can be
shared between threads, one request at a time.

The DLL is 64-bit, so is the Python running this. It's looked for, in order:
the dll_path given, the BAKASHROT_DLL environment variable, next to this
file, then in the current directory. libsodium.dll must be next to it.
"""

from __future__ import annotations

import configparser
import ctypes
import json
import os
import threading
import time
from dataclasses import dataclass, field
from typing import Any, Iterator, Optional, Union

__all__ = [
    "Client", "Message", "MessagesPage", "NameEntry", "NamesList",
    "BakaShrotError", "RefusedError", "ConnectionLostError",
    "MAX_GET_MESSAGES", "MAX_MESSAGE_SIZE",
]

# Same as the server: Commons/Networking/Packets.pbi, GetMessagesPacket.pbi.
MAX_GET_MESSAGES = 10000
MAX_MESSAGE_SIZE = 16 * 1024 * 1024 - 4096

Ref = Union[str, int]


class BakaShrotError(Exception):
    """Something failed: the DLL couldn't be loaded, a bad argument, ..."""


class RefusedError(BakaShrotError):
    """The server refused the request, the connection is still open."""

    def __init__(self, reason: str):
        super().__init__(reason or "Refused")
        self.reason = reason


class ConnectionLostError(BakaShrotError):
    """The connection failed or was closed, connect() again to go on."""


@dataclass(frozen=True)
class Message:
    """A stored message. data is as stored: JSON or not (the server's
    is_json column tells which, json() parses it)."""

    id: int
    topic: str
    node: str
    topic_id: int
    node_id: int
    data: str

    def json(self) -> Any:
        """The data parsed as JSON, raises ValueError if it isn't."""
        return json.loads(self.data)


@dataclass(frozen=True)
class MessagesPage:
    """One answer to get_messages(): in message id order. more is True if
    more follow the last one, ask again with after=last_id."""

    messages: list = field(default_factory=list)
    more: bool = False

    @property
    def last_id(self) -> Optional[int]:
        return self.messages[-1].id if self.messages else None

    def __iter__(self):
        return iter(self.messages)

    def __len__(self):
        return len(self.messages)


@dataclass(frozen=True)
class NameEntry:
    id: int
    name: str  # "" if unnamed: those don't replicate
    origin: str  # "config", "id", "peer"


@dataclass(frozen=True)
class NamesList:
    kind: str  # "topic" or "node"
    items: list
    truncated: bool  # True if they didn't all fit in one answer


def _ref(value: Ref) -> bytes:
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        raise TypeError(f"a topic or node is a name or an id, not {value!r}")
    if isinstance(value, int) and not 0 <= value <= 65535:
        raise ValueError(f"an id is 0-65535, not {value}")
    return str(value).encode("utf-8")


def _find_dll(dll_path: Optional[str]) -> str:
    candidates = []
    if dll_path:
        candidates.append(dll_path)
    if os.environ.get("BAKASHROT_DLL"):
        candidates.append(os.environ["BAKASHROT_DLL"])
    candidates.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), "BakaShrot_Client.dll"))
    candidates.append(os.path.join(os.getcwd(), "BakaShrot_Client.dll"))
    for candidate in candidates:
        if os.path.isfile(candidate):
            return os.path.abspath(candidate)
    raise BakaShrotError("BakaShrot_Client.dll not found, looked at: " + ", ".join(candidates))


class _Dll:
    """The DLL's functions, with their types. Loaded once per process."""

    _instance: Optional["_Dll"] = None
    _instance_lock = threading.Lock()

    @classmethod
    def get(cls, dll_path: Optional[str]) -> "_Dll":
        with cls._instance_lock:
            if cls._instance is None:
                cls._instance = cls(_find_dll(dll_path))
            return cls._instance

    def __init__(self, path: str):
        if ctypes.sizeof(ctypes.c_void_p) != 8:
            raise BakaShrotError("BakaShrot_Client.dll is 64-bit, this Python is 32-bit")
        try:
            self.lib = ctypes.CDLL(path)
        except OSError as error:
            raise BakaShrotError(f"Failed to load {path} (is libsodium.dll next to it?): {error}") from error
        self.path = path

        I, L, Q, P, S = ctypes.c_ssize_t, ctypes.c_int32, ctypes.c_int64, ctypes.c_char_p, ctypes.c_void_p
        signatures = {
            "BakaShrot_SetPrivateKeyA": (I, [P]),
            "BakaShrot_SetPublicKeyA": (I, [P]),
            "BakaShrot_SetServerPublicKeyA": (I, [P]),
            "BakaShrot_SetTopicA": (I, [P]),
            "BakaShrot_SetNodeA": (I, [P]),
            "BakaShrot_ConnectA": (I, [P, L]),
            "BakaShrot_IsConnected": (I, []),
            "BakaShrot_Disconnect": (I, []),
            "BakaShrot_PushMessageToA": (Q, [P, P]),
            "BakaShrot_GetLatestMessageOfA": (I, [P, P]),
            "BakaShrot_GetMessagesA": (L, [P, P, Q, L]),
            "BakaShrot_GetMessageCount": (L, []),
            "BakaShrot_SelectMessage": (I, [L]),
            "BakaShrot_HasMoreMessages": (I, []),
            "BakaShrot_GetMessageId": (Q, []),
            "BakaShrot_GetMessageTopicId": (L, []),
            "BakaShrot_GetMessageNodeId": (L, []),
            "BakaShrot_GetMessageTopicA": (I, [S, I]),
            "BakaShrot_GetMessageNodeA": (I, [S, I]),
            "BakaShrot_GetMessageDataA": (I, [S, I]),
            "BakaShrot_ResolveTopicA": (L, [P]),
            "BakaShrot_ResolveNodeA": (L, [P]),
            "BakaShrot_GetResolvedNameA": (I, [S, I]),
            "BakaShrot_ListTopics": (L, []),
            "BakaShrot_ListNodes": (L, []),
            "BakaShrot_GetNamesListA": (I, [S, I]),
            "BakaShrot_QueryA": (I, [P]),
            "BakaShrot_GetQueryResultA": (I, [S, I]),
            "BakaShrot_GetRefusalReasonA": (I, [S, I]),
        }
        for name, (restype, argtypes) in signatures.items():
            try:
                function = getattr(self.lib, name)
            except AttributeError as error:
                raise BakaShrotError(f"{path} has no {name}, is it an older build?") from error
            function.restype = restype
            function.argtypes = argtypes
            setattr(self, name[len("BakaShrot_"):], function)

    def string(self, getter) -> str:
        """Calls a string getter: asks for the size, then copies (UTF-8)."""
        size = getter(None, 0)
        if size <= 1:
            return ""
        buffer = ctypes.create_string_buffer(size)
        getter(buffer, size)
        return buffer.raw[: size - 1].decode("utf-8")


class Client:
    """A connection to a BakaShrot server, through the DLL.

    private_key, public_key: the client's Ed25519 keys in Base64 (KeyGen.exe).
    server_public_key: the server's Ed25519 public key in Base64, it must
    prove it holds the matching private key.
    topic, node: who the client is, names or ids, as the server's
    [BakaShrot.Client.<name>] Identities lists them.
    """

    _connected_client: Optional["Client"] = None

    def __init__(self, private_key: str, public_key: str, server_public_key: str, topic: Ref, node: Ref,
                 host: str = "127.0.0.1", port: int = 12345, dll_path: Optional[str] = None):
        self._dll = _Dll.get(dll_path)
        self._lock = threading.RLock()
        self.private_key = private_key
        self.public_key = public_key
        self.server_public_key = server_public_key
        self.topic = topic
        self.node = node
        self.host = host
        self.port = int(port)

    @classmethod
    def from_ini(cls, path: str, dll_path: Optional[str] = None) -> "Client":
        """From a client.ini as the tools read it: [BakaShrot] PrivateKey,
        PublicKey, ServerPublicKey, Topic, Node, ServerHost, ServerPort."""
        parser = configparser.ConfigParser(interpolation=None)
        if not parser.read(path, encoding="utf-8-sig"):
            raise BakaShrotError(f"Failed to open '{path}'")
        section = parser["BakaShrot"] if parser.has_section("BakaShrot") else {}

        def get(key, fallback=None):
            value = section.get(key, fallback)
            if value is None:
                raise BakaShrotError(f"'{path}' has no [BakaShrot] {key}")
            return value.strip()

        return cls(get("PrivateKey"), get("PublicKey"), get("ServerPublicKey"),
                   get("Topic", section.get("TopicId")), get("Node", section.get("NodeId")),
                   get("ServerHost"), int(get("ServerPort")), dll_path)

    # --- Connection --------------------------------------------------------

    def connect(self) -> "Client":
        """Connects and authenticates, raises BakaShrotError on failure."""
        with self._lock:
            owner = Client._connected_client
            if owner is not None and owner is not self and owner.connected:
                raise BakaShrotError("The DLL holds one connection, another Client is connected")
            if self.connected:
                return self
            dll = self._dll
            if not dll.SetPrivateKeyA(self.private_key.encode("ascii")):
                raise BakaShrotError("Invalid private key")
            if not dll.SetPublicKeyA(self.public_key.encode("ascii")):
                raise BakaShrotError("Invalid public key")
            if not dll.SetServerPublicKeyA(self.server_public_key.encode("ascii")):
                raise BakaShrotError("Invalid server public key")
            if not dll.SetTopicA(_ref(self.topic)):
                raise BakaShrotError(f"Invalid topic {self.topic!r}")
            if not dll.SetNodeA(_ref(self.node)):
                raise BakaShrotError(f"Invalid node {self.node!r}")
            if not dll.ConnectA(self.host.encode("utf-8"), self.port):
                raise ConnectionLostError(f"Failed to connect and authenticate to {self.host}:{self.port}")
            Client._connected_client = self
            return self

    def close(self) -> None:
        with self._lock:
            if Client._connected_client is self:
                self._dll.Disconnect()
                Client._connected_client = None

    @property
    def connected(self) -> bool:
        return Client._connected_client is self and bool(self._dll.IsConnected())

    def __enter__(self) -> "Client":
        return self.connect()

    def __exit__(self, *_) -> None:
        self.close()

    def _check_connected(self) -> None:
        if not self.connected:
            raise ConnectionLostError("Not connected")

    def _failed(self, what: str) -> BakaShrotError:
        """The error for a failed request: refused, or the connection is gone."""
        if self._dll.IsConnected():
            reason = self._dll.string(self._dll.GetRefusalReasonA)
            return RefusedError(reason) if reason else BakaShrotError(f"{what} failed")
        if Client._connected_client is self:
            Client._connected_client = None
        return ConnectionLostError(f"{what}: the connection to the server failed")

    # --- Requests ----------------------------------------------------------

    def push(self, data: Any, topic: Optional[Ref] = None) -> int:
        """Pushes a message into topic (default: the client's own), under
        the client's node. data is stored as is if it's a str (JSON or not),
        anything else is turned into JSON first. Returns its message id."""
        if not isinstance(data, str):
            data = json.dumps(data, separators=(",", ":"), ensure_ascii=False)
        encoded = data.encode("utf-8")
        if len(encoded) > MAX_MESSAGE_SIZE:
            raise BakaShrotError(f"The message is too big: {len(encoded)} bytes, at most {MAX_MESSAGE_SIZE}")
        with self._lock:
            self._check_connected()
            message_id = self._dll.PushMessageToA(b"" if topic is None else _ref(topic), encoded)
            if message_id < 1:
                raise self._failed("Push")
            return message_id

    def _current(self) -> Message:
        dll = self._dll
        return Message(dll.GetMessageId(), dll.string(dll.GetMessageTopicA), dll.string(dll.GetMessageNodeA),
                       dll.GetMessageTopicId(), dll.GetMessageNodeId(), dll.string(dll.GetMessageDataA))

    def latest(self, topic: Ref, node: Ref) -> Optional[Message]:
        """The latest message of topic/node, None if there's none yet."""
        with self._lock:
            self._check_connected()
            if not self._dll.GetLatestMessageOfA(_ref(topic), _ref(node)):
                error = self._failed("Latest message")
                if isinstance(error, RefusedError) and error.reason.startswith("No message for"):
                    return None
                raise error
            return self._current()

    def get_messages(self, topic: Ref, node: Ref, after: int = 0, limit: int = 1000) -> MessagesPage:
        """The messages of topic/node after message id `after` (0: from the
        first), in id order: at most limit (1-10000), fewer if they didn't
        fit in about 1 MB (a bigger one comes alone). None if there are no
        more, that's not an error."""
        if not 1 <= limit <= MAX_GET_MESSAGES:
            raise ValueError(f"limit is 1-{MAX_GET_MESSAGES}, not {limit}")
        if after < 0:
            raise ValueError(f"after is 0 or more, not {after}")
        with self._lock:
            self._check_connected()
            dll = self._dll
            count = dll.GetMessagesA(_ref(topic), _ref(node), after, limit)
            if count < 0:
                raise self._failed("Get messages")
            messages = []
            for index in range(count):
                dll.SelectMessage(index)
                messages.append(self._current())
            return MessagesPage(messages, bool(dll.HasMoreMessages()))

    def iter_messages(self, topic: Ref, node: Ref, after: int = 0, batch: int = 1000) -> Iterator[Message]:
        """Every message of topic/node after `after`, asking for batch at a
        time, until there are no more."""
        while True:
            page = self.get_messages(topic, node, after, batch)
            yield from page.messages
            if page.messages:
                after = page.last_id
            if not page.more:
                return

    def follow(self, topic: Ref, node: Ref, after: Union[int, str] = "latest",
               interval: float = 0.5, batch: int = 1000) -> Iterator[Message]:
        """Every message of topic/node after `after`, then new ones as they
        come, checking every `interval` seconds once caught up. Forever:
        stop iterating to stop. after="latest" starts with the next new one.
        Raises ConnectionLostError if the connection fails."""
        if after == "latest":
            latest = self.latest(topic, node)
            after = latest.id if latest else 0
        elif not isinstance(after, int):
            raise ValueError(f"after is a message id or 'latest', not {after!r}")
        while True:
            page = self.get_messages(topic, node, after, batch)
            yield from page.messages
            if page.messages:
                after = page.last_id
            if not page.more:
                time.sleep(interval)

    def resolve_topic(self, ref: Ref) -> tuple:
        """(id, name) of a topic on this server, name "" if unnamed."""
        return self._resolve(self._dll.ResolveTopicA, ref, "Resolve topic")

    def resolve_node(self, ref: Ref) -> tuple:
        """(id, name) of a node on this server, name "" if unnamed."""
        return self._resolve(self._dll.ResolveNodeA, ref, "Resolve node")

    def _resolve(self, function, ref: Ref, what: str) -> tuple:
        with self._lock:
            self._check_connected()
            resolved = function(_ref(ref))
            if resolved < 0:
                raise self._failed(what)
            return resolved, self._dll.string(self._dll.GetResolvedNameA)

    def list_topics(self) -> NamesList:
        """Every topic the client may see, with this server's ids."""
        return self._list(self._dll.ListTopics, "List topics")

    def list_nodes(self) -> NamesList:
        """Every node, with this server's ids."""
        return self._list(self._dll.ListNodes, "List nodes")

    def _list(self, function, what: str) -> NamesList:
        with self._lock:
            self._check_connected()
            if function() < 0:
                raise self._failed(what)
            parsed = json.loads(self._dll.string(self._dll.GetNamesListA))
        return NamesList(parsed["kind"], [NameEntry(i["id"], i["name"], i["origin"]) for i in parsed["items"]],
                         bool(parsed["truncated"]))

    def query_raw(self, sql: str) -> str:
        """Runs one read-only SELECT on the server (the client needs
        AllowQuery = 1), returns its result as the server's JSON text:
        {"columns": [...], "rows": [[...], ...]}, every value a str or null.
        JSON functions on message_data need "is_json = 1" in the WHERE (or
        CASE WHEN is_json THEN ... END) when some rows aren't JSON, or the
        query is refused: RefusedError "Query failed: malformed JSON"."""
        with self._lock:
            self._check_connected()
            if not self._dll.QueryA(sql.encode("utf-8")):
                raise self._failed("Query")
            return self._dll.string(self._dll.GetQueryResultA)

    def query(self, sql: str) -> list:
        """query_raw(), as a list of dicts, one per row, by column name."""
        result = json.loads(self.query_raw(sql))
        columns = result["columns"]
        return [dict(zip(columns, row)) for row in result["rows"]]
