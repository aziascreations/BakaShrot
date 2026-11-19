//! BakaShrot's C DLL (`bakashrot.dll`, `libbakashrot.so`): the
//! `BakaShrot_*` exports over [`bakashrot_client`], for C, PureBasic,
//! Python (ctypes) and anything that loads a DLL. `docs/client.md`
//! has the whole API; `bindings/c/bakashrot.h` is generated from this file.
//!
//! The conventions:
//!
//! - **Clients:** `BakaShrot_CreateClient()` makes one; its handle is the
//!   first argument of every other export. Each has its own connection,
//!   answers and errors; different clients can be used from different
//!   threads at once.
//! - **Enumerations** (`BakaShrot_EnumerateNames()`, `EnumerateQuery()`):
//!   an answer kept whole, read with `Next...()` (before the first item
//!   at first) and its getters, closed with `BakaShrot_CloseEnum()` or
//!   with their client by `BakaShrot_FreeClient()`. Their handles are
//!   numbered with the clients', so one is never the other's.
//! - **`A` and `W` exports:** strings in and out as UTF-8 (`char*`) or
//!   UTF-16 (`uint16_t*`, `wchar_t*` on Windows), null-terminated.
//! - **Strings out** are copied into the caller's buffer of `BufferSize`
//!   bytes: the getter returns the bytes needed, terminator included, and
//!   copies nothing if they don't fit (a null buffer asks for the size).
//! - **Failures:** 0 (or -1 where a count or an id is returned), then
//!   `BakaShrot_GetLastError(Client)` gives the code (1-99 a server's
//!   refusal, the connection still open; 100 and up the client's own) and
//!   `BakaShrot_GetRefusalReason()` why, in words. After `ConnectionLost`
//!   or `ProtocolError` the connection is closed: connect again.
//! - **Safety:** pointers are null or valid for what's said, strings
//!   terminated, buffers writable for their size. A bad handle fails
//!   (`InvalidArgument`). A panic inside is caught and reported as
//!   `Internal`; nothing allocated here is freed by the caller, or the
//!   other way.

#![allow(unsafe_code, non_snake_case, clippy::missing_safety_doc)]

mod enumerations;
pub use enumerations::*;
mod text;

use bakashrot_client::{Client, Error, Settings};
use bakashrot_proto::ErrorCode;
use bakashrot_proto::packets::{MessageEntry, NameKind, NamesList};
use std::collections::BTreeMap;
use std::ffi::{c_char, c_void};
use std::fs::File;
use std::io::Cursor;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use text::{Text, Utf8, Utf16};

type Result<T> = std::result::Result<T, Error>;

/// The clients and enumerations by handle. A call holds its client's
/// `Arc`, so a client freed during a call goes when the call ends.
static HANDLES: Mutex<Handles> = Mutex::new(Handles {
    next: 1,
    clients: BTreeMap::new(),
    enumerations: BTreeMap::new(),
});

struct Handles {
    /// The next handle, of a client or an enumeration: never reused.
    next: i64,
    clients: BTreeMap<i64, Shared>,
    /// Freed with their client. Only ever copied from, under this lock.
    enumerations: BTreeMap<i64, enumerations::Enumeration>,
}

impl Handles {
    fn take(&mut self) -> i64 {
        self.next += 1;
        self.next - 1
    }
}

type Shared = Arc<Mutex<State>>;

/// A client: its settings, its connection, the last answers.
struct State {
    ca: Option<String>,
    certificate: Option<String>,
    key: Option<String>,
    crl: Option<String>,
    client: Option<Client>,
    /// The last call's error code, 0 if it succeeded.
    last_error: u32,
    /// Why it failed.
    reason: String,
    /// The last `GetMessages` or `GetLatestMessageOf`.
    topic: String,
    node: String,
    messages: Vec<MessageEntry>,
    selected: usize,
    more: bool,
    /// The last `ListNames`, as JSON.
    names: String,
    /// The last `Query`'s result.
    query: String,
    /// The last `LoadAttachment`'s attachment.
    attachment: Vec<u8>,
}

impl State {
    const fn new() -> State {
        State {
            ca: None,
            certificate: None,
            key: None,
            crl: None,
            client: None,
            last_error: 0,
            reason: String::new(),
            topic: String::new(),
            node: String::new(),
            messages: Vec::new(),
            selected: 0,
            more: false,
            names: String::new(),
            query: String::new(),
            attachment: Vec::new(),
        }
    }

    fn fail(&mut self, error: Error) {
        self.last_error = error.code();
        self.reason = error.message().to_owned();
        let closed = [ErrorCode::ConnectionLost, ErrorCode::ProtocolError]
            .iter()
            .any(|code| code.code() == error.code());
        if closed {
            self.client = None;
        }
    }

