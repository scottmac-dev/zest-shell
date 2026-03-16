const std = @import("std");
const helpers = @import("../core/helpers.zig");
const types = @import("../core/types.zig");
const Allocator = std.mem.Allocator;
const ExecContext = @import("../core/command.zig").ExecContext;
const List = types.List;
const Map = types.Map;
const ShellError = @import("../core/errors.zig").ShellError;
const Value = types.Value;
const MAX_TABLE_COL_WIDTH: usize = 48;
const DEFAULT_TABLE_WIDTH: usize = 80;
const MIN_TABLE_COL_WIDTH: usize = 4;

// Data transform operations applying to builtin -> builtin pipelines or to filter builtin output
const Operator = enum {
    eq,
    neq,
    lt,
    gt,
    lte,
    gte,
    contains,

    pub fn fromString(s: []const u8) ?Operator {
        if (std.mem.eql(u8, s, "==")) return .eq;
        if (std.mem.eql(u8, s, "!=")) return .neq;
        if (std.mem.eql(u8, s, ">")) return .gt;
        if (std.mem.eql(u8, s, "<")) return .lt;
        if (std.mem.eql(u8, s, ">=")) return .gte;
        if (std.mem.eql(u8, s, "<=")) return .lte;
        if (std.mem.eql(u8, s, "contains")) return .contains;
        return null;
    }
};

pub const Predicate = struct {
    field: []const u8, // stripped of leading dot
    op: Operator,
    rhs: Value,

    pub fn parse(args: [][]const u8) ?Predicate {
        if (args.len < 3) return null;

        const field_arg = args[0];
        if (field_arg.len < 2 or field_arg[0] != '.') return null;
        const field = field_arg[1..]; // strip dot

        const op = Operator.fromString(args[1]) orelse return null;

        // Parse rhs literal
        const rhs_str = args[2];
        const rhs: Value = blk: {
            if (std.fmt.parseInt(i64, rhs_str, 10) catch null) |n|
                break :blk Value{ .integer = n };
            if (std.fmt.parseFloat(f64, rhs_str) catch null) |f|
                break :blk Value{ .float = f };
            if (std.mem.eql(u8, rhs_str, "true")) break :blk Value{ .boolean = true };
            if (std.mem.eql(u8, rhs_str, "false")) break :blk Value{ .boolean = false };
            if (rhs_str.len >= 2 and rhs_str[0] == '"' and rhs_str[rhs_str.len - 1] == '"')
                break :blk Value{ .text = rhs_str[1 .. rhs_str.len - 1] };
            break :blk Value{ .text = rhs_str };
        };

        return Predicate{ .field = field, .op = op, .rhs = rhs };
    }

    pub fn evaluate(self: Predicate, map: *Map) bool {
        const lhs = map.get(self.field) orelse return false;
        return compareValues(lhs, self.op, self.rhs);
    }
};

fn compareValues(lhs: Value, op: Operator, rhs: Value) bool {
    return switch (op) {
        .eq => valuesEqual(lhs, rhs),
        .neq => !valuesEqual(lhs, rhs),
        .contains => switch (lhs) {
            .text => |t| switch (rhs) {
                .text => |r| std.mem.indexOf(u8, t, r) != null,
                else => false,
            },
            else => false,
        },
        // Ordered comparisons - coerce types where sensible
        .lt, .gt, .lte, .gte => switch (lhs) {
            .integer => |l| switch (rhs) {
                .integer => |r| compareOrdered(l, r, op),
                .float => |r| compareOrdered(@as(f64, @floatFromInt(l)), r, op),
                else => false,
            },
            .float => |l| switch (rhs) {
                .float => |r| compareOrdered(l, r, op),
                .integer => |r| compareOrdered(l, @as(f64, @floatFromInt(r)), op),
                else => false,
            },
            .text => |l| switch (rhs) {
                .text => |r| switch (op) {
                    .lt => std.mem.order(u8, l, r) == .lt,
                    .gt => std.mem.order(u8, l, r) == .gt,
                    .lte => std.mem.order(u8, l, r) != .gt,
                    .gte => std.mem.order(u8, l, r) != .lt,
                    else => false,
                },
                else => false,
            },
            else => false,
        },
    };
}

