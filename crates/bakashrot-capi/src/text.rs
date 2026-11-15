//! Strings across the C boundary: arguments read as UTF-8 (`A` exports) or
//! UTF-16 (`W` exports), answers copied into the caller's buffers.

use bakashrot_client::Error;
use bakashrot_proto::ErrorCode;

/// An encoding of the exports' strings.
pub(crate) trait Text {
    /// One code unit: `u8` or `u16`.
    type Unit: Copy + Default + PartialEq;
    /// Its name, for errors.
    const NAME: &'static str;
    fn decode(units: &[Self::Unit]) -> Option<String>;
    fn encode(text: &str) -> Vec<Self::Unit>;
}

/// UTF-8, `char*`: the `A` exports.
pub(crate) struct Utf8;

impl Text for Utf8 {
    type Unit = u8;
    const NAME: &'static str = "UTF-8";

    fn decode(units: &[u8]) -> Option<String> {
        String::from_utf8(units.to_vec()).ok()
    }

    fn encode(text: &str) -> Vec<u8> {
        text.as_bytes().to_vec()
    }
}

/// UTF-16, `uint16_t*` (`wchar_t*` on Windows): the `W` exports.
pub(crate) struct Utf16;

impl Text for Utf16 {
    type Unit = u16;
    const NAME: &'static str = "UTF-16";

    fn decode(units: &[u16]) -> Option<String> {
        String::from_utf16(units).ok()
    }

    fn encode(text: &str) -> Vec<u16> {
        text.encode_utf16().collect()
    }
}

/// A null-terminated string argument; `None` for a null pointer (what
/// PureBasic passes for an empty string).
///
/// # Safety
///
/// `pointer` is null, or points to a string ending with a zero unit.
pub(crate) unsafe fn read<T: Text>(
    pointer: *const T::Unit,
    what: &str,
) -> Result<Option<String>, Error> {
    if pointer.is_null() {
        return Ok(None);
    }
    let mut units = Vec::new();
    loop {
        // Unaligned: callers' buffers may be byte arrays.
        let unit = unsafe { pointer.add(units.len()).read_unaligned() };
        if unit == T::Unit::default() {
            break;
        }
        units.push(unit);
    }
    T::decode(&units).map(Some).ok_or_else(|| {
        Error::new(
            ErrorCode::InvalidArgument,
            format!("{what}: not valid {}", T::NAME),
        )
    })
}

/// Copies `text`, terminated, into `buffer` of `size` bytes if it fits
/// (nothing otherwise, or with a null `buffer`): the bytes it needs.
///
/// # Safety
///
/// `buffer` is null, or writable for `size` bytes.
pub(crate) unsafe fn copy<T: Text>(text: &str, buffer: *mut T::Unit, size: isize) -> isize {
    let mut units = T::encode(text);
    units.push(T::Unit::default());
    let needed = std::mem::size_of_val(units.as_slice());
    if !buffer.is_null() && size >= needed as isize {
        unsafe {
            std::ptr::copy_nonoverlapping(units.as_ptr().cast::<u8>(), buffer.cast::<u8>(), needed);
        }
    }
    needed as isize
}
