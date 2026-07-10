const std = @import("std");
const Allocator = std.mem.Allocator;

/// Horizontal placement of the sprite within the terminal.
pub const Align = enum { left, center };

pub const Sprite = struct {
    dir: []const u8,
    tiers: u32,
    scale_tokens: u64,
    box_cols: u32,
    /// Explicit per-tier face paths. Null means "derive from dir" (see `deriveFaces`).
    faces: ?[]const []const u8,
    @"align": Align,
    /// Idle gaze animation while the session is active. Only takes effect when
    /// gaze frames (face<N>l.png / face<N>r.png) exist next to the tier faces.
    animate: bool,
};

pub const Line = struct {
    command: ?[]const u8,
};

pub const Line2 = struct {
    /// 256-color palette index for the model name. Null means unstyled.
    color: ?u8,
};

pub const Config = struct {
    sprite: Sprite,
    line1: Line,
    line2: Line2,
    line3: Line,
    /// Backing storage for any strings parsed from TOML. Null for the pure
    /// `defaults()` value, whose strings are program-lifetime literals.
    arena: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Config) void {
        if (self.arena) |arena| {
            const child = arena.child_allocator;
            arena.deinit();
            child.destroy(arena);
            self.arena = null;
        }
    }
};

pub fn defaults() Config {
    return .{
        .sprite = .{
            .dir = "./test-sprites",
            .tiers = 5,
            .scale_tokens = 200000,
            .box_cols = 6,
            .faces = null,
            .@"align" = .left,
            .animate = true,
        },
        .line1 = .{ .command = null },
        .line2 = .{ .color = null },
        .line3 = .{ .command = null },
        .arena = null,
    };
}

/// Pure path resolver: `$XDG_CONFIG_HOME/statusline-sprite/config.toml` when
/// `xdg_config_home` is set, else `$HOME/.config/statusline-sprite/config.toml`.
/// Kept free of real-environment reads so it can be unit-tested deterministically.
/// Caller owns the returned slice.
pub fn resolveConfigPath(
    allocator: Allocator,
    xdg_config_home: ?[]const u8,
    home: ?[]const u8,
) ![]u8 {
    if (xdg_config_home) |xdg| {
        if (xdg.len != 0)
            return std.fmt.allocPrint(allocator, "{s}/statusline-sprite/config.toml", .{xdg});
    }
    if (home) |h| {
        if (h.len != 0)
            return std.fmt.allocPrint(allocator, "{s}/.config/statusline-sprite/config.toml", .{h});
    }
    return error.NoConfigDir;
}

/// Resolve the config path from the process environment, read it, and parse.
/// A missing file yields `defaults()` rather than an error.
pub fn load(allocator: Allocator, io: std.Io, environ: std.process.Environ) !Config {
    const xdg: ?[]const u8 = environ.getPosix("XDG_CONFIG_HOME");
    const home: ?[]const u8 = environ.getPosix("HOME");

    const path = resolveConfigPath(allocator, xdg, home) catch return defaults();
    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return defaults(),
        else => return err,
    };
    defer allocator.free(bytes);

    return loadFromToml(allocator, bytes);
}

pub fn loadFromToml(allocator: Allocator, toml_bytes: []const u8) !Config {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const a = arena.allocator();

    var cfg = defaults();
    cfg.arena = arena;

    var current_table: []const u8 = "";
    var it = std.mem.splitScalar(u8, toml_bytes, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            current_table = std.mem.trim(u8, line[1..end], " \t");
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (key.len == 0 or rhs.len == 0) continue;

        try applyKey(a, &cfg, current_table, key, rhs);
    }

    return cfg;
}

