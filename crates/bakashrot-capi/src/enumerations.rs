//! Enumerations: a list of names or a query's rows, kept whole, read an
//! item at a time like Win32's `FindFirstFile` / `FindNextFile` /
//! `FindClose`. `Next...()` first (an enumeration starts before its first
//! item), then the getters; `BakaShrot_CloseEnum()` once done, or
//! `BakaShrot_FreeClient()` closes its client's.

use super::{
    Error, HANDLES, Result, State, Text, Utf8, Utf16, bool_result, call, fetch_names, fetch_query,
    invalid, lock, text,
};
use bakashrot_proto::ErrorCode;
use std::ffi::c_char;
use std::panic::{AssertUnwindSafe, catch_unwind};

/// An answer of a client, kept whole.
pub(crate) struct Enumeration {
    pub(crate) client: i64,
    items: Items,
}

enum Items {
    Names {
        names: Cursor<String>,
        truncated: bool,
    },
    Query {
        columns: Vec<String>,
        rows: Cursor<Vec<Option<String>>>,
    },
}

/// Items and where it's at: 0 before the first, `n` on the `n`th, the
/// count + 1 past the last.
struct Cursor<T> {
    items: Vec<T>,
    position: usize,
}

impl<T> Cursor<T> {
    fn new(items: Vec<T>) -> Cursor<T> {
        Cursor { items, position: 0 }
    }

    /// Moves to the next item: whether there was one.
    fn advance(&mut self) -> bool {
        self.position = (self.position + 1).min(self.items.len() + 1);
        self.position <= self.items.len()
    }

    fn current(&self) -> Option<&T> {
        self.items.get(self.position.checked_sub(1)?)
    }
}

/// Runs `fetch` on a client, keeps what it gives as an enumeration of that
/// client: its handle, 0 if it failed (the client's last error says why).
fn enumerate(client: i64, fetch: impl FnOnce(&mut State) -> Result<Items>) -> i64 {
    call(client, 0, |state| {
        let items = fetch(state)?;
        let handles = &mut *lock(&HANDLES);
        // Freed by another thread during the call: its enumerations went.
        if !handles.clients.contains_key(&client) {
            return Err(invalid(format!("client {client} freed during the call")));
        }
        let handle = handles.take();
        handles
            .enumerations
            .insert(handle, Enumeration { client, items });
        Ok(handle)
    })
}

/// Reads an enumeration: `default` for a bad handle, or `read` giving
/// `None` (one of the other kind, no current item, no such column).
fn read<R>(handle: i64, default: R, read: impl FnOnce(&mut Items) -> Option<R>) -> R {
    catch_unwind(AssertUnwindSafe(|| {
        let handles = &mut *lock(&HANDLES);
        read(&mut handles.enumerations.get_mut(&handle)?.items)
    }))
    .ok()
    .flatten()
    .unwrap_or(default)
}

/// A column index, as arguments.
fn column(index: i32) -> Option<usize> {
    usize::try_from(index).ok()
}

/// Closes an enumeration: 1, or 0 if it wasn't one.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_CloseEnum(enumeration: i64) -> isize {
    let closed = catch_unwind(|| lock(&HANDLES).enumerations.remove(&enumeration).is_some());
    bool_result(closed.unwrap_or(false))
}

// --- Names -------------------------------------------------------------------

unsafe fn enumerate_names<T: Text>(
    client: i64,
    kind: i32,
    topics: *const T::Unit,
    nodes: *const T::Unit,
) -> i64 {
    enumerate(client, |state| {
        let list = unsafe { fetch_names::<T>(state, kind, topics, nodes)? };
        Ok(Items::Names {
            names: Cursor::new(list.names),
            truncated: list.truncated,
        })
    })
}

/// Lists names as `BakaShrot_ListNames()` does (the same arguments), into
/// an enumeration: its handle, 0 on failure (`BakaShrot_GetLastError(client)`).
/// Then `BakaShrot_NextName()` and `BakaShrot_GetEnumName()`, and
/// `BakaShrot_CloseEnum()`. Closed with its client by
/// `BakaShrot_FreeClient()`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_EnumerateNamesA(
    client: i64,
    kind: i32,
    topics: *const c_char,
    nodes: *const c_char,
) -> i64 {
    unsafe { enumerate_names::<Utf8>(client, kind, topics.cast(), nodes.cast()) }
}

