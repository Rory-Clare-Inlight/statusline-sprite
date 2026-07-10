const std = @import("std");
const config = @import("config.zig");
const gaze = @import("gaze.zig");
const statusline = @import("statusline.zig");
const tier = @import("tier.zig");
const kitty = @import("kitty.zig");
const rows = @import("rows.zig");
const cache = @import("cache.zig");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const environ = init.minimal.environ;

    const stdin_bytes = readStdin(gpa, io) catch &.{};
    defer gpa.free(stdin_bytes);

    const parsed: ?statusline.ParsedStatusline = statusline.parse(gpa, stdin_bytes) catch null;
    defer if (parsed) |p| p.deinit();
    const sl: statusline.Statusline = if (parsed) |p| p.value else .{
        .model_display_name = "",
        .total_input_tokens = 0,
        .used_percentage = null,
        .context_window_size = null,
    };

    var cfg = config.load(gpa, io, environ) catch config.defaults();
    defer cfg.deinit();

    const tokens = tier.tokensFrom(sl);
    const tier_idx = tier.selectTier(tokens, cfg.sprite.scale_tokens, cfg.sprite.tiers);
    // Three ids per tier, one per gaze frame. Base 100 keeps every id <= 255
    // so it fits a 256-color palette index; the placeholder cell encodes the
    // id via `38;5;<id>` (see kitty.placeholderGrid).
    const base_id: u32 = 100 + tier_idx * 3;

    const frames = readFaces(gpa, io, cfg, tier_idx);
    defer for (frames) |f| {
        if (f) |b| gpa.free(b);
    };

    // Gaze pick: animate the whole time Claude is working -- generating,
    // running tools, driving subagents -- and go still only once the turn
    // ends and the session sits waiting for user input (like the game
    // between fights). The transcript tail is the busy signal; the legacy
    // work-signal heuristic remains as a fallback when the statusline JSON
    // carries no transcript path. All three frames stay uploaded; the pick
    // just selects which image id the placeholder cells reference this run.
    const now_ms = Io.Clock.now(.real, io).toMilliseconds();
    const active = blk: {
        if (!cfg.sprite.animate) break :blk false;
        if (sl.transcript_path) |tp|
            break :blk gaze.isBusy(gpa, io, tp, now_ms, gaze.default_grace_ms);
        const tmp_path = environ.getPosix("TMPDIR") orelse "/tmp";
        var state_dir = std.Io.Dir.openDirAbsolute(io, tmp_path, .{}) catch break :blk false;
        defer state_dir.close(io);
        const sig_src: [2]u64 = .{ sl.api_duration_ms orelse 0, sl.total_input_tokens orelse 0 };
        const work_sig = std.hash.Wyhash.hash(0, std.mem.asBytes(&sig_src));
        break :blk gaze.isActive(
            gpa,
            io,
            state_dir,
            sl.session_id orelse "default",
            work_sig,
            now_ms,
            gaze.default_timeout_ms,
        );
    };
    const available: [3]bool = .{ frames[0] != null, frames[1] != null, frames[2] != null };
    const chosen = chooseFrame(cfg.sprite.animate, active, now_ms, available);
    const image_id = base_id + chosen;

    const caps = detectCaps(environ);

    var dbg: std.ArrayList(u8) = .empty;
    defer dbg.deinit(gpa);
    dbg.print(gpa, "tmux={} kitty_capable={} tmux_pane={s} png_len={?d} box_cols={d} active={} chosen={d}\n", .{
        caps.tmux,                      caps.kitty_capable,
        caps.tmux_pane orelse "(null)", if (frames[0]) |b| b.len else null,
        cfg.sprite.box_cols,            active,
        chosen,
    }) catch {};

    // Best-effort graphics. `grid` backs the sprite-row slices, so it must
    // outlive the assembleRows call below.
    var grid: ?[]u8 = null;
    defer if (grid) |g| gpa.free(g);
    var sprite_arr: [rows.line_count][]const u8 = undefined;
    var have_sprite = false;

    // tmux masks the host terminal's identity (TERM=tmux-256color, no
    // KITTY_WINDOW_ID), so capability can't be sniffed through it. Attempt
    // graphics anyway when inside tmux -- the escapes are passthrough-wrapped
    // and a non-graphics host simply drops them (best-effort, matches proto).
    const can_graphics = caps.kitty_capable or caps.tmux;
    dbg.print(gpa, "can_graphics={} image_id={d}\n", .{ can_graphics, image_id }) catch {};

    const term_info = probeTerm(gpa, io, caps, environ, &dbg);
    defer if (term_info.tty_path) |p| gpa.free(p);

    if (can_graphics and frames[0] != null and term_info.tty_path != null) {
        const tmpdir = environ.getPosix("TMPDIR");
        if (tryGraphics(gpa, io, caps, term_info.tty_path.?, tmpdir, base_id, frames, rows.line_count, cfg.sprite.box_cols, &dbg)) {
            if (kitty.placeholderGrid(gpa, image_id, rows.line_count, cfg.sprite.box_cols) catch null) |g| {
                grid = g;
                var count: usize = 0;
                var it = std.mem.splitScalar(u8, g, '\n');
                while (it.next()) |line| : (count += 1) {
                    if (count < rows.line_count) sprite_arr[count] = line;
                }
                if (count == rows.line_count) have_sprite = true;
            }
        }
    }
    dbg.print(gpa, "have_sprite={}\n", .{have_sprite}) catch {};

    const l1 = if (cfg.line1.command) |c| rows.runCommand(gpa, io, c, 1000) else try gpa.dupe(u8, "");
    defer gpa.free(l1);
    const l2 = if (cfg.line2.color) |c|
        try std.fmt.allocPrint(gpa, "\x1b[38;5;{d}m{s}\x1b[0m", .{ c, sl.model_display_name })
    else
        try gpa.dupe(u8, sl.model_display_name);
    defer gpa.free(l2);
    const l3 = if (cfg.line3.command) |c| rows.runCommand(gpa, io, c, 1000) else try gpa.dupe(u8, "");
    defer gpa.free(l3);
    const text_lines: [rows.line_count][]const u8 = .{ l1, l2, l3 };

    const sprite_rows: ?[]const []const u8 = if (have_sprite) sprite_arr[0..] else null;
    // Centering needs a width; when none could be probed, fall back to the
    // classic left layout rather than guessing.
    const block = if (cfg.sprite.@"align" == .center and term_info.width != null)
        try rows.assembleRowsCentered(gpa, sprite_rows, text_lines, cfg.sprite.box_cols, term_info.width.?)
    else
        try rows.assembleRows(gpa, sprite_rows, text_lines, "  ");
    defer gpa.free(block);

    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io, block);
    try stdout.writeStreamingAll(io, "\n");
}

