const std = @import("std");
const types = @import("../core/types.zig");
const core_transforms = @import("transforms.zig");
const ShellError = @import("../core/errors.zig").ShellError;
const Allocator = std.mem.Allocator;
const Value = types.Value;
const List = types.List;
const Map = types.Map;
const Predicate = core_transforms.Predicate;

pub const MapSpecTag = enum {
    identity,
    field,
    upper,
    lower,
    trim,
    len,
    tostring,
    prefix,
    suffix,
    add,
    mul,
};

pub const MapSpec = struct {
    tag: MapSpecTag,
    arg: ?[]const u8 = null,
};

const FilterSpecTag = enum {
    predicate,
    truthy,
    compare,
};

const CompareOp = enum {
    eq,
    neq,
    lt,
    gt,
    lte,
    gte,
    contains,
};

const FilterSpec = union(FilterSpecTag) {
    predicate: Predicate,
    truthy: void,
    compare: struct {
        op: CompareOp,
        rhs: Value,
    },
};

pub fn parseMapSpec(args: [][]const u8) !MapSpec {
    if (args.len == 0) return ShellError.MissingArgument;

    const token = args[0];
    if (token.len > 1 and token[0] == '.') {
        return .{ .tag = .field, .arg = token[1..] };
    }

    if (std.mem.eql(u8, token, "identity")) return .{ .tag = .identity };
    if (std.mem.eql(u8, token, "upper")) return .{ .tag = .upper };
    if (std.mem.eql(u8, token, "lower")) return .{ .tag = .lower };
    if (std.mem.eql(u8, token, "trim")) return .{ .tag = .trim };
    if (std.mem.eql(u8, token, "len")) return .{ .tag = .len };
    if (std.mem.eql(u8, token, "str")) return .{ .tag = .tostring };

    if (std.mem.eql(u8, token, "prefix")) {
        if (args.len < 2) return ShellError.MissingArgument;
        return .{ .tag = .prefix, .arg = args[1] };
    }
    if (std.mem.eql(u8, token, "suffix")) {
        if (args.len < 2) return ShellError.MissingArgument;
        return .{ .tag = .suffix, .arg = args[1] };
    }
    if (std.mem.eql(u8, token, "add")) {
        if (args.len < 2) return ShellError.MissingArgument;
        return .{ .tag = .add, .arg = args[1] };
    }
    if (std.mem.eql(u8, token, "mul")) {
        if (args.len < 2) return ShellError.MissingArgument;
        return .{ .tag = .mul, .arg = args[1] };
    }

    return ShellError.InvalidArgument;
}

pub fn mapValues(allocator: Allocator, input: *List, spec: MapSpec) !*List {
    const out = try allocator.create(List);
    out.* = try List.initCapacity(allocator, input.items.len);

    for (input.items) |item| {
        const mapped = try applyMap(allocator, item, spec);
        try out.append(allocator, mapped);
    }

    return out;
}

pub fn filterValues(allocator: Allocator, input: *List, args: [][]const u8) !*List {
    const spec = try parseFilterSpec(args);

    const out = try allocator.create(List);
    out.* = try List.initCapacity(allocator, input.items.len);

    for (input.items) |item| {
        if (try shouldKeep(item, spec)) {
            try out.append(allocator, try cloneValue(allocator, item));
        }
    }

    return out;
}

