const std = @import("std");
const Io = std.Io;

/// The statusline's fixed line count. The sprite grid, the text lines, and the
/// assembled block all share this height; it is a layout invariant, not a knob.
pub const line_count = 3;

/// Assemble the three-line text block, optionally prefixed by sprite cells.
///
/// With `sprite_rows == null` the block is just the text lines joined by '\n'.
/// Otherwise each line is `sprite_rows[i] ++ gap ++ text_lines[i]`, and
/// `sprite_rows` must have exactly `line_count` entries. No trailing newline.
pub fn assembleRows(
    allocator: std.mem.Allocator,
    sprite_rows: ?[]const []const u8,
    text_lines: [line_count][]const u8,
    gap: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    if (sprite_rows) |rows| {
        if (rows.len != line_count) return error.SpriteRowCountMismatch;
        for (0..line_count) |i| {
            if (i > 0) try out.append(allocator, '\n');
            try out.appendSlice(allocator, rows[i]);
            try out.appendSlice(allocator, gap);
            try out.appendSlice(allocator, text_lines[i]);
        }
    } else {
        for (0..line_count) |i| {
            if (i > 0) try out.append(allocator, '\n');
            try out.appendSlice(allocator, text_lines[i]);
        }
    }

    return out.toOwnedSlice(allocator);
}

/// Display width of `s` in terminal columns: CSI escape sequences (`ESC [`
/// through their final byte) contribute nothing, every remaining codepoint
/// counts as one column. Wide glyphs and combining marks are approximated at
/// width 1, which is accurate for statusline content.
pub fn visibleWidth(s: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b == 0x1b) {
            if (i + 1 < s.len and s[i + 1] == '[') {
                i += 2;
                while (i < s.len) : (i += 1) {
                    if (s[i] >= 0x40 and s[i] <= 0x7e) {
                        i += 1;
                        break;
                    }
                }
            } else {
                i += 1;
            }
            continue;
        }
        // Count UTF-8 lead bytes only, so multi-byte codepoints are 1 column.
        if ((b & 0xC0) != 0x80) w += 1;
        i += 1;
    }
    return w;
}

/// Like `assembleRows`, but pins the sprite to the horizontal center of a
/// `term_width`-column terminal: each row is `text ++ padding ++ sprite`,
/// with the sprite starting at `(term_width - sprite_cols) / 2`. A text line
/// too long for that keeps a minimum 2-space gap and pushes the sprite right
/// on its row only. Without sprite rows this is a plain text join.
pub fn assembleRowsCentered(
    allocator: std.mem.Allocator,
    sprite_rows: ?[]const []const u8,
    text_lines: [line_count][]const u8,
    sprite_cols: u32,
    term_width: u32,
) ![]u8 {
    const rows = sprite_rows orelse return assembleRows(allocator, null, text_lines, "");
    if (rows.len != line_count) return error.SpriteRowCountMismatch;

    const center_start: usize =
        if (term_width > sprite_cols) (term_width - sprite_cols) / 2 else 0;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (0..line_count) |i| {
        if (i > 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, text_lines[i]);
        const tw = visibleWidth(text_lines[i]);
        const start = @max(center_start, tw + 2);
        try out.appendNTimes(allocator, ' ', start - tw);
        try out.appendSlice(allocator, rows[i]);
    }
    return out.toOwnedSlice(allocator);
}

/// First non-blank line of `bytes` (trailing CR stripped). Leading blank lines
/// are skipped so multi-line prompt commands (e.g. `starship prompt`, which
/// leads with an empty line) still yield their content. Empty if all blank.
fn firstLine(bytes: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len > 0) return line;
    }
    return bytes[0..0];
}

/// Run `sh -c "<cmd>"`, capture stdout, enforce a wall-clock `timeout_ms`.
///
/// Returns an owned slice containing only the FIRST line of stdout (with any
/// trailing CR/LF stripped). Any failure -- spawn error, non-zero exit,
/// timeout, empty stdout -- yields an empty owned slice. Errors are NEVER
/// propagated: a broken prompt command must not break the statusline.
pub fn runCommand(
    allocator: std.mem.Allocator,
    io: Io,
    cmd: []const u8,
    timeout_ms: u64,
) []u8 {
    const empty: []u8 = &.{};

    const argv = [_][]const u8{ "sh", "-c", cmd };
    const timeout: Io.Timeout = .{ .duration = .{
        .raw = Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
        .clock = .awake,
    } };

    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .timeout = timeout.toDeadline(io),
    }) catch return empty;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return empty,
        else => return empty,
    }

    return allocator.dupe(u8, firstLine(result.stdout)) catch empty;
}

test "visibleWidth: plain ascii" {
    try std.testing.expectEqual(@as(usize, 3), visibleWidth("abc"));
}

test "visibleWidth: SGR sequences add no width" {
    try std.testing.expectEqual(@as(usize, 3), visibleWidth("\x1b[38;5;100mabc\x1b[0m"));
}

