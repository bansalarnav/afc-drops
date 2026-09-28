//! QUIC frame types (RFC 9000 Section 19).
//!
//! Frames are carried inside the (decrypted) payload of a QUIC packet, one
//! or more per packet. This module defines the frame type tags and payload
//! shapes, plus stub encode/decode entry points. Packet-level concerns
//! (headers, packet numbers) live in `packet.zig`; connection/stream state
//! that reacts to frames lives in `connection.zig` / `stream.zig`.

const std = @import("std");
const varint = @import("varint.zig");

/// Frame type codes, per RFC 9000 Section 19. STREAM and
/// DATAGRAM frame types are actually ranges (low bits carry flags); the
/// canonical/base value is listed here.
pub const FrameType = enum(u64) {
    padding = 0x00,
    ping = 0x01,
    ack = 0x02,
    ack_ecn = 0x03,
    reset_stream = 0x04,
    stop_sending = 0x05,
    crypto = 0x06,
    new_token = 0x07,
    stream = 0x08, // 0x08..0x0f, low 3 bits are flags (FIN/LEN/OFF)
    max_data = 0x10,
    max_stream_data = 0x11,
    max_streams_bidi = 0x12,
    max_streams_uni = 0x13,
    data_blocked = 0x14,
    stream_data_blocked = 0x15,
    streams_blocked_bidi = 0x16,
    streams_blocked_uni = 0x17,
    new_connection_id = 0x18,
    retire_connection_id = 0x19,
    path_challenge = 0x1a,
    path_response = 0x1b,
    connection_close_transport = 0x1c,
    connection_close_app = 0x1d,
    handshake_done = 0x1e,
};

pub const PingFrame = struct {};

pub const CryptoFrame = struct {
    offset: u64,
    data: []const u8,
};

pub const StreamFrame = struct {
    stream_id: u64,
    offset: u64 = 0,
    data: []const u8,
    fin: bool = false,
};

pub const AckRange = struct {
    gap: u64,
    ack_range_len: u64,
};

pub const AckFrame = struct {
    largest_acknowledged: u64,
    ack_delay: u64,
    first_ack_range: u64,
    ranges: []const AckRange = &.{},
};

pub const ConnectionCloseFrame = struct {
    error_code: u64,
    /// Set only for the transport-level (0x1c) variant.
    frame_type: ?u64 = null,
    reason: []const u8 = &.{},
};

pub const MaxDataFrame = struct {
    maximum_data: u64,
};

pub const ResetStreamFrame = struct {
    stream_id: u64,
    application_error_code: u64,
    final_size: u64,
};

/// A decoded QUIC frame. Only a representative subset of frame types has a
/// dedicated payload struct so far; the rest can be added as this scaffold
/// grows into a real implementation.
pub const Frame = union(enum) {
    padding: void,
    ping: PingFrame,
    ack: AckFrame,
    crypto: CryptoFrame,
    stream: StreamFrame,
    reset_stream: ResetStreamFrame,
    max_data: MaxDataFrame,
    connection_close: ConnectionCloseFrame,
    handshake_done: void,
};

/// Errors that can occur while decoding a frame.
pub const ParseError = error{
    BufferTooShort,
    UnknownFrameType,
    MalformedFrame,
} || varint.DecodeError;

/// Errors that can occur while encoding a frame.
pub const EncodeError = error{
    BufferTooShort,
} || varint.EncodeError;

/// Parses a single frame from the start of `in`. Returns the frame and the
/// number of bytes consumed.
pub const ParseResult = struct {
    frame: Frame,
    consumed: usize,
};

pub fn parse(in: []const u8) ParseError!ParseResult {
    _ = in;
    unreachable; // TODO: implement frame.parse
}

/// Serializes `frame` into `out`, returning the number of bytes written.
pub fn encode(out: []u8, frame: Frame) EncodeError!usize {
    _ = out;
    _ = frame;
    unreachable; // TODO: implement frame.encode
}

test "module compiles" {
    try std.testing.expect(true);
}
