//! The error codes: what a server sends with each refusal (1-99, in a
//! `RequestRefused`), and the client's own (100 and up, what the DLL's
//! `BakaShrot_GetLastError()` returns). The same numbers as protocol 6
//! (`OldSource/Client/BakaShrot_ErrorCodes.pbi`): never renumber one, only
//! add new ones.
//!
//! What to do about each:
//! - reconnect, then retry: `NotConnected`, `ConnectFailed`,
//!   `ConnectionLost`, `ProtocolError` (the connection is closed);
//! - retry later: `NotReady`, `ServerError`;
//! - fix the configuration: `AuthRejected`, `ServerNotVerified`,
//!   `NotAllowed`, `UnknownName`, `NoDefaultTopic`;
//! - update one end: `VersionMismatch`;
//! - fix the call: `InvalidArgument`, `InvalidRequest`, `TooBig`,
//!   `QueryFailed`, `FileError`;
//! - gone, or not there yet: `NotFound`;
//! - send it again: `DataMismatch` (an upload), `AttachmentMismatch` (a
//!   download).
//!
//! A push whose answer was lost (`ConnectionLost`) may have been stored all
//! the same: pushed again, it's stored twice. Delivery is at least once.

use std::fmt;

/// The highest code a refusal can have: anything above is the client's own.
pub const MAX_REFUSAL_CODE: u32 = 99;

macro_rules! error_codes {
    ($( $name:ident = $code:literal, $description:literal; )*) => {
        /// An error code, see the [module](self).
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
        #[repr(u32)]
        pub enum ErrorCode {
            $( #[doc = $description] $name = $code, )*
        }

        impl ErrorCode {
            /// Every code, in order.
            pub const ALL: &'static [ErrorCode] = &[$(ErrorCode::$name),*];

            /// The code with this number, if there's one.
            pub const fn from_code(code: u32) -> Option<ErrorCode> {
                match code {
                    $( $code => Some(ErrorCode::$name), )*
                    _ => None,
                }
            }

            /// Its name, as the constants have it: "NotFound".
            pub const fn name(self) -> &'static str {
                match self {
                    $( ErrorCode::$name => stringify!($name), )*
                }
            }

            /// What it means: its documentation.
            pub const fn description(self) -> &'static str {
                match self {
                    $( ErrorCode::$name => $description, )*
                }
            }
        }
    };
}

// One text per code: its documentation, and what `description()` says.
error_codes! {
    // Refused by the server: the connection is still open.
    NotAllowed = 1, "Not allowed to this client: its roles' permissions, or a request only peers may make.";
    UnknownName = 2, "A node this server has no message of.";
    NotFound = 3, "No such message or attachment.";
    NotReady = 4, "The attachment isn't on this server yet (still being replicated).";
    TooBig = 5, "A message, attachment or query result over a limit, or an attachment bigger than this server keeps.";
    NoDefaultTopic = 6, "Protocol 6's: a push without a topic and no default one. Protocol 7 pushes always name their topic: never sent, kept so the number isn't reused.";
    InvalidRequest = 7, "A request that doesn't fit: an attachment's parts not matching its size, a part that doesn't exist...";
    DataMismatch = 8, "An uploaded attachment that doesn't match its SHA-256: dropped.";
    QueryFailed = 9, "The SQL of a query failed (its error in the reason).";
    ServerError = 10, "The server couldn't store or read something: its database failed.";

    // The client's own.
    NotConnected = 100, "Not connected: never, or the connection was closed or lost before.";
    ConnectFailed = 101, "The server couldn't be reached at that host and port.";
    AuthRejected = 102, "The server refused the connection: a certificate it doesn't take (another CA, revoked, expired), or another protocol version.";
    ServerNotVerified = 103, "The server's certificate isn't from the expected CA, or isn't for that host.";
    ConnectionLost = 104, "The connection broke during a request (it's closed now). A push may still have been stored.";
    ProtocolError = 105, "The server answered something unexpected or malformed: the connection is closed.";
    InvalidArgument = 106, "A bad argument: a topic or node that isn't a name, a null pointer, a message or attachment over the limits, a setting missing before connecting.";
    FileError = 107, "A file couldn't be opened, read or written.";
    AttachmentMismatch = 108, "A downloaded attachment doesn't match its SHA-256.";
    AlreadyConnected = 109, "Already connected: disconnect first.";
    Internal = 110, "Out of memory, or another failure inside the client.";
    VersionMismatch = 111, "The server speaks another version of the protocol: update the client or the server.";
}

impl ErrorCode {
    /// Its number.
    pub const fn code(self) -> u32 {
        self as u32
    }

    /// Whether a server sends it with a refusal (1-99): the connection is
    /// still open.
    pub const fn is_refusal(self) -> bool {
        is_refusal_code(self.code())
    }
}

/// Whether `code` is a refusal's (1-99), known or not.
pub const fn is_refusal_code(code: u32) -> bool {
    code >= 1 && code <= MAX_REFUSAL_CODE
}

/// The name of any code: `None` for 0, the code's name, or `Error <code>`
/// for one this version doesn't know.
pub fn code_name(code: u32) -> String {
    match ErrorCode::from_code(code) {
        Some(known) => known.name().to_owned(),
        None if code == 0 => "None".to_owned(),
        None => format!("Error {code}"),
    }
}

impl fmt::Display for ErrorCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_numbers_of_protocol_6() {
        let expected: &[(u32, &str)] = &[
            (1, "NotAllowed"),
            (2, "UnknownName"),
            (3, "NotFound"),
            (4, "NotReady"),
            (5, "TooBig"),
            (6, "NoDefaultTopic"),
            (7, "InvalidRequest"),
            (8, "DataMismatch"),
            (9, "QueryFailed"),
            (10, "ServerError"),
            (100, "NotConnected"),
            (101, "ConnectFailed"),
            (102, "AuthRejected"),
            (103, "ServerNotVerified"),
            (104, "ConnectionLost"),
            (105, "ProtocolError"),
            (106, "InvalidArgument"),
            (107, "FileError"),
            (108, "AttachmentMismatch"),
            (109, "AlreadyConnected"),
            (110, "Internal"),
            (111, "VersionMismatch"),
        ];
        assert_eq!(ErrorCode::ALL.len(), expected.len());
        for (code, name) in expected {
            let known = ErrorCode::from_code(*code).expect("a known code");
            assert_eq!(known.code(), *code);
            assert_eq!(known.name(), *name);
            assert_eq!(known.is_refusal(), *code < 100);
            assert!(!known.description().is_empty());
        }
    }

    #[test]
    fn names_of_any_code() {
        assert_eq!(code_name(0), "None");
        assert_eq!(code_name(3), "NotFound");
        assert_eq!(code_name(42), "Error 42");
        assert_eq!(ErrorCode::from_code(0), None);
        assert_eq!(ErrorCode::from_code(42), None);
        assert!(is_refusal_code(42));
        assert!(!is_refusal_code(0));
        assert!(!is_refusal_code(100));
        assert_eq!(ErrorCode::TooBig.to_string(), "TooBig");
    }
}