pub fn reduceValues(allocator: Allocator, input: *List, op: []const u8, delimiter: ?[]const u8) !Value {
    if (std.mem.eql(u8, op, "sum")) {
        if (input.items.len == 0) return Value{ .integer = 0 };
        var is_float = false;
        var int_sum: i64 = 0;
        var float_sum: f64 = 0;

        for (input.items) |item| {
            switch (item) {
                .integer => |n| {
                    int_sum += n;
                    float_sum += @as(f64, @floatFromInt(n));
                },
                .float => |f| {
                    is_float = true;
                    float_sum += f;
                },
                else => return ShellError.TypeMismatch,
            }
        }

        if (is_float) return Value{ .float = float_sum };
        return Value{ .integer = int_sum };
    }

    if (std.mem.eql(u8, op, "concat")) {
        const delim = delimiter orelse "";
        var builder = try std.ArrayList(u8).initCapacity(allocator, 64);
        errdefer builder.deinit(allocator);

        for (input.items, 0..) |item, idx| {
            const str = try item.toString(allocator);
            defer allocator.free(str);
            try builder.appendSlice(allocator, str);
            if (idx + 1 < input.items.len) {
                try builder.appendSlice(allocator, delim);
            }
        }

        return Value{ .text = try builder.toOwnedSlice(allocator) };
    }

    if (std.mem.eql(u8, op, "merge")) {
        const merged = try allocator.create(Map);
        merged.* = Map.init(allocator);

        for (input.items) |item| {
            const row = switch (item) {
                .map => |m| m,
                else => return ShellError.TypeMismatch,
            };

            var it = row.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const value = try cloneValue(allocator, entry.value_ptr.*);
                if (merged.getPtr(key)) |existing| {
                    existing.deinit(allocator);
                    existing.* = value;
                } else {
                    try merged.put(try allocator.dupe(u8, key), value);
                }
            }
        }

        return Value{ .map = merged };
    }

    return ShellError.InvalidArgument;
}

pub fn linesOfText(allocator: Allocator, text: []const u8) !*List {
    const out = try allocator.create(List);
    out.* = try List.initCapacity(allocator, 8);

    var it = std.mem.splitScalar(u8, text, '\n');
    var idx: usize = 0;
    while (it.next()) |line_raw| : (idx += 1) {
        var line = line_raw;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }

        // Drop only trailing empty from final newline.
        if (line.len == 0 and idx > 0 and idx == countLines(text) - 1 and text.len > 0 and text[text.len - 1] == '\n') {
            continue;
        }

        try out.append(allocator, Value{ .text = try allocator.dupe(u8, line) });
    }

    return out;
}

pub fn splitText(allocator: Allocator, text: []const u8, delimiter: ?[]const u8) !*List {
    const out = try allocator.create(List);
    out.* = try List.initCapacity(allocator, 8);

    if (delimiter) |delim| {
        if (std.mem.eql(u8, delim, "chars") or delim.len == 0) {
            for (text) |b| {
                const chunk = try allocator.alloc(u8, 1);
                chunk[0] = b;
                try out.append(allocator, Value{ .text = chunk });
            }
            return out;
        }

        var it = std.mem.splitSequence(u8, text, delim);
        while (it.next()) |part| {
            try out.append(allocator, Value{ .text = try allocator.dupe(u8, part) });
        }
        return out;
    }

    var tok = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (tok.next()) |part| {
        try out.append(allocator, Value{ .text = try allocator.dupe(u8, part) });
    }
    return out;
}

pub fn joinValues(allocator: Allocator, input: *List, delimiter: []const u8) ![]const u8 {
    var builder = try std.ArrayList(u8).initCapacity(allocator, 64);
    errdefer builder.deinit(allocator);

    for (input.items, 0..) |item, idx| {
        const text = try item.toString(allocator);
        defer allocator.free(text);
        try builder.appendSlice(allocator, text);
        if (idx + 1 < input.items.len) {
            try builder.appendSlice(allocator, delimiter);
        }
    }

    return builder.toOwnedSlice(allocator);
}

fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var n: usize = 1;
    for (text) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

fn parseFilterSpec(args: [][]const u8) !FilterSpec {
    if (args.len == 0) return ShellError.MissingArgument;

    if (args[0].len > 1 and args[0][0] == '.') {
        const pred = Predicate.parse(args) orelse return ShellError.InvalidArgument;
        return .{ .predicate = pred };
    }

    if (args.len == 1 and std.mem.eql(u8, args[0], "truthy")) {
        return .{ .truthy = {} };
    }

    if (args.len == 2) {
        const op = parseCompareOp(args[0]) orelse return ShellError.InvalidArgument;
        return .{ .compare = .{ .op = op, .rhs = parseLiteral(args[1]) } };
    }

    return ShellError.InvalidArgument;
}

