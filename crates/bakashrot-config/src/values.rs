//! The values that need more than a type: durations, ages, sizes,
//! addresses, names.

use bakashrot_proto::limits::{MAX_ATTACHMENT_SIZE, MAX_MESSAGES_PER_PACKET};
use bakashrot_proto::names::{is_valid_name_or_pattern, names_equal};
use serde::de::Error as _;
use serde::{Deserialize, Deserializer};
use std::net::{Ipv6Addr, SocketAddr};
use std::time::Duration;

/// What a duration looks like, for errors.
pub(crate) const DURATION_HELP: &str = "numbers with a unit (s m h d w), like 30s or 1d12h";

/// What a name looks like, for errors.
pub(crate) const NAME_HELP: &str = "1-64 of A-Z a-z 0-9 _ . -, not only digits; patterns: * and ?";

/// A duration: numbers with a unit, added up (`1d12h`). Units `s m h d w`,
/// without case. More than 0.
pub(crate) fn parse_duration(text: &str) -> Option<Duration> {
    let mut seconds: u64 = 0;
    let mut number: Option<u64> = None;
    for c in text.trim().chars() {
        if let Some(digit) = c.to_digit(10) {
            number = Some(
                number
                    .unwrap_or(0)
                    .checked_mul(10)?
                    .checked_add(digit.into())?,
            );
            continue;
        }
        let unit: u64 = match c.to_ascii_lowercase() {
            's' => 1,
            'm' => 60,
            'h' => 3600,
            'd' => 86_400,
            'w' => 604_800,
            _ => return None,
        };
        seconds = seconds.checked_add(number.take()?.checked_mul(unit)?)?;
    }
    if number.is_some() || seconds == 0 {
        return None;
    }
    Some(Duration::from_secs(seconds))
}

/// A retention age: a duration, or `forever` (`Some(None)`).
pub(crate) fn parse_age(text: &str) -> Option<Option<Duration>> {
    if text.trim().eq_ignore_ascii_case("forever") {
        return Some(None);
    }
    parse_duration(text).map(Some)
}

/// A size: bytes (a number), or text with K, M, G or T (1024-based, without
/// case), up to `MAX_ATTACHMENT_SIZE`. 0 is a size.
pub(crate) fn parse_size(value: &toml::Value) -> Option<u64> {
    let size = match value {
        toml::Value::Integer(bytes) => u64::try_from(*bytes).ok()?,
        toml::Value::String(text) => {
            let text = text.trim();
            let (digits, unit) = match text.char_indices().last()? {
                (at, c) if c.is_ascii_alphabetic() => (&text[..at], c.to_ascii_uppercase()),
                _ => (text, 'B'),
            };
            let shift = match unit {
                'B' => 0,
                'K' => 10,
                'M' => 20,
                'G' => 30,
                'T' => 40,
                _ => return None,
            };
            if digits.is_empty() || !digits.bytes().all(|c| c.is_ascii_digit()) {
                return None;
            }
            digits.parse::<u64>().ok()?.checked_mul(1 << shift)?
        }
        _ => return None,
    };
    (size <= MAX_ATTACHMENT_SIZE).then_some(size)
}

/// Whether `text` is a host and a port: `10.0.0.2:7000`,
/// `server-2.lan:7000`, `[fd00::2]:7000`. The port isn't 0.
pub(crate) fn is_peer_address(text: &str) -> bool {
    let Some((host, port)) = text.rsplit_once(':') else {
        return false;
    };
    let port = port.parse::<u16>().is_ok_and(|port| port != 0);
    let host = match host.strip_prefix('[').and_then(|h| h.strip_suffix(']')) {
        Some(v6) => v6.parse::<Ipv6Addr>().is_ok(),
        None => is_hostname(host),
    };
    port && host
}

/// A hostname or an IPv4 address: letters, digits, dots and dashes.
fn is_hostname(host: &str) -> bool {
    !host.is_empty()
        && host
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'.' || c == b'-')
}

// As serde reads them (`deserialize_with`): a value that's wrong fails
// there, and toml says on which line.

/// A duration, more than 0.
pub(crate) fn duration<'de, D: Deserializer<'de>>(reader: D) -> Result<Duration, D::Error> {
    let text = String::deserialize(reader)?;
    parse_duration(&text)
        .ok_or_else(|| D::Error::custom(format!("'{text}' isn't a duration: {DURATION_HELP}")))
}

/// A size up to `MAX_ATTACHMENT_SIZE`.
pub(crate) fn size<'de, D: Deserializer<'de>>(reader: D) -> Result<u64, D::Error> {
    let value = toml::Value::deserialize(reader)?;
    parse_size(&value).ok_or_else(|| {
        D::Error::custom(format!(
            "{value} isn't a size up to 1T: bytes, or a number with K, M, G or T, like \"500M\" \
             (0: no attachments)"
        ))
    })
}

/// An address and a port to listen on.
pub(crate) fn listen<'de, D: Deserializer<'de>>(reader: D) -> Result<SocketAddr, D::Error> {
    let text = String::deserialize(reader)?;
    text.parse().map_err(|_| {
        D::Error::custom(format!(
            "'{text}' isn't an address and a port, like \"0.0.0.0:7000\""
        ))
    })
}

