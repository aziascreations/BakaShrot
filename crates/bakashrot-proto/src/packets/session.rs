//! The connection itself: the server's welcome, refusals, and the go-ahead
//! for an attachment's parts.

use super::Check;
use super::DecodeError;
use super::rules;
use crate::error::{ErrorCode, MAX_REFUSAL_CODE};
use serde::{Deserialize, Serialize};

/// The server's first packet, once TLS is up and both ends' versions
/// matched (`frame::check_version()`): who this connection is, as the
/// server sees it.
///
/// `[1, [server, node]]`
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Welcome {
    /// The server's own name (its node).
    pub server: String,
    /// The node this connection writes as, from its certificate.
    pub node: String,
}

impl Check for Welcome {
    fn check(&self) -> Result<(), DecodeError> {
        rules::name(&self.server, "Welcome.server")?;
        rules::name(&self.node, "Welcome.node")
    }
}

/// A request refused: the connection stays open.
///
/// `[2, [code, reason]]`
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RequestRefused {
    /// What kind of refusal, 1-99: what clients act on. Kept as a number,
    /// a newer server may send one this version doesn't know.
    pub code: u32,
    /// Why, for logs and people.
    pub reason: String,
}

impl RequestRefused {
    /// A refusal with a known code (a refusal's, 1-99).
    pub fn new(code: ErrorCode, reason: impl Into<String>) -> Self {
        debug_assert!(code.is_refusal(), "{code} isn't a refusal's code");
        RequestRefused {
            code: code.code(),
            reason: reason.into(),
        }
    }

    /// Its code, if this version knows it.
    pub fn error_code(&self) -> Option<ErrorCode> {
        ErrorCode::from_code(self.code)
    }
}

impl Check for RequestRefused {
    fn check(&self) -> Result<(), DecodeError> {
        rules::range(
            self.code.into(),
            1,
            MAX_REFUSAL_CODE.into(),
            "RequestRefused.code",
        )
    }
}

/// Send the attachment's parts now: the answer to a `PushMessage` or a
/// `ReplicateAttachment` with an attachment, when the server takes it.
///
/// `[3, []]`
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Continue {}

impl Check for Continue {}