fn readStdin(gpa: std.mem.Allocator, io: Io) ![]u8 {
    var buf: [4096]u8 = undefined;
    var fr = std.Io.File.stdin().readerStreaming(io, &buf);
    return fr.interface.allocRemaining(gpa, .limited(1 << 20));
}

/// Which gaze frame to show this run. Forward unless animation applies and
/// the picked frame's sprite actually exists on disk.
fn chooseFrame(animate: bool, active: bool, now_ms: i64, available: [3]bool) u2 {
    if (!animate or !active) return gaze.forward;
    const g = gaze.selectGaze(now_ms);
    return if (available[g]) g else gaze.forward;
}

/// Load the tier's face frames: [forward, left, right]. Forward follows the
/// existing resolution (explicit faces list or dir naming); the gaze frames
/// only exist in dir-naming mode (face<N>l.png / face<N>r.png). Any failure
/// yields null for that frame; a missing gaze frame just means a static face.
fn readFaces(gpa: std.mem.Allocator, io: Io, cfg: config.Config, tier_idx: u32) [3]?[]u8 {
    var out: [3]?[]u8 = .{ null, null, null };
    out[0] = readFace(gpa, io, cfg, tier_idx);
    if (cfg.sprite.faces != null) return out;
    out[1] = readGazeFrame(gpa, io, cfg.sprite.dir, tier_idx, 'l');
    out[2] = readGazeFrame(gpa, io, cfg.sprite.dir, tier_idx, 'r');
    return out;
}

fn readGazeFrame(gpa: std.mem.Allocator, io: Io, dir: []const u8, tier_idx: u32, suffix: u8) ?[]u8 {
    const path = std.fmt.allocPrint(gpa, "{s}/face{d}{c}.png", .{ dir, tier_idx, suffix }) catch return null;
    defer gpa.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch null;
}

