//! QUIC variable-length integer encoding (RFC 9000, Section 16).
//!
//! QUIC packets and frames encode non-negative integers up to 62 bits using
//! a prefix-length scheme: the two most significant bits of the first byte
//! encode the length of the encoding (1, 2, 4, or 8 bytes), and the
//! remaining bits (across all bytes) hold the value.
//!
//! This module will own encoding/decoding of that format plus helpers for
//! computing the encoded length of a value ahead of time (useful for
//! pre-sizing buffers when building packets/frames).

const std = @import("std");

/// Largest value representable by a QUIC variable-length integer (2^62 - 1).
pub const max_value: u64 = (1 << 62) - 1;

/// Errors that can occur while decoding a variable-length integer.
pub const DecodeError = error{
    /// Not enough bytes remained in the input to decode a full value.
    BufferTooShort,
};

/// Errors that can occur while encoding a variable-length integer.
pub const EncodeError = error{
    /// Value exceeds `max_value` and cannot be represented.
    ValueTooLarge,
};

/// Number of bytes needed to encode `value` as a QUIC varint (1, 2, 4, or 8).
pub fn encodedLength(value: u64) EncodeError!u8 {
    _ = value;
    unreachable; // TODO: implement varint.encodedLength
}

/// Encodes `value` as a QUIC variable-length integer into `out`, returning
/// the number of bytes written. `out` must be at least
/// `encodedLength(value)` bytes long.
pub fn encode(out: []u8, value: u64) EncodeError!usize {
    _ = out;
    _ = value;
    unreachable; // TODO: implement varint.encode
}

/// Result of decoding a QUIC variable-length integer.
pub const DecodeResult = struct {
    value: u64,
    consumed: usize,
};

/// Decodes a QUIC variable-length integer from the start of `in`.
/// Returns the decoded value and the number of bytes consumed.
pub fn decode(in: []const u8) DecodeError!DecodeResult {
    _ = in;
    unreachable; // TODO: implement varint.decode
}

test "module compiles" {
    // Placeholder: real tests should cover the boundary values 63, 16383,
    // 1073741823, and max_value once encode/decode are implemented.
    try std.testing.expect(true);
}