/// Peer addresses, none twice.
pub(crate) fn peers<'de, D: Deserializer<'de>>(reader: D) -> Result<Vec<String>, D::Error> {
    let peers = Vec::<String>::deserialize(reader)?;
    for (at, peer) in peers.iter().enumerate() {
        if !is_peer_address(peer) {
            return Err(D::Error::custom(format!(
                "'{peer}' isn't a host and a port, like \"10.0.0.2:7000\" or \
                 \"server-2.lan:7000\""
            )));
        }
        if peers[..at].contains(peer) {
            return Err(D::Error::custom(format!("'{peer}' is given twice")));
        }
    }
    Ok(peers)
}

/// Hosts without a port: IP addresses or hostnames, or `*` for all; none
/// twice.
pub(crate) fn hosts<'de, D: Deserializer<'de>>(reader: D) -> Result<Vec<String>, D::Error> {
    let hosts = Vec::<String>::deserialize(reader)?;
    for (at, host) in hosts.iter().enumerate() {
        if host != "*" && !is_hostname(host) && host.parse::<Ipv6Addr>().is_err() {
            return Err(D::Error::custom(format!(
                "'{host}' isn't an IP address or a hostname (without a port), like \
                 \"10.0.0.2\" or \"server-2.lan\", or \"*\" for all"
            )));
        }
        if hosts[..at]
            .iter()
            .any(|before| before.eq_ignore_ascii_case(host))
        {
            return Err(D::Error::custom(format!("'{host}' is given twice")));
        }
    }
    Ok(hosts)
}

/// A batch size, 1 to `MAX_MESSAGES_PER_PACKET`.
pub(crate) fn batch_size<'de, D: Deserializer<'de>>(reader: D) -> Result<u32, D::Error> {
    let size = u32::deserialize(reader)?;
    if !(1..=MAX_MESSAGES_PER_PACKET).contains(&size) {
        return Err(D::Error::custom(format!(
            "the batch size must be 1 to {MAX_MESSAGES_PER_PACKET}"
        )));
    }
    Ok(size)
}

/// The most idle database connections a server keeps per pool.
pub(crate) const MAX_IDLE_CONNECTIONS: u32 = 512;

/// How many idle database connections to keep, 0 to
/// `MAX_IDLE_CONNECTIONS`.
pub(crate) fn idle_connections<'de, D: Deserializer<'de>>(reader: D) -> Result<usize, D::Error> {
    let count = u32::deserialize(reader)?;
    if count > MAX_IDLE_CONNECTIONS {
        return Err(D::Error::custom(format!(
            "{count} idle database connections: 0 to {MAX_IDLE_CONNECTIONS}"
        )));
    }
    Ok(count as usize)
}

/// Checks a list of names or patterns, none twice.
pub(crate) fn check_names(list: &[String]) -> Result<(), String> {
    for (at, entry) in list.iter().enumerate() {
        if !is_valid_name_or_pattern(entry) {
            return Err(format!("'{entry}' isn't a name or a pattern ({NAME_HELP})"));
        }
        if list[..at].iter().any(|before| names_equal(before, entry)) {
            return Err(format!("'{entry}' is given twice"));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durations() {
        let s = Duration::from_secs;
        assert_eq!(parse_duration("30s"), Some(s(30)));
        assert_eq!(parse_duration("1d12h"), Some(s(129_600)));
        assert_eq!(parse_duration(" 2W "), Some(s(1_209_600)));
        assert_eq!(parse_duration("1m30s"), Some(s(90)));
        for bad in [
            "",
            "30",
            "s",
            "1x",
            "0s",
            "1h 30m",
            "-1s",
            "99999999999999999999w",
        ] {
            assert_eq!(parse_duration(bad), None, "{bad}");
        }
        assert_eq!(parse_age("Forever"), Some(None));
        assert_eq!(parse_age("30d"), Some(Some(s(2_592_000))));
        assert_eq!(parse_age("never"), None);
    }

    #[test]
    fn sizes() {
        let text = |t: &str| parse_size(&toml::Value::String(t.into()));
        assert_eq!(text("0"), Some(0));
        assert_eq!(text("500"), Some(500));
        assert_eq!(text("500k"), Some(500 << 10));
        assert_eq!(text("1G"), Some(1 << 30));
        assert_eq!(text("1T"), Some(1 << 40));
        assert_eq!(parse_size(&toml::Value::Integer(1024)), Some(1024));
        for bad in ["", "G", "2T", "1.5G", "1GB", "-1", "1 G"] {
            assert_eq!(text(bad), None, "{bad}");
        }
        assert_eq!(parse_size(&toml::Value::Integer(-1)), None);
        assert_eq!(parse_size(&toml::Value::Boolean(true)), None);
    }

    #[test]
    fn peer_addresses() {
        for good in [
            "10.0.0.2:7000",
            "server-2.lan:7000",
            "[fd00::2]:7000",
            "localhost:1",
        ] {
            assert!(is_peer_address(good), "{good}");
        }
        for bad in [
            "10.0.0.2",
            "10.0.0.2:0",
            ":7000",
            "fd00::2:7000",
            "a b:7000",
            "x:70000",
        ] {
            assert!(!is_peer_address(bad), "{bad}");
        }
    }
}