/// Resolve and read the tier's face PNG. Any failure yields null (no sprite).
fn readFace(gpa: std.mem.Allocator, io: Io, cfg: config.Config, tier_idx: u32) ?[]u8 {
    var derived: ?[][]u8 = null;
    defer if (derived) |d| config.freeFaces(gpa, d);

    const face_path: []const u8 = blk: {
        if (cfg.sprite.faces) |faces| {
            if (faces.len == 0) return null;
            break :blk faces[@min(@as(usize, tier_idx), faces.len - 1)];
        }
        const d = config.deriveFaces(gpa, cfg.sprite.dir, cfg.sprite.tiers) catch return null;
        derived = d;
        if (d.len == 0) return null;
        break :blk d[@min(@as(usize, tier_idx), d.len - 1)];
    };

    return std.Io.Dir.cwd().readFileAlloc(io, face_path, gpa, .limited(1 << 20)) catch null;
}

const Caps = struct {
    tmux: bool,
    kitty_capable: bool,
    /// The `%N` pane this process belongs to (from $TMUX_PANE). Null outside
    /// tmux. Used to target `tmux display -t` at the correct pane's tty.
    tmux_pane: ?[]const u8,
    /// $KITTY_WINDOW_ID verbatim; keys the transmit cache so a restarted kitty
    /// (fresh image store, same /dev/tty ctime) doesn't hit a stale entry.
    kitty_window_id: ?[]const u8,
};

fn detectCaps(environ: std.process.Environ) Caps {
    const term = environ.getPosix("TERM");
    const term_program = environ.getPosix("TERM_PROGRAM");
    const tmux_env = environ.getPosix("TMUX");
    const tmux_pane = environ.getPosix("TMUX_PANE");
    const kitty_win = environ.getPosix("KITTY_WINDOW_ID");

    const is_tmux = (tmux_env != null and tmux_env.?.len > 0) or
        (term != null and (std.mem.startsWith(u8, term.?, "tmux") or
            std.mem.startsWith(u8, term.?, "screen")));

    var capable = kitty_win != null and kitty_win.?.len > 0;
    if (term) |t| {
        if (std.mem.indexOf(u8, t, "kitty") != null) capable = true;
        if (std.mem.indexOf(u8, t, "ghostty") != null) capable = true;
        if (std.mem.indexOf(u8, t, "wezterm") != null) capable = true;
    }
    if (term_program) |tp| {
        if (std.ascii.indexOfIgnoreCase(tp, "wezterm") != null) capable = true;
    }

    const pane = if (tmux_pane) |p| (if (p.len > 0) p else null) else null;
    return .{
        .tmux = is_tmux,
        .kitty_capable = capable,
        .tmux_pane = pane,
        .kitty_window_id = kitty_win,
    };
}

/// What we know about the terminal we render into, probed once per run.
const TermInfo = struct {
    /// The tty device graphics escapes are written to. Owned by the caller;
    /// null when no usable tty was found (graphics are skipped).
    tty_path: ?[]u8,
    /// Terminal width in columns, for `align = "center"`. Null when unknown.
    width: ?u32,
};

/// Split `tmux display` output of the form `<pane_tty> <pane_width>`.
/// A missing or non-numeric width yields null; the tty is whatever precedes
/// the first space (possibly empty).
fn parseTmuxDisplay(out: []const u8) struct { tty: []const u8, width: ?u32 } {
    const space = std.mem.indexOfScalar(u8, out, ' ') orelse
        return .{ .tty = out, .width = null };
    const width = std.fmt.parseInt(u32, std.mem.trim(u8, out[space + 1 ..], " \t"), 10) catch null;
    return .{ .tty = out[0..space], .width = width };
}

/// Terminal width via TIOCGWINSZ on /dev/tty. Null when there is no
/// controlling terminal (the Claude Code statusline case) or the ioctl fails.
fn ttyWidth(io: Io) ?u32 {
    const f = std.Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_only }) catch return null;
    defer f.close(io);
    var ws: std.posix.winsize = undefined;
    const req: c_int = @bitCast(@as(u32, @truncate(std.c.T.IOCGWINSZ)));
    if (std.c.ioctl(f.handle, req, &ws) != 0) return null;
    return if (ws.col == 0) null else ws.col;
}