fn applyMap(allocator: Allocator, value: Value, spec: MapSpec) !Value {
    return switch (spec.tag) {
        .identity => cloneValue(allocator, value),
        .field => blk: {
            const field = spec.arg orelse return ShellError.InvalidArgument;
            const row = switch (value) {
                .map => |m| m,
                else => return ShellError.TypeMismatch,
            };
            const picked = row.get(field) orelse return ShellError.InvalidArgument;
            break :blk try cloneValue(allocator, picked);
        },
        .upper => mapTextValue(allocator, value, std.ascii.toUpper),
        .lower => mapTextValue(allocator, value, std.ascii.toLower),
        .trim => blk: {
            const s = try value.toString(allocator);
            defer allocator.free(s);
            const trimmed = std.mem.trim(u8, s, " \t\r\n");
            break :blk Value{ .text = try allocator.dupe(u8, trimmed) };
        },
        .len => switch (value) {
            .text => |s| Value{ .integer = @intCast(s.len) },
            .list => |l| Value{ .integer = @intCast(l.items.len) },
            .map => |m| Value{ .integer = @intCast(m.count()) },
            else => ShellError.TypeMismatch,
        },
        .tostring => Value{ .text = try value.toString(allocator) },
        .prefix => blk: {
            const prefix = spec.arg orelse return ShellError.InvalidArgument;
            const s = try value.toString(allocator);
            defer allocator.free(s);
            break :blk Value{ .text = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, s }) };
        },
        .suffix => blk: {
            const suffix = spec.arg orelse return ShellError.InvalidArgument;
            const s = try value.toString(allocator);
            defer allocator.free(s);
            break :blk Value{ .text = try std.fmt.allocPrint(allocator, "{s}{s}", .{ s, suffix }) };
        },
        .add => applyNumericMap(value, spec.arg orelse return ShellError.InvalidArgument, true),
        .mul => applyNumericMap(value, spec.arg orelse return ShellError.InvalidArgument, false),
    };
}

fn mapTextValue(allocator: Allocator, value: Value, mapper: *const fn (u8) u8) !Value {
    const s = try value.toString(allocator);
    defer allocator.free(s);

    const out = try allocator.dupe(u8, s);
    for (out) |*b| {
        b.* = mapper(b.*);
    }
    return Value{ .text = out };
}

fn applyNumericMap(value: Value, rhs_text: []const u8, is_add: bool) !Value {
    const rhs_i = std.fmt.parseInt(i64, rhs_text, 10) catch null;
    const rhs_f = std.fmt.parseFloat(f64, rhs_text) catch null;

    return switch (value) {
        .integer => |n| blk: {
            if (rhs_i) |ri| {
                break :blk Value{ .integer = if (is_add) n + ri else n * ri };
            }
            if (rhs_f) |rf| {
                const left = @as(f64, @floatFromInt(n));
                break :blk Value{ .float = if (is_add) left + rf else left * rf };
            }
            break :blk ShellError.InvalidArgument;
        },
        .float => |n| blk: {
            if (rhs_f) |rf| {
                break :blk Value{ .float = if (is_add) n + rf else n * rf };
            }
            if (rhs_i) |ri| {
                const right = @as(f64, @floatFromInt(ri));
                break :blk Value{ .float = if (is_add) n + right else n * right };
            }
            break :blk ShellError.InvalidArgument;
        },
        else => ShellError.TypeMismatch,
    };
}

fn shouldKeep(value: Value, spec: FilterSpec) !bool {
    return switch (spec) {
        .truthy => isTruthy(value),
        .predicate => |pred| switch (value) {
            .map => |m| pred.evaluate(m),
            else => false,
        },
        .compare => |cmp| compareValues(value, cmp.op, cmp.rhs),
    };
}

fn isTruthy(value: Value) bool {
    return switch (value) {
        .void => false,
        .boolean => |b| b,
        .integer => |n| n != 0,
        .float => |f| f != 0,
        .text => |t| t.len != 0,
        .list => |l| l.items.len != 0,
        .map => |m| m.count() != 0,
        .err => false,
    };
}

