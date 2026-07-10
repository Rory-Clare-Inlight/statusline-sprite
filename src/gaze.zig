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
/// Only used by the legacy work-signal fallback (no transcript path).
pub const default_timeout_ms: i64 = 2500;

/// Grace window after the transcript's last append during which the session
/// still counts as busy even when the tail reads as idle. Covers the gap
/// where Claude Code has written one content block (e.g. leading text) but
/// is still generating the next (e.g. a large tool call), which appends
/// nothing until it completes.
pub const default_grace_ms: i64 = 5000;

/// How much of the transcript tail to inspect. Only the last main-chain
/// entry matters; 64 KiB comfortably covers it plus trailing sidechain noise.
const tail_read_len: u64 = 64 * 1024;

/// A busy-looking tail only counts while the transcript changed this
/// recently. Sessions can end on a busy-shaped entry (closed or errored
/// mid-turn, before any reply landed) and nothing legitimate runs this long
/// without appending, so past the ceiling the face goes still.
pub const busy_ceiling_ms: i64 = 30 * std.time.ms_per_min;

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

/// Whether Claude is busy -- anything other than sitting at the prompt
/// waiting for the next user input -- judged by the session transcript.
/// The JSONL tail is the primary signal (see busyFromTranscriptTail); when
/// the tail reads idle or unclassifiable, a recent mtime still counts as
/// busy so the face keeps moving through append gaps mid-generation.
/// A missing or unreadable transcript reports idle.
pub fn isBusy(
    gpa: std.mem.Allocator,
    io: Io,
    transcript_path: []const u8,
    now_ms: i64,
    grace_ms: i64,
) bool {
    const f = std.Io.Dir.cwd().openFile(io, transcript_path, .{ .mode = .read_only }) catch return false;
    defer f.close(io);
    const st = f.stat(io) catch return false;

    const read_len: usize = @intCast(@min(st.size, tail_read_len));
    const offset = st.size - read_len;
    const buf = gpa.alloc(u8, read_len) catch return false;
    defer gpa.free(buf);
    const n = f.readPositionalAll(io, buf, offset) catch return false;

    const mtime_ms: i64 = @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_ms));
    const age_ms = now_ms - mtime_ms;
    if (busyFromTranscriptTail(buf[0..n], offset != 0)) |busy| {
        if (busy) return age_ms < busy_ceiling_ms;
    }
    return age_ms < grace_ms;
}

/// Classify a transcript tail: true = Claude is working, false = the last
/// turn ended and Claude awaits user input, null = nothing classifiable.
/// Scans entries from the end, skipping sidechain (subagent) lines -- while
/// a subagent runs, the main chain's pending Agent tool_use is what decides.
/// A user entry means Claude is generating a response (unless it records an
/// interrupt, which lands the session back at the prompt); an assistant
/// entry with a tool_use block means a tool is running or awaiting approval,
/// and one with a thinking block is mid-turn; an assistant entry with
/// neither closed the turn. Matching is on compact
/// JSON substrings: inside JSONL strings every quote is escaped, so a bare
/// `"type":"user"` can only be structure, never message text.
/// `truncated` marks a tail that starts mid-line; the earliest fragment is
/// then never classified.
pub fn busyFromTranscriptTail(tail: []const u8, truncated: bool) ?bool {
    var it = std.mem.splitBackwardsScalar(u8, tail, '\n');
    while (it.next()) |raw| {
        if (truncated and it.rest().len == 0) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, "\"isSidechain\":true") != null) continue;
        if (std.mem.indexOf(u8, line, "\"type\":\"user\"") != null)
            return std.mem.indexOf(u8, line, "[Request interrupted by user") == null;
        if (std.mem.indexOf(u8, line, "\"type\":\"assistant\"") != null)
            return std.mem.indexOf(u8, line, "\"type\":\"tool_use\"") != null or
                std.mem.indexOf(u8, line, "\"type\":\"thinking\"") != null;
    }
    return null;
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

test "busyFromTranscriptTail: user entry means generating" {
    const tail =
        \\{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"text","text":"done"}]}}
        \\{"type":"user","isSidechain":false,"message":{"content":[{"type":"text","text":"do the thing"}]}}
    ;
    try std.testing.expectEqual(@as(?bool, true), busyFromTranscriptTail(tail, false));
}

