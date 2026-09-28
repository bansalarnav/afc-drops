//! QUIC streams (RFC 9000 Section 2 and Section 3).
//!
//! QUIC multiplexes independent, ordered byte streams over a single
//! connection. Streams can be client- or server-initiated, and
//! bidirectional or unidirectional; the low two bits of a stream ID encode
//! that. Each direction of each stream has its own send/receive state
//! machine (RFC 9000 Section 3) and flow-control limits.
//!
//! This module owns per-stream state and buffering. Frame (de)serialization
//! for STREAM/RESET_STREAM/etc. lives in `frame.zig`; `connection.zig` is
//! responsible for routing incoming frames to the right `Stream` and for
//! connection-level flow control.

const std = @import("std");

/// A QUIC stream identifier. The two low bits encode initiator and
/// directionality; see `initiator` and `directionality` below.
pub const StreamId = u64;

pub const Initiator = enum {
    client,
    server,
};

pub const Directionality = enum {
    bidirectional,
    unidirectional,
};

pub fn initiator(id: StreamId) Initiator {
    _ = id;
    unreachable; // TODO: implement stream.initiator (bit 0 of id)
}

pub fn directionality(id: StreamId) Directionality {
    _ = id;
    unreachable; // TODO: implement stream.directionality (bit 1 of id)
}

/// Send-side stream states (RFC 9000 Section 3.1).
pub const SendState = enum {
    ready,
    send,
    data_sent,
    data_recvd,
    reset_sent,
    reset_recvd,
};

/// Receive-side stream states (RFC 9000 Section 3.2).
pub const RecvState = enum {
    recv,
    size_known,
    data_recvd,
    data_read,
    reset_recvd,
    reset_read,
};

/// Per-stream flow-control accounting for one direction.
pub const FlowControl = struct {
    /// Highest offset sent/received so far.
    consumed: u64 = 0,
    /// Highest offset the peer has authorized.
    max: u64 = 0,
};

/// State for a single QUIC stream. Bidirectional streams use both
/// `send` and `recv`; unidirectional streams only populate the side that
/// applies to this endpoint.
pub const Stream = struct {
    id: StreamId,
    send_state: SendState = .ready,
    recv_state: RecvState = .recv,
    send_flow: FlowControl = .{},
    recv_flow: FlowControl = .{},

    pub fn init(id: StreamId) Stream {
        return .{ .id = id };
    }

    /// Queues `data` for sending on this stream.
    pub fn write(self: *Stream, data: []const u8, fin: bool) !usize {
        _ = self;
        _ = data;
        _ = fin;
        unreachable; // TODO: implement stream write buffering
    }

    /// Copies received, in-order stream data into `out`, returning the
    /// number of bytes read.
    pub fn read(self: *Stream, out: []u8) !usize {
        _ = self;
        _ = out;
        unreachable; // TODO: implement stream read buffering
    }
};

/// Owns the set of streams for one connection, keyed by `StreamId`, plus
/// bookkeeping for the next locally-initiated stream IDs.
pub const StreamMap = struct {
    allocator: std.mem.Allocator,
    streams: std.AutoHashMapUnmanaged(StreamId, Stream) = .{},

    pub fn init(allocator: std.mem.Allocator) StreamMap {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StreamMap) void {
        self.streams.deinit(self.allocator);
    }

    pub fn get(self: *StreamMap, id: StreamId) ?*Stream {
        return self.streams.getPtr(id);
    }

    pub fn getOrOpen(self: *StreamMap, id: StreamId) !*Stream {
        _ = self;
        _ = id;
        unreachable; // TODO: implement stream.StreamMap.getOrOpen
    }
};

test "module compiles" {
    try std.testing.expect(true);
}