fn valuesEqual(a: Value, b: Value) bool {
    return switch (a) {
        .integer => |l| switch (b) {
            .integer => l == b.integer,
            .float => @as(f64, @floatFromInt(l)) == b.float,
            else => false,
        },
        .float => |l| switch (b) {
            .float => l == b.float,
            .integer => l == @as(f64, @floatFromInt(b.integer)),
            else => false,
        },
        .boolean => |l| switch (b) {
            .boolean => l == b.boolean,
            else => false,
        },
        .text => |l| switch (b) {
            .text => std.mem.eql(u8, l, b.text),
            else => false,
        },
        else => false,
    };
}

fn compareOrdered(a: anytype, b: @TypeOf(a), op: Operator) bool {
    return switch (op) {
        .lt => a < b,
        .gt => a > b,
        .lte => a <= b,
        .gte => a >= b,
        else => false,
    };
}

fn normalizeField(raw: []const u8) ?[]const u8 {
    if (raw.len == 0) return null;
    if (raw[0] == '.') {
        if (raw.len < 2) return null;
        return raw[1..];
    }
    return raw;
}

pub fn selectFields(allocator: Allocator, input: *List, raw_fields: [][]const u8) !*List {
    if (raw_fields.len == 0) return ShellError.MissingArgument;

    var fields = try std.ArrayList([]const u8).initCapacity(allocator, raw_fields.len);
    for (raw_fields) |raw| {
        const field = normalizeField(raw) orelse return ShellError.InvalidArgument;
        try fields.append(allocator, field);
    }

    const result = try allocator.create(List);
    result.* = try List.initCapacity(allocator, input.items.len);

    for (input.items) |item| {
        const src = switch (item) {
            .map => |m| m,
            else => return ShellError.TypeMismatch,
        };

        const selected = try allocator.create(Map);
        selected.* = Map.init(allocator);

        for (fields.items) |field| {
            const value = src.get(field) orelse return ShellError.InvalidArgument;
            try selected.put(try allocator.dupe(u8, field), value);
        }

        try result.append(allocator, Value{ .map = selected });
    }

    return result;
}

fn compareForSort(lhs: Value, rhs: Value) std.math.Order {
    return switch (lhs) {
        .integer => |li| switch (rhs) {
            .integer => |ri| std.math.order(li, ri),
            .float => |rf| std.math.order(@as(f64, @floatFromInt(li)), rf),
            else => std.math.order(1, 0),
        },
        .float => |lf| switch (rhs) {
            .integer => |ri| std.math.order(lf, @as(f64, @floatFromInt(ri))),
            .float => |rf| std.math.order(lf, rf),
            else => std.math.order(1, 0),
        },
        .text => |lt| switch (rhs) {
            .text => |rt| std.mem.order(u8, lt, rt),
            else => std.math.order(1, 0),
        },
        .boolean => |lb| switch (rhs) {
            .boolean => |rb| std.math.order(@intFromBool(lb), @intFromBool(rb)),
            else => std.math.order(1, 0),
        },
        else => std.math.order(1, 0),
    };
}

const SortCtx = struct { field: ?[]const u8 };

fn lessByValue(_: void, lhs: Value, rhs: Value) bool {
    return compareForSort(lhs, rhs) == .lt;
}

fn lessByMapField(ctx: SortCtx, lhs: Value, rhs: Value) bool {
    const key = ctx.field.?;
    const lhs_map = lhs.map;
    const rhs_map = rhs.map;
    const lhs_value = lhs_map.get(key).?;
    const rhs_value = rhs_map.get(key).?;
    return compareForSort(lhs_value, rhs_value) == .lt;
}

pub fn sortValues(allocator: Allocator, input: *List, raw_field: ?[]const u8) !*List {
    const result = try allocator.create(List);
    result.* = try List.initCapacity(allocator, input.items.len);
    for (input.items) |item| {
        try result.append(allocator, item);
    }

    if (result.items.len < 2) return result;

    const first = result.items[0];
    switch (first) {
        .text, .integer, .float => {
            if (raw_field != null) return ShellError.InvalidArgument;
            std.mem.sort(Value, result.items, {}, lessByValue);
            return result;
        },
        .map => {
            const field = normalizeField(raw_field orelse return ShellError.MissingArgument) orelse
                return ShellError.InvalidArgument;
            for (result.items) |item| {
                if (item != .map) return ShellError.TypeMismatch;
                if (item.map.get(field) == null) return ShellError.InvalidArgument;
            }
            std.mem.sort(Value, result.items, SortCtx{ .field = field }, lessByMapField);
            return result;
        },
        else => return ShellError.TypeMismatch,
    }
}