test "busyFromTranscriptTail: pending tool_use means busy" {
    const tail =
        \\{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"text","text":"Running tests."},{"type":"tool_use","name":"Bash","input":{}}]}}
    ;
    try std.testing.expectEqual(@as(?bool, true), busyFromTranscriptTail(tail, false));
}

test "busyFromTranscriptTail: text-only assistant entry means turn ended" {
    const tail =
        \\{"type":"user","isSidechain":false,"message":{"content":[{"type":"tool_result","content":"ok"}]}}
        \\{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"text","text":"All green."}]}}
        \\
    ;
    try std.testing.expectEqual(@as(?bool, false), busyFromTranscriptTail(tail, false));
}

test "busyFromTranscriptTail: sidechain entries are skipped" {
    // Subagent chatter last; the main chain's pending Agent tool_use decides.
    const tail =
        \\{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"tool_use","name":"Agent","input":{}}]}}
        \\{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"subagent done"}]}}
    ;
    try std.testing.expectEqual(@as(?bool, true), busyFromTranscriptTail(tail, false));
}

test "busyFromTranscriptTail: thinking-only assistant entry is mid-turn" {
    const tail =
        \\{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"thinking","thinking":"hmm"}]}}
    ;
    try std.testing.expectEqual(@as(?bool, true), busyFromTranscriptTail(tail, false));
}

test "busyFromTranscriptTail: non-message records are skipped" {
    const tail =
        \\{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"text","text":"bye"}]}}
        \\{"type":"mode","mode":"normal","sessionId":"x"}
        \\{"type":"last-prompt","leafUuid":"y","sessionId":"x"}
    ;
    try std.testing.expectEqual(@as(?bool, false), busyFromTranscriptTail(tail, false));
}

test "busyFromTranscriptTail: interrupt lands back at the prompt" {
    const tail =
        \\{"type":"user","isSidechain":false,"message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}
    ;
    try std.testing.expectEqual(@as(?bool, false), busyFromTranscriptTail(tail, false));
}

test "busyFromTranscriptTail: empty or unclassifiable tail yields null" {
    try std.testing.expectEqual(@as(?bool, null), busyFromTranscriptTail("", false));
    try std.testing.expectEqual(@as(?bool, null), busyFromTranscriptTail("{\"type\":\"summary\"}\n", false));
}

test "busyFromTranscriptTail: truncated leading fragment is not classified" {
    // Looks like a user entry but is the partial first line of a truncated
    // read, so it must not decide.
    const tail =
        \\ext","text":"...\"type\":\"user\" mentioned"}]},"type":"user","uuid":"x"}
    ;
    try std.testing.expectEqual(@as(?bool, null), busyFromTranscriptTail(tail, true));
}

test "isBusy: busy tail wins over zero grace, but not past the ceiling" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{
        .sub_path = "t.jsonl",
        .data = "{\"type\":\"user\",\"isSidechain\":false,\"message\":{}}\n",
    });
    const path = try tmp.dir.realPathFileAlloc(io, "t.jsonl", a);
    defer a.free(path);

    // Freshly written file, zero grace: only the busy tail can explain busy.
    const now_ms = Io.Clock.now(.real, io).toMilliseconds();
    try std.testing.expect(isBusy(a, io, path, now_ms, 0));
    // Same busy tail long abandoned (session died mid-turn): still, not busy.
    try std.testing.expect(!isBusy(a, io, path, now_ms + busy_ceiling_ms + 1000, 0));
}

test "isBusy: idle tail with stale mtime reports idle, recent mtime busy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{
        .sub_path = "t.jsonl",
        .data = "{\"type\":\"assistant\",\"isSidechain\":false,\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}\n",
    });
    const path = try tmp.dir.realPathFileAlloc(io, "t.jsonl", a);
    defer a.free(path);
    // Stale: now far beyond mtime + grace.
    try std.testing.expect(!isBusy(a, io, path, 1 << 60, 0));
    // Recent: an enormous grace keeps the just-written file busy.
    try std.testing.expect(isBusy(a, io, path, 1 << 60, std.math.maxInt(i64)));
}

test "isBusy: missing transcript reports idle" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expect(!isBusy(a, io, "/nonexistent/nope.jsonl", 0, 5000));
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