/// Resolve the graphics tty and terminal width. Inside tmux both come from a
/// single `tmux display` query pinned to this pane (`-t $TMUX_PANE`) -- without
/// the pin, `tmux display` resolves the session's *active* pane, which for a
/// Claude Code statusline subprocess is often a different pane, so the image
/// would land on the wrong tty. Outside tmux the tty is /dev/tty and the width
/// comes from TIOCGWINSZ. $COLUMNS is the width fallback of last resort.
fn probeTerm(
    gpa: std.mem.Allocator,
    io: Io,
    caps: Caps,
    environ: std.process.Environ,
    dbg: *std.ArrayList(u8),
) TermInfo {
    var info: TermInfo = .{ .tty_path = null, .width = null };

    if (caps.tmux) {
        const cmd = blk: {
            if (caps.tmux_pane) |pane|
                break :blk std.fmt.allocPrint(
                    gpa,
                    "tmux display -p -t '{s}' '#{{pane_tty}} #{{pane_width}}'",
                    .{pane},
                ) catch null;
            break :blk gpa.dupe(u8, "tmux display -p '#{pane_tty} #{pane_width}'") catch null;
        };
        if (cmd) |c| {
            defer gpa.free(c);
            const out = rows.runCommand(gpa, io, c, 1000);
            defer gpa.free(out);
            dbg.print(gpa, "tmux_query={s} -> {s}\n", .{ c, out }) catch {};
            const parsed = parseTmuxDisplay(out);
            if (parsed.tty.len > 0)
                info.tty_path = gpa.dupe(u8, parsed.tty) catch null;
            info.width = parsed.width;
        }
    } else {
        info.tty_path = gpa.dupe(u8, "/dev/tty") catch null;
        info.width = ttyWidth(io);
    }

    if (info.width == null) {
        if (environ.getPosix("COLUMNS")) |cols|
            info.width = std.fmt.parseInt(u32, cols, 10) catch null;
    }
    return info;
}

/// Open the graphics target and write delete/transmit/placement escapes for
/// every gaze frame, unless the transmit cache says this (tty, base_id, pngs)
/// set already landed -- re-writing every refresh races Claude Code's own
/// writes on the same tty (interleaving mid-DCS corrupts the terminal) and
/// blinks the sprite.
/// Returns true only if everything succeeded; any failure degrades to no sprite.
fn tryGraphics(
    gpa: std.mem.Allocator,
    io: Io,
    caps: Caps,
    tty_path: []const u8,
    tmpdir: ?[]const u8,
    base_id: u32,
    frames: [3]?[]u8,
    box_rows: u32,
    box_cols: u32,
    dbg: *std.ArrayList(u8),
) bool {
    // Cache setup is best-effort: any failure means "no caching", never "no
    // sprite". The exclusive lock also serializes concurrent statusline
    // instances so their tty writes can't interleave. All gaze frames upload
    // together, so one entry keyed on base_id and the combined frame hash
    // covers the whole set.
    var hasher = std.hash.XxHash64.init(0);
    for (frames) |maybe_png| {
        if (maybe_png) |png| hasher.update(png);
    }
    const png_hash = hasher.final();
    var locked: ?cache.Locked = null;
    defer if (locked) |*l| l.close(io);
    var tty_ctime: i96 = 0;

    if (std.Io.Dir.cwd().statFile(io, tty_path, .{})) |st| {
        tty_ctime = st.ctime.nanoseconds;
        if (cache.statePath(gpa, tmpdir, tty_path, caps.kitty_window_id) catch null) |path| {
            defer gpa.free(path);
            locked = cache.Locked.open(io, path) catch null;
        }
    } else |e| {
        dbg.print(gpa, "stat tty {s} failed: {} (cache bypassed)\n", .{ tty_path, e }) catch {};
    }

    if (locked) |l| {
        if (cache.isHit(l.state, tty_ctime, base_id, png_hash)) {
            dbg.print(gpa, "cache=hit id={d}\n", .{base_id}) catch {};
            return true;
        }
        dbg.print(gpa, "cache=miss id={d}\n", .{base_id}) catch {};
    } else {
        dbg.print(gpa, "cache=bypass\n", .{}) catch {};
    }

    const tty = std.Io.Dir.openFileAbsolute(io, tty_path, .{ .mode = .write_only }) catch |e| {
        dbg.print(gpa, "open tty {s} failed: {}\n", .{ tty_path, e }) catch {};
        return false;
    };
    defer tty.close(io);

    buildAndWrite(gpa, io, tty, caps.tmux, base_id, frames, box_rows, box_cols) catch |e| {
        dbg.print(gpa, "buildAndWrite failed: {}\n", .{e}) catch {};
        return false;
    };
    dbg.print(gpa, "graphics written to {s}\n", .{tty_path}) catch {};

    // Only a confirmed write gets recorded; a failed commit just means a
    // redundant retransmit next frame.
    if (locked) |*l| {
        cache.record(&l.state, tty_ctime, base_id, png_hash);
        l.commit(gpa, io) catch {};
    }
    return true;
}

