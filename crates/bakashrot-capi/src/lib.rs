//! BakaShrot's C DLL (`bakashrot.dll`, `libbakashrot.so`): the old
//! `BakaShrot_*` exports over [`bakashrot_client`], for C, PureBasic,
//! Python (ctypes) and anything that loads a DLL. `docs/client.md`
//! has the whole API; `bindings/c/bakashrot.h` is generated from this file.
//!
//! The conventions, the old DLL's:
//!
//! - **One connection per process:** set the certificates, connect, send
//!   requests, one at a time (calls from several threads wait for each
//!   other).
//! - **`A` and `W` exports:** strings in and out as UTF-8 (`char*`) or
//!   UTF-16 (`uint16_t*`, `wchar_t*` on Windows), null-terminated.
//! - **Strings out** are copied into the caller's buffer of `BufferSize`
//!   bytes: the getter returns the bytes needed, terminator included, and
//!   copies nothing if they don't fit (a null buffer asks for the size).
//! - **Failures:** 0 (or -1 where a count or an id is returned), then
//!   `BakaShrot_GetLastError()` gives the code (1-99 a server's refusal, the
//!   connection still open; 100 and up the client's own) and
//!   `BakaShrot_GetRefusalReason()` why, in words. After `ConnectionLost`
//!   or `ProtocolError` the connection is closed: connect again.
//! - **Safety:** pointers are null or valid for what's said, strings
//!   terminated, buffers writable for their size. A panic inside is caught
//!   and reported as `Internal`; nothing allocated here is freed by the
//!   caller, or the other way.

#![allow(unsafe_code, non_snake_case, clippy::missing_safety_doc)]

mod text;

use bakashrot_client::{Client, Error, Settings};
use bakashrot_proto::ErrorCode;
use bakashrot_proto::packets::{MessageEntry, NameKind};
use std::ffi::{c_char, c_void};
use std::fs::File;
use std::io::Cursor;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::sync::{Mutex, MutexGuard, PoisonError};
use text::{Text, Utf8, Utf16};

type Result<T> = std::result::Result<T, Error>;

/// Everything the DLL holds: its one connection, its settings, the last
/// answers.
static STATE: Mutex<State> = Mutex::new(State::new());

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
    /// The last `ListTopics` / `ListNodes`, as JSON.
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

fn state() -> MutexGuard<'static, State> {
    STATE.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Runs a call that can fail: the last error reset, then set if it fails
/// (or panics), `failed` returned then.
fn call<T>(failed: T, run: impl FnOnce(&mut State) -> Result<T>) -> T {
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        let mut state = state();
        state.last_error = 0;
        state.reason.clear();
        let outcome = run(&mut state);
        outcome.map_err(|error| state.fail(error))
    }));
    match outcome {
        Ok(Ok(value)) => value,
        Ok(Err(())) => failed,
        Err(_) => {
            state().fail(Error::new(ErrorCode::Internal, "the DLL panicked"));
            failed
        }
    }
}

/// Runs a getter: the last error stays as it is.
fn get<T>(default: T, read: impl FnOnce(&State) -> T) -> T {
    catch_unwind(AssertUnwindSafe(|| read(&state()))).unwrap_or(default)
}

/// Copies a string of the state into the caller's buffer.
unsafe fn get_text<T: Text>(buffer: *mut T::Unit, size: isize, text: fn(&State) -> &str) -> isize {
    get(0, |state| unsafe {
        text::copy::<T>(text(state), buffer, size)
    })
}

fn invalid(why: impl Into<String>) -> Error {
    Error::new(ErrorCode::InvalidArgument, why)
}

fn required(value: Option<String>, what: &str) -> Result<String> {
    value.ok_or_else(|| invalid(format!("no {what} (a null pointer)")))
}

fn bool_result(ok: bool) -> isize {
    isize::from(ok)
}

// --- Errors ------------------------------------------------------------------

/// Why the last call failed: a protocol error code (1-99 a server's
/// refusal, the connection still open; 100 and up the client's own), 0 if
/// it succeeded. Getters don't change it.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_GetLastError() -> i32 {
    get(ErrorCode::Internal.code() as i32, |state| {
        state.last_error as i32
    })
}

/// Why the last call failed, in words: the server's reason for a refusal,
/// the client's otherwise. Empty if it succeeded.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetRefusalReasonA(buffer: *mut c_char, size: isize) -> isize {
    unsafe { get_text::<Utf8>(buffer.cast(), size, |state| &state.reason) }
}