    fn client(&mut self) -> Result<&mut Client> {
        self.client.as_mut().ok_or_else(|| {
            Error::new(
                ErrorCode::NotConnected,
                "not connected: BakaShrot_Connect() first",
            )
        })
    }

    /// The selected message of the last answer.
    fn message(&self) -> Option<&MessageEntry> {
        self.messages.get(self.selected)
    }

    /// Forgets the last answer's messages.
    fn clear_messages(&mut self, topic: &str, node: &str) {
        self.topic = topic.to_owned();
        self.node = node.to_owned();
        self.messages.clear();
        self.selected = 0;
        self.more = false;
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn find(client: i64) -> Option<Shared> {
    lock(&HANDLES).clients.get(&client).cloned()
}

/// Runs a call that can fail on a client: its last error reset, then set
/// if it fails (or panics). `failed` then, or for a bad handle.
fn call<T>(client: i64, failed: T, run: impl FnOnce(&mut State) -> Result<T>) -> T {
    let Some(shared) = find(client) else {
        return failed;
    };
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        let mut state = lock(&shared);
        state.last_error = 0;
        state.reason.clear();
        let outcome = run(&mut state);
        outcome.map_err(|error| state.fail(error))
    }));
    match outcome {
        Ok(Ok(value)) => value,
        Ok(Err(())) => failed,
        Err(_) => {
            lock(&shared).fail(Error::new(ErrorCode::Internal, "the DLL panicked"));
            failed
        }
    }
}

/// Runs a getter on a client, its last error unchanged. `default` for a
/// bad handle.
fn get<T>(client: i64, default: T, read: impl FnOnce(&mut State) -> T) -> T {
    let Some(shared) = find(client) else {
        return default;
    };
    catch_unwind(AssertUnwindSafe(|| read(&mut lock(&shared)))).unwrap_or(default)
}

/// Copies a string of a client's state into the caller's buffer.
unsafe fn get_text<T: Text>(
    client: i64,
    buffer: *mut T::Unit,
    size: isize,
    text: fn(&State) -> &str,
) -> isize {
    get(client, 0, |state| unsafe {
        text::copy::<T>(text(state), buffer, size)
    })
}

fn invalid(why: impl Into<String>) -> Error {
    Error::new(ErrorCode::InvalidArgument, why)
}

/// A string argument that must be there: `InvalidArgument` for a null
/// pointer.
unsafe fn required<T: Text>(pointer: *const T::Unit, what: &str) -> Result<String> {
    unsafe { text::read::<T>(pointer, what)? }
        .ok_or_else(|| invalid(format!("no {what} (a null pointer)")))
}

/// Settings change only before connecting.
fn not_connected(state: &State) -> Result<()> {
    match state.client {
        Some(_) => Err(Error::new(
            ErrorCode::AlreadyConnected,
            "already connected: disconnect first",
        )),
        None => Ok(()),
    }
}

fn bool_result(ok: bool) -> isize {
    isize::from(ok)
}

// --- Clients -----------------------------------------------------------------

/// Makes a client: its handle (1 and up, never reused), 0 if it failed.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_CreateClient() -> i64 {
    let made = catch_unwind(|| {
        let handles = &mut *lock(&HANDLES);
        let client = handles.take();
        handles
            .clients
            .insert(client, Arc::new(Mutex::new(State::new())));
        client
    });
    made.unwrap_or(0)
}

/// Frees a client and closes its connection (once a call on it in another
/// thread ends), its enumerations closed too: 1, or 0 if it wasn't one.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_FreeClient(client: i64) -> isize {
    let freed = catch_unwind(|| {
        let handles = &mut *lock(&HANDLES);
        handles
            .enumerations
            .retain(|_, enumeration| enumeration.client != client);
        handles.clients.remove(&client).is_some()
    });
    bool_result(freed.unwrap_or(false))
}

// --- Errors ------------------------------------------------------------------

/// Why the client's last call failed: a protocol error code (1-99 a
/// server's refusal, the connection still open; 100 and up the client's
/// own), 0 if it succeeded. Getters don't change it. `InvalidArgument` for
/// a bad handle.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_GetLastError(client: i64) -> i32 {
    get(client, ErrorCode::InvalidArgument.code() as i32, |state| {
        state.last_error as i32
    })
}

/// The client's reason, or why its handle is bad.
unsafe fn refusal_reason<T: Text>(client: i64, buffer: *mut T::Unit, size: isize) -> isize {
    match find(client) {
        Some(_) => unsafe { get_text::<T>(client, buffer, size, |state| &state.reason) },
        None => {
            let why = format!("no client {client}: never made, or freed");
            unsafe { text::copy::<T>(&why, buffer, size) }
        }
    }
}

