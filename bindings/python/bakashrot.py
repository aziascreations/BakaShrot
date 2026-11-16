"""BakaShrot client for Python, over the client DLL (bakashrot.dll,
libbakashrot.so).

No dependencies beyond the standard library: the DLL is loaded with ctypes
and does the connecting and talking to the server. Messages come back as
stored, a str that may or may not be JSON: parsing them is up to the app
(Message.json() helps).

    from bakashrot import Client

    with Client.from_file("client.toml") as client:
        message_id = client.push({"temperature": 21.5}, "sensors")
        for message in client.get_messages("sensors", client.node, after=0):
            print(message.id, message.data)
        for message in client.follow("logs", "kitchen"):   # until stopped
            print(message.id, message.json())

Who the client is comes from its certificate, issued by the CA the server
trusts (bakashrot-cert): its name is its node, its roles say what it may
do. client.toml says where the server is and where the certificates are
(docs/client.md):

    server = "10.0.0.2:7000"
    ca = "ca.crt"
    certificate = "kitchen.crt"
    key = "kitchen.key"
    # crl = "ca.crl"

Errors are exceptions with a code (`error.code`, an ErrorCode, the same
numbers as the DLL's BakaShrot_GetLastError()):
  RefusedError         the server refused (codes 1-99), still connected
  ConnectionLostError  not connected, unreachable, the connection lost or
                       broken: connect() again (nothing reconnects by itself)
  AuthError            a certificate refused, either way, or none of its
                       roles allowed: fix the certificates, retrying won't help
  BakaShrotError       the rest: a bad argument, a file, the DLL itself
A push whose answer was lost (ConnectionLostError) may have been stored all
the same: pushed again, it's stored twice. Delivery is at least once.

The DLL holds a single connection per process: only one Client may be
connected at a time. Calls are serialized with a lock, so a Client can be
shared between threads, one request at a time.

The DLL is looked for, in order: the dll_path given, the BAKASHROT_DLL
environment variable, next to this file, then in the current directory.
"""

from __future__ import annotations

import ctypes
import enum
import json
import os
import sys
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Iterator, Optional, Union

__version__ = "0.2.0"

__all__ = [
    "Client", "Message", "MessagesPage", "NamesList",
    "BakaShrotError", "RefusedError", "ConnectionLostError", "AuthError", "ErrorCode",
    "MAX_GET_MESSAGES", "MAX_MESSAGE_SIZE",
]

# The protocol's: crates/bakashrot-proto/src/limits.rs.
MAX_GET_MESSAGES = 10000
MAX_MESSAGE_SIZE = 16 * 1024 * 1024 - 4096

DLL_NAME = "bakashrot.dll" if sys.platform == "win32" else "libbakashrot.so"


class ErrorCode(enum.IntEnum):
    """What failed: the protocol's codes (crates/bakashrot-proto/src/error.rs).
    1-99: refused by the server, 100+: the client's own."""
    NONE = 0
    # Refused by the server, the connection still open.
    NOT_ALLOWED = 1          # its roles don't allow it (or none is the server's, when connecting)
    UNKNOWN_NAME = 2         # a node this server has no message of
    NOT_FOUND = 3            # no such message or attachment
    NOT_READY = 4            # the attachment isn't on this server yet: retry later
    TOO_BIG = 5              # over a limit, or more than this server keeps
    NO_DEFAULT_TOPIC = 6     # protocol 6's, never sent any more
    INVALID_REQUEST = 7      # a request that doesn't fit (parts out of order...)
    DATA_MISMATCH = 8        # an upload that doesn't match its SHA-256
    QUERY_FAILED = 9         # the SQL failed
    SERVER_ERROR = 10        # the server's database failed: retry later
    # The client's own.
    NOT_CONNECTED = 100      # never connected, or closed or lost before
    CONNECT_FAILED = 101     # nothing answers at that host and port
    AUTH_REJECTED = 102      # the server refused this client's certificate
    SERVER_NOT_VERIFIED = 103  # this client refused the server's certificate
    CONNECTION_LOST = 104    # broke during a request (a push may still be stored)
    PROTOCOL_ERROR = 105     # an unexpected answer, the connection is closed
    INVALID_ARGUMENT = 106
    FILE_ERROR = 107
    ATTACHMENT_MISMATCH = 108  # a downloaded attachment that doesn't match its SHA-256
    ALREADY_CONNECTED = 109
    INTERNAL = 110           # a failure inside the DLL, or the DLL missing or too old
    VERSION_MISMATCH = 111   # the server speaks another protocol version

    @property
    def is_refusal(self) -> bool:
        return 1 <= self.value <= 99


