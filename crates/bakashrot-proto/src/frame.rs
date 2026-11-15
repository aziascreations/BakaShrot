//! Frames: every packet goes as one, its size as a 4-byte little-endian
//! unsigned integer, then the packet. A frame of more than the limit is
//! invalid as soon as its size arrived: the connection is aborted without
//! waiting for the rest. An empty one is too (as a frame here, as a packet
//! that doesn't decode with [`codec()`]).
//!
//! Over TLS, which takes care of the encryption: unlike protocol 6, frames
//! carry packets as they are.
//!
//! Before any frame, right after TLS, each end sends its protocol version
//! (4 bytes, little-endian) and reads the other's: [`write_version()`],
//! [`read_version()`], [`check_version()`]. Ends of different versions
//! abandon the connection there, whatever later versions do to frames and
//! packets.
//!
//! - [`write()`] and [`read()`]: on a blocking stream, the client's (the
//!   DLL has no async runtime).
//! - [`codec()`], with the `tokio` feature: the same frames for the async
//!   server, `tokio-util`'s codec (with `Framed`, a connection becomes a
//!   stream of packets in and a sink of packets out).

use crate::limits::{MAX_PACKET_SIZE, PROTOCOL_VERSION};
use std::fmt;
use std::io::{self, Read, Write};

/// The size of a frame's header.
pub const HEADER_SIZE: usize = 4;

/// The size of the version each end sends first.
pub const VERSION_SIZE: usize = 4;

/// The version bytes this end sends: [`PROTOCOL_VERSION`], little-endian.
pub const fn version_bytes() -> [u8; VERSION_SIZE] {
    PROTOCOL_VERSION.to_le_bytes()
}

/// Checks the version bytes the other end sent: `Err` with its version if
/// it isn't this one (abandon the connection then).
pub const fn check_version(bytes: [u8; VERSION_SIZE]) -> Result<(), u32> {
    let theirs = u32::from_le_bytes(bytes);
    if theirs == PROTOCOL_VERSION {
        Ok(())
    } else {
        Err(theirs)
    }
}

/// Sends this end's version, on a blocking stream.
pub fn write_version<W: Write>(writer: &mut W) -> io::Result<()> {
    writer.write_all(&version_bytes())
}

/// Reads the other end's version, on a blocking stream: compare it with
/// [`check_version()`].
pub fn read_version<R: Read>(reader: &mut R) -> io::Result<[u8; VERSION_SIZE]> {
    let mut bytes = [0; VERSION_SIZE];
    reader.read_exact(&mut bytes)?;
    Ok(bytes)
}

/// Why a frame is invalid. Either aborts the connection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameError {
    /// A frame of 0 bytes.
    Empty,
    /// A frame bigger than the limit.
    TooBig {
        /// Its size.
        size: usize,
        /// The limit.
        max: usize,
    },
}

impl fmt::Display for FrameError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            FrameError::Empty => f.write_str("an empty frame"),
            FrameError::TooBig { size, max } => {
                write!(f, "a frame of {size} bytes, over the limit of {max}")
            }
        }
    }
}

impl std::error::Error for FrameError {}

fn check(size: usize, max: usize) -> Result<(), FrameError> {
    if size == 0 {
        Err(FrameError::Empty)
    } else if size > max {
        Err(FrameError::TooBig { size, max })
    } else {
        Ok(())
    }
}

/// `packet` as a frame: its size, then itself. Fails if it's empty or over
/// [`MAX_PACKET_SIZE`].
pub fn encode(packet: &[u8]) -> Result<Vec<u8>, FrameError> {
    check(packet.len(), MAX_PACKET_SIZE)?;
    let mut frame = Vec::with_capacity(HEADER_SIZE + packet.len());
    frame.extend_from_slice(&(packet.len() as u32).to_le_bytes());
    frame.extend_from_slice(packet);
    Ok(frame)
}

/// Writes `packet` as a frame, in one write.
pub fn write<W: Write>(writer: &mut W, packet: &[u8]) -> io::Result<()> {
    let frame =
        encode(packet).map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;
    writer.write_all(&frame)
}

