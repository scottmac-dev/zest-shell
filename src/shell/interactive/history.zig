const std = @import("std");
const helpers = @import("../../lib-core/core/helpers.zig");
const Allocator = std.mem.Allocator;
const ShellCtx = @import("../../lib-core/core/context.zig").ShellCtx;
const Value = @import("../../lib-core/core/types.zig").Value;
const MAX_CAPACITY: usize = 100;
const HOT_CACHE_SIZE: usize = 10;
const RECENT_SCAN_LIMIT: usize = 20;

/// Wraps how the shell interacts with the history and history file
pub const HistoryManager = struct {
    const Self = @This();
    const HistoryStats = struct {
        count: usize,
        last_idx: usize,
    };
    const RankedHistory = struct {
        cmd: []const u8,
        score: usize,
        last_idx: usize,
    };

    allocator: Allocator,
    list: std.ArrayList([]u8),
    last_saved_idx: usize,
    loaded: bool, // loaded from config file, for lazy load
    hot_commands: [HOT_CACHE_SIZE]?[]u8,
    hot_count: usize,
    hot_dirty: bool,

    pub fn init(allocator: Allocator) !*Self {
        const hm = try allocator.create(Self); // returns pointer to allocated memory
        hm.* = Self{
            .allocator = allocator,
            .list = try std.ArrayList([]u8).initCapacity(allocator, MAX_CAPACITY),
            .last_saved_idx = 0,
            .loaded = false,
            .hot_commands = [_]?[]u8{null} ** HOT_CACHE_SIZE,
            .hot_count = 0,
            .hot_dirty = false,
        };
        return hm;
    }

    pub fn deinit(self: *Self) void {
        self.clearHotCache();
        for (self.list.items) |item| {
            self.allocator.free(item);
        }
        self.list.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Inserts item while maintaining MAX_CAPACITY
    pub fn push(self: *Self, cmd: []u8) !void {
        try self.list.append(self.allocator, cmd);

        if (self.list.items.len > MAX_CAPACITY) {
            const removed = self.list.orderedRemove(0);
            self.allocator.free(removed);
            if (self.last_saved_idx > 0) {
                self.last_saved_idx -= 1;
            }
        }
        self.hot_dirty = true;
    }

    pub fn size(self: *Self) usize {
        return self.list.items.len;
    }

    /// Find a suggestion that starts with prefix, preferring recent history first,
    /// then hot cached commands, then the remaining older range.
    pub fn findSuggestion(self: *Self, prefix: []const u8) ?[]const u8 {
        if (prefix.len == 0 or self.list.items.len == 0) return null;

        const recent_floor = if (self.list.items.len > RECENT_SCAN_LIMIT)
            self.list.items.len - RECENT_SCAN_LIMIT
        else
            0;

        var idx = self.list.items.len;
        while (idx > recent_floor) {
            idx -= 1;
            const cmd = self.list.items[idx];
            if (isPrefixSuggestion(prefix, cmd)) return cmd;
        }

        if (self.hot_dirty) {
            self.rebuildHotCache() catch {
                self.clearHotCache();
            };
        }

        for (0..self.hot_count) |hot_idx| {
            const cmd = self.hot_commands[hot_idx] orelse continue;
            if (isPrefixSuggestion(prefix, cmd)) return cmd;
        }

        idx = recent_floor;
        while (idx > 0) {
            idx -= 1;
            const cmd = self.list.items[idx];
            if (isPrefixSuggestion(prefix, cmd)) return cmd;
        }
        return null;
    }

    fn isPrefixSuggestion(prefix: []const u8, cmd: []const u8) bool {
        return cmd.len > prefix.len and std.mem.startsWith(u8, cmd, prefix);
    }

    fn clearHotCache(self: *Self) void {
        for (0..self.hot_count) |idx| {
            if (self.hot_commands[idx]) |cmd| {
                self.allocator.free(cmd);
                self.hot_commands[idx] = null;
            }
        }
        self.hot_count = 0;
    }

    fn rebuildHotCache(self: *Self) !void {
        self.clearHotCache();
        if (self.list.items.len == 0) {
            self.hot_dirty = false;
            return;
        }

        var stats = std.StringHashMap(HistoryStats).init(self.allocator);
        defer stats.deinit();

        for (self.list.items, 0..) |cmd, idx| {
            const found = try stats.getOrPut(cmd);
            if (!found.found_existing) {
                found.value_ptr.* = .{
                    .count = 1,
                    .last_idx = idx,
                };
            } else {
                found.value_ptr.count += 1;
                found.value_ptr.last_idx = idx;
            }
        }

        var ranked = try std.ArrayList(RankedHistory).initCapacity(self.allocator, stats.count());
        defer ranked.deinit(self.allocator);

        var iter = stats.iterator();
        while (iter.next()) |entry| {
            const count = entry.value_ptr.count;
            const last_idx = entry.value_ptr.last_idx;
            // Bias frequency first, then recency as a deterministic tie-breaker.
            try ranked.append(self.allocator, .{
                .cmd = entry.key_ptr.*,
                .score = (count * 1024) + last_idx,
                .last_idx = last_idx,
            });
        }

        std.mem.sort(RankedHistory, ranked.items, {}, struct {
            fn lessThan(_: void, a: RankedHistory, b: RankedHistory) bool {
                if (a.score == b.score) return a.last_idx > b.last_idx;
                return a.score > b.score;
            }
        }.lessThan);

        const take = @min(HOT_CACHE_SIZE, ranked.items.len);
        for (0..take) |idx| {
            self.hot_commands[idx] = try self.allocator.dupe(u8, ranked.items[idx].cmd);
        }
        self.hot_count = take;
        self.hot_dirty = false;
    }

    /// Read from a file and append to the history
    pub fn importHistory(self: *Self, ctx: *ShellCtx, file_path: []const u8) !void {
        if (self.loaded) return; // already imported
        self.loaded = true;

        if (ctx.exe_mode != .interactive) return; // dont load from disk for -c oneshot mode

        // Try to open file, but if it doesn't exist, that's fine - just return
        var file = helpers.getFileFromPath(ctx, ctx.allocator, file_path, .{ .write = false, .truncate = false, .pre_expanded = false }) catch |err| {
            if (err == error.FileNotFound) {
                // First time running - no history yet, that's okay
                return;
            }
            return err;
        };
        defer file.close(ctx.io.*);

        var read_buffer: [1024]u8 = undefined;
        var file_reader = file.reader(ctx.io.*, &read_buffer);
        const reader = &file_reader.interface;

        var imported = try std.ArrayList([]u8).initCapacity(self.allocator, MAX_CAPACITY);
        defer imported.deinit(self.allocator);

        while (true) {
            // read history file line by line
            const line = reader.takeDelimiterExclusive('\n') catch |err| {
                if (err == error.EndOfStream) break else return err;
            };

            // move to next line by consuming '\n'
            _ = reader.takeByte() catch |err| {
                if (err == error.EndOfStream) {} else return err;
            };

            const trimmed = std.mem.trim(u8, line, " \n\r\t");
            if (trimmed.len == 0) continue;

            const cmd = try self.allocator.dupe(u8, trimmed);
            errdefer self.allocator.free(cmd);

            // Keep only the newest MAX_CAPACITY imported lines.
            if (imported.items.len == MAX_CAPACITY) {
                const dropped = imported.orderedRemove(0);
                self.allocator.free(dropped);
            }
            try imported.append(self.allocator, cmd);
        }

        // Merge imported history with any in-memory entries, preserving order and cap.
        for (imported.items) |cmd| {
            try self.list.append(self.allocator, cmd);
            if (self.list.items.len > MAX_CAPACITY) {
                const dropped = self.list.orderedRemove(0);
                self.allocator.free(dropped);
            }
        }

        try self.rebuildHotCache();
        self.last_saved_idx = self.list.items.len;
    }

    /// Export new history additions to to a log file
    pub fn exportHistory(self: *Self, ctx: *ShellCtx, file_path: []const u8, truncate: bool) !void {
        if (ctx.exe_mode != .interactive) return; // dont write to disk for -c oneshot mode

        // Expand the path first so we can create parent directories
        const expanded_path = try helpers.expandPathToAbs(ctx, ctx.allocator, file_path);
        defer ctx.allocator.free(expanded_path);

        // Ensure parent directory exists (e.g., ~/.config/zest) to allow lazy export
        try helpers.ensureDirPath(ctx, expanded_path);

        var file = try helpers.getFileFromPath(ctx, ctx.allocator, expanded_path, .{
            .pre_expanded = true,
            .write = true,
            .truncate = truncate,
        });
        defer file.close(ctx.io.*);

        var data = try std.ArrayList(u8).initCapacity(ctx.allocator, 1024);
        defer data.deinit(ctx.allocator);

        var appended: usize = 0;
        for (self.last_saved_idx..self.list.items.len) |cmd_idx| {
            try data.appendSlice(ctx.allocator, self.list.items[cmd_idx]);
            try data.append(ctx.allocator, '\n');
            appended += 1;
        }

        if (truncate) {
            try helpers.fileWriteAll(ctx.io.*, file, data.items);
        } else {
            try helpers.fileAppendAll(ctx.io.*, file, data.items);
        }

        self.last_saved_idx += appended;
    }

    // Write all current history to a log file, doesnt track appended lines, used for -w and -a flag
    pub fn writeHistory(self: *Self, ctx: *ShellCtx, file_path: []const u8, truncate: bool) !void {
        const expanded_path = try helpers.expandPathToAbs(ctx, ctx.allocator, file_path);
        defer ctx.allocator.free(expanded_path);

        try helpers.ensureDirPath(ctx, expanded_path);

        var file = try helpers.getFileFromPath(ctx, ctx.allocator, expanded_path, .{
            .pre_expanded = true,
            .write = true,
            .truncate = truncate,
        });
        defer file.close(ctx.io.*);

        var data = try std.ArrayList(u8).initCapacity(ctx.allocator, 1024);
        defer data.deinit(ctx.allocator);

        for (self.last_saved_idx..self.list.items.len) |cmd_idx| {
            try data.appendSlice(ctx.allocator, self.list.items[cmd_idx]);
            try data.append(ctx.allocator, '\n');
        }

        if (truncate) {
            try helpers.fileWriteAll(ctx.io.*, file, data.items);
        } else {
            try helpers.fileAppendAll(ctx.io.*, file, data.items);
        }
    }

    // Write 0..n history items to a buffer for stdout piping
    pub fn getHistoryText(self: *Self, allocator: Allocator, buffer: *std.ArrayList(u8), n: ?u32) !void {
        const len = self.size();
        if (len > 0) {
            // Oldest first
            if (n) |limit| {
                // Avoid overflow
                const verified_limit = if (limit > len) len else limit;

                const fromBack = self.list.items.len - verified_limit;
                for (fromBack..self.list.items.len, 1..) |idx, pos| {
                    var buf: [128]u8 = undefined; // TODO: generous but could overflow??
                    const item = try std.fmt.bufPrint(&buf, "{d}: {s}\n", .{ pos, self.list.items[idx] });
                    try buffer.appendSlice(allocator, item);
                }
            } else {
                for (self.list.items, 1..) |cmd, pos| {
                    var buf: [128]u8 = undefined;
                    const item = try std.fmt.bufPrint(&buf, "{d}: {s}\n", .{ pos, cmd });
                    try buffer.appendSlice(allocator, item);
                }
            }
        }
    }

    // Write 0..n history items to a Value list stdout capture
    pub fn getHistoryList(self: *Self, allocator: Allocator, list: *std.ArrayList(Value), n: ?u32) !void {
        const len = self.size();
        if (len > 0) {
            // Oldest first
            if (n) |limit| {
                // Avoid overflow
                const verified_limit = if (limit > len) len else limit;

                const fromBack = self.list.items.len - verified_limit;
                for (fromBack..self.list.items.len) |idx| {
                    try list.append(allocator, .{ .text = self.list.items[idx] });
                }
            } else {
                for (self.list.items) |cmd| {
                    try list.append(allocator, .{ .text = cmd });
                }
            }
        }
    }
};

test "findSuggestion prefers the most recent matching history line" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var hm = try HistoryManager.init(allocator);
    defer hm.deinit();

    try hm.push(try allocator.dupe(u8, "echo alpha"));
    try hm.push(try allocator.dupe(u8, "pwd"));
    try hm.push(try allocator.dupe(u8, "echo beta"));

    const suggestion = hm.findSuggestion("echo ") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.eql(u8, suggestion, "echo beta"));
}

