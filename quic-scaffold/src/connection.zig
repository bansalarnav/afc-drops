//! QUIC connection state machine (RFC 9000 Section 4 and related).
//!
//! A `Connection` is the top-level object tying together packet
//! processing, the TLS handshake, and per-stream state: it decrypts and
//! parses incoming packets (`packet.zig`), dispatches contained frames
//! (`frame.zig`) to the right stream (`stream.zig`) or to itself (for
//! connection-level frames like MAX_DATA), and drives the TLS handshake
//! (`tls.zig`) to derive packet-protection keys.
//!
//! This module does not perform any I/O itself; callers push received
//! datagrams in and pull packets to send out, so the same state machine can
//! back a sync or async transport.

const std = @import("std");
const packet = @import("packet.zig");
const frame = @import("frame.zig");
const stream_mod = @import("stream.zig");
const tls = @import("tls.zig");

/// High-level connection lifecycle state (RFC 9000 Section 4, collapsed to
/// the phases that matter for API consumers).
pub const State = enum {
    idle,
    handshaking,
    established,
    closing,
    draining,
    closed,
};

/// Why a connection was closed, mirroring CONNECTION_CLOSE semantics.
pub const CloseReason = struct {
    error_code: u64,
    is_application_error: bool,
    reason_phrase: []const u8 = &.{},
};

/// Configuration needed to create a `Connection`.
pub const Options = struct {
    allocator: std.mem.Allocator,
    is_server: bool,
    /// Connection ID this endpoint has chosen for itself.
    local_conn_id: packet.ConnectionId,
    /// Server name for client connections (used for the TLS SNI /
    /// certificate validation); unused for servers.
    server_name: []const u8 = &.{},
};

/// A single QUIC connection.
pub const Connection = struct {
    allocator: std.mem.Allocator,
    state: State = .idle,
    is_server: bool,
    local_conn_id: packet.ConnectionId,
    remote_conn_id: packet.ConnectionId = .{},
    handshake: tls.Handshake = .{},
    streams: stream_mod.StreamMap,
    close_reason: ?CloseReason = null,

    pub fn init(options: Options) !Connection {
        return .{
            .allocator = options.allocator,
            .is_server = options.is_server,
            .local_conn_id = options.local_conn_id,
            .streams = stream_mod.StreamMap.init(options.allocator),
        };
    }

    pub fn deinit(self: *Connection) void {
        self.streams.deinit();
    }

    /// Feeds a single received, still-encrypted UDP datagram into the
    /// connection. May contain one or more coalesced QUIC packets.
    pub fn recvDatagram(self: *Connection, data: []const u8) !void {
        _ = self;
        _ = data;
        unreachable; // TODO: implement connection.Connection.recvDatagram
    }

    /// Writes the next outgoing datagram (if any) into `out`, returning the
    /// number of bytes written, or 0 if there is nothing to send right now.
    pub fn sendDatagram(self: *Connection, out: []u8) !usize {
        _ = self;
        _ = out;
        unreachable; // TODO: implement connection.Connection.sendDatagram
    }

    /// Opens a new locally-initiated stream and returns its ID.
    pub fn openStream(self: *Connection, directionality: stream_mod.Directionality) !stream_mod.StreamId {
        _ = self;
        _ = directionality;
        unreachable; // TODO: implement connection.Connection.openStream
    }

    /// Dispatches a single decoded frame from a decrypted packet payload.
    fn handleFrame(self: *Connection, f: frame.Frame) !void {
        _ = self;
        _ = f;
        unreachable; // TODO: implement connection.Connection.handleFrame
    }

    /// Begins closing the connection with the given reason, per RFC 9000
    /// Section 10.
    pub fn close(self: *Connection, reason: CloseReason) void {
        _ = reason;
        self.state = .closing;
        unreachable; // TODO: implement connection.Connection.close
    }
};

test "module compiles" {
    try std.testing.expect(true);
}