def _error_code(value: int):
    """An ErrorCode, or the int itself if this module doesn't know it."""
    try:
        return ErrorCode(value)
    except ValueError:
        return value


class BakaShrotError(Exception):
    """Something failed: code (an ErrorCode) tells what, see ErrorCode."""

    def __init__(self, message: str, code: int = ErrorCode.INTERNAL):
        super().__init__(message)
        self.code = _error_code(code)


class RefusedError(BakaShrotError):
    """The server refused the request, the connection is still open. code
    says why (1-99, e.g. ErrorCode.NOT_FOUND), reason in the server's words."""

    def __init__(self, reason: str, code: int):
        super().__init__(reason or "Refused", code)
        self.reason = reason


class ConnectionLostError(BakaShrotError):
    """Not connected, or the connection failed or was closed (code:
    NOT_CONNECTED, CONNECT_FAILED, CONNECTION_LOST, PROTOCOL_ERROR):
    connect() again to go on."""


class AuthError(BakaShrotError):
    """Connecting was refused for good: the server refused this client's
    certificate (AUTH_REJECTED), this client the server's
    (SERVER_NOT_VERIFIED), none of its roles is allowed (NOT_ALLOWED), or
    another protocol version (VERSION_MISMATCH). Retrying won't help."""


@dataclass(frozen=True)
class Message:
    """A stored message. data is as stored: JSON or not (json() parses it).
    pushed_at: when it was pushed, to whichever server it was pushed to, in
    milliseconds since 1970-01-01 UTC (pushed is the same as a datetime).
    attachment_size: its attachment's, 0 for none; attachment_ready:
    whether all of it is on this server."""

    id: int
    topic: str
    node: str
    data: str
    pushed_at: int = 0
    attachment_size: int = 0
    attachment_ready: bool = False

    def json(self) -> Any:
        """The data parsed as JSON, raises ValueError if it isn't."""
        return json.loads(self.data)

    @property
    def pushed(self) -> datetime:
        """When it was pushed, as an aware datetime in UTC."""
        return datetime.fromtimestamp(self.pushed_at / 1000, tz=timezone.utc)


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
class NamesList:
    kind: str  # "topic" or "node"
    names: list
    truncated: bool  # True if they didn't all fit in one answer


def _name(value: str) -> bytes:
    if not isinstance(value, str):
        raise TypeError(f"a topic or node is a name, not {value!r}")
    return value.encode("utf-8")