fn applyKey(a: Allocator, cfg: *Config, table: []const u8, key: []const u8, rhs: []const u8) !void {
    if (std.mem.eql(u8, table, "sprite")) {
        if (std.mem.eql(u8, key, "dir")) {
            if (try parseString(a, rhs)) |v| cfg.sprite.dir = v;
        } else if (std.mem.eql(u8, key, "tiers")) {
            if (parseInt(u32, rhs)) |v| cfg.sprite.tiers = v;
        } else if (std.mem.eql(u8, key, "scale_tokens")) {
            if (parseInt(u64, rhs)) |v| cfg.sprite.scale_tokens = v;
        } else if (std.mem.eql(u8, key, "box_cols")) {
            if (parseInt(u32, rhs)) |v| cfg.sprite.box_cols = v;
        } else if (std.mem.eql(u8, key, "faces")) {
            if (try parseStringArray(a, rhs)) |v| cfg.sprite.faces = v;
        } else if (std.mem.eql(u8, key, "align")) {
            // Unknown values keep the default (left), matching the parser's
            // forgiving posture everywhere else.
            if (try parseString(a, rhs)) |v| {
                if (std.mem.eql(u8, v, "center")) cfg.sprite.@"align" = .center;
            }
        } else if (std.mem.eql(u8, key, "animate")) {
            if (parseBool(rhs)) |v| cfg.sprite.animate = v;
        }
    } else if (std.mem.eql(u8, table, "line1")) {
        if (std.mem.eql(u8, key, "command")) {
            if (try parseString(a, rhs)) |v| cfg.line1.command = v;
        }
    } else if (std.mem.eql(u8, table, "line2")) {
        if (std.mem.eql(u8, key, "color")) {
            if (parseInt(u8, rhs)) |v| cfg.line2.color = v;
        }
    } else if (std.mem.eql(u8, table, "line3")) {
        if (std.mem.eql(u8, key, "command")) {
            if (try parseString(a, rhs)) |v| cfg.line3.command = v;
        }
    }
    // Unknown tables/keys are ignored.
}

/// Parse a double-quoted string, duping its contents into `a`. Returns null on
/// anything that isn't a `"..."` literal.
fn parseString(a: Allocator, rhs: []const u8) !?[]const u8 {
    if (rhs.len < 2 or rhs[0] != '"') return null;
    const close = std.mem.indexOfScalarPos(u8, rhs, 1, '"') orelse return null;
    return try a.dupe(u8, rhs[1..close]);
}

/// Parse an integer, tolerating a trailing `# comment`.
fn parseInt(comptime T: type, rhs: []const u8) ?T {
    const hash = std.mem.indexOfScalar(u8, rhs, '#');
    const token = std.mem.trim(u8, if (hash) |h| rhs[0..h] else rhs, " \t");
    return std.fmt.parseInt(T, token, 10) catch null;
}

/// Parse a bare `true`/`false`, tolerating a trailing `# comment`.
fn parseBool(rhs: []const u8) ?bool {
    const hash = std.mem.indexOfScalar(u8, rhs, '#');
    const token = std.mem.trim(u8, if (hash) |h| rhs[0..h] else rhs, " \t");
    if (std.mem.eql(u8, token, "true")) return true;
    if (std.mem.eql(u8, token, "false")) return false;
    return null;
}

/// Parse a single-line array of double-quoted strings, e.g. `["a.png", "b.png"]`.
fn parseStringArray(a: Allocator, rhs: []const u8) !?[]const []const u8 {
    if (rhs.len == 0 or rhs[0] != '[') return null;

    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(a);

    var i: usize = 1;
    while (i < rhs.len) {
        const open = std.mem.indexOfScalarPos(u8, rhs, i, '"') orelse break;
        const close = std.mem.indexOfScalarPos(u8, rhs, open + 1, '"') orelse break;
        try list.append(a, try a.dupe(u8, rhs[open + 1 .. close]));
        i = close + 1;
    }

    return try list.toOwnedSlice(a);
}

/// Derive default face paths `<dir>/face<N>.png` for N in 0..tiers. Caller owns
/// the result; free with `freeFaces`. Used when `sprite.faces` is unset.
pub fn deriveFaces(allocator: Allocator, dir: []const u8, tiers: u32) ![][]u8 {
    const list = try allocator.alloc([]u8, tiers);
    var n: u32 = 0;
    errdefer {
        var j: u32 = 0;
        while (j < n) : (j += 1) allocator.free(list[j]);
        allocator.free(list);
    }
    while (n < tiers) : (n += 1) {
        list[n] = try std.fmt.allocPrint(allocator, "{s}/face{d}.png", .{ dir, n });
    }
    return list;
}

