const std = @import("std");

/// Flattened view of the fields we care about from Claude's statusline JSON.
/// String fields borrow from the owning `ParsedStatusline` arena.
pub const Statusline = struct {
    model_display_name: []const u8,
    total_input_tokens: ?u64,
    used_percentage: ?f64,
    context_window_size: ?u64,
    /// Claude Code session id; keys the per-session animation state file.
    session_id: ?[]const u8 = null,
    /// cost.total_api_duration_ms -- ticks only while Claude is doing API
    /// work, which makes it the "is the session active" signal. Deliberately
    /// not total_duration_ms, which ticks even when idle.
    api_duration_ms: ?u64 = null,
};

/// Owns the arena backing `value`. Caller must `deinit()` when done.
pub const ParsedStatusline = struct {
    parsed: std.json.Parsed(Raw),
    value: Statusline,

    pub fn deinit(self: ParsedStatusline) void {
        self.parsed.deinit();
    }
};

const Model = struct {
    display_name: []const u8 = "unknown",
};

const ContextWindow = struct {
    total_input_tokens: ?u64 = null,
    used_percentage: ?f64 = null,
    context_window_size: ?u64 = null,
};

const Cost = struct {
    total_api_duration_ms: ?u64 = null,
};

const Raw = struct {
    model: Model = .{},
    context_window: ContextWindow = .{},
    session_id: ?[]const u8 = null,
    cost: Cost = .{},
};

pub fn parse(allocator: std.mem.Allocator, json_bytes: []const u8) !ParsedStatusline {
    // .alloc_always so strings are copied into the arena and the result is
    // self-contained regardless of the lifetime of json_bytes.
    const parsed = try std.json.parseFromSlice(Raw, allocator, json_bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    return .{
        .parsed = parsed,
        .value = .{
            .model_display_name = parsed.value.model.display_name,
            .total_input_tokens = parsed.value.context_window.total_input_tokens,
            .used_percentage = parsed.value.context_window.used_percentage,
            .context_window_size = parsed.value.context_window.context_window_size,
            .session_id = parsed.value.session_id,
            .api_duration_ms = parsed.value.cost.total_api_duration_ms,
        },
    };
}

test "extracts session_id and cost.total_api_duration_ms" {
    const json =
        \\{
        \\  "session_id": "abc-123",
        \\  "model": { "display_name": "Sonnet" },
        \\  "cost": { "total_cost_usd": 1.25, "total_duration_ms": 999999, "total_api_duration_ms": 45000 }
        \\}
    ;
    const result = try parse(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expectEqualStrings("abc-123", result.value.session_id.?);
    try std.testing.expectEqual(@as(?u64, 45000), result.value.api_duration_ms);
}

test "missing session_id and cost yield nulls" {
    const json =
        \\{ "model": { "display_name": "Sonnet" } }
    ;
    const result = try parse(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), result.value.session_id);
    try std.testing.expectEqual(@as(?u64, null), result.value.api_duration_ms);
}

test "extracts nested model.display_name and ignores unrelated fields" {
    const json =
        \\{
        \\  "session_id": "abc-123",
        \\  "cwd": "/Users/dev/project",
        \\  "version": "1.2.3",
        \\  "workspace": { "current_dir": "/Users/dev/project", "project_dir": "/Users/dev" },
        \\  "model": { "id": "claude-opus-4", "display_name": "Opus 4.8" }
        \\}
    ;
    const result = try parse(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expectEqualStrings("Opus 4.8", result.value.model_display_name);
}

test "populates token optionals from nested context_window" {
    const json =
        \\{
        \\  "model": { "display_name": "Sonnet" },
        \\  "context_window": {
        \\    "total_input_tokens": 12345,
        \\    "total_output_tokens": 678,
        \\    "used_percentage": 42.5,
        \\    "context_window_size": 200000
        \\  }
        \\}
    ;
    const result = try parse(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(?u64, 12345), result.value.total_input_tokens);
    try std.testing.expectEqual(@as(?f64, 42.5), result.value.used_percentage);
    try std.testing.expectEqual(@as(?u64, 200000), result.value.context_window_size);
}

test "integer used_percentage parses into f64" {
    const json =
        \\{
        \\  "model": { "display_name": "Sonnet" },
        \\  "context_window": { "used_percentage": 8, "context_window_size": 200000 }
        \\}
    ;
    const result = try parse(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(?f64, 8.0), result.value.used_percentage);
}

test "top-level token fields are ignored, not picked up" {
    const json =
        \\{
        \\  "model": { "display_name": "Sonnet" },
        \\  "total_input_tokens": 12345,
        \\  "used_percentage": 42.5,
        \\  "context_window_size": 200000
        \\}
    ;
    const result = try parse(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(?u64, null), result.value.total_input_tokens);
    try std.testing.expectEqual(@as(?f64, null), result.value.used_percentage);
    try std.testing.expectEqual(@as(?u64, null), result.value.context_window_size);
}

test "missing context_window yields null, not an error" {
    const json =
        \\{
        \\  "session_id": "xyz",
        \\  "model": { "display_name": "Haiku" }
        \\}
    ;
    const result = try parse(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(?u64, null), result.value.total_input_tokens);
    try std.testing.expectEqual(@as(?f64, null), result.value.used_percentage);
    try std.testing.expectEqual(@as(?u64, null), result.value.context_window_size);
    try std.testing.expectEqualStrings("Haiku", result.value.model_display_name);
}

test "absent model uses default display name" {
    const json =
        \\{ "session_id": "no-model" }
    ;
    const result = try parse(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expectEqualStrings("unknown", result.value.model_display_name);
}