/// Why the client's last call failed, in words: the server's reason for a
/// refusal, the client's otherwise. Empty if it succeeded.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetRefusalReasonA(
    client: i64,
    buffer: *mut c_char,
    size: isize,
) -> isize {
    unsafe { refusal_reason::<Utf8>(client, buffer.cast(), size) }
}

/// The same as `BakaShrot_GetRefusalReasonA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetRefusalReasonW(
    client: i64,
    buffer: *mut u16,
    size: isize,
) -> isize {
    unsafe { refusal_reason::<Utf16>(client, buffer, size) }
}

// --- Settings ----------------------------------------------------------------

/// A setting's PEM: the text itself if it starts with `-----BEGIN`, a
/// file's path otherwise. `None` (null or empty) only if `optional`.
fn pem_or_file(value: Option<String>, what: &str, optional: bool) -> Result<Option<String>> {
    let Some(value) = value.filter(|value| !value.trim().is_empty()) else {
        return match optional {
            true => Ok(None),
            false => Err(invalid(format!("no {what}"))),
        };
    };
    if value.trim_start().starts_with("-----BEGIN") {
        return Ok(Some(value));
    }
    std::fs::read_to_string(&value)
        .map(Some)
        .map_err(|error| Error::new(ErrorCode::FileError, format!("{what} '{value}': {error}")))
}

/// Sets one of the certificates' settings, before connecting.
unsafe fn set<T: Text>(
    client: i64,
    value: *const T::Unit,
    what: &str,
    optional: bool,
    slot: fn(&mut State) -> &mut Option<String>,
) -> isize {
    call(client, 0, |state| {
        not_connected(state)?;
        let value = unsafe { text::read::<T>(value, what)? };
        *slot(state) = pem_or_file(value, what, optional)?;
        Ok(1)
    })
}

/// Sets the CA's certificate, which the server's must be issued by: PEM
/// text, or the path of a file holding it. Before connecting.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_SetCaCertificateA(
    client: i64,
    certificate: *const c_char,
) -> isize {
    unsafe {
        set::<Utf8>(
            client,
            certificate.cast(),
            "CA certificate",
            false,
            |state| &mut state.ca,
        )
    }
}

/// The same as `BakaShrot_SetCaCertificateA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_SetCaCertificateW(
    client: i64,
    certificate: *const u16,
) -> isize {
    unsafe {
        set::<Utf16>(client, certificate, "CA certificate", false, |state| {
            &mut state.ca
        })
    }
}

/// Sets the client's certificate, which says its node and its roles: PEM
/// text, or the path of a file holding it. Before connecting.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_SetCertificateA(
    client: i64,
    certificate: *const c_char,
) -> isize {
    unsafe {
        set::<Utf8>(client, certificate.cast(), "certificate", false, |state| {
            &mut state.certificate
        })
    }
}

/// The same as `BakaShrot_SetCertificateA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_SetCertificateW(client: i64, certificate: *const u16) -> isize {
    unsafe {
        set::<Utf16>(client, certificate, "certificate", false, |state| {
            &mut state.certificate
        })
    }
}

/// Sets the client's private key, its certificate's: PEM text, or the path
/// of a file holding it. Before connecting.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_SetPrivateKeyA(client: i64, key: *const c_char) -> isize {
    unsafe {
        set::<Utf8>(client, key.cast(), "private key", false, |state| {
            &mut state.key
        })
    }
}

/// The same as `BakaShrot_SetPrivateKeyA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_SetPrivateKeyW(client: i64, key: *const u16) -> isize {
    unsafe { set::<Utf16>(client, key, "private key", false, |state| &mut state.key) }
}

/// Sets the CA's CRL, optional: servers it revokes are refused. PEM text,
/// or the path of a file holding it (one that isn't there is a
/// `FileError`); null or empty for none. Before connecting.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_SetCrlA(client: i64, crl: *const c_char) -> isize {
    unsafe { set::<Utf8>(client, crl.cast(), "CRL", true, |state| &mut state.crl) }
}

/// The same as `BakaShrot_SetCrlA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_SetCrlW(client: i64, crl: *const u16) -> isize {
    unsafe { set::<Utf16>(client, crl, "CRL", true, |state| &mut state.crl) }
}

// --- The connection ----------------------------------------------------------