pub fn freeFaces(allocator: Allocator, faces: [][]u8) void {
    for (faces) |f| allocator.free(f);
    allocator.free(faces);
}

test "defaults returns documented values" {
    const cfg = defaults();
    try std.testing.expectEqualStrings("./test-sprites", cfg.sprite.dir);
    try std.testing.expectEqual(@as(u32, 5), cfg.sprite.tiers);
    try std.testing.expectEqual(@as(u64, 200000), cfg.sprite.scale_tokens);
    try std.testing.expectEqual(@as(u32, 6), cfg.sprite.box_cols);
    try std.testing.expectEqual(@as(?[]const []const u8, null), cfg.sprite.faces);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.line1.command);
    try std.testing.expectEqual(@as(?u8, null), cfg.line2.color);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.line3.command);
}

test "loadFromToml merges partial overrides over defaults" {
    const toml =
        \\[sprite]
        \\dir = "/opt/sprites"
        \\tiers = 8
        \\
        \\[line1]
        \\command = "echo hi"
    ;
    var cfg = try loadFromToml(std.testing.allocator, toml);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("/opt/sprites", cfg.sprite.dir);
    try std.testing.expectEqual(@as(u32, 8), cfg.sprite.tiers);
    try std.testing.expectEqualStrings("echo hi", cfg.line1.command.?);

    // Untouched fields keep their defaults.
    try std.testing.expectEqual(@as(u64, 200000), cfg.sprite.scale_tokens);
    try std.testing.expectEqual(@as(u32, 6), cfg.sprite.box_cols);
    try std.testing.expectEqual(@as(?[]const []const u8, null), cfg.sprite.faces);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.line3.command);
}

test "loadFromToml parses line2 color" {
    const toml =
        \\[line2]
        \\color = 213
    ;
    var cfg = try loadFromToml(std.testing.allocator, toml);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(?u8, 213), cfg.line2.color);
}

test "loadFromToml ignores out-of-range line2 color" {
    const toml =
        \\[line2]
        \\color = 999
    ;
    var cfg = try loadFromToml(std.testing.allocator, toml);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(?u8, null), cfg.line2.color);
}

test "loadFromToml parses a faces array" {
    const toml =
        \\[sprite]
        \\faces = ["a.png", "b.png"]
    ;
    var cfg = try loadFromToml(std.testing.allocator, toml);
    defer cfg.deinit();

    const faces = cfg.sprite.faces.?;
    try std.testing.expectEqual(@as(usize, 2), faces.len);
    try std.testing.expectEqualStrings("a.png", faces[0]);
    try std.testing.expectEqualStrings("b.png", faces[1]);
}

test "align defaults to left, parses center, junk falls back to left" {
    const d = defaults();
    try std.testing.expectEqual(Align.left, d.sprite.@"align");

    const toml =
        \\[sprite]
        \\align = "center"
    ;
    var cfg = try loadFromToml(std.testing.allocator, toml);
    defer cfg.deinit();
    try std.testing.expectEqual(Align.center, cfg.sprite.@"align");

    const junk =
        \\[sprite]
        \\align = "diagonal"
    ;
    var cfg2 = try loadFromToml(std.testing.allocator, junk);
    defer cfg2.deinit();
    try std.testing.expectEqual(Align.left, cfg2.sprite.@"align");
}

test "animate defaults to true and parses false" {
    const d = defaults();
    try std.testing.expectEqual(true, d.sprite.animate);

    const toml =
        \\[sprite]
        \\animate = false
    ;
    var cfg = try loadFromToml(std.testing.allocator, toml);
    defer cfg.deinit();
    try std.testing.expectEqual(false, cfg.sprite.animate);
}

test "loadFromToml on empty/whitespace input equals defaults" {
    const toml = "   \n\t\n  # just a comment\n   \n";
    var cfg = try loadFromToml(std.testing.allocator, toml);
    defer cfg.deinit();

    const d = defaults();
    try std.testing.expectEqualStrings(d.sprite.dir, cfg.sprite.dir);
    try std.testing.expectEqual(d.sprite.tiers, cfg.sprite.tiers);
    try std.testing.expectEqual(d.sprite.scale_tokens, cfg.sprite.scale_tokens);
    try std.testing.expectEqual(d.sprite.box_cols, cfg.sprite.box_cols);
    try std.testing.expectEqual(@as(?[]const []const u8, null), cfg.sprite.faces);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.line1.command);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.line3.command);
}