/// The same as `BakaShrot_EnumerateNamesA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_EnumerateNamesW(
    client: i64,
    kind: i32,
    topics: *const u16,
    nodes: *const u16,
) -> i64 {
    unsafe { enumerate_names::<Utf16>(client, kind, topics, nodes) }
}

/// Moves to the next name (the first, the first time): 1, 0 if there are
/// no more, -1 if it isn't a names enumeration.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_NextName(enumeration: i64) -> isize {
    read(enumeration, -1, |items| match items {
        Items::Names { names, .. } => Some(bool_result(names.advance())),
        Items::Query { .. } => None,
    })
}

unsafe fn enum_name<T: Text>(enumeration: i64, buffer: *mut T::Unit, size: isize) -> isize {
    read(enumeration, 0, |items| match items {
        Items::Names { names, .. } => names
            .current()
            .map(|name| unsafe { text::copy::<T>(name, buffer, size) }),
        Items::Query { .. } => None,
    })
}

/// The current name: the bytes it needs, 0 if there's none (before the
/// first, past the last) or it isn't a names enumeration.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetEnumNameA(
    enumeration: i64,
    buffer: *mut c_char,
    size: isize,
) -> isize {
    unsafe { enum_name::<Utf8>(enumeration, buffer.cast(), size) }
}

/// The same as `BakaShrot_GetEnumNameA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetEnumNameW(
    enumeration: i64,
    buffer: *mut u16,
    size: isize,
) -> isize {
    unsafe { enum_name::<Utf16>(enumeration, buffer, size) }
}

/// How many names, -1 if it isn't a names enumeration.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_GetNameCount(enumeration: i64) -> i32 {
    read(enumeration, -1, |items| match items {
        Items::Names { names, .. } => Some(names.items.len() as i32),
        Items::Query { .. } => None,
    })
}

/// Whether some names didn't fit in the server's answer: 1 or 0, -1 if it
/// isn't a names enumeration.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_IsNamesListTruncated(enumeration: i64) -> isize {
    read(enumeration, -1, |items| match items {
        Items::Names { truncated, .. } => Some(bool_result(*truncated)),
        Items::Query { .. } => None,
    })
}

// --- Queries -----------------------------------------------------------------

/// The server's `{"columns":[...],"rows":[[...],...]}`, each value a
/// string or null.
fn parse_query(json: &str) -> Option<Items> {
    let value: serde_json::Value = serde_json::from_str(json).ok()?;
    let columns = value
        .get("columns")?
        .as_array()?
        .iter()
        .map(|column| column.as_str().map(str::to_owned))
        .collect::<Option<Vec<_>>>()?;
    let rows = value
        .get("rows")?
        .as_array()?
        .iter()
        .map(|row| {
            row.as_array()?
                .iter()
                .map(|value| match value {
                    serde_json::Value::Null => Some(None),
                    serde_json::Value::String(text) => Some(Some(text.clone())),
                    _ => None,
                })
                .collect::<Option<Vec<_>>>()
        })
        .collect::<Option<Vec<_>>>()?;
    Some(Items::Query {
        columns,
        rows: Cursor::new(rows),
    })
}

unsafe fn enumerate_query<T: Text>(client: i64, sql: *const T::Unit) -> i64 {
    enumerate(client, |state| {
        let json = unsafe { fetch_query::<T>(state, sql)? };
        parse_query(&json)
            .ok_or_else(|| Error::new(ErrorCode::Internal, "the server's query result isn't one"))
    })
}