/// Upload every available gaze frame (id = base_id + gaze) with its own
/// virtual placement. Keeping all frames resident means switching gaze is a
/// pure placeholder fg-color change on stdout -- an atomic cell rewrite with
/// no transmit race and no flicker.
fn buildAndWrite(
    gpa: std.mem.Allocator,
    io: Io,
    tty: std.Io.File,
    tmux: bool,
    base_id: u32,
    frames: [3]?[]u8,
    box_rows: u32,
    box_cols: u32,
) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);

    for (frames, 0..) |maybe_png, g| {
        const png = maybe_png orelse continue;
        const id: u32 = base_id + @as(u32, @intCast(g));
        {
            const esc = try kitty.delete(gpa, id);
            defer gpa.free(esc);
            try appendMaybeTmux(gpa, &payload, tmux, esc);
        }
        {
            const esc = try kitty.transmit(gpa, id, png, .{});
            defer gpa.free(esc);
            try appendMaybeTmux(gpa, &payload, tmux, esc);
        }
        {
            const esc = try kitty.virtualPlacement(gpa, id, box_rows, box_cols);
            defer gpa.free(esc);
            try appendMaybeTmux(gpa, &payload, tmux, esc);
        }
    }

    try tty.writeStreamingAll(io, payload.items);
}

fn appendMaybeTmux(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(u8),
    tmux: bool,
    esc: []const u8,
) !void {
    if (tmux) {
        const wrapped = try kitty.wrapTmux(gpa, esc);
        defer gpa.free(wrapped);
        try list.appendSlice(gpa, wrapped);
    } else {
        try list.appendSlice(gpa, esc);
    }
}

test "chooseFrame: forward when animation is off or session idle" {
    const all: [3]bool = .{ true, true, true };
    try std.testing.expectEqual(@as(u2, 0), chooseFrame(false, true, 1234, all));
    try std.testing.expectEqual(@as(u2, 0), chooseFrame(true, false, 1234, all));
}

test "chooseFrame: animated pick matches selectGaze and respects availability" {
    const all: [3]bool = .{ true, true, true };
    // Find an instant whose gaze is non-forward so the fallback case is real.
    var t: i64 = 0;
    while (gaze.selectGaze(t) == 0) t += 500;

    try std.testing.expectEqual(gaze.selectGaze(t), chooseFrame(true, true, t, all));

    // Same instant with that frame missing falls back to forward.
    var only_forward: [3]bool = .{ true, false, false };
    try std.testing.expectEqual(@as(u2, 0), chooseFrame(true, true, t, only_forward));
    _ = &only_forward;
}

test "parseTmuxDisplay: tty and width" {
    const r = parseTmuxDisplay("/dev/ttys004 181");
    try std.testing.expectEqualStrings("/dev/ttys004", r.tty);
    try std.testing.expectEqual(@as(?u32, 181), r.width);
}

test "parseTmuxDisplay: missing width yields null width" {
    const r = parseTmuxDisplay("/dev/ttys004");
    try std.testing.expectEqualStrings("/dev/ttys004", r.tty);
    try std.testing.expectEqual(@as(?u32, null), r.width);
}

test "parseTmuxDisplay: junk width yields null width" {
    const r = parseTmuxDisplay("/dev/ttys004 abc");
    try std.testing.expectEqualStrings("/dev/ttys004", r.tty);
    try std.testing.expectEqual(@as(?u32, null), r.width);
}

test "parseTmuxDisplay: empty input" {
    const r = parseTmuxDisplay("");
    try std.testing.expectEqualStrings("", r.tty);
    try std.testing.expectEqual(@as(?u32, null), r.width);
}

test {
    _ = @import("config.zig");
    _ = @import("gaze.zig");
    _ = @import("statusline.zig");
    _ = @import("tier.zig");
    _ = @import("kitty.zig");
    _ = @import("rows.zig");
    _ = @import("cache.zig");
}
