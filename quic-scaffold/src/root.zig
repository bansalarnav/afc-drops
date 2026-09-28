//! Public entry point for the `quic` library module.
//!
//! This scaffold organizes the protocol into one file per concern:
//!
//!   - `varint`     — QUIC variable-length integer codec (wire primitive).
//!   - `packet`     — packet header parsing/construction.
//!   - `frame`      — frame type definitions and (de)serialization.
//!   - `stream`     — per-stream state and flow control.
//!   - `tls`        — TLS 1.3 handshake integration and key derivation.
//!   - `connection` — the top-level connection state machine tying the
//!                    above together.
//!
//! Downstream users should generally only need `connection.Connection`;
//! the rest are exposed for testing and for advanced use (e.g. building a
//! custom packet pacer or a proxy that only needs header parsing).

pub const varint = @import("varint.zig");
pub const packet = @import("packet.zig");
pub const frame = @import("frame.zig");
pub const stream = @import("stream.zig");
pub const tls = @import("tls.zig");
pub const connection = @import("connection.zig");

pub const Connection = connection.Connection;

test {
    // Ensures `zig build test` discovers tests in every submodule above,
    // since only files reachable via @import from a test root are scanned.
    @import("std").testing.refAllDecls(@This());
}