pub fn lengthOfValue(input: Value) !i64 {
    return switch (input) {
        .list => |l| @intCast(l.items.len),
        .text => |t| @intCast(t.len),
        else => ShellError.TypeMismatch,
    };
}

// ---- Value display helpers / renderers for table output

fn isListOfMaps(list: *List) bool {
    if (list.items.len == 0) return false;
    for (list.items) |item| {
        if (item != .map) return false;
    }
    return true;
}

fn collectUnionKeys(arena: Allocator, list: *List) ![][]const u8 {
    var keys = try std.ArrayList([]const u8).initCapacity(arena, 8);

    for (list.items) |item| {
        const map = item.map;
        var iter = map.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            var seen = false;
            for (keys.items) |existing| {
                if (std.mem.eql(u8, existing, key)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                try keys.append(arena, key);
            }
        }
    }

    return keys.toOwnedSlice(arena);
}

fn writePadding(io: anytype, file: anytype, n: usize) !void {
    const spaces = " " ** 256;
    var remaining = n;
    while (remaining > 0) {
        const chunk = @min(remaining, 256);
        try helpers.fileWriteAll(io, file, spaces[0..chunk]);
        remaining -= chunk;
    }
}

fn cappedLen(s: []const u8, max_width: usize) usize {
    return if (s.len > max_width) max_width else s.len;
}

fn writeTruncated(io: anytype, file: anytype, s: []const u8, width: usize) !usize {
    if (width == 0) return 0;
    if (s.len <= width) {
        try helpers.fileWriteAll(io, file, s);
        return s.len;
    }
    if (width <= 3) {
        var n: usize = 0;
        while (n < width) : (n += 1) {
            try helpers.fileWriteAll(io, file, ".");
        }
        return width;
    }
    const head = width - 3;
    try helpers.fileWriteAll(io, file, s[0..head]);
    try helpers.fileWriteAll(io, file, "...");
    return width;
}

fn getOutputWidth() usize {
    var ws: std.posix.winsize = undefined;
    const err = std.posix.system.ioctl(
        std.posix.STDOUT_FILENO,
        std.posix.T.IOCGWINSZ,
        @intFromPtr(&ws),
    );
    if (err != 0 or ws.col == 0) return DEFAULT_TABLE_WIDTH;
    return ws.col;
}

fn tableWidthForCount(order: []const usize, widths: []const usize, visible_count: usize, spacing: usize) usize {
    if (visible_count == 0) return 0;
    var total: usize = 0;
    for (order[0..visible_count]) |idx| total += widths[idx];
    total += spacing * (visible_count - 1);
    return total;
}

fn shrinkWidestWidths(order: []const usize, widths: []usize, visible_count: usize, spacing: usize, min_width: usize, max_total_width: usize) void {
    while (tableWidthForCount(order, widths, visible_count, spacing) > max_total_width) {
        var widest_idx: ?usize = null;
        var widest_width: usize = 0;
        for (order[0..visible_count]) |idx| {
            if (widths[idx] > min_width and widths[idx] > widest_width) {
                widest_width = widths[idx];
                widest_idx = idx;
            }
        }
        if (widest_idx) |idx| {
            widths[idx] -= 1;
        } else {
            break;
        }
    }
}

const TableLayout = struct {
    visible_count: usize,
    spacing: usize,
    dropped_columns: bool,
};

fn fitTableToWidth(order: []const usize, widths: []usize, max_total_width: usize) TableLayout {
    if (order.len == 0) return .{ .visible_count = 0, .spacing = 2, .dropped_columns = false };
    if (max_total_width == 0) return .{ .visible_count = 0, .spacing = 1, .dropped_columns = true };

    var spacing: usize = 2;
    var visible_count = order.len;

    shrinkWidestWidths(order, widths, visible_count, spacing, MIN_TABLE_COL_WIDTH, max_total_width);
    if (tableWidthForCount(order, widths, visible_count, spacing) > max_total_width) {
        spacing = 1;
        shrinkWidestWidths(order, widths, visible_count, spacing, MIN_TABLE_COL_WIDTH, max_total_width);
    }
    if (tableWidthForCount(order, widths, visible_count, spacing) > max_total_width) {
        shrinkWidestWidths(order, widths, visible_count, spacing, 1, max_total_width);
    }

    var dropped = false;
    while (visible_count > 0 and tableWidthForCount(order, widths, visible_count, spacing) > max_total_width) {
        visible_count -= 1;
        dropped = true;
    }

    if (visible_count < order.len) {
        dropped = true;
        const overflow_width: usize = if (visible_count > 0) spacing + 3 else 3;
        while (visible_count > 0 and tableWidthForCount(order, widths, visible_count, spacing) + overflow_width > max_total_width) {
            visible_count -= 1;
        }
    }

    return .{
        .visible_count = visible_count,
        .spacing = spacing,
        .dropped_columns = dropped,
    };
}