/// The same as `BakaShrot_GetRefusalReasonA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetRefusalReasonW(buffer: *mut u16, size: isize) -> isize {
    unsafe { get_text::<Utf16>(buffer, size, |state| &state.reason) }
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
    value: *const T::Unit,
    what: &str,
    optional: bool,
    slot: fn(&mut State) -> &mut Option<String>,
) -> isize {
    call(0, |state| {
        if state.client.is_some() {
            return Err(Error::new(
                ErrorCode::AlreadyConnected,
                "already connected: disconnect first",
            ));
        }
        let value = unsafe { text::read::<T>(value, what)? };
        *slot(state) = pem_or_file(value, what, optional)?;
        Ok(1)
    })
}

/// Sets the CA's certificate, which the server's must be issued by: PEM
/// text, or the path of a file holding it. Before connecting.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_SetCaCertificateA(certificate: *const c_char) -> isize {
    unsafe {
        set::<Utf8>(certificate.cast(), "CA certificate", false, |state| {
            &mut state.ca
        })
    }
}

/// The same as `BakaShrot_SetCaCertificateA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_SetCaCertificateW(certificate: *const u16) -> isize {
    unsafe { set::<Utf16>(certificate, "CA certificate", false, |state| &mut state.ca) }
}

/// Sets this client's certificate, which says its node and its roles: PEM
/// text, or the path of a file holding it. Before connecting.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_SetCertificateA(certificate: *const c_char) -> isize {
    unsafe {
        set::<Utf8>(certificate.cast(), "certificate", false, |state| {
            &mut state.certificate
        })
    }
}

/// The same as `BakaShrot_SetCertificateA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_SetCertificateW(certificate: *const u16) -> isize {
    unsafe {
        set::<Utf16>(certificate, "certificate", false, |state| {
            &mut state.certificate
        })
    }
}

/// Sets this client's private key, its certificate's: PEM text, or the path
/// of a file holding it. Before connecting.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_SetPrivateKeyA(key: *const c_char) -> isize {
    unsafe { set::<Utf8>(key.cast(), "private key", false, |state| &mut state.key) }
}

/// The same as `BakaShrot_SetPrivateKeyA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_SetPrivateKeyW(key: *const u16) -> isize {
    unsafe { set::<Utf16>(key, "private key", false, |state| &mut state.key) }
}

/// Sets the CA's CRL, optional: servers it revokes are refused. PEM text,
/// or the path of a file holding it (one that isn't there is a
/// `FileError`); null or empty for none. Before connecting.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_SetCrlA(crl: *const c_char) -> isize {
    unsafe { set::<Utf8>(crl.cast(), "CRL", true, |state| &mut state.crl) }
}

/// The same as `BakaShrot_SetCrlA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_SetCrlW(crl: *const u16) -> isize {
    unsafe { set::<Utf16>(crl, "CRL", true, |state| &mut state.crl) }
}

// --- The connection ----------------------------------------------------------

unsafe fn connect<T: Text>(host: *const T::Unit, port: i32) -> isize {
    call(0, |state| {
        if state.client.is_some() {
            return Err(Error::new(
                ErrorCode::AlreadyConnected,
                "already connected: disconnect first",
            ));
        }
        let host = required(unsafe { text::read::<T>(host, "host")? }, "host")?;
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
pub unsafe extern "C" fn BakaShrot_ConnectA(host: *const c_char, port: i32) -> isize {
    unsafe { connect::<Utf8>(host.cast(), port) }
}

/// The same as `BakaShrot_ConnectA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_ConnectW(host: *const u16, port: i32) -> isize {
    unsafe { connect::<Utf16>(host, port) }
}

/// 1 while connected: notices when the server closed the connection
/// (forgotten then: connect again).
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_IsConnected() -> isize {
    let open = catch_unwind(AssertUnwindSafe(|| {
        let mut state = state();
        let open = state.client.as_ref().is_some_and(Client::is_open);
        if !open {
            state.client = None;
        }
        open
    }));
    bool_result(open.unwrap_or(false))
}

/// Closes the connection: 0 if there was none. The settings stay.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_Disconnect() -> isize {
    let closed = catch_unwind(AssertUnwindSafe(|| state().client.take().is_some()));
    bool_result(closed.unwrap_or(false))
}

/// The node this client is, as the server said when connecting: its
/// certificate's name. Empty when not connected.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetNodeA(buffer: *mut c_char, size: isize) -> isize {
    unsafe {
        get_text::<Utf8>(buffer.cast(), size, |state| {
            state.client.as_ref().map_or("", Client::node)
        })
    }
}

