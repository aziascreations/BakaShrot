//! `bindings/c/bakashrot.h` matches the exports: rewritten when it doesn't
//! (the test fails then, check the new one in).

use std::path::Path;

#[test]
fn the_header_is_current() {
    let crate_dir = env!("CARGO_MANIFEST_DIR");
    let path = Path::new(crate_dir).join("../../bindings/c/bakashrot.h");
    let mut generated = Vec::new();
    cbindgen::generate(crate_dir)
        .expect("cbindgen reads the crate")
        .write(&mut generated);
    let current = std::fs::read(&path).unwrap_or_default();
    if current != generated {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, &generated).unwrap();
        panic!("{} was out of date: rewritten, check it in", path.display());
    }
}