fn containsKey(keys: [][]const u8, needle: []const u8) bool {
    for (keys) |key| {
        if (std.mem.eql(u8, key, needle)) return true;
    }
    return false;
}

fn inferPrimaryKey(keys: [][]const u8) ?[]const u8 {
    const preferred = [_][]const u8{ "name", "command", "path", "key", "id" };
    for (preferred) |k| {
        if (containsKey(keys, k)) return k;
    }
    return null;
}

fn insertionSortIndices(keys: [][]const u8, order: []usize, right_align: []bool, primary_key: ?[]const u8) void {
    for (1..order.len) |i| {
        var j = i;
        const current = order[i];
        while (j > 0) {
            const prev = order[j - 1];
            const prev_key = keys[prev];
            const cur_key = keys[current];

            const prev_rank: u8 = if (primary_key != null and std.mem.eql(u8, prev_key, primary_key.?))
                0
            else if (!right_align[prev])
                1
            else
                2;
            const cur_rank: u8 = if (primary_key != null and std.mem.eql(u8, cur_key, primary_key.?))
                0
            else if (!right_align[current])
                1
            else
                2;

            const should_swap = if (cur_rank < prev_rank)
                true
            else if (cur_rank > prev_rank)
                false
            else
                std.mem.order(u8, cur_key, prev_key) == .lt;

            if (!should_swap) break;
            order[j] = prev;
            j -= 1;
        }
        order[j] = current;
    }
}