/// The same as `BakaShrot_GetNodeA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetNodeW(buffer: *mut u16, size: isize) -> isize {
    unsafe {
        get_text::<Utf16>(buffer, size, |state| {
            state.client.as_ref().map_or("", Client::node)
        })
    }
}

// --- Pushing -----------------------------------------------------------------

/// A push's topic and message, as arguments: a null message is an empty
/// one (PureBasic passes "" as null).
unsafe fn topic_and_data<T: Text>(
    topic: *const T::Unit,
    data: *const T::Unit,
) -> Result<(String, String)> {
    let topic = required(unsafe { text::read::<T>(topic, "topic")? }, "topic")?;
    let data = unsafe { text::read::<T>(data, "the message")? }.unwrap_or_default();
    Ok((topic, data))
}

unsafe fn push_to<T: Text>(topic: *const T::Unit, data: *const T::Unit) -> i64 {
    call(-1, |state| {
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
    topic: *const c_char,
    data: *const c_char,
) -> i64 {
    unsafe { push_to::<Utf8>(topic.cast(), data.cast()) }
}

/// The same as `BakaShrot_PushMessageToA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_PushMessageToW(topic: *const u16, data: *const u16) -> i64 {
    unsafe { push_to::<Utf16>(topic, data) }
}

// --- Reading -----------------------------------------------------------------

/// A topic and node, as arguments.
unsafe fn topic_and_node<T: Text>(
    topic: *const T::Unit,
    node: *const T::Unit,
) -> Result<(String, String)> {
    let topic = required(unsafe { text::read::<T>(topic, "topic")? }, "topic")?;
    let node = required(unsafe { text::read::<T>(node, "node")? }, "node")?;
    Ok((topic, node))
}

unsafe fn latest_of<T: Text>(topic: *const T::Unit, node: *const T::Unit) -> isize {
    call(0, |state| {
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
    topic: *const c_char,
    node: *const c_char,
) -> isize {
    unsafe { latest_of::<Utf8>(topic.cast(), node.cast()) }
}

/// The same as `BakaShrot_GetLatestMessageOfA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetLatestMessageOfW(
    topic: *const u16,
    node: *const u16,
) -> isize {
    unsafe { latest_of::<Utf16>(topic, node) }
}

unsafe fn messages<T: Text>(
    topic: *const T::Unit,
    node: *const T::Unit,
    after: i64,
    limit: i32,
) -> i32 {
    call(-1, |state| {
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
    topic: *const c_char,
    node: *const c_char,
    after: i64,
    limit: i32,
) -> i32 {
    unsafe { messages::<Utf8>(topic.cast(), node.cast(), after, limit) }
}

/// The same as `BakaShrot_GetMessagesA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetMessagesW(
    topic: *const u16,
    node: *const u16,
    after: i64,
    limit: i32,
) -> i32 {
    unsafe { messages::<Utf16>(topic, node, after, limit) }
}

/// How many messages the last `GetMessages` or `GetLatestMessageOf` got.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_GetMessageCount() -> i32 {
    get(0, |state| state.messages.len() as i32)
}

/// Selects the message at `index` (0 to the count - 1) for the getters: 0
/// if there's none there (`InvalidArgument`), the selection unchanged.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_SelectMessage(index: i32) -> isize {
    call(0, |state| {
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
pub extern "C" fn BakaShrot_HasMoreMessages() -> isize {
    get(0, |state| bool_result(state.more))
}

/// The selected message's id, 0 if none.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_GetMessageId() -> i64 {
    get(0, |state| {
        state.message().map_or(0, |message| message.id as i64)
    })
}

/// When the selected message was pushed, by the server it was pushed to:
/// milliseconds since 1970-01-01 UTC, 0 if none.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_GetMessagePushedAt() -> i64 {
    get(0, |state| {
        state
            .message()
            .map_or(0, |message| message.pushed_at as i64)
    })
}

/// The selected message's attachment's size, 0 without one.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_GetMessageAttachmentSize() -> i64 {
    get(0, |state| {
        state
            .message()
            .and_then(|message| message.attachment.as_ref())
            .map_or(0, |attachment| attachment.size as i64)
    })
}

/// 1 if the selected message's attachment is all on this server (a
/// replicated one may still be on its way).
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_IsMessageAttachmentReady() -> isize {
    get(0, |state| {
        let attachment = state
            .message()
            .and_then(|message| message.attachment.as_ref());
        bool_result(attachment.is_some_and(|attachment| attachment.ready))
    })
}

/// The selected message's data, as pushed (JSON or not).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetMessageDataA(buffer: *mut c_char, size: isize) -> isize {
    unsafe {
        get_text::<Utf8>(buffer.cast(), size, |state| {
            state.message().map_or("", |message| &message.data)
        })
    }
}