def _find_dll(dll_path: Optional[str]) -> str:
    candidates = []
    if dll_path:
        candidates.append(dll_path)
    if os.environ.get("BAKASHROT_DLL"):
        candidates.append(os.environ["BAKASHROT_DLL"])
    candidates.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), DLL_NAME))
    candidates.append(os.path.join(os.getcwd(), DLL_NAME))
    for candidate in candidates:
        if os.path.isfile(candidate):
            return os.path.abspath(candidate)
    raise BakaShrotError(f"{DLL_NAME} not found, looked at: " + ", ".join(candidates))


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
        try:
            self.lib = ctypes.CDLL(path)
        except OSError as error:
            raise BakaShrotError(f"Failed to load {path}: {error}") from error
        self.path = path

        I, L, Q, P, S = ctypes.c_ssize_t, ctypes.c_int32, ctypes.c_int64, ctypes.c_char_p, ctypes.c_void_p
        signatures = {
            "BakaShrot_GetLastError": (L, []),
            "BakaShrot_GetRefusalReasonA": (I, [S, I]),
            "BakaShrot_SetCaCertificateA": (I, [P]),
            "BakaShrot_SetCertificateA": (I, [P]),
            "BakaShrot_SetPrivateKeyA": (I, [P]),
            "BakaShrot_SetCrlA": (I, [P]),
            "BakaShrot_ConnectA": (I, [P, L]),
            "BakaShrot_IsConnected": (I, []),
            "BakaShrot_Disconnect": (I, []),
            "BakaShrot_GetNodeA": (I, [S, I]),
            "BakaShrot_PushMessageToA": (Q, [P, P]),
            "BakaShrot_GetLatestMessageOfA": (I, [P, P]),
            "BakaShrot_GetMessagesA": (L, [P, P, Q, L]),
            "BakaShrot_GetMessageCount": (L, []),
            "BakaShrot_SelectMessage": (I, [L]),
            "BakaShrot_HasMoreMessages": (I, []),
            "BakaShrot_GetMessageId": (Q, []),
            "BakaShrot_GetMessagePushedAt": (Q, []),
            "BakaShrot_GetMessageAttachmentSize": (Q, []),
            "BakaShrot_IsMessageAttachmentReady": (I, []),
            "BakaShrot_GetMessageTopicA": (I, [S, I]),
            "BakaShrot_GetMessageNodeA": (I, [S, I]),
            "BakaShrot_GetMessageDataA": (I, [S, I]),
            "BakaShrot_ListTopics": (L, []),
            "BakaShrot_ListNodes": (L, []),
            "BakaShrot_GetNamesListA": (I, [S, I]),
            "BakaShrot_QueryA": (I, [P]),
            "BakaShrot_GetQueryResultA": (I, [S, I]),
            "BakaShrot_PushMessageWithFileA": (Q, [P, P, P]),
            "BakaShrot_PushMessageWithDataA": (Q, [P, P, P, Q]),
            "BakaShrot_SaveAttachmentA": (Q, [P, P, Q, P]),
            "BakaShrot_LoadAttachmentA": (Q, [P, P, Q]),
            "BakaShrot_GetAttachmentData": (Q, [S, Q]),
            "BakaShrot_FreeAttachmentData": (I, []),
        }
        for name, (restype, argtypes) in signatures.items():
            try:
                function = getattr(self.lib, name)
            except AttributeError as error:
                raise BakaShrotError(f"{path} has no {name}, is it an older build?", ErrorCode.INTERNAL) from error
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


def _split_server(server: str) -> tuple:
    """"host:port" (an IPv6 address in brackets) as (host, port)."""
    host, _, port = server.rpartition(":")
    if not host or not port.isdigit():
        raise BakaShrotError(f"server is host:port, not {server!r}", ErrorCode.INVALID_ARGUMENT)
    return host.strip("[]"), int(port)