test "resolveConfigPath honours XDG_CONFIG_HOME when set" {
    const path = try resolveConfigPath(std.testing.allocator, "/xdg", "/home/me");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/xdg/statusline-sprite/config.toml", path);
}

test "resolveConfigPath falls back to HOME/.config" {
    const path = try resolveConfigPath(std.testing.allocator, null, "/home/me");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/home/me/.config/statusline-sprite/config.toml", path);

    const path2 = try resolveConfigPath(std.testing.allocator, "", "/home/me");
    defer std.testing.allocator.free(path2);
    try std.testing.expectEqualStrings("/home/me/.config/statusline-sprite/config.toml", path2);
}

test "resolveConfigPath errors when no home is available" {
    try std.testing.expectError(error.NoConfigDir, resolveConfigPath(std.testing.allocator, null, null));
}

/// Build a minimal POSIX `Environ` exposing a single `HOME=<home>` entry (and
/// no `XDG_CONFIG_HOME`), for driving `load` deterministically in tests. Free
/// with `freeTestEnviron`.
fn testEnvironWithHome(a: Allocator, home: []const u8) !std.process.Environ {
    const entry = try std.fmt.allocPrintSentinel(a, "HOME={s}", .{home}, 0);
    const slice = try a.allocSentinel(?[*:0]const u8, 1, null);
    slice[0] = entry.ptr;
    return .{ .block = .{ .slice = slice } };
}

fn freeTestEnviron(a: Allocator, environ: std.process.Environ) void {
    a.free(std.mem.span(environ.block.slice[0].?));
    a.free(environ.block.slice);
}

test "load returns defaults when config file is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // An isolated HOME with no statusline-sprite/config.toml under it.
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);

    const environ = try testEnvironWithHome(std.testing.allocator, home);
    defer freeTestEnviron(std.testing.allocator, environ);

    var cfg = try load(std.testing.allocator, std.testing.io, environ);
    defer cfg.deinit();

    const d = defaults();
    try std.testing.expectEqualStrings(d.sprite.dir, cfg.sprite.dir);
    try std.testing.expectEqual(d.sprite.tiers, cfg.sprite.tiers);
    try std.testing.expectEqual(d.sprite.scale_tokens, cfg.sprite.scale_tokens);
    try std.testing.expectEqual(d.sprite.box_cols, cfg.sprite.box_cols);
    try std.testing.expectEqual(@as(?[]const []const u8, null), cfg.sprite.faces);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.line1.command);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.line3.command);
}

test "load reads and parses an existing config file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cfg_dir = try tmp.dir.createDirPathOpen(std.testing.io, ".config/statusline-sprite", .{});
    defer cfg_dir.close(std.testing.io);
    try cfg_dir.writeFile(std.testing.io, .{
        .sub_path = "config.toml",
        .data =
        \\[sprite]
        \\dir = "/opt/sprites"
        ,
    });

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);

    const environ = try testEnvironWithHome(std.testing.allocator, home);
    defer freeTestEnviron(std.testing.allocator, environ);

    var cfg = try load(std.testing.allocator, std.testing.io, environ);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("/opt/sprites", cfg.sprite.dir);
    // Untouched fields keep their defaults.
    try std.testing.expectEqual(@as(u32, 5), cfg.sprite.tiers);
}

test "deriveFaces builds <dir>/face<N>.png" {
    const faces = try deriveFaces(std.testing.allocator, "./sprites", 3);
    defer freeFaces(std.testing.allocator, faces);
    try std.testing.expectEqual(@as(usize, 3), faces.len);
    try std.testing.expectEqualStrings("./sprites/face0.png", faces[0]);
    try std.testing.expectEqualStrings("./sprites/face1.png", faces[1]);
    try std.testing.expectEqualStrings("./sprites/face2.png", faces[2]);
}