/// Reads the next frame's packet, at most `max` bytes.
///
/// `Ok(None)` when the stream ended cleanly, before the next frame. An
/// error of kind `UnexpectedEof` if it ended inside one, `InvalidData` (a
/// [`FrameError`] inside) if its size is 0 or over `max`.
pub fn read<R: Read>(reader: &mut R, max: usize) -> io::Result<Option<Vec<u8>>> {
    let mut header = [0u8; HEADER_SIZE];
    let mut got = 0;
    while got < HEADER_SIZE {
        match reader.read(&mut header[got..]) {
            Ok(0) if got == 0 => return Ok(None),
            Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
            Ok(count) => got += count,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    let size = u32::from_le_bytes(header) as usize;
    check(size, max).map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    let mut packet = vec![0; size];
    reader.read_exact(&mut packet)?;
    Ok(Some(packet))
}

/// The frames as `tokio-util` cuts and writes them, for the async server:
/// the same as [`read()`] and [`write()`], packets of up to `max` bytes
/// ([`MAX_PACKET_SIZE`] at most). Use it with `tokio_util::codec::Framed`.
#[cfg(feature = "tokio")]
pub fn codec(max: usize) -> tokio_util::codec::LengthDelimitedCodec {
    tokio_util::codec::LengthDelimitedCodec::builder()
        .little_endian()
        .length_field_length(HEADER_SIZE)
        .max_frame_length(max.min(MAX_PACKET_SIZE))
        .new_codec()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blocking_round_trip() {
        let mut stream = Vec::new();
        write(&mut stream, b"abc").unwrap();
        write(&mut stream, &[7; 300]).unwrap();
        assert_eq!(&stream[..7], &[3, 0, 0, 0, b'a', b'b', b'c']);

        let mut reader = &stream[..];
        assert_eq!(read(&mut reader, 1000).unwrap(), Some(b"abc".to_vec()));
        assert_eq!(read(&mut reader, 1000).unwrap(), Some(vec![7; 300]));
        assert_eq!(read(&mut reader, 1000).unwrap(), None);
    }

    #[test]
    fn versions() {
        let mut stream = Vec::new();
        write_version(&mut stream).unwrap();
        assert_eq!(stream, [7, 0, 0, 0]);
        let bytes = read_version(&mut &stream[..]).unwrap();
        assert_eq!(check_version(bytes), Ok(()));
        assert_eq!(check_version([6, 0, 0, 0]), Err(6));
        assert_eq!(check_version([8, 0, 0, 0]), Err(8));
        assert!(read_version(&mut &[7u8, 0][..]).is_err());
    }

    #[test]
    fn blocking_refusals() {
        assert_eq!(encode(&[]), Err(FrameError::Empty));
        assert!(write(&mut Vec::new(), &[]).is_err());

        let kind = |bytes: &[u8], max| read(&mut &bytes[..], max).unwrap_err().kind();
        assert_eq!(kind(&[0, 0, 0, 0], 10), io::ErrorKind::InvalidData);
        assert_eq!(kind(&[11, 0, 0, 0], 10), io::ErrorKind::InvalidData);
        assert_eq!(kind(&[3, 0], 10), io::ErrorKind::UnexpectedEof);
        assert_eq!(kind(&[3, 0, 0, 0, 1], 10), io::ErrorKind::UnexpectedEof);
    }

    #[cfg(feature = "tokio")]
    mod codec {
        use super::super::*;
        use bytes::{Bytes, BytesMut};
        use tokio_util::codec::{Decoder, Encoder};

        #[test]
        fn the_same_frames() {
            let mut codec = codec(MAX_PACKET_SIZE);
            let mut written = BytesMut::new();
            codec
                .encode(Bytes::from_static(b"abc"), &mut written)
                .unwrap();
            assert_eq!(&written[..], &encode(b"abc").unwrap()[..]);
        }

        #[test]
        fn byte_by_byte() {
            let mut stream = encode(b"first").unwrap();
            stream.extend(encode(&[1; 70_000]).unwrap());
            stream.extend(encode(b"third").unwrap());

            let mut codec = codec(100_000);
            let mut buffer = BytesMut::new();
            let mut packets = Vec::new();
            for byte in &stream {
                buffer.extend_from_slice(&[*byte]);
                while let Some(packet) = codec.decode(&mut buffer).unwrap() {
                    packets.push(packet.to_vec());
                }
            }
            assert_eq!(
                packets,
                vec![b"first".to_vec(), vec![1; 70_000], b"third".to_vec()]
            );
        }

        #[test]
        fn refused_as_soon_as_the_size_came() {
            let mut codec = codec(10);
            let mut buffer = BytesMut::from(&[11u8, 0, 0][..]);
            assert!(codec.decode(&mut buffer).unwrap().is_none());
            buffer.extend_from_slice(&[0]);
            assert!(codec.decode(&mut buffer).is_err());

            // Never above the protocol's limit.
            assert_eq!(
                super::super::codec(usize::MAX).max_frame_length(),
                MAX_PACKET_SIZE
            );
        }

        #[test]
        fn an_empty_frame_is_an_empty_packet() {
            let mut codec = codec(10);
            let mut buffer = BytesMut::from(&[0u8, 0, 0, 0][..]);
            let packet = codec.decode(&mut buffer).unwrap().unwrap();
            assert!(crate::Packet::decode(&packet).is_err());
        }
    }
}
