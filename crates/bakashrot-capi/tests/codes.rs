//! The bindings' error codes are the protocol's, every one, by the same
//! numbers: Python's `ErrorCode`, C#'s `ErrorCode`, PureBasic's constants.
//! And the values they copy are the Rust side's.

use bakashrot_client::ANSWER_TIMEOUT;
use bakashrot_proto::ErrorCode;
use bakashrot_proto::limits::{KEEPALIVE_SECS, MAX_MESSAGES_PER_PACKET};
use std::collections::BTreeMap;
use std::path::PathBuf;

fn binding(path: &str) -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../bindings")
        .join(path);
    std::fs::read_to_string(&path).unwrap_or_else(|error| panic!("{}: {error}", path.display()))
}

/// The protocol's codes, by number: their names as `name` writes them.
fn expected(name: impl Fn(ErrorCode) -> String) -> BTreeMap<u32, String> {
    ErrorCode::ALL
        .iter()
        .map(|&code| (code.code(), name(code)))
        .collect()
}

/// `NotFound` as `NOT_FOUND`.
fn upper_snake(name: &str) -> String {
    let mut snake = String::new();
    for (at, c) in name.char_indices() {
        if c.is_ascii_uppercase() && at > 0 {
            snake.push('_');
        }
        snake.push(c.to_ascii_uppercase());
    }
    snake
}

/// `NAME = 12` in `text`, one per line or comma: the names and numbers.
fn assignments<'a>(text: impl Iterator<Item = &'a str>) -> BTreeMap<u32, String> {
    let mut found = BTreeMap::new();
    for item in text.flat_map(|line| line.split(',')) {
        // Comments: PureBasic's `;`, Python's ` #` (PureBasic's constants
        // start with `#`).
        let item = item.split(';').next().unwrap_or("");
        let item = item.split(" #").next().unwrap_or("").trim();
        let Some((name, number)) = item.split_once('=') else {
            continue;
        };
        let Ok(number) = number.trim().parse::<u32>() else {
            continue;
        };
        let before = found.insert(number, name.trim().to_owned());
        assert!(before.is_none(), "{number} twice: {before:?}, {name}");
    }
    found
}

/// The lines of `text` from the one starting with `start` to the next
/// starting with `end`.
fn section<'a>(text: &'a str, start: &str, end: &str) -> impl Iterator<Item = &'a str> {
    text.lines()
        .skip_while(move |line| !line.trim_start().starts_with(start))
        .skip(1)
        .take_while(move |line| !line.trim_start().starts_with(end))
}

/// The number `name` is set to in `text`: `NAME = 12`, a `;` after or not.
fn number(text: &str, name: &str) -> f64 {
    let set = format!("{name} = ");
    let line = text.lines().find(|line| line.contains(&set));
    let line = line.unwrap_or_else(|| panic!("no {set}"));
    let value = line.split(&set).nth(1).unwrap_or("");
    let value = value.trim().trim_end_matches(';');
    value.parse().unwrap_or_else(|_| panic!("{set}{value}"))
}

#[test]
fn copied_values() {
    let python = binding("python/bakashrot.py");
    let csharp = binding("csharp/NibblePoker.BakaShrot.Client/BakaShrot.cs");
    let answer = ANSWER_TIMEOUT.as_secs_f64();
    let keepalive = KEEPALIVE_SECS as f64;
    assert_eq!(number(&python, "ANSWER_TIMEOUT_SECONDS"), answer);
    assert_eq!(number(&python, "KEEPALIVE_SECONDS"), keepalive);
    assert_eq!(
        number(&python, "MAX_GET_MESSAGES"),
        f64::from(MAX_MESSAGES_PER_PACKET)
    );
    assert_eq!(number(&csharp, "DefaultAnswerTimeoutMs"), answer * 1000.0);
    assert_eq!(number(&csharp, "KeepAliveMs"), keepalive * 1000.0);
}

#[test]
fn python() {
    let text = binding("python/bakashrot.py");
    let found = assignments(section(&text, "class ErrorCode", "@property"));
    let mut expected = expected(|code| upper_snake(code.name()));
    expected.insert(0, "NONE".into());
    assert_eq!(found, expected);
}

#[test]
fn csharp() {
    let text = binding("csharp/NibblePoker.BakaShrot.Client/BakaShrot.cs");
    let found = assignments(section(&text, "public enum ErrorCode", "}"));
    let mut expected = expected(|code| code.name().to_owned());
    expected.insert(0, "None".into());
    assert_eq!(found, expected);
}

#[test]
fn purebasic() {
    let text = binding("purebasic/BakaShrot_ErrorCodes.pbi");
    let constants = text
        .lines()
        .filter(|line| line.starts_with("#BakaShrot_") && !line.contains("_Max"));
    let found = assignments(constants);
    let mut expected = expected(|code| {
        let kind = if code.is_refusal() {
            "Refused"
        } else {
            "Error"
        };
        format!("#BakaShrot_{kind}_{}", code.name())
    });
    expected.insert(0, "#BakaShrot_Error_None".into());
    assert_eq!(found, expected);
    // Each named by BakaShrot_ErrorName().
    for code in ErrorCode::ALL {
        let case = format!("ProcedureReturn \"{}\"", code.name());
        assert!(text.contains(&case), "BakaShrot_ErrorName() lacks {code}");
    }
}
