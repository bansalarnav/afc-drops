//! Demo/CLI entry point for the QUIC scaffold.
//!
//! Not a real client or server yet -- the protocol logic in the `quic`
//! module is all stubbed out. This just proves the executable links
//! against the library module and prints a banner, so the overall project
//! layout can be exercised with `zig build run`.

const std = @import("std");
const quic = @import("quic");

pub fn main() !void {
    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("quic-scaffold: no protocol logic implemented yet.\n", .{});
    try stdout.print("varint.max_value = {d}\n", .{quic.varint.max_value});
    try stdout.print("packet.max_connection_id_len = {d}\n", .{quic.packet.max_connection_id_len});
    try stdout.flush();
}

test "module compiles" {
    try std.testing.expect(true);
}
