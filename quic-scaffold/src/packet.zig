//! QUIC packet framing: header parsing/construction for both long-header
//! packets (Initial, 0-RTT, Handshake, Retry) and short-header (1-RTT)
//! packets, per RFC 9000 Section 17.
//!
//! This module is concerned with the *packet* layer only: header fields,
//! packet numbers, and connection IDs. Frame contents carried inside the
//! (decrypted) packet payload live in `frame.zig`. Header/payload
//! protection (AEAD sealing, header protection masks) belongs in
//! `tls.zig` or a future `protection.zig`, and is out of scope here.

const std = @import("std");
const varint = @import("varint.zig");

/// Maximum length of a QUIC connection ID, in bytes (RFC 9000 Section 17.2).
pub const max_connection_id_len: u8 = 20;

/// A QUIC connection ID: a short opaque byte string used to identify a
/// connection independent of network path (addr/port tuple).
pub const ConnectionId = struct {
    bytes: [max_connection_id_len]u8 = std.mem.zeroes([max_connection_id_len]u8),
    len: u8 = 0,

    pub fn slice(self: *const ConnectionId) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// The long-header packet types defined by RFC 9000 Section 17.2.
pub const LongPacketType = enum(u2) {
    initial = 0x0,
    zero_rtt = 0x1,
    handshake = 0x2,
    retry = 0x3,
};

/// Discriminates between the long-header and short-header packet forms.
pub const PacketForm = enum {
    long,
    short,
};

/// Fields common to all long-header packet types.
pub const LongHeader = struct {
    packet_type: LongPacketType,
    version: u32,
    dest_conn_id: ConnectionId,
    src_conn_id: ConnectionId,
    /// Present on Initial packets only; omitted (len 0) otherwise.
    token: []const u8 = &.{},
    /// Length of the remaining packet (packet number + payload), as carried
    /// on Initial/0-RTT/Handshake packets.
    length: u64 = 0,
};

/// Fields for a short-header (1-RTT) packet.
pub const ShortHeader = struct {
    dest_conn_id: ConnectionId,
    spin_bit: bool,
    key_phase: bool,
};

/// A parsed (but not yet payload-decrypted) packet header.
pub const Header = union(PacketForm) {
    long: LongHeader,
    short: ShortHeader,
};

/// Errors that can occur while parsing a packet header.
pub const ParseError = error{
    BufferTooShort,
    UnsupportedVersion,
    MalformedHeader,
} || varint.DecodeError;

/// Errors that can occur while serializing a packet header.
pub const EncodeError = error{
    BufferTooShort,
} || varint.EncodeError;

/// Parses a packet header from the start of `in`. `dcid_len` is the length
/// of destination connection IDs this endpoint expects on short-header
/// packets (it is not self-describing, unlike on long-header packets).
///
/// Returns the parsed header and the number of bytes consumed (i.e. the
/// offset at which the packet number / protected payload begins).
pub const ParseResult = struct {
    header: Header,
    consumed: usize,
};

pub fn parseHeader(in: []const u8, dcid_len: u8) ParseError!ParseResult {
    _ = in;
    _ = dcid_len;
    unreachable; // TODO: implement packet.parseHeader
}

/// Serializes `header` into `out`, returning the number of bytes written.
pub fn encodeHeader(out: []u8, header: Header) EncodeError!usize {
    _ = out;
    _ = header;
    unreachable; // TODO: implement packet.encodeHeader
}

test "module compiles" {
    try std.testing.expect(true);
}