pub fn renderTableWithPrimaryKey(
    exec_ctx: *ExecContext,
    list: *List,
    primary_key: ?[]const u8,
) Value {
    if (exec_ctx.output != .stream) return Value{ .err = ShellError.ExpectedStream };
    const io = exec_ctx.shell_ctx.io.*;
    const arena = exec_ctx.allocator;
    const stdout = exec_ctx.output.stream;

    if (list.items.len == 0)
        return Value{ .void = {} };

    if (!isListOfMaps(list)) {
        const pretty = (Value{ .list = list }).toPrettyString(arena) catch return Value{ .err = ShellError.AllocFailed };
        defer arena.free(pretty);
        helpers.fileWriteAll(io, stdout, pretty) catch return Value{ .err = ShellError.WriteFailed };
        helpers.fileWriteAll(io, stdout, "\n") catch return Value{ .err = ShellError.WriteFailed };
        return Value{ .void = {} };
    }

    const keys = collectUnionKeys(arena, list) catch return Value{ .err = ShellError.AllocFailed };
    defer arena.free(keys);
    if (keys.len == 0) return Value{ .void = {} };

    // Column profiles
    var widths = arena.alloc(usize, keys.len) catch return Value{ .err = ShellError.AllocFailed };
    defer arena.free(widths);
    var right_align = arena.alloc(bool, keys.len) catch return Value{ .err = ShellError.AllocFailed };
    defer arena.free(right_align);
    for (keys, 0..) |key, i| {
        widths[i] = cappedLen(key, MAX_TABLE_COL_WIDTH);
        right_align[i] = true;
    }

    for (list.items) |item| {
        const map = item.map;
        for (keys, 0..) |key, i| {
            if (map.get(key)) |value| {
                const str = value.toString(arena) catch return Value{ .err = ShellError.AllocFailed };
                defer arena.free(str);
                const w = cappedLen(str, MAX_TABLE_COL_WIDTH);
                if (w > widths[i]) widths[i] = w;

                switch (value) {
                    .integer, .float => {},
                    else => right_align[i] = false,
                }
            } else {
                right_align[i] = false;
            }
        }
    }

    // Column order: primary key (if set/found), then text-like, then numeric.
    var order = arena.alloc(usize, keys.len) catch return Value{ .err = ShellError.AllocFailed };
    defer arena.free(order);
    for (0..keys.len) |i| order[i] = i;

    const resolved_primary = if (primary_key) |k|
        (if (containsKey(keys, k)) k else inferPrimaryKey(keys))
    else
        inferPrimaryKey(keys);
    insertionSortIndices(keys, order, right_align, resolved_primary);
    const layout = fitTableToWidth(order, widths, getOutputWidth());
    const visible_order = order[0..layout.visible_count];

    // Header
    for (visible_order, 0..) |col_idx, out_i| {
        const key = keys[col_idx];
        const width = widths[col_idx];
        const align_right = right_align[col_idx];
        const key_len = cappedLen(key, width);

        if (align_right and width > key_len) {
            writePadding(io, stdout, width - key_len) catch return Value{ .err = ShellError.WriteFailed };
        }
        _ = writeTruncated(io, stdout, key, width) catch return Value{ .err = ShellError.WriteFailed };

        if (!align_right and width > key_len) {
            writePadding(io, stdout, width - key_len) catch return Value{ .err = ShellError.WriteFailed };
        }
        if (out_i + 1 < visible_order.len) {
            writePadding(io, stdout, layout.spacing) catch return Value{ .err = ShellError.WriteFailed };
        }
    }
    if (layout.dropped_columns) {
        if (visible_order.len > 0) {
            writePadding(io, stdout, layout.spacing) catch return Value{ .err = ShellError.WriteFailed };
        }
        helpers.fileWriteAll(io, stdout, "...") catch return Value{ .err = ShellError.WriteFailed };
    }
    helpers.fileWriteAll(io, stdout, "\n") catch return Value{ .err = ShellError.WriteFailed };

    // Rows
    for (list.items) |item| {
        const map = item.map;

        for (visible_order, 0..) |col_idx, out_i| {
            const key = keys[col_idx];
            const width = widths[col_idx];
            const align_right = right_align[col_idx];

            if (map.get(key)) |value| {
                const str = value.toString(arena) catch return Value{ .err = ShellError.AllocFailed };
                defer arena.free(str);
                const str_len = cappedLen(str, width);
                if (align_right and width > str_len) {
                    writePadding(io, stdout, width - str_len) catch return Value{ .err = ShellError.WriteFailed };
                }
                _ = writeTruncated(io, stdout, str, width) catch return Value{ .err = ShellError.WriteFailed };
                if (!align_right and width > str_len) {
                    writePadding(io, stdout, width - str_len) catch return Value{ .err = ShellError.WriteFailed };
                }
            } else {
                writePadding(io, stdout, width) catch return Value{ .err = ShellError.WriteFailed };
            }
            if (out_i + 1 < visible_order.len) {
                writePadding(io, stdout, layout.spacing) catch return Value{ .err = ShellError.WriteFailed };
            }
        }
        if (layout.dropped_columns) {
            if (visible_order.len > 0) {
                writePadding(io, stdout, layout.spacing) catch return Value{ .err = ShellError.WriteFailed };
            }
            helpers.fileWriteAll(io, stdout, "...") catch return Value{ .err = ShellError.WriteFailed };
        }
        helpers.fileWriteAll(io, stdout, "\n") catch return Value{ .err = ShellError.WriteFailed };
    }

    return Value{ .void = {} };
}

pub fn renderTable(
    exec_ctx: *ExecContext,
    list: *List,
) Value {
    return renderTableWithPrimaryKey(exec_ctx, list, null);
}

pub fn renderValue(
    exec_ctx: *ExecContext,
    value: Value,
) Value {
    if (exec_ctx.output != .stream) return Value{ .err = ShellError.ExpectedStream };

    return switch (value) {
        .list => |l| renderTable(exec_ctx, l),
        else => blk: {
            const text = value.toPrettyString(exec_ctx.allocator) catch break :blk Value{ .err = ShellError.AllocFailed };
            defer exec_ctx.allocator.free(text);
            helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, exec_ctx.output.stream, text) catch break :blk Value{ .err = ShellError.WriteFailed };
            helpers.fileWriteAll(exec_ctx.shell_ctx.io.*, exec_ctx.output.stream, "\n") catch break :blk Value{ .err = ShellError.WriteFailed };
            break :blk Value{ .void = {} };
        },
    };
}