/// The same as `BakaShrot_GetMessageDataA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetMessageDataW(buffer: *mut u16, size: isize) -> isize {
    unsafe {
        get_text::<Utf16>(buffer, size, |state| {
            state.message().map_or("", |message| &message.data)
        })
    }
}

/// The topic the last `GetMessages` or `GetLatestMessageOf` asked for.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetMessageTopicA(buffer: *mut c_char, size: isize) -> isize {
    unsafe { get_text::<Utf8>(buffer.cast(), size, |state| &state.topic) }
}

/// The same as `BakaShrot_GetMessageTopicA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetMessageTopicW(buffer: *mut u16, size: isize) -> isize {
    unsafe { get_text::<Utf16>(buffer, size, |state| &state.topic) }
}

/// The node the last `GetMessages` or `GetLatestMessageOf` asked for.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetMessageNodeA(buffer: *mut c_char, size: isize) -> isize {
    unsafe { get_text::<Utf8>(buffer.cast(), size, |state| &state.node) }
}

/// The same as `BakaShrot_GetMessageNodeA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetMessageNodeW(buffer: *mut u16, size: isize) -> isize {
    unsafe { get_text::<Utf16>(buffer, size, |state| &state.node) }
}

// --- Names -------------------------------------------------------------------

fn list(kind: NameKind) -> i32 {
    call(-1, |state| {
        state.names.clear();
        let list = state.client()?.list_names(kind)?;
        let kind = match kind {
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

/// Lists the topics with messages that this client may push to or read
/// (every one if its roles have `list_topics` or `query`): how many, -1 on
/// failure. Then `BakaShrot_GetNamesList()`.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_ListTopics() -> i32 {
    list(NameKind::Topic)
}

/// Lists the nodes with messages in the topics this client may read (every
/// one if its roles have `list_nodes` or `query`): how many, -1 on failure. Then
/// `BakaShrot_GetNamesList()`.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_ListNodes() -> i32 {
    list(NameKind::Node)
}

/// The last list, as JSON:
/// `{"kind":"topic","truncated":false,"names":["logs",...]}`, `truncated`
/// if some didn't fit.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetNamesListA(buffer: *mut c_char, size: isize) -> isize {
    unsafe { get_text::<Utf8>(buffer.cast(), size, |state| &state.names) }
}

/// The same as `BakaShrot_GetNamesListA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetNamesListW(buffer: *mut u16, size: isize) -> isize {
    unsafe { get_text::<Utf16>(buffer, size, |state| &state.names) }
}

// --- Queries -----------------------------------------------------------------

unsafe fn query<T: Text>(sql: *const T::Unit) -> isize {
    call(0, |state| {
        state.query.clear();
        let sql = required(unsafe { text::read::<T>(sql, "query")? }, "query")?;
        state.query = state.client()?.query(&sql)?;
        Ok(1)
    })
}

/// Runs read-only SQL on the server (one SELECT or WITH), if this client
/// may query. Then `BakaShrot_GetQueryResult()`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_QueryA(sql: *const c_char) -> isize {
    unsafe { query::<Utf8>(sql.cast()) }
}

/// The same as `BakaShrot_QueryA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_QueryW(sql: *const u16) -> isize {
    unsafe { query::<Utf16>(sql) }
}

/// The last query's result, as JSON:
/// `{"columns":[...],"rows":[[...],...]}`, every value a string or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetQueryResultA(buffer: *mut c_char, size: isize) -> isize {
    unsafe { get_text::<Utf8>(buffer.cast(), size, |state| &state.query) }
}