class Client:
    """A connection to a BakaShrot server, through the DLL.

    server: "host:port". ca, certificate, key, crl (optional): PEM text, or
    the paths of files holding it: the CA's certificate (the server's must
    be issued by it), this client's certificate (its node, its roles) and
    its private key, the CA's CRL (servers it revokes are refused).
    """

    _connected_client: Optional["Client"] = None

    def __init__(self, server: str, ca: str, certificate: str, key: str, crl: Optional[str] = None,
                 dll_path: Optional[str] = None):
        self._dll = _Dll.get(dll_path)
        self._lock = threading.RLock()
        self.host, self.port = _split_server(server)
        self.ca = os.fspath(ca)
        self.certificate = os.fspath(certificate)
        self.key = os.fspath(key)
        self.crl = os.fspath(crl) if crl else None
        self.node = ""

    @classmethod
    def from_file(cls, path: Union[str, os.PathLike], dll_path: Optional[str] = None) -> "Client":
        """From a client.toml (server, ca, certificate, key, crl), the tools'
        too; paths in it are relative to its folder. Needs Python 3.11+
        (tomllib)."""
        import tomllib

        try:
            with open(path, "rb") as file:
                settings = tomllib.load(file)
        except OSError as error:
            raise BakaShrotError(f"Failed to open '{path}': {error}", ErrorCode.FILE_ERROR) from error
        except tomllib.TOMLDecodeError as error:
            raise BakaShrotError(f"'{path}': {error}", ErrorCode.INVALID_ARGUMENT) from error
        folder = os.path.dirname(os.path.abspath(path))

        def get(key, required=True):
            value = settings.get(key)
            if value is None and required:
                raise BakaShrotError(f"'{path}' has no {key}", ErrorCode.INVALID_ARGUMENT)
            if not isinstance(value, (str, type(None))):
                raise BakaShrotError(f"'{path}': {key} is a string", ErrorCode.INVALID_ARGUMENT)
            return value

        def file(key, required=True):
            value = get(key, required)
            return os.path.join(folder, value) if value else None

        return cls(get("server"), file("ca"), file("certificate"), file("key"), file("crl", False), dll_path)

    # --- Connection --------------------------------------------------------

    def connect(self) -> "Client":
        """Connects. Raises ConnectionLostError when the server can't be
        reached (CONNECT_FAILED), AuthError when a certificate is refused,
        BakaShrotError on a bad setting (INVALID_ARGUMENT, FILE_ERROR) or
        another Client holding the DLL's connection (ALREADY_CONNECTED)."""
        with self._lock:
            owner = Client._connected_client
            if owner is not None and owner is not self and owner.connected:
                raise BakaShrotError("The DLL holds one connection, another Client is connected", ErrorCode.ALREADY_CONNECTED)
            if self.connected:
                return self
            dll = self._dll
            for setter, value in ((dll.SetCaCertificateA, self.ca), (dll.SetCertificateA, self.certificate),
                                  (dll.SetPrivateKeyA, self.key), (dll.SetCrlA, self.crl or "")):
                if not setter(value.encode("utf-8")):
                    raise self._failed("Certificates")
            if not dll.ConnectA(self.host.encode("utf-8"), self.port):
                raise self._failed(f"Connect to {self.host}:{self.port}", connecting=True)
            self.node = dll.string(dll.GetNodeA)
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
            raise ConnectionLostError("Not connected", ErrorCode.NOT_CONNECTED)

    def _failed(self, what: str, connecting: bool = False) -> BakaShrotError:
        """The error for a failed call, by the DLL's BakaShrot_GetLastError()."""
        code = _error_code(self._dll.GetLastError())
        reason = self._dll.string(self._dll.GetRefusalReasonA)
        if connecting and code in (ErrorCode.AUTH_REJECTED, ErrorCode.SERVER_NOT_VERIFIED,
                                   ErrorCode.NOT_ALLOWED, ErrorCode.VERSION_MISMATCH):
            return AuthError(f"{what}: {reason}", code)
        if isinstance(code, int) and 1 <= int(code) <= 99:
            return RefusedError(reason, code)
        if not self._dll.IsConnected() and Client._connected_client is self:
            Client._connected_client = None
        name = code.name if isinstance(code, ErrorCode) else str(code)
        message = f"{what} ({name}): {reason or 'failed'}"
        if code in (ErrorCode.NOT_CONNECTED, ErrorCode.CONNECT_FAILED, ErrorCode.CONNECTION_LOST, ErrorCode.PROTOCOL_ERROR):
            return ConnectionLostError(message, code)
        return BakaShrotError(message, code if code else ErrorCode.INTERNAL)

    # --- Requests ----------------------------------------------------------

    def push(self, data: Any, topic: str,
             attachment: Union[None, bytes, bytearray, memoryview, str, os.PathLike] = None) -> int:
        """Pushes a message into topic, under the client's node. data is
        stored as is if it's a str (JSON or not), anything else is turned
        into JSON first. Returns its message id.

        attachment: bytes, or the path of a file, uploaded with it (1 byte
        and up, as much as the server's max_attachment_size takes): the
        message is only stored once all of it came."""
        if not isinstance(data, str):
            data = json.dumps(data, separators=(",", ":"), ensure_ascii=False)
        encoded = data.encode("utf-8")
        if len(encoded) > MAX_MESSAGE_SIZE:
            raise BakaShrotError(f"The message is too big: {len(encoded)} bytes, at most {MAX_MESSAGE_SIZE}", ErrorCode.INVALID_ARGUMENT)
        with self._lock:
            self._check_connected()
            if attachment is None:
                message_id = self._dll.PushMessageToA(_name(topic), encoded)
            elif isinstance(attachment, (bytes, bytearray, memoryview)):
                raw = bytes(attachment)
                message_id = self._dll.PushMessageWithDataA(_name(topic), encoded, raw, len(raw))
            else:
                path = os.fspath(attachment).encode("utf-8")
                message_id = self._dll.PushMessageWithFileA(_name(topic), encoded, path)
            if message_id < 1:
                raise self._failed("Push")
            return message_id

    def get_attachment(self, topic: str, node: str, message_id: int) -> bytes:
        """The attachment of a message, all of it in memory (save_attachment()
        for big ones), checked with its SHA-256. RefusedError if it has none
        (NOT_FOUND) or it isn't on this server yet (NOT_READY)."""
        with self._lock:
            self._check_connected()
            size = self._dll.LoadAttachmentA(_name(topic), _name(node), int(message_id))
            if size < 0:
                raise self._failed("Attachment")
            try:
                buffer = ctypes.create_string_buffer(size)
                self._dll.GetAttachmentData(buffer, size)
                return buffer.raw[:size]
            finally:
                self._dll.FreeAttachmentData()

    def save_attachment(self, topic: str, node: str, message_id: int, path: Union[str, os.PathLike]) -> int:
        """Saves the attachment of a message as path (replaced), a part at a
        time, checked with its SHA-256. Returns its size. A failed one
        leaves no file."""
        with self._lock:
            self._check_connected()
            size = self._dll.SaveAttachmentA(_name(topic), _name(node), int(message_id),
                                             os.fspath(path).encode("utf-8"))
            if size < 0:
                raise self._failed("Attachment")
            return size

    def _current(self) -> Message:
        dll = self._dll
        return Message(dll.GetMessageId(), dll.string(dll.GetMessageTopicA), dll.string(dll.GetMessageNodeA),
                       dll.string(dll.GetMessageDataA), dll.GetMessagePushedAt(), dll.GetMessageAttachmentSize(),
                       bool(dll.IsMessageAttachmentReady()))

    def latest(self, topic: str, node: str) -> Optional[Message]:
        """The latest message of topic/node, None if there's none yet."""
        with self._lock:
            self._check_connected()
            if not self._dll.GetLatestMessageOfA(_name(topic), _name(node)):
                error = self._failed("Latest message")
                if isinstance(error, RefusedError) and error.code == ErrorCode.NOT_FOUND:
                    return None
                raise error
            return self._current()

    def get_messages(self, topic: str, node: str, after: int = 0, limit: int = 1000) -> MessagesPage:
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
            count = dll.GetMessagesA(_name(topic), _name(node), after, limit)
            if count < 0:
                raise self._failed("Get messages")
            messages = []
            for index in range(count):
                dll.SelectMessage(index)
                messages.append(self._current())
            return MessagesPage(messages, bool(dll.HasMoreMessages()))

    def iter_messages(self, topic: str, node: str, after: int = 0, batch: int = 1000) -> Iterator[Message]:
        """Every message of topic/node after `after`, asking for batch at a
        time, until there are no more."""
        while True:
            page = self.get_messages(topic, node, after, batch)
            yield from page.messages
            if page.messages:
                after = page.last_id
            if not page.more:
                return

    def follow(self, topic: str, node: str, after: Union[int, str] = "latest",
               interval: float = 0.5, batch: int = 1000) -> Iterator[Message]:
        """Every message of topic/node after `after`, then new ones as they
        come, checking every `interval` seconds once caught up. Forever:
        stop iterating to stop. after="latest" starts with the next new one.
        Raises ConnectionLostError if the connection fails: nothing
        reconnects by itself, connect() again and follow from the last id."""
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

    def list_topics(self) -> NamesList:
        """The topics with messages that the client may push to or read (every one if it may query)."""
        return self._list(self._dll.ListTopics, "List topics")

    def list_nodes(self) -> NamesList:
        """Every node with messages."""
        return self._list(self._dll.ListNodes, "List nodes")

    def _list(self, function, what: str) -> NamesList:
        with self._lock:
            self._check_connected()
            if function() < 0:
                raise self._failed(what)
            parsed = json.loads(self._dll.string(self._dll.GetNamesListA))
        return NamesList(parsed["kind"], parsed["names"], bool(parsed["truncated"]))

    def query_raw(self, sql: str) -> str:
        """Runs one read-only SELECT on the server (a role with query =
        true), returns its result as the server's JSON text:
        {"columns": [...], "rows": [[...], ...]}, every value a str or null.
        JSON functions on message_data need "is_json = 1" in the WHERE (or
        CASE WHEN is_json THEN ... END) when some rows aren't JSON, or the
        query is refused: RefusedError "malformed JSON"."""
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
