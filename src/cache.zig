const std = @import("std");
const Io = std.Io;

pub const max_entries = 16;

pub const Entry = struct { image_id: u32, png_hash: u64 };

/// Which (image_id, png content) pairs have already been transmitted to a
/// given tty. `tty_ctime` fingerprints the pty node: a recreated pane/terminal
/// gets a fresh ctime, invalidating every entry at once. Known gap: tmux
/// detach -> reattach from a NEW terminal leaves the pane tty untouched, so
/// the sprite won't re-render until the next content change.
pub const State = struct {
    tty_ctime: i96 = 0,
    len: usize = 0,
    entries: [max_entries]Entry = undefined,
};

/// Tolerant: bad magic, short line, or unparsable field yields empty state
/// (=> retransmit). Never an error.
pub fn parse(bytes: []const u8) State {
    var state: State = .{};

    var it = std.mem.splitScalar(u8, bytes, '\n');
    const header = std.mem.trim(u8, it.next() orelse return state, " \t\r");
    if (!std.mem.startsWith(u8, header, "v1 ")) return state;
    state.tty_ctime = std.fmt.parseInt(i96, header[3..], 10) catch return state;

    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (state.len == max_entries) break;

        const space = std.mem.indexOfScalar(u8, line, ' ') orelse return .{ .tty_ctime = state.tty_ctime };
        const id = std.fmt.parseInt(u32, line[0..space], 10) catch return .{ .tty_ctime = state.tty_ctime };
        const hash = std.fmt.parseInt(u64, line[space + 1 ..], 16) catch return .{ .tty_ctime = state.tty_ctime };
        state.entries[state.len] = .{ .image_id = id, .png_hash = hash };
        state.len += 1;
    }

    return state;
}

/// Caller owns the returned slice.
pub fn serialize(allocator: std.mem.Allocator, state: State) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.print(allocator, "v1 {d}\n", .{state.tty_ctime});
    for (state.entries[0..state.len]) |e|
        try out.print(allocator, "{d} {x}\n", .{ e.image_id, e.png_hash });

    return out.toOwnedSlice(allocator);
}

pub fn isHit(state: State, tty_ctime: i96, image_id: u32, png_hash: u64) bool {
    if (state.tty_ctime != tty_ctime) return false;
    for (state.entries[0..state.len]) |e| {
        if (e.image_id == image_id and e.png_hash == png_hash) return true;
    }
    return false;
}

/// Ctime mismatch wipes all entries first (the terminal's image store is
/// gone); then upserts. Silently drops the entry when full — worst case is a
/// redundant retransmit, never an error.
pub fn record(state: *State, tty_ctime: i96, image_id: u32, png_hash: u64) void {
    if (state.tty_ctime != tty_ctime) {
        state.tty_ctime = tty_ctime;
        state.len = 0;
    }
    for (state.entries[0..state.len]) |*e| {
        if (e.image_id == image_id) {
            e.png_hash = png_hash;
            return;
        }
    }
    if (state.len == max_entries) return;
    state.entries[state.len] = .{ .image_id = image_id, .png_hash = png_hash };
    state.len += 1;
}

/// "<tmpdir>/statusline-sprite-<key>.state"; tmpdir falls back to "/tmp",
/// trailing '/' trimmed. Key = tty path with '/' -> '_', plus
/// "-w<KITTY_WINDOW_ID>" when present (distinguishes kitty restarts outside
/// tmux, where /dev/tty's ctime never changes). Caller owns the slice.
pub fn statePath(
    allocator: std.mem.Allocator,
    tmpdir: ?[]const u8,
    tty_path: []const u8,
    kitty_window_id: ?[]const u8,
) ![]u8 {
    var dir: []const u8 = "/tmp";
    if (tmpdir) |t| {
        const trimmed = std.mem.trimEnd(u8, t, "/");
        if (trimmed.len != 0) dir = trimmed;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.print(allocator, "{s}/statusline-sprite-", .{dir});
    for (tty_path) |b| try out.append(allocator, if (b == '/') '_' else b);
    if (kitty_window_id) |w| {
        if (w.len != 0) try out.print(allocator, "-w{s}", .{w});
    }
    try out.appendSlice(allocator, ".state");

    return out.toOwnedSlice(allocator);
}

/// State file held under an exclusive advisory lock for the whole
/// read -> decide -> tty-write -> commit critical section, serializing
/// concurrent statusline instances. Lock releases on close/process death.
pub const Locked = struct {
    file: Io.File,
    state: State,

    pub fn open(io: Io, path: []const u8) !Locked {
        const file = try Io.Dir.createFileAbsolute(io, path, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
        });
        errdefer file.close(io);

        var buf: [4096]u8 = undefined;
        const n = try file.readPositionalAll(io, &buf, 0);
        return .{ .file = file, .state = parse(buf[0..n]) };
    }

    pub fn commit(self: *Locked, allocator: std.mem.Allocator, io: Io) !void {
        const bytes = try serialize(allocator, self.state);
        defer allocator.free(bytes);
        try self.file.writePositionalAll(io, bytes, 0);
        try self.file.setLength(io, bytes.len);
    }

    pub fn close(self: *Locked, io: Io) void {
        self.file.close(io);
    }
};