unsafe fn connect<T: Text>(client: i64, host: *const T::Unit, port: i32) -> isize {
    call(client, 0, |state| {
        not_connected(state)?;
        let host = unsafe { required::<T>(host, "host")? };
        let port = u16::try_from(port)
            .ok()
            .filter(|port| *port != 0)
            .ok_or_else(|| invalid(format!("port {port}: 1 to 65535")))?;
        let missing = |what: &str, setter: &str| invalid(format!("no {what}: {setter}() first"));
        let settings = Settings {
            ca: state
                .ca
                .as_deref()
                .ok_or_else(|| missing("CA certificate", "BakaShrot_SetCaCertificate"))?,
            certificate: state
                .certificate
                .as_deref()
                .ok_or_else(|| missing("certificate", "BakaShrot_SetCertificate"))?,
            key: state
                .key
                .as_deref()
                .ok_or_else(|| missing("private key", "BakaShrot_SetPrivateKey"))?,
            crl: state.crl.as_deref(),
        };
        // An IPv6 address goes in brackets before its port.
        let address = match host.contains(':') && !host.starts_with('[') {
            true => format!("[{host}]:{port}"),
            false => format!("{host}:{port}"),
        };
        let client = Client::connect(&address, &settings)?;
        state.client = Some(client);
        Ok(1)
    })
}

/// Connects to the server at `host` (a name or an address) and `port`:
/// TLS with the certificates set, then the server says who this client is
/// (`BakaShrot_GetNode()`). Refused: the code says by whom (`AuthRejected`
/// the server refused the certificate, `ServerNotVerified` this client
/// refused the server's, `NotAllowed` none of its roles is the server's).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_ConnectA(client: i64, host: *const c_char, port: i32) -> isize {
    unsafe { connect::<Utf8>(client, host.cast(), port) }
}

/// The same as `BakaShrot_ConnectA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_ConnectW(client: i64, host: *const u16, port: i32) -> isize {
    unsafe { connect::<Utf16>(client, host, port) }
}

/// 1 while connected: notices when the server closed the connection
/// (forgotten then: connect again).
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_IsConnected(client: i64) -> isize {
    get(client, 0, |state| {
        let open = state.client.as_ref().is_some_and(Client::is_open);
        if !open {
            state.client = None;
        }
        bool_result(open)
    })
}

/// Closes the connection: 0 if there was none. The settings stay.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_Disconnect(client: i64) -> isize {
    get(client, 0, |state| {
        bool_result(state.client.take().is_some())
    })
}

fn node(state: &State) -> &str {
    state.client.as_ref().map_or("", Client::node)
}

/// The node this client is, as the server said when connecting: its
/// certificate's name. Empty when not connected.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetNodeA(
    client: i64,
    buffer: *mut c_char,
    size: isize,
) -> isize {
    unsafe { get_text::<Utf8>(client, buffer.cast(), size, node) }
}

/// The same as `BakaShrot_GetNodeA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetNodeW(client: i64, buffer: *mut u16, size: isize) -> isize {
    unsafe { get_text::<Utf16>(client, buffer, size, node) }
}

// --- Pushing -----------------------------------------------------------------

/// A push's topic and message, as arguments: a null message is an empty
/// one (PureBasic passes "" as null).
unsafe fn topic_and_data<T: Text>(
    topic: *const T::Unit,
    data: *const T::Unit,
) -> Result<(String, String)> {
    let topic = unsafe { required::<T>(topic, "topic")? };
    let data = unsafe { text::read::<T>(data, "the message")? }.unwrap_or_default();
    Ok((topic, data))
}

unsafe fn push_to<T: Text>(client: i64, topic: *const T::Unit, data: *const T::Unit) -> i64 {
    call(client, -1, |state| {
        let (topic, data) = unsafe { topic_and_data::<T>(topic, data)? };
        let id = state.client()?.push(&topic, &data)?;
        Ok(id as i64)
    })
}

/// Pushes a message (JSON or not) to `topic`, as this client's node: its
/// id (1 and up), -1 on failure. A push whose answer was lost
/// (`ConnectionLost`) may have been stored all the same.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_PushMessageToA(
    client: i64,
    topic: *const c_char,
    data: *const c_char,
) -> i64 {
    unsafe { push_to::<Utf8>(client, topic.cast(), data.cast()) }
}

/// The same as `BakaShrot_PushMessageToA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_PushMessageToW(
    client: i64,
    topic: *const u16,
    data: *const u16,
) -> i64 {
    unsafe { push_to::<Utf16>(client, topic, data) }
}

// --- Reading -----------------------------------------------------------------

/// A topic and node, as arguments.
unsafe fn topic_and_node<T: Text>(
    topic: *const T::Unit,
    node: *const T::Unit,
) -> Result<(String, String)> {
    let topic = unsafe { required::<T>(topic, "topic")? };
    let node = unsafe { required::<T>(node, "node")? };
    Ok((topic, node))
}