test "fitTableToWidth drops columns when terminal is too narrow" {
    var widths = [_]usize{ 8, 8, 8, 8 };
    const order = [_]usize{ 0, 1, 2, 3 };
    const max_total_width: usize = 6;

    const layout = fitTableToWidth(order[0..], widths[0..], max_total_width);
    try std.testing.expect(layout.dropped_columns);
    try std.testing.expect(layout.visible_count < order.len);

    const visible_width = tableWidthForCount(order[0..], widths[0..], layout.visible_count, layout.spacing);
    const overflow_width: usize = if (layout.visible_count > 0) layout.spacing + 3 else 3;
    try std.testing.expect(visible_width + overflow_width <= max_total_width);
}

test "renderTable falls back to pretty list for non-map lists" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        _ = gpa.deinit();
    }

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("../core/env.zig").EnvMap.init(allocator);
    defer env_map.deinit();

    var shell_ctx = try @import("../core/context.zig").ShellCtx.initEngine(&io, allocator, env_map);
    defer shell_ctx.deinit();

    const out_path = try std.fmt.allocPrint(allocator, "/tmp/zest-render-fallback-{d}.txt", .{std.os.linux.getpid()});
    defer allocator.free(out_path);
    const out_path_z = try allocator.dupeZ(u8, out_path);
    defer allocator.free(out_path_z);

    var out_file = try std.Io.Dir.createFileAbsolute(io, out_path, .{ .truncate = true });
    defer out_file.close(io);

    var exec_ctx = ExecContext{
        .shell_ctx = &shell_ctx,
        .allocator = allocator,
        .output = .{ .stream = out_file },
    };

    var list = try allocator.create(List);
    list.* = try List.initCapacity(allocator, 2);
    try list.append(allocator, Value{ .text = try allocator.dupe(u8, "one") });
    try list.append(allocator, Value{ .text = try allocator.dupe(u8, "two") });
    defer {
        const v = Value{ .list = list };
        v.deinit(allocator);
    }

    const res = renderTable(&exec_ctx, list);
    try std.testing.expect(res == .void);

    var read_file = try std.Io.Dir.openFileAbsolute(io, out_path, .{ .mode = .read_only });
    defer read_file.close(io);
    const content = try helpers.fileReadAll(io, allocator, read_file);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "[") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "one") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "two") != null);
    _ = std.os.linux.unlink(out_path_z.ptr);
}

test "renderTable truncates long cell values" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        _ = gpa.deinit();
    }

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("../core/env.zig").EnvMap.init(allocator);
    defer env_map.deinit();

    var shell_ctx = try @import("../core/context.zig").ShellCtx.initEngine(&io, allocator, env_map);
    defer shell_ctx.deinit();

    const out_path = try std.fmt.allocPrint(allocator, "/tmp/zest-render-trunc-{d}.txt", .{std.os.linux.getpid()});
    defer allocator.free(out_path);
    const out_path_z = try allocator.dupeZ(u8, out_path);
    defer allocator.free(out_path_z);

    var out_file = try std.Io.Dir.createFileAbsolute(io, out_path, .{ .truncate = true });
    defer out_file.close(io);

    var exec_ctx = ExecContext{
        .shell_ctx = &shell_ctx,
        .allocator = allocator,
        .output = .{ .stream = out_file },
    };

    var row = try allocator.create(Map);
    row.* = Map.init(allocator);
    const long_text = "this-is-a-very-long-value-that-should-be-truncated-in-table-render-output";
    try row.put(try allocator.dupe(u8, "name"), Value{ .text = try allocator.dupe(u8, long_text) });

    var list = try allocator.create(List);
    list.* = try List.initCapacity(allocator, 1);
    try list.append(allocator, Value{ .map = row });
    defer {
        const v = Value{ .list = list };
        v.deinit(allocator);
    }

    const res = renderTable(&exec_ctx, list);
    try std.testing.expect(res == .void);

    var read_file = try std.Io.Dir.openFileAbsolute(io, out_path, .{ .mode = .read_only });
    defer read_file.close(io);
    const content = try helpers.fileReadAll(io, allocator, read_file);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "...") != null);
    _ = std.os.linux.unlink(out_path_z.ptr);
}