test "serialize/parse round trip" {
    const a = std.testing.allocator;
    var state: State = .{ .tty_ctime = -1234567890123456789 };
    record(&state, state.tty_ctime, 100, 0xdeadbeefcafe1234);
    record(&state, state.tty_ctime, 101, 0);

    const bytes = try serialize(a, state);
    defer a.free(bytes);

    const back = parse(bytes);
    try std.testing.expectEqual(state.tty_ctime, back.tty_ctime);
    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqual(@as(u32, 100), back.entries[0].image_id);
    try std.testing.expectEqual(@as(u64, 0xdeadbeefcafe1234), back.entries[0].png_hash);
    try std.testing.expectEqual(@as(u32, 101), back.entries[1].image_id);
    try std.testing.expectEqual(@as(u64, 0), back.entries[1].png_hash);
}

test "parse tolerates malformed input" {
    try std.testing.expectEqual(@as(usize, 0), parse("").len);
    try std.testing.expectEqual(@as(i96, 0), parse("").tty_ctime);
    try std.testing.expectEqual(@as(usize, 0), parse("v2 123\n100 ff\n").len);
    try std.testing.expectEqual(@as(usize, 0), parse("v1 notanumber\n").len);

    // Garbage entry line wipes entries but keeps the ctime.
    const garbled = parse("v1 42\n100 ff\nnonsense\n");
    try std.testing.expectEqual(@as(usize, 0), garbled.len);
    try std.testing.expectEqual(@as(i96, 42), garbled.tty_ctime);

    // Blank lines are fine.
    const blanks = parse("v1 42\n\n100 ff\n\n");
    try std.testing.expectEqual(@as(usize, 1), blanks.len);
}

test "parse caps entries at max_entries" {
    const a = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    try bytes.appendSlice(a, "v1 1\n");
    var i: u32 = 0;
    while (i < max_entries + 4) : (i += 1) try bytes.print(a, "{d} ff\n", .{i});

    try std.testing.expectEqual(@as(usize, max_entries), parse(bytes.items).len);
}

test "isHit: hit, unknown id, hash mismatch, ctime mismatch" {
    var state: State = .{ .tty_ctime = 7 };
    record(&state, 7, 100, 0xabc);

    try std.testing.expect(isHit(state, 7, 100, 0xabc));
    try std.testing.expect(!isHit(state, 7, 101, 0xabc));
    try std.testing.expect(!isHit(state, 7, 100, 0xdef));
    try std.testing.expect(!isHit(state, 8, 100, 0xabc));
}

test "record: upsert, ctime wipe, capacity overflow" {
    var state: State = .{ .tty_ctime = 1 };
    record(&state, 1, 100, 0xa);
    record(&state, 1, 100, 0xb);
    try std.testing.expectEqual(@as(usize, 1), state.len);
    try std.testing.expectEqual(@as(u64, 0xb), state.entries[0].png_hash);

    record(&state, 1, 101, 0xc);
    try std.testing.expectEqual(@as(usize, 2), state.len);

    // New ctime wipes previous entries.
    record(&state, 2, 102, 0xd);
    try std.testing.expectEqual(@as(i96, 2), state.tty_ctime);
    try std.testing.expectEqual(@as(usize, 1), state.len);
    try std.testing.expectEqual(@as(u32, 102), state.entries[0].image_id);

    var i: u32 = 0;
    while (i < max_entries + 4) : (i += 1) record(&state, 2, 200 + i, 0xe);
    try std.testing.expectEqual(@as(usize, max_entries), state.len);
}

test "statePath variants" {
    const a = std.testing.allocator;

    const p1 = try statePath(a, "/tmp/x/", "/dev/ttys011", null);
    defer a.free(p1);
    try std.testing.expectEqualStrings("/tmp/x/statusline-sprite-_dev_ttys011.state", p1);

    const p2 = try statePath(a, null, "/dev/ttys011", null);
    defer a.free(p2);
    try std.testing.expectEqualStrings("/tmp/statusline-sprite-_dev_ttys011.state", p2);

    const p3 = try statePath(a, "/tmp", "/dev/tty", "3");
    defer a.free(p3);
    try std.testing.expectEqualStrings("/tmp/statusline-sprite-_dev_tty-w3.state", p3);
}

test "Locked: missing file opens empty, commit round-trips" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const path = try std.fmt.allocPrint(a, "{s}/test.state", .{dir});
    defer a.free(path);

    var locked = try Locked.open(io, path);
    try std.testing.expectEqual(@as(usize, 0), locked.state.len);
    record(&locked.state, 9, 100, 0xfeed);
    try locked.commit(a, io);
    locked.close(io);

    var reopened = try Locked.open(io, path);
    defer reopened.close(io);
    try std.testing.expect(isHit(reopened.state, 9, 100, 0xfeed));
}

test "Locked: commit shrinks the file" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const path = try std.fmt.allocPrint(a, "{s}/test.state", .{dir});
    defer a.free(path);

    {
        var locked = try Locked.open(io, path);
        defer locked.close(io);
        var i: u32 = 0;
        while (i < 3) : (i += 1) record(&locked.state, 1, 100 + i, 0xff);
        try locked.commit(a, io);
    }
    {
        var locked = try Locked.open(io, path);
        defer locked.close(io);
        try std.testing.expectEqual(@as(usize, 3), locked.state.len);
        locked.state.len = 1;
        try locked.commit(a, io);
    }

    var final = try Locked.open(io, path);
    defer final.close(io);
    try std.testing.expectEqual(@as(usize, 1), final.state.len);
}

test "Locked: second opener cannot take the lock" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const path = try std.fmt.allocPrint(a, "{s}/test.state", .{dir});
    defer a.free(path);

    var locked = try Locked.open(io, path);
    defer locked.close(io);

    // Advisory flock conflicts across separate fds even within one process.
    const other = try Io.Dir.openFileAbsolute(io, path, .{});
    defer other.close(io);
    try std.testing.expect(!try other.tryLock(io, .exclusive));
}