unsafe fn latest_of<T: Text>(client: i64, topic: *const T::Unit, node: *const T::Unit) -> isize {
    call(client, 0, |state| {
        let (topic, node) = unsafe { topic_and_node::<T>(topic, node)? };
        state.clear_messages(&topic, &node);
        let answer = state.client()?.get_messages(&topic, &node, None, 1)?;
        if answer.messages.is_empty() {
            return Err(Error::new(
                ErrorCode::NotFound,
                format!("no message in {topic}/{node} yet"),
            ));
        }
        state.messages = answer.messages;
        Ok(1)
    })
}

/// Gets the latest message of `topic` and `node`, then read with the
/// `BakaShrot_GetMessage*()` getters. `NotFound` if there's none yet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetLatestMessageOfA(
    client: i64,
    topic: *const c_char,
    node: *const c_char,
) -> isize {
    unsafe { latest_of::<Utf8>(client, topic.cast(), node.cast()) }
}

/// The same as `BakaShrot_GetLatestMessageOfA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetLatestMessageOfW(
    client: i64,
    topic: *const u16,
    node: *const u16,
) -> isize {
    unsafe { latest_of::<Utf16>(client, topic, node) }
}

unsafe fn messages<T: Text>(
    client: i64,
    topic: *const T::Unit,
    node: *const T::Unit,
    after: i64,
    limit: i32,
) -> i32 {
    call(client, -1, |state| {
        let (topic, node) = unsafe { topic_and_node::<T>(topic, node)? };
        state.clear_messages(&topic, &node);
        let after =
            u64::try_from(after).map_err(|_| invalid(format!("after {after}: 0 or more")))?;
        let limit = u32::try_from(limit).map_err(|_| invalid(format!("a limit of {limit}")))?;
        let answer = state
            .client()?
            .get_messages(&topic, &node, Some(after), limit)?;
        state.more = answer.more;
        state.messages = answer.messages;
        Ok(state.messages.len() as i32)
    })
}

/// Gets the messages of `topic` and `node` after id `after` (0 for the
/// first ones), in order: `limit` at most (1-10000), fewer past about
/// 1 MB. Returns how many came (none isn't a failure), -1 on failure. The
/// first is selected; `BakaShrot_SelectMessage()` selects the others,
/// `BakaShrot_HasMoreMessages()` says whether more follow the last one.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetMessagesA(
    client: i64,
    topic: *const c_char,
    node: *const c_char,
    after: i64,
    limit: i32,
) -> i32 {
    unsafe { messages::<Utf8>(client, topic.cast(), node.cast(), after, limit) }
}

/// The same as `BakaShrot_GetMessagesA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetMessagesW(
    client: i64,
    topic: *const u16,
    node: *const u16,
    after: i64,
    limit: i32,
) -> i32 {
    unsafe { messages::<Utf16>(client, topic, node, after, limit) }
}

/// How many messages the last `GetMessages` or `GetLatestMessageOf` got.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_GetMessageCount(client: i64) -> i32 {
    get(client, 0, |state| state.messages.len() as i32)
}

/// Selects the message at `index` (0 to the count - 1) for the getters: 0
/// if there's none there (`InvalidArgument`), the selection unchanged.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_SelectMessage(client: i64, index: i32) -> isize {
    call(client, 0, |state| {
        let index = usize::try_from(index)
            .ok()
            .filter(|index| *index < state.messages.len())
            .ok_or_else(|| invalid(format!("no message at {index}")))?;
        state.selected = index;
        Ok(1)
    })
}

/// 1 if more messages follow the last one the last `GetMessages` got: ask
/// again after its id.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_HasMoreMessages(client: i64) -> isize {
    get(client, 0, |state| bool_result(state.more))
}

/// The selected message's id, 0 if none.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_GetMessageId(client: i64) -> i64 {
    get(client, 0, |state| {
        state.message().map_or(0, |message| message.id as i64)
    })
}

/// When the selected message was pushed, by the server it was pushed to:
/// milliseconds since 1970-01-01 UTC, 0 if none.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_GetMessagePushedAt(client: i64) -> i64 {
    get(client, 0, |state| {
        state
            .message()
            .map_or(0, |message| message.pushed_at as i64)
    })
}

/// The selected message's attachment's size, 0 without one.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_GetMessageAttachmentSize(client: i64) -> i64 {
    get(client, 0, |state| {
        state
            .message()
            .and_then(|message| message.attachment.as_ref())
            .map_or(0, |attachment| attachment.size as i64)
    })
}

