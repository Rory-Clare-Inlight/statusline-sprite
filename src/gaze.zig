//! DOOM-style idle gaze animation: which of the three status bar face frames
//! (forward / looking left / looking right) to show, and whether the session
//! is active enough to animate at all.

const std = @import("std");
const Io = std.Io;

pub const forward: u2 = 0;

/// The game repicks a random idle gaze every half second
/// (ST_STRAIGHTFACECOUNT = TICRATE/2); we mirror that cadence.
const bucket_ms: i64 = 500;

/// How long after the last observed work signal the face keeps animating.
pub const default_timeout_ms: i64 = 2500;

/// Gaze frame for this instant: pseudo-random per 500 ms wall-clock bucket,
/// deterministic within a bucket so multiple runs inside one bucket agree.
/// Returns 0 (forward), 1 (left) or 2 (right).
pub fn selectGaze(now_ms: i64) u2 {
    const bucket: u64 = @bitCast(@divFloor(now_ms, bucket_ms));
    const h = std.hash.Wyhash.hash(0x600d_9aee, std.mem.asBytes(&bucket));
    return @intCast(h % 3);
}

/// Whether the session is actively working, judged by `work_sig` (a hash of
/// statusline fields that only change while Claude does API work). State is a
/// tiny per-session file in `state_dir`: "<sig> <ms of last sig change>".
/// A changed (or unreadable) signature stamps the file and reports active;
/// an unchanged one reports active until `timeout_ms` since the stamp.
/// All failures degrade to inactive-safe behavior, never an error.
pub fn isActive(
    gpa: std.mem.Allocator,
    io: Io,
    state_dir: std.Io.Dir,
    session_id: []const u8,
    work_sig: u64,
    now_ms: i64,
    timeout_ms: i64,
) bool {
    const name = std.fmt.allocPrint(gpa, "statusline-sprite-{s}.state", .{session_id}) catch return false;
    defer gpa.free(name);

    if (state_dir.readFileAlloc(io, name, gpa, .limited(256)) catch null) |bytes| {
        defer gpa.free(bytes);
        if (parseState(bytes)) |st| {
            if (st.sig == work_sig) return (now_ms - st.ts) < timeout_ms;
        }
    }
    writeState(gpa, io, state_dir, name, work_sig, now_ms);
    return true;
}

const State = struct { sig: u64, ts: i64 };

fn parseState(bytes: []const u8) ?State {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    const space = std.mem.indexOfScalar(u8, trimmed, ' ') orelse return null;
    const sig = std.fmt.parseInt(u64, trimmed[0..space], 10) catch return null;
    const ts = std.fmt.parseInt(i64, trimmed[space + 1 ..], 10) catch return null;
    return .{ .sig = sig, .ts = ts };
}

fn writeState(
    gpa: std.mem.Allocator,
    io: Io,
    dir: std.Io.Dir,
    name: []const u8,
    sig: u64,
    ts: i64,
) void {
    const content = std.fmt.allocPrint(gpa, "{d} {d}", .{ sig, ts }) catch return;
    defer gpa.free(content);
    dir.writeFile(io, .{ .sub_path = name, .data = content }) catch {};
}

test "selectGaze: deterministic within a bucket and always in range" {
    const g = selectGaze(1000);
    try std.testing.expectEqual(g, selectGaze(1499)); // same 500 ms bucket
    try std.testing.expect(g < 3);
}

test "selectGaze: varies across buckets" {
    var seen = [_]bool{ false, false, false };
    var i: i64 = 0;
    while (i < 40) : (i += 1) seen[selectGaze(i * bucket_ms)] = true;
    var distinct: u8 = 0;
    for (seen) |s| {
        if (s) distinct += 1;
    }
    // 40 buckets landing on a single frame would mean a broken hash.
    try std.testing.expect(distinct >= 2);
}

test "isActive: sig change stamps state and reports active" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const io = std.testing.io;

    // First sighting of this session: active.
    try std.testing.expect(isActive(a, io, tmp.dir, "s1", 111, 10_000, 2500));
    // Same sig shortly after: still active (within timeout of the stamp).
    try std.testing.expect(isActive(a, io, tmp.dir, "s1", 111, 11_000, 2500));
    // Same sig beyond the timeout: idle.
    try std.testing.expect(!isActive(a, io, tmp.dir, "s1", 111, 13_000, 2500));
    // Work resumes (sig changes): active again.
    try std.testing.expect(isActive(a, io, tmp.dir, "s1", 222, 13_000, 2500));
}

test "isActive: corrupt state file recovers as active" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{
        .sub_path = "statusline-sprite-s2.state",
        .data = "not a state file",
    });
    try std.testing.expect(isActive(a, io, tmp.dir, "s2", 5, 1_000, 2500));
    // And the rewrite made it parseable: unchanged sig within timeout is active.
    try std.testing.expect(isActive(a, io, tmp.dir, "s2", 5, 2_000, 2500));
    // ...and idle after the timeout.
    try std.testing.expect(!isActive(a, io, tmp.dir, "s2", 5, 9_000, 2500));
}

test "isActive: sessions do not share state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const io = std.testing.io;

    try std.testing.expect(isActive(a, io, tmp.dir, "a", 1, 1_000, 2500));
    // Session "b" with the same sig is a fresh sighting, not a continuation.
    try std.testing.expect(isActive(a, io, tmp.dir, "b", 1, 900_000, 2500));
}