test "visibleWidth: multi-byte codepoints count once" {
    // U+23F5 is 3 bytes in UTF-8; two of them are 2 columns here.
    try std.testing.expectEqual(@as(usize, 2), visibleWidth("\u{23F5}\u{23F5}"));
}

test "visibleWidth: empty and dangling escape do not crash" {
    try std.testing.expectEqual(@as(usize, 0), visibleWidth(""));
    try std.testing.expectEqual(@as(usize, 0), visibleWidth("\x1b["));
    try std.testing.expectEqual(@as(usize, 1), visibleWidth("\x1b[0ma"));
}

test "assembleRowsCentered: sprite starts at (width - cols) / 2" {
    const a = std.testing.allocator;
    const sprite = [_][]const u8{ "S0", "S1", "S2" };
    // width 40, cols 6 -> sprite column 17. "abc" is 3 wide -> 14 pad spaces.
    const out = try assembleRowsCentered(a, &sprite, .{ "abc", "", "" }, 6, 40);
    defer a.free(out);
    try std.testing.expectEqualStrings(
        "abc" ++ " " ** 14 ++ "S0\n" ++ " " ** 17 ++ "S1\n" ++ " " ** 17 ++ "S2",
        out,
    );
}

test "assembleRowsCentered: SGR in text does not shift the sprite" {
    const a = std.testing.allocator;
    const sprite = [_][]const u8{ "S0", "S1", "S2" };
    const out = try assembleRowsCentered(a, &sprite, .{ "\x1b[36mabc\x1b[0m", "", "" }, 6, 40);
    defer a.free(out);
    try std.testing.expectEqualStrings(
        "\x1b[36mabc\x1b[0m" ++ " " ** 14 ++ "S0\n" ++ " " ** 17 ++ "S1\n" ++ " " ** 17 ++ "S2",
        out,
    );
}

test "assembleRowsCentered: long text clamps to a 2-space gap" {
    const a = std.testing.allocator;
    const sprite = [_][]const u8{ "S0", "S1", "S2" };
    const long = "abcdefghijklmnopqrst"; // 20 wide > center col 17
    const out = try assembleRowsCentered(a, &sprite, .{ long, "", "" }, 6, 40);
    defer a.free(out);
    try std.testing.expectEqualStrings(
        long ++ "  S0\n" ++ " " ** 17 ++ "S1\n" ++ " " ** 17 ++ "S2",
        out,
    );
}

test "assembleRowsCentered: null sprite joins text lines" {
    const a = std.testing.allocator;
    const out = try assembleRowsCentered(a, null, .{ "L1", "L2", "L3" }, 6, 40);
    defer a.free(out);
    try std.testing.expectEqualStrings("L1\nL2\nL3", out);
}

test "assembleRows: no sprite joins text lines with newlines, no trailing" {
    const a = std.testing.allocator;
    const out = try assembleRows(a, null, .{ "L1", "L2", "L3" }, "  ");
    defer a.free(out);
    try std.testing.expectEqualStrings("L1\nL2\nL3", out);
}

test "assembleRows: sprite prefix with gap per line" {
    const a = std.testing.allocator;
    const sprite = [_][]const u8{ "S0", "S1", "S2" };
    const out = try assembleRows(a, &sprite, .{ "a", "b", "c" }, "  ");
    defer a.free(out);
    try std.testing.expectEqualStrings("S0  a\nS1  b\nS2  c", out);
}

test "assembleRows: empty text line still yields its sprite-prefixed line" {
    const a = std.testing.allocator;
    const sprite = [_][]const u8{ "S0", "S1", "S2" };
    const out = try assembleRows(a, &sprite, .{ "a", "", "c" }, "|");
    defer a.free(out);
    try std.testing.expectEqualStrings("S0|a\nS1|\nS2|c", out);
}

test "assembleRows: wrong sprite row count errors" {
    const a = std.testing.allocator;
    const sprite = [_][]const u8{ "S0", "S1" };
    try std.testing.expectError(
        error.SpriteRowCountMismatch,
        assembleRows(a, &sprite, .{ "a", "b", "c" }, " "),
    );
}

test "runCommand: echo returns first line only" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const hi = runCommand(a, io, "echo hi", 2000);
    defer a.free(hi);
    try std.testing.expectEqualStrings("hi", hi);

    const first = runCommand(a, io, "printf 'hi\\nsecond'", 2000);
    defer a.free(first);
    try std.testing.expectEqualStrings("hi", first);
}

test "runCommand: non-zero exit with no stdout yields empty" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const out = runCommand(a, io, "false", 2000);
    defer a.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "runCommand: timeout kills child and returns empty promptly" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const start = Io.Clock.now(.awake, io);
    const out = runCommand(a, io, "sleep 1", 50);
    const elapsed_ms = start.durationTo(Io.Clock.now(.awake, io)).toMilliseconds();
    defer a.free(out);

    try std.testing.expectEqual(@as(usize, 0), out.len);
    // Must not have blocked for the full 1s sleep.
    try std.testing.expect(elapsed_ms < 800);
}