/// 1 if the selected message's attachment is all on this server (a
/// replicated one may still be on its way).
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_IsMessageAttachmentReady(client: i64) -> isize {
    get(client, 0, |state| {
        let attachment = state
            .message()
            .and_then(|message| message.attachment.as_ref());
        bool_result(attachment.is_some_and(|attachment| attachment.ready))
    })
}

/// The selected message's data, as pushed (JSON or not).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetMessageDataA(
    client: i64,
    buffer: *mut c_char,
    size: isize,
) -> isize {
    unsafe {
        get_text::<Utf8>(client, buffer.cast(), size, |state| {
            state.message().map_or("", |message| &message.data)
        })
    }
}

/// The same as `BakaShrot_GetMessageDataA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetMessageDataW(
    client: i64,
    buffer: *mut u16,
    size: isize,
) -> isize {
    unsafe {
        get_text::<Utf16>(client, buffer, size, |state| {
            state.message().map_or("", |message| &message.data)
        })
    }
}

/// The topic the last `GetMessages` or `GetLatestMessageOf` asked for.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetMessageTopicA(
    client: i64,
    buffer: *mut c_char,
    size: isize,
) -> isize {
    unsafe { get_text::<Utf8>(client, buffer.cast(), size, |state| &state.topic) }
}

/// The same as `BakaShrot_GetMessageTopicA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetMessageTopicW(
    client: i64,
    buffer: *mut u16,
    size: isize,
) -> isize {
    unsafe { get_text::<Utf16>(client, buffer, size, |state| &state.topic) }
}

/// The node the last `GetMessages` or `GetLatestMessageOf` asked for.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetMessageNodeA(
    client: i64,
    buffer: *mut c_char,
    size: isize,
) -> isize {
    unsafe { get_text::<Utf8>(client, buffer.cast(), size, |state| &state.node) }
}

/// The same as `BakaShrot_GetMessageNodeA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetMessageNodeW(
    client: i64,
    buffer: *mut u16,
    size: isize,
) -> isize {
    unsafe { get_text::<Utf16>(client, buffer, size, |state| &state.node) }
}

// --- Names -------------------------------------------------------------------

/// Asks for a list of names: `kind` 1 topics, 2 nodes, as on the wire;
/// the filters null for any.
unsafe fn fetch_names<T: Text>(
    state: &mut State,
    kind: i32,
    topics: *const T::Unit,
    nodes: *const T::Unit,
) -> Result<NamesList> {
    let kind = u8::try_from(kind)
        .ok()
        .and_then(|kind| NameKind::try_from(kind).ok())
        .ok_or_else(|| invalid(format!("a kind of {kind}: 1 (topics) or 2 (nodes)")))?;
    let topics = unsafe { text::read::<T>(topics, "topics")? };
    let nodes = unsafe { text::read::<T>(nodes, "nodes")? };
    state
        .client()?
        .list_names(kind, topics.as_deref(), nodes.as_deref())
}

unsafe fn list<T: Text>(
    client: i64,
    kind: i32,
    topics: *const T::Unit,
    nodes: *const T::Unit,
) -> i32 {
    call(client, -1, |state| {
        state.names.clear();
        let list = unsafe { fetch_names::<T>(state, kind, topics, nodes)? };
        let kind = match list.kind {
            NameKind::Topic => "topic",
            NameKind::Node => "node",
        };
        let count = list.names.len() as i32;
        state.names = serde_json::json!({
            "kind": kind,
            "truncated": list.truncated,
            "names": list.names,
        })
        .to_string();
        Ok(count)
    })
}

/// Lists topics (`kind` 1) or nodes (`kind` 2): the topics with messages
/// that this client may push to or read (every one if its roles have
/// `list_topics` or `query`), the nodes with messages in the topics it may
/// read (every one with `list_nodes` or `query`). Only those of the topic
/// and node pairs that `topics` and `nodes` match: each a name or a
/// pattern (`sensors.*`), null for any. Every topic: 1, null, null; the
/// topics a node pushed to: 1, null, the node; the nodes that pushed to a
/// topic: 2, the topic, null. How many, -1 on failure. Then
/// `BakaShrot_GetNamesListAsJson()`, or `BakaShrot_EnumerateNames()`
/// instead.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_ListNamesA(
    client: i64,
    kind: i32,
    topics: *const c_char,
    nodes: *const c_char,
) -> i32 {
    unsafe { list::<Utf8>(client, kind, topics.cast(), nodes.cast()) }
}

/// The same as `BakaShrot_ListNamesA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_ListNamesW(
    client: i64,
    kind: i32,
    topics: *const u16,
    nodes: *const u16,
) -> i32 {
    unsafe { list::<Utf16>(client, kind, topics, nodes) }
}