test "findSuggestion ignores exact command matches with no suffix" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var hm = try HistoryManager.init(allocator);
    defer hm.deinit();

    try hm.push(try allocator.dupe(u8, "echo"));
    try std.testing.expect(hm.findSuggestion("echo") == null);
}

test "rebuildHotCache keeps up to ten ranked commands" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var hm = try HistoryManager.init(allocator);
    defer hm.deinit();

    var i: usize = 0;
    while (i < 15) : (i += 1) {
        var buf: [32]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "cmd-{d}", .{i});
        try hm.push(try allocator.dupe(u8, cmd));
    }
    try hm.push(try allocator.dupe(u8, "deploy prod"));
    try hm.push(try allocator.dupe(u8, "deploy prod"));
    try hm.push(try allocator.dupe(u8, "deploy prod"));

    try std.testing.expect(hm.hot_count <= HOT_CACHE_SIZE);
    const suggestion = hm.findSuggestion("dep") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.eql(u8, suggestion, "deploy prod"));
}

test "importHistory keeps newest bounded history and builds hot cache once" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("../../lib-core/core/env.zig").EnvMap.init(allocator);
    defer env_map.deinit();

    var ctx = try @import("../../lib-core/core/context.zig").ShellCtx.initEngine(&io, allocator, env_map);
    defer ctx.deinit();
    ctx.exe_mode = .interactive;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var file = try tmp_dir.dir.createFile(io, "history.txt", .{});
    defer file.close(io);

    var content = try std.ArrayList(u8).initCapacity(allocator, 1024);
    defer content.deinit(allocator);

    const total = MAX_CAPACITY + 5;
    for (0..total) |idx| {
        const line = try std.fmt.allocPrint(allocator, "cmd-{d}\n", .{idx});
        defer allocator.free(line);
        try content.appendSlice(allocator, line);
    }
    try helpers.fileWriteAll(io, file, content.items);

    const hist_path = try std.fmt.allocPrint(allocator, "./.zig-cache/tmp/{s}/history.txt", .{tmp_dir.sub_path[0..]});
    defer allocator.free(hist_path);

    var hm = try HistoryManager.init(allocator);
    defer hm.deinit();

    try hm.importHistory(&ctx, hist_path);

    try std.testing.expectEqual(@as(usize, MAX_CAPACITY), hm.size());
    try std.testing.expectEqualStrings("cmd-5", hm.list.items[0]);
    try std.testing.expectEqualStrings("cmd-104", hm.list.items[hm.list.items.len - 1]);
    try std.testing.expect(hm.hot_count > 0);
}