fn parseCompareOp(token: []const u8) ?CompareOp {
    if (std.mem.eql(u8, token, "==")) return .eq;
    if (std.mem.eql(u8, token, "!=")) return .neq;
    if (std.mem.eql(u8, token, ">")) return .gt;
    if (std.mem.eql(u8, token, "<")) return .lt;
    if (std.mem.eql(u8, token, ">=")) return .gte;
    if (std.mem.eql(u8, token, "<=")) return .lte;
    if (std.mem.eql(u8, token, "contains")) return .contains;
    return null;
}

fn parseLiteral(raw: []const u8) Value {
    if (std.fmt.parseInt(i64, raw, 10) catch null) |n| {
        return Value{ .integer = n };
    }
    if (std.fmt.parseFloat(f64, raw) catch null) |f| {
        return Value{ .float = f };
    }
    if (std.mem.eql(u8, raw, "true")) return Value{ .boolean = true };
    if (std.mem.eql(u8, raw, "false")) return Value{ .boolean = false };
    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
        return Value{ .text = raw[1 .. raw.len - 1] };
    }
    return Value{ .text = raw };
}

fn compareValues(lhs: Value, op: CompareOp, rhs: Value) bool {
    return switch (op) {
        .eq => valuesEqual(lhs, rhs),
        .neq => !valuesEqual(lhs, rhs),
        .contains => switch (lhs) {
            .text => |lt| switch (rhs) {
                .text => |rt| std.mem.indexOf(u8, lt, rt) != null,
                else => false,
            },
            else => false,
        },
        .lt, .gt, .lte, .gte => compareOrderedValues(lhs, op, rhs),
    };
}

fn compareOrderedValues(lhs: Value, op: CompareOp, rhs: Value) bool {
    return switch (lhs) {
        .integer => |li| switch (rhs) {
            .integer => |ri| compareOrdered(li, ri, op),
            .float => |rf| compareOrdered(@as(f64, @floatFromInt(li)), rf, op),
            else => false,
        },
        .float => |lf| switch (rhs) {
            .integer => |ri| compareOrdered(lf, @as(f64, @floatFromInt(ri)), op),
            .float => |rf| compareOrdered(lf, rf, op),
            else => false,
        },
        .text => |lt| switch (rhs) {
            .text => |rt| switch (op) {
                .lt => std.mem.order(u8, lt, rt) == .lt,
                .gt => std.mem.order(u8, lt, rt) == .gt,
                .lte => std.mem.order(u8, lt, rt) != .gt,
                .gte => std.mem.order(u8, lt, rt) != .lt,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

fn compareOrdered(a: anytype, b: @TypeOf(a), op: CompareOp) bool {
    return switch (op) {
        .lt => a < b,
        .gt => a > b,
        .lte => a <= b,
        .gte => a >= b,
        else => false,
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

fn cloneValue(allocator: Allocator, value: Value) !Value {
    return switch (value) {
        .void => Value{ .void = {} },
        .integer => |n| Value{ .integer = n },
        .float => |f| Value{ .float = f },
        .boolean => |b| Value{ .boolean = b },
        .err => |e| Value{ .err = e },
        .text => |t| Value{ .text = try allocator.dupe(u8, t) },
        .list => |list| blk: {
            const out = try allocator.create(List);
            out.* = try List.initCapacity(allocator, list.items.len);
            for (list.items) |item| {
                try out.append(allocator, try cloneValue(allocator, item));
            }
            break :blk Value{ .list = out };
        },
        .map => |map| blk: {
            const out = try allocator.create(Map);
            out.* = Map.init(allocator);
            var it = map.iterator();
            while (it.next()) |entry| {
                try out.put(
                    try allocator.dupe(u8, entry.key_ptr.*),
                    try cloneValue(allocator, entry.value_ptr.*),
                );
            }
            break :blk Value{ .map = out };
        },
    };
}