/// The last list, as JSON:
/// `{"kind":"topic","truncated":false,"names":["logs",...]}`, `truncated`
/// if some didn't fit.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetNamesListAsJsonA(
    client: i64,
    buffer: *mut c_char,
    size: isize,
) -> isize {
    unsafe { get_text::<Utf8>(client, buffer.cast(), size, |state| &state.names) }
}

/// The same as `BakaShrot_GetNamesListAsJsonA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetNamesListAsJsonW(
    client: i64,
    buffer: *mut u16,
    size: isize,
) -> isize {
    unsafe { get_text::<Utf16>(client, buffer, size, |state| &state.names) }
}

// --- Queries -----------------------------------------------------------------

/// Runs a query: the server's JSON.
unsafe fn fetch_query<T: Text>(state: &mut State, sql: *const T::Unit) -> Result<String> {
    let sql = unsafe { required::<T>(sql, "query")? };
    state.client()?.query(&sql)
}

unsafe fn query<T: Text>(client: i64, sql: *const T::Unit) -> isize {
    call(client, 0, |state| {
        state.query.clear();
        state.query = unsafe { fetch_query::<T>(state, sql)? };
        Ok(1)
    })
}

/// Runs read-only SQL on the server (one SELECT or WITH), if this client
/// may query. Then `BakaShrot_GetQueryResultAsJson()`, or
/// `BakaShrot_EnumerateQuery()` instead.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_QueryA(client: i64, sql: *const c_char) -> isize {
    unsafe { query::<Utf8>(client, sql.cast()) }
}

/// The same as `BakaShrot_QueryA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_QueryW(client: i64, sql: *const u16) -> isize {
    unsafe { query::<Utf16>(client, sql) }
}

/// The last query's result, as JSON:
/// `{"columns":[...],"rows":[[...],...]}`, every value a string or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetQueryResultAsJsonA(
    client: i64,
    buffer: *mut c_char,
    size: isize,
) -> isize {
    unsafe { get_text::<Utf8>(client, buffer.cast(), size, |state| &state.query) }
}

/// The same as `BakaShrot_GetQueryResultAsJsonA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetQueryResultAsJsonW(
    client: i64,
    buffer: *mut u16,
    size: isize,
) -> isize {
    unsafe { get_text::<Utf16>(client, buffer, size, |state| &state.query) }
}

// --- Attachments -------------------------------------------------------------

/// A message id, as arguments.
fn message_id(id: i64) -> Result<u64> {
    u64::try_from(id).map_err(|_| invalid(format!("message {id}")))
}

unsafe fn push_with_file<T: Text>(
    client: i64,
    topic: *const T::Unit,
    data: *const T::Unit,
    path: *const T::Unit,
) -> i64 {
    call(client, -1, |state| {
        let (topic, data) = unsafe { topic_and_data::<T>(topic, data)? };
        let path = unsafe { required::<T>(path, "file")? };
        let mut file = File::open(&path)
            .map_err(|error| Error::new(ErrorCode::FileError, format!("{path}: {error}")))?;
        let id = state
            .client()?
            .push_with_attachment(&topic, &data, &mut file)?;
        Ok(id as i64)
    })
}

/// Pushes a message with the file at `FilePath` as its attachment (1 byte
/// to 1 TiB, the server may take less: `TooBig`): uploaded with it, the
/// message stored once all of it came. Its id, -1 on failure. The file is
/// read twice (its SHA-256 first): one changed in between is refused
/// (`DataMismatch`).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_PushMessageWithFileA(
    client: i64,
    topic: *const c_char,
    data: *const c_char,
    file_path: *const c_char,
) -> i64 {
    unsafe { push_with_file::<Utf8>(client, topic.cast(), data.cast(), file_path.cast()) }
}

/// The same as `BakaShrot_PushMessageWithFileA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_PushMessageWithFileW(
    client: i64,
    topic: *const u16,
    data: *const u16,
    file_path: *const u16,
) -> i64 {
    unsafe { push_with_file::<Utf16>(client, topic, data, file_path) }
}

unsafe fn push_with_data<T: Text>(
    client: i64,
    topic: *const T::Unit,
    data: *const T::Unit,
    attachment: *const c_void,
    size: i64,
) -> i64 {
    call(client, -1, |state| {
        let (topic, data) = unsafe { topic_and_data::<T>(topic, data)? };
        if attachment.is_null() {
            return Err(invalid("no attachment (a null pointer)"));
        }
        let size = usize::try_from(size)
            .ok()
            .filter(|size| *size > 0)
            .ok_or_else(|| invalid(format!("an attachment of {size} bytes")))?;
        let bytes = unsafe { std::slice::from_raw_parts(attachment.cast::<u8>(), size) };
        let id = state
            .client()?
            .push_with_attachment(&topic, &data, &mut Cursor::new(bytes))?;
        Ok(id as i64)
    })
}