/// The same as `BakaShrot_GetQueryResultA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetQueryResultW(buffer: *mut u16, size: isize) -> isize {
    unsafe { get_text::<Utf16>(buffer, size, |state| &state.query) }
}

// --- Attachments -------------------------------------------------------------

/// A message id, as arguments.
fn message_id(id: i64) -> Result<u64> {
    u64::try_from(id).map_err(|_| invalid(format!("message {id}")))
}

unsafe fn push_with_file<T: Text>(
    topic: *const T::Unit,
    data: *const T::Unit,
    path: *const T::Unit,
) -> i64 {
    call(-1, |state| {
        let (topic, data) = unsafe { topic_and_data::<T>(topic, data)? };
        let path = required(unsafe { text::read::<T>(path, "the file")? }, "file")?;
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
    topic: *const c_char,
    data: *const c_char,
    file_path: *const c_char,
) -> i64 {
    unsafe { push_with_file::<Utf8>(topic.cast(), data.cast(), file_path.cast()) }
}

/// The same as `BakaShrot_PushMessageWithFileA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_PushMessageWithFileW(
    topic: *const u16,
    data: *const u16,
    file_path: *const u16,
) -> i64 {
    unsafe { push_with_file::<Utf16>(topic, data, file_path) }
}

unsafe fn push_with_data<T: Text>(
    topic: *const T::Unit,
    data: *const T::Unit,
    attachment: *const c_void,
    size: i64,
) -> i64 {
    call(-1, |state| {
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
    topic: *const c_char,
    data: *const c_char,
    attachment: *const c_void,
    size: i64,
) -> i64 {
    unsafe { push_with_data::<Utf8>(topic.cast(), data.cast(), attachment, size) }
}

/// The same as `BakaShrot_PushMessageWithDataA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_PushMessageWithDataW(
    topic: *const u16,
    data: *const u16,
    attachment: *const c_void,
    size: i64,
) -> i64 {
    unsafe { push_with_data::<Utf16>(topic, data, attachment, size) }
}

unsafe fn save<T: Text>(
    topic: *const T::Unit,
    node: *const T::Unit,
    id: i64,
    path: *const T::Unit,
) -> i64 {
    call(-1, |state| {
        let (topic, node) = unsafe { topic_and_node::<T>(topic, node)? };
        let path = required(unsafe { text::read::<T>(path, "the file")? }, "file")?;
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
    topic: *const c_char,
    node: *const c_char,
    message_id: i64,
    file_path: *const c_char,
) -> i64 {
    unsafe { save::<Utf8>(topic.cast(), node.cast(), message_id, file_path.cast()) }
}

/// The same as `BakaShrot_SaveAttachmentA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_SaveAttachmentW(
    topic: *const u16,
    node: *const u16,
    message_id: i64,
    file_path: *const u16,
) -> i64 {
    unsafe { save::<Utf16>(topic, node, message_id, file_path) }
}

unsafe fn load<T: Text>(topic: *const T::Unit, node: *const T::Unit, id: i64) -> i64 {
    call(-1, |state| {
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
    topic: *const c_char,
    node: *const c_char,
    message_id: i64,
) -> i64 {
    unsafe { load::<Utf8>(topic.cast(), node.cast(), message_id) }
}

/// The same as `BakaShrot_LoadAttachmentA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_LoadAttachmentW(
    topic: *const u16,
    node: *const u16,
    message_id: i64,
) -> i64 {
    unsafe { load::<Utf16>(topic, node, message_id) }
}

/// Copies what the last `BakaShrot_LoadAttachment()` read into `Buffer`, if
/// `BufferSize` is enough: returns its size (0 if none), copies nothing if
/// it doesn't fit (a null `Buffer` asks for the size).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetAttachmentData(buffer: *mut c_void, buffer_size: i64) -> i64 {
    get(0, |state| {
        let data = &state.attachment;
        if !buffer.is_null() && usize::try_from(buffer_size).is_ok_and(|size| size >= data.len()) {
            unsafe { std::ptr::copy_nonoverlapping(data.as_ptr(), buffer.cast(), data.len()) };
        }
        data.len() as i64
    })
}

/// Frees what `BakaShrot_LoadAttachment()` read: 1.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_FreeAttachmentData() -> isize {
    let freed = catch_unwind(AssertUnwindSafe(|| state().attachment = Vec::new()));
    bool_result(freed.is_ok())
}