/// Runs a query as `BakaShrot_Query()` does, into an enumeration: its
/// handle, 0 on failure (`BakaShrot_GetLastError(client)`). Then
/// `BakaShrot_GetQueryColumnCount()` and `GetQueryColumnName()`,
/// `BakaShrot_NextQueryRow()` and `GetQueryValue()` / `IsQueryValueNull()`,
/// and `BakaShrot_CloseEnum()`. Closed with its client by
/// `BakaShrot_FreeClient()`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_EnumerateQueryA(client: i64, sql: *const c_char) -> i64 {
    unsafe { enumerate_query::<Utf8>(client, sql.cast()) }
}

/// The same as `BakaShrot_EnumerateQueryA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_EnumerateQueryW(client: i64, sql: *const u16) -> i64 {
    unsafe { enumerate_query::<Utf16>(client, sql) }
}

/// How many columns, -1 if it isn't a query enumeration.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_GetQueryColumnCount(enumeration: i64) -> i32 {
    read(enumeration, -1, |items| match items {
        Items::Query { columns, .. } => Some(columns.len() as i32),
        Items::Names { .. } => None,
    })
}

unsafe fn column_name<T: Text>(
    enumeration: i64,
    index: i32,
    buffer: *mut T::Unit,
    size: isize,
) -> isize {
    read(enumeration, 0, |items| match items {
        Items::Query { columns, .. } => columns
            .get(column(index)?)
            .map(|name| unsafe { text::copy::<T>(name, buffer, size) }),
        Items::Names { .. } => None,
    })
}

/// A column's name (`index` 0 to the count - 1): the bytes it needs, 0 if
/// there's no such column or it isn't a query enumeration.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetQueryColumnNameA(
    enumeration: i64,
    index: i32,
    buffer: *mut c_char,
    size: isize,
) -> isize {
    unsafe { column_name::<Utf8>(enumeration, index, buffer.cast(), size) }
}

/// The same as `BakaShrot_GetQueryColumnNameA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetQueryColumnNameW(
    enumeration: i64,
    index: i32,
    buffer: *mut u16,
    size: isize,
) -> isize {
    unsafe { column_name::<Utf16>(enumeration, index, buffer, size) }
}

/// Moves to the next row (the first, the first time): 1, 0 if there are
/// no more, -1 if it isn't a query enumeration.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_NextQueryRow(enumeration: i64) -> isize {
    read(enumeration, -1, |items| match items {
        Items::Query { rows, .. } => Some(bool_result(rows.advance())),
        Items::Names { .. } => None,
    })
}

/// The current row's value in a column: `None` without a row or column.
fn value(items: &Items, index: i32) -> Option<&Option<String>> {
    match items {
        Items::Query { rows, .. } => rows.current()?.get(column(index)?),
        Items::Names { .. } => None,
    }
}

unsafe fn query_value<T: Text>(
    enumeration: i64,
    index: i32,
    buffer: *mut T::Unit,
    size: isize,
) -> isize {
    read(enumeration, 0, |items| {
        value(items, index)?
            .as_deref()
            .map(|text| unsafe { text::copy::<T>(text, buffer, size) })
    })
}

/// The current row's value in a column (`index` 0 to the count - 1): the
/// bytes it needs, 0 if it's null (`BakaShrot_IsQueryValueNull()`), there's
/// no current row or such column, or it isn't a query enumeration.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetQueryValueA(
    enumeration: i64,
    index: i32,
    buffer: *mut c_char,
    size: isize,
) -> isize {
    unsafe { query_value::<Utf8>(enumeration, index, buffer.cast(), size) }
}

/// The same as `BakaShrot_GetQueryValueA`, in UTF-16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn BakaShrot_GetQueryValueW(
    enumeration: i64,
    index: i32,
    buffer: *mut u16,
    size: isize,
) -> isize {
    unsafe { query_value::<Utf16>(enumeration, index, buffer, size) }
}

/// Whether the current row's value in a column is null: 1 or 0, -1 if
/// there's no current row or such column, or it isn't a query enumeration.
#[unsafe(no_mangle)]
pub extern "C" fn BakaShrot_IsQueryValueNull(enumeration: i64, index: i32) -> isize {
    read(enumeration, -1, |items| {
        value(items, index).map(|value| bool_result(value.is_none()))
    })
}