/// Pushes a message with the `Size` bytes at `Data` as its attachment, as
/// `BakaShrot_PushMessageWithFileA` does.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_PushMessageWithDataA(
    client: i64,
    topic: *const c_char,
    data: *const c_char,
    attachment: *const c_void,
    size: i64,
) -> i64 {
    unsafe { push_with_data::<Utf8>(client, topic.cast(), data.cast(), attachment, size) }
}

/// The same as `BakaShrot_PushMessageWithDataA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_PushMessageWithDataW(
    client: i64,
    topic: *const u16,
    data: *const u16,
    attachment: *const c_void,
    size: i64,
) -> i64 {
    unsafe { push_with_data::<Utf16>(client, topic, data, attachment, size) }
}

unsafe fn save<T: Text>(
    client: i64,
    topic: *const T::Unit,
    node: *const T::Unit,
    id: i64,
    path: *const T::Unit,
) -> i64 {
    call(client, -1, |state| {
        let (topic, node) = unsafe { topic_and_node::<T>(topic, node)? };
        let path = unsafe { required::<T>(path, "file")? };
        let size =
            state
                .client()?
                .save_attachment(&topic, &node, message_id(id)?, Path::new(&path))?;
        Ok(size as i64)
    })
}

/// Saves the attachment of `Topic`, `Node`'s message `MessageId` as the
/// file at `FilePath` (replaced), read a part at a time and checked with
/// its SHA-256: its size, -1 on failure (`NotFound` without one,
/// `NotReady` if it isn't on this server yet, `AttachmentMismatch`). A
/// failed one leaves no file.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_SaveAttachmentA(
    client: i64,
    topic: *const c_char,
    node: *const c_char,
    message_id: i64,
    file_path: *const c_char,
) -> i64 {
    unsafe {
        save::<Utf8>(
            client,
            topic.cast(),
            node.cast(),
            message_id,
            file_path.cast(),
        )
    }
}

/// The same as `BakaShrot_SaveAttachmentA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_SaveAttachmentW(
    client: i64,
    topic: *const u16,
    node: *const u16,
    message_id: i64,
    file_path: *const u16,
) -> i64 {
    unsafe { save::<Utf16>(client, topic, node, message_id, file_path) }
}

unsafe fn load<T: Text>(client: i64, topic: *const T::Unit, node: *const T::Unit, id: i64) -> i64 {
    call(client, -1, |state| {
        state.attachment = Vec::new();
        let (topic, node) = unsafe { topic_and_node::<T>(topic, node)? };
        let mut attachment = Vec::new();
        let size =
            state
                .client()?
                .get_attachment(&topic, &node, message_id(id)?, &mut attachment)?;
        state.attachment = attachment;
        Ok(size as i64)
    })
}

/// Reads the attachment of `Topic`, `Node`'s message `MessageId` into
/// memory, checked with its SHA-256 (`BakaShrot_SaveAttachmentA` for big
/// ones): its size, -1 on failure. Then `BakaShrot_GetAttachmentData()`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_LoadAttachmentA(
    client: i64,
    topic: *const c_char,
    node: *const c_char,
    message_id: i64,
) -> i64 {
    unsafe { load::<Utf8>(client, topic.cast(), node.cast(), message_id) }
}

/// The same as `BakaShrot_LoadAttachmentA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_LoadAttachmentW(
    client: i64,
    topic: *const u16,
    node: *const u16,
    message_id: i64,
) -> i64 {
    unsafe { load::<Utf16>(client, topic, node, message_id) }
}

/// Copies what the last `BakaShrot_LoadAttachment()` read into `Buffer`, if
/// `BufferSize` is enough: returns its size (0 if none), copies nothing if
/// it doesn't fit (a null `Buffer` asks for the size).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetAttachmentData(
    client: i64,
    buffer: *mut c_void,
    buffer_size: i64,
) -> i64 {
    get(client, 0, |state| {
        let data = &state.attachment;
        if !buffer.is_null() && usize::try_from(buffer_size).is_ok_and(|size| size >= data.len()) {
            unsafe { std::ptr::copy_nonoverlapping(data.as_ptr(), buffer.cast(), data.len()) };
        }
        data.len() as i64
    })
}

/// Frees what `BakaShrot_LoadAttachment()` read: 1.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_FreeAttachmentData(client: i64) -> isize {
    get(client, 0, |state| {
        state.attachment = Vec::new();
        1
    })
}
