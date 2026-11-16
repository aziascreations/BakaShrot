//! Topic and node names, and wildcards.
//!
//! Topics and nodes go by name everywhere on the wire: a server's ids for
//! them are its own business, in its database.
//!
//! - A **name** is 1-64 characters out of `A-Z a-z 0-9 _ . -`, not only
//!   digits, compared without case ("Logs" is "logs").
//! - A **pattern** is a name with wildcards, like file names: `*` any
//!   characters (none included), `?` exactly one.

use crate::limits::MAX_NAME_LENGTH;

/// Whether `c` may be in a name.
const fn is_name_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_' || c == b'.' || c == b'-'
}

/// Whether `name` can be a topic or node name, see the [module](self).
pub fn is_valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= MAX_NAME_LENGTH
        && !name.bytes().all(|c| c.is_ascii_digit())
        && name.bytes().all(is_name_char)
}

/// Whether two names are the same name (without case).
pub fn names_equal(a: &str, b: &str) -> bool {
    a.eq_ignore_ascii_case(b)
}

/// Whether `pattern` is a valid pattern: a `*` or a `?` at least, and
/// otherwise only characters a name can have, 64 at most.
pub fn is_valid_pattern(pattern: &str) -> bool {
    !pattern.is_empty()
        && pattern.len() <= MAX_NAME_LENGTH
        && pattern.bytes().any(|c| c == b'*' || c == b'?')
        && pattern
            .bytes()
            .all(|c| is_name_char(c) || c == b'*' || c == b'?')
}

/// Whether `text` is a name or a pattern: what a list of topics or nodes
/// holds (`SyncState`, configs).
pub fn is_valid_name_or_pattern(text: &str) -> bool {
    is_valid_name(text) || is_valid_pattern(text)
}

/// Whether the name `name` matches `pattern` (without case). Anything that
/// isn't a valid name never matches.
pub fn pattern_matches(pattern: &str, name: &str) -> bool {
    if !is_valid_name(name) {
        return false;
    }
    let pattern = pattern.as_bytes();
    let name = name.as_bytes();
    let (mut p, mut n) = (0, 0);
    // Where the last `*` was, and where in the name it started matching.
    let mut star: Option<(usize, usize)> = None;

    // Greedy, going back to the last `*` on a mismatch: linear enough for
    // 64 characters.
    while n < name.len() {
        if p < pattern.len() && pattern[p] == b'*' {
            star = Some((p, n));
            p += 1;
        } else if p < pattern.len()
            && (pattern[p] == b'?' || pattern[p].eq_ignore_ascii_case(&name[n]))
        {
            p += 1;
            n += 1;
        } else if let Some((star_p, star_n)) = star {
            p = star_p + 1;
            n = star_n + 1;
            star = Some((star_p, star_n + 1));
        } else {
            return false;
        }
    }
    pattern[p..].iter().all(|c| *c == b'*')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names() {
        for name in [
            "logs",
            "Logs",
            "kitchen-1",
            "a.b_c-d",
            "x",
            "1a",
            &"a".repeat(64),
        ] {
            assert!(is_valid_name(name), "{name}");
        }
        for name in ["", "12", "0", "a b", "é", "a/b", "a*", &"a".repeat(65)] {
            assert!(!is_valid_name(name), "{name}");
        }
        assert!(names_equal("Logs", "lOGS"));
        assert!(!names_equal("logs", "log"));
    }

    #[test]
    fn patterns() {
        for pattern in ["*", "?", "sensors.*", "kitchen-??", "*a*b*"] {
            assert!(is_valid_pattern(pattern), "{pattern}");
            assert!(is_valid_name_or_pattern(pattern), "{pattern}");
        }
        for pattern in ["", "logs", "a b*", "a/*", &format!("{}*", "a".repeat(64))] {
            assert!(!is_valid_pattern(pattern), "{pattern}");
        }
        assert!(is_valid_name_or_pattern("logs"));
        assert!(!is_valid_name_or_pattern("12"));
        assert!(!is_valid_name_or_pattern("a b"));

        let cases = [
            ("*", "logs", true),
            ("sensors.*", "sensors.kitchen", true),
            // `*` matches nothing too, and "sensors." is a name.
            ("sensors.*", "sensors.", true),
            ("sensors.*", "SENSORS.x", true),
            ("sensors.*", "sensor.x", false),
            ("kitchen-??", "kitchen-12", true),
            ("kitchen-??", "kitchen-1", false),
            ("kitchen-??", "kitchen-123", false),
            ("*a*b*", "xxaxxbxx", true),
            ("*a*b", "ab", true),
            ("*a*b", "aba", false),
            ("a*a*a", "aaa", true),
            ("a*a*a", "aa", false),
            ("**", "x", true),
            ("*", "12", false),
            ("?", "1", false),
            ("*", "", false),
        ];
        for (pattern, name, expected) in cases {
            assert_eq!(
                pattern_matches(pattern, name),
                expected,
                "{pattern} / {name}"
            );
        }
    }
}
