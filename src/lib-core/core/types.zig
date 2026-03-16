const std = @import("std");
const Json = @import("../../lib-serialize/json.zig");
const Allocator = std.mem.Allocator;
const ExecContext = @import("command.zig").ExecContext;
const errors = @import("errors.zig");
const ShellError = errors.ShellError;
const BuiltinCommand = @import("builtins.zig").BuiltinCommand;
const INIT_CAPACITY = 256; // for text stream characters

/// Shell native type tag
pub const TypeTag = enum {
    void,
    text,
    integer,
    float,
    boolean,
    list,
    map,
    err,
};

pub const PathType = enum {
    absolute,
    relative,
    home,
    invalid,

    pub fn getPathType(path: []const u8) PathType {
        if (path.len > 0) {
            const first = path[0];
            _ = switch (first) {
                '/' => return .absolute,
                '~' => return .home,
                else => return .relative,
            };
        }
        return .invalid;
    }
};

// TODO: remove later if not needed, original pipe struct used
pub const TextStream = struct {
    allocator: Allocator,
    buffer: std.ArrayList(u8),

    pub fn init(allocator: Allocator) !TextStream {
        return .{
            .allocator = allocator,
            .buffer = try std.ArrayList(u8).initCapacity(allocator, INIT_CAPACITY),
        };
    }

    pub fn write(self: *TextStream, text: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, text);
    }

    pub fn writeLine(self: *TextStream, text: []const u8) !void {
        try self.write(text);
        try self.buffer.append(self.allocator, '\n');
    }

    pub fn asSlice(self: *const TextStream) []const u8 {
        return self.buffer.items;
    }

    pub fn toOwnedSlice(self: *TextStream) ![]const u8 {
        return try self.buffer.toOwnedSlice(self.allocator);
    }

    pub fn deinit(self: *TextStream) void {
        self.buffer.deinit(self.allocator);
    }
};

pub const List = std.ArrayList(Value);
pub const Map = std.StringHashMap(Value);

/// Shell native type tagged union
pub const Value = union(TypeTag) {
    void: void,
    text: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    list: *List,
    map: *Map,
    err: ShellError,

    pub fn deinit(self: Value, allocator: Allocator) void {
        switch (self) {
            .text => |t| allocator.free(t),
            .list => |l| {
                for (l.items) |item| {
                    item.deinit(allocator);
                }
                l.deinit(allocator);
                allocator.destroy(l);
            },
            .map => |m| {
                var iter = m.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.*.deinit(allocator);
                }
                m.deinit();
                allocator.destroy(m);
            },
            else => {},
        }
    }

    pub fn clone(self: Value, allocator: Allocator) !Value {
        return switch (self) {
            .void => .{ .void = {} },
            .text => |t| .{ .text = try allocator.dupe(u8, t) },
            .integer => |i| .{ .integer = i },
            .float => |f| .{ .float = f },
            .boolean => |b| .{ .boolean = b },
            .err => |e| .{ .err = e },
            .list => |l| blk: {
                const out = try allocator.create(List);
                out.* = try List.initCapacity(allocator, l.items.len);
                errdefer {
                    for (out.items) |item| item.deinit(allocator);
                    out.deinit(allocator);
                    allocator.destroy(out);
                }
                for (l.items) |item| {
                    const cloned_item = try item.clone(allocator);
                    errdefer cloned_item.deinit(allocator);
                    try out.append(allocator, cloned_item);
                }
                break :blk .{ .list = out };
            },
            .map => |m| blk: {
                const out = try allocator.create(Map);
                out.* = Map.init(allocator);
                errdefer {
                    var iter = out.iterator();
                    while (iter.next()) |entry| {
                        allocator.free(entry.key_ptr.*);
                        entry.value_ptr.*.deinit(allocator);
                    }
                    out.deinit();
                    allocator.destroy(out);
                }

                var iter = m.iterator();
                while (iter.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    errdefer allocator.free(key);
                    const cloned_value = try entry.value_ptr.*.clone(allocator);
                    errdefer cloned_value.deinit(allocator);
                    try out.put(key, cloned_value);
                }
                break :blk .{ .map = out };
            },
        };
    }

    pub fn toString(self: Value, allocator: Allocator) ![]const u8 {
        return switch (self) {
            .void => allocator.dupe(u8, ""),
            .text => |t| allocator.dupe(u8, t),
            .integer => |i| std.fmt.allocPrint(allocator, "{d}", .{i}),
            .float => |f| std.fmt.allocPrint(allocator, "{d}", .{f}),
            .boolean => |b| if (b) allocator.dupe(u8, "true") else allocator.dupe(u8, "false"),
            .err => |e| blk: {
                const diag = try errors.toStructured(e, allocator);
                break :blk std.fmt.allocPrint(allocator, "{s}: {s}", .{ diag.code, diag.message });
            },
            .list => |l| {
                var builder = try std.ArrayList(u8).initCapacity(allocator, 64);
                defer builder.deinit(allocator);
                try builder.append(allocator, '[');
                for (l.items, 0..) |item, idx| {
                    const item_str = try item.toString(allocator);
                    defer allocator.free(item_str); // Free the string allocated by item.toString
                    try builder.appendSlice(allocator, item_str);
                    if (idx < l.items.len - 1) {
                        try builder.appendSlice(allocator, ", ");
                    }
                }
                try builder.append(allocator, ']');
                return builder.toOwnedSlice(allocator); // Return owned slice
            },
            .map => |m| {
                var builder = try std.ArrayList(u8).initCapacity(allocator, 64);
                defer builder.deinit(allocator);
                try builder.append(allocator, '{');
                var iter = m.iterator();
                var idx: usize = 0;
                const map_count = m.count();
                while (iter.next()) |entry| {
                    try builder.appendSlice(allocator, "\"");
                    try builder.appendSlice(allocator, entry.key_ptr.*);
                    try builder.appendSlice(allocator, "\": ");
                    const value_str = try entry.value_ptr.*.toString(allocator);
                    defer allocator.free(value_str); // Free the string allocated by entry.value_ptr.*.toString
                    try builder.appendSlice(allocator, value_str);
                    if (idx + 1 < map_count) {
                        try builder.appendSlice(allocator, ", ");
                    }
                    idx += 1;
                }
                try builder.append(allocator, '}');
                return builder.toOwnedSlice(allocator); // Return owned slice
            },
        };
    }

    pub fn toPrettyString(self: Value, allocator: Allocator) ![]const u8 {
        var builder = try std.ArrayList(u8).initCapacity(allocator, 128);
        errdefer builder.deinit(allocator);
        try appendPrettyValue(&builder, allocator, self, 0);
        return builder.toOwnedSlice(allocator);
    }

    // Compact JSON serializer used by engine/machine-oriented paths.
    // Human-oriented pretty JSON is handled by lib-serialize/json.zig::toJsonPretty.
    pub fn toJson(self: Value, allocator: Allocator) ![]const u8 {
        switch (self) {
            .void => return try Json.serializeJson(allocator, null),
            .text => return try Json.serializeJson(allocator, self.text),
            .integer => return try Json.serializeJson(allocator, self.integer),
            .float => return try Json.serializeJson(allocator, self.float),
            .boolean => return try Json.serializeJson(allocator, self.boolean),
            .err => |e| {
                const diag = try errors.toStructured(e, allocator);
                return try Json.serializeJson(allocator, .{
                    .code = diag.code,
                    .category = diag.category,
                    .message = diag.message,
                    .hint = diag.hint,
                });
            },
            .list => |l| {
                // Build a JSON array manually to handle nested Values
                var json_items = try allocator.alloc([]const u8, l.items.len);
                defer allocator.free(json_items);

                for (l.items, 0..) |item, i| {
                    json_items[i] = try item.toJson(allocator);
                }
                defer {
                    for (json_items) |item_json| {
                        allocator.free(item_json);
                    }
                }

                var builder = try std.ArrayList(u8).initCapacity(allocator, 64);
                errdefer builder.deinit(allocator);
                try builder.append(allocator, '[');
                for (json_items, 0..) |item_json, idx| {
                    try builder.appendSlice(allocator, item_json);
                    if (idx < json_items.len - 1) {
                        try builder.append(allocator, ',');
                    }
                }
                try builder.append(allocator, ']');
                return builder.toOwnedSlice(allocator);
            },
            .map => |m| {
                var builder = try std.ArrayList(u8).initCapacity(allocator, 64);
                errdefer builder.deinit(allocator);
                try builder.append(allocator, '{');

                var iter = m.iterator();
                var idx: usize = 0;
                const map_count = m.count();
                while (iter.next()) |entry| {
                    // Serialize the key
                    const key_json = try Json.serializeJson(allocator, entry.key_ptr.*);
                    defer allocator.free(key_json);
                    try builder.appendSlice(allocator, key_json);
                    try builder.append(allocator, ':');

                    // Serialize the value
                    const value_json = try entry.value_ptr.*.toJson(allocator);
                    defer allocator.free(value_json);
                    try builder.appendSlice(allocator, value_json);

                    if (idx + 1 < map_count) {
                        try builder.append(allocator, ',');
                    }
                    idx += 1;
                }
                try builder.append(allocator, '}');
                return builder.toOwnedSlice(allocator);
            },
        }
    }
};

pub fn jsonToValue(allocator: Allocator, node: std.json.Value) !Value {
    return switch (node) {
        .null => .{ .void = {} },
        .bool => |b| .{ .boolean = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |ns| blk: {
            if (std.fmt.parseInt(i64, ns, 10) catch null) |n| break :blk .{ .integer = n };
            if (std.fmt.parseFloat(f64, ns) catch null) |f| break :blk .{ .float = f };
            break :blk .{ .text = try allocator.dupe(u8, ns) };
        },
        .string => |s| .{ .text = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            const list = try allocator.create(List);
            list.* = try List.initCapacity(allocator, arr.items.len);
            for (arr.items) |item| {
                try list.append(allocator, try jsonToValue(allocator, item));
            }
            break :blk .{ .list = list };
        },
        .object => |obj| blk: {
            const map = try allocator.create(Map);
            map.* = Map.init(allocator);
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                try map.put(
                    try allocator.dupe(u8, entry.key_ptr.*),
                    try jsonToValue(allocator, entry.value_ptr.*),
                );
            }
            break :blk .{ .map = map };
        },
    };
}

fn appendIndent(builder: *std.ArrayList(u8), allocator: Allocator, depth: usize) !void {
    const n = depth * 2;
    if (n == 0) return;
    const spaces = " " ** 64;
    var remaining = n;
    while (remaining > 0) {
        const chunk = @min(remaining, spaces.len);
        try builder.appendSlice(allocator, spaces[0..chunk]);
        remaining -= chunk;
    }
}

fn appendPrettyValue(
    builder: *std.ArrayList(u8),
    allocator: Allocator,
    value: Value,
    depth: usize,
) !void {
    switch (value) {
        .void => try builder.appendSlice(allocator, "null"),
        .text => |t| try builder.appendSlice(allocator, t),
        .integer => |i| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{i});
            defer allocator.free(s);
            try builder.appendSlice(allocator, s);
        },
        .float => |f| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{f});
            defer allocator.free(s);
            try builder.appendSlice(allocator, s);
        },
        .boolean => |b| try builder.appendSlice(allocator, if (b) "true" else "false"),
        .err => |e| {
            const diag = try errors.toStructured(e, allocator);
            const s = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ diag.code, diag.message });
            defer allocator.free(s);
            try builder.appendSlice(allocator, s);
        },
        .list => |l| {
            if (l.items.len == 0) {
                try builder.appendSlice(allocator, "[]");
                return;
            }
            try builder.appendSlice(allocator, "[\n");
            for (l.items, 0..) |item, idx| {
                try appendIndent(builder, allocator, depth + 1);
                try appendPrettyValue(builder, allocator, item, depth + 1);
                if (idx + 1 < l.items.len) try builder.append(allocator, ',');
                try builder.append(allocator, '\n');
            }
            try appendIndent(builder, allocator, depth);
            try builder.append(allocator, ']');
        },
        .map => |m| {
            if (m.count() == 0) {
                try builder.appendSlice(allocator, "{}");
                return;
            }
            try builder.appendSlice(allocator, "{\n");
            var iter = m.iterator();
            var idx: usize = 0;
            while (iter.next()) |entry| {
                try appendIndent(builder, allocator, depth + 1);
                try builder.appendSlice(allocator, entry.key_ptr.*);
                try builder.appendSlice(allocator, ": ");
                try appendPrettyValue(builder, allocator, entry.value_ptr.*, depth + 1);
                if (idx + 1 < m.count()) try builder.append(allocator, ',');
                try builder.append(allocator, '\n');
                idx += 1;
            }
            try appendIndent(builder, allocator, depth);
            try builder.append(allocator, '}');
        },
    }
}

//
// ------ TESTING ----
//
test "Value basic toString and toJson" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        _ = gpa.deinit();
    }

    // Test void
    {
        const v_void = Value{ .void = {} };
        defer v_void.deinit(allocator);

        const str = try v_void.toString(allocator);
        defer allocator.free(str);
        try std.testing.expectEqualStrings("", str);

        const json = try v_void.toJson(allocator);
        defer allocator.free(json);
        try std.testing.expectEqualStrings("null", json);
    }

    // Test text
    {
        const text_str = try allocator.dupe(u8, "hello");
        const v_text = Value{ .text = text_str };
        defer v_text.deinit(allocator);

        const str = try v_text.toString(allocator);
        defer allocator.free(str);
        try std.testing.expectEqualStrings("hello", str);

        const json = try v_text.toJson(allocator);
        defer allocator.free(json);
        try std.testing.expectEqualStrings("\"hello\"", json);
    }

    // Test integer
    {
        const v_int = Value{ .integer = 123 };
        defer v_int.deinit(allocator);

        const str = try v_int.toString(allocator);
        defer allocator.free(str);
        try std.testing.expectEqualStrings("123", str);

        const json = try v_int.toJson(allocator);
        defer allocator.free(json);
        try std.testing.expectEqualStrings("123", json);
    }

    // Test float
    {
        const v_float = Value{ .float = 1.23 };
        defer v_float.deinit(allocator);

        const str = try v_float.toString(allocator);
        defer allocator.free(str);
        try std.testing.expectEqualStrings("1.23", str);

        const json = try v_float.toJson(allocator);
        defer allocator.free(json);
        try std.testing.expectEqualStrings("1.23", json);
    }

    // Test boolean true
    {
        const v_bool_true = Value{ .boolean = true };
        defer v_bool_true.deinit(allocator);

        const str = try v_bool_true.toString(allocator);
        defer allocator.free(str);
        try std.testing.expectEqualStrings("true", str);

        const json = try v_bool_true.toJson(allocator);
        defer allocator.free(json);
        try std.testing.expectEqualStrings("true", json);
    }

    // Test boolean false
    {
        const v_bool_false = Value{ .boolean = false };
        defer v_bool_false.deinit(allocator);

        const str = try v_bool_false.toString(allocator);
        defer allocator.free(str);
        try std.testing.expectEqualStrings("false", str);

        const json = try v_bool_false.toJson(allocator);
        defer allocator.free(json);
        try std.testing.expectEqualStrings("false", json);
    }

    // Test ShellError
    {
        const err_value = Value{ .err = ShellError.CommandNotFound };
        defer err_value.deinit(allocator);

        const str = try err_value.toString(allocator);
        defer allocator.free(str);
        try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "CommandNotFound"));
        try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "Command was not found."));

        const json = try err_value.toJson(allocator);
        defer allocator.free(json);
        try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"code\":\"CommandNotFound\""));
        try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"message\":\"Command was not found.\""));
    }

    // Test list
    {
        var list = try allocator.create(List);
        list.* = try List.initCapacity(allocator, 4);
        try list.append(allocator, Value{ .integer = 1 });
        const list_text_str = try allocator.dupe(u8, "a");
        try list.append(allocator, Value{ .text = list_text_str });

        const v_list = Value{ .list = list };
        defer v_list.deinit(allocator);

        const str = try v_list.toString(allocator);
        defer allocator.free(str);
        try std.testing.expectEqualStrings("[1, a]", str);

        const json = try v_list.toJson(allocator);
        defer allocator.free(json);
        try std.testing.expectEqualStrings("[1,\"a\"]", json);
    }

    // Test map
    {
        var map = try allocator.create(Map);
        map.* = Map.init(allocator);
        const key1 = try allocator.dupe(u8, "key1");
        try map.put(key1, Value{ .integer = 1 });
        const key2 = try allocator.dupe(u8, "key2");
        const map_text_str = try allocator.dupe(u8, "value");
        try map.put(key2, Value{ .text = map_text_str });

        const v_map = Value{ .map = map };
        defer v_map.deinit(allocator);

        // Map toString order is not guaranteed, so check for contains
        const map_str = try v_map.toString(allocator);
        defer allocator.free(map_str);
        try std.testing.expect(std.mem.indexOf(u8, map_str, "{") != null);
        try std.testing.expect(std.mem.indexOf(u8, map_str, "\"key1\": 1") != null);
        try std.testing.expect(std.mem.indexOf(u8, map_str, "\"key2\": value") != null);
        try std.testing.expect(std.mem.indexOf(u8, map_str, "}") != null);

        // Map toJson order is not guaranteed, so check for contains
        const map_json = try v_map.toJson(allocator);
        defer allocator.free(map_json);
        try std.testing.expect(std.mem.indexOf(u8, map_json, "{") != null);
        try std.testing.expect(std.mem.indexOf(u8, map_json, "\"key1\":1") != null);
        try std.testing.expect(std.mem.indexOf(u8, map_json, "\"key2\":\"value\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, map_json, "}") != null);
    }
}

test "Value complex nested structure" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        _ = gpa.deinit();
    }

    // Create a complex nested structure:
    // {
    //   "user": {
    //     "name": "Alice",
    //     "age": 30,
    //     "active": true
    //   },
    //   "scores": [100, 95, 87],
    //   "metadata": {
    //     "tags": ["admin", "verified"],
    //     "score": 4.5
    //   }
    // }

    // Create the root map
    var root_map = try allocator.create(Map);
    root_map.* = Map.init(allocator);

    // Create "user" nested map
    var user_map = try allocator.create(Map);
    user_map.* = Map.init(allocator);
    try user_map.put(try allocator.dupe(u8, "name"), Value{ .text = try allocator.dupe(u8, "Alice") });
    try user_map.put(try allocator.dupe(u8, "age"), Value{ .integer = 30 });
    try user_map.put(try allocator.dupe(u8, "active"), Value{ .boolean = true });

    // Create "scores" list
    var scores_list = try allocator.create(List);
    scores_list.* = try List.initCapacity(allocator, 4);
    try scores_list.append(allocator, Value{ .integer = 100 });
    try scores_list.append(allocator, Value{ .integer = 95 });
    try scores_list.append(allocator, Value{ .integer = 87 });

    // Create "metadata" nested map
    var metadata_map = try allocator.create(Map);
    metadata_map.* = Map.init(allocator);

    // Create "tags" list inside metadata
    var tags_list = try allocator.create(List);
    tags_list.* = try List.initCapacity(allocator, 4);
    try tags_list.append(allocator, Value{ .text = try allocator.dupe(u8, "admin") });
    try tags_list.append(allocator, Value{ .text = try allocator.dupe(u8, "verified") });

    try metadata_map.put(try allocator.dupe(u8, "tags"), Value{ .list = tags_list });
    try metadata_map.put(try allocator.dupe(u8, "score"), Value{ .float = 4.5 });

    // Add everything to root map
    try root_map.put(try allocator.dupe(u8, "user"), Value{ .map = user_map });
    try root_map.put(try allocator.dupe(u8, "scores"), Value{ .list = scores_list });
    try root_map.put(try allocator.dupe(u8, "metadata"), Value{ .map = metadata_map });

    const v_complex = Value{ .map = root_map };
    defer v_complex.deinit(allocator);

    // Test toString - verify all components are present
    const str = try v_complex.toString(allocator);
    defer allocator.free(str);

    try std.testing.expect(std.mem.indexOf(u8, str, "\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, str, "\"name\": Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, str, "\"age\": 30") != null);
    try std.testing.expect(std.mem.indexOf(u8, str, "\"active\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, str, "\"scores\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, str, "[100, 95, 87]") != null);
    try std.testing.expect(std.mem.indexOf(u8, str, "\"metadata\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, str, "\"tags\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, str, "[admin, verified]") != null);
    try std.testing.expect(std.mem.indexOf(u8, str, "\"score\": 4.5") != null);

    // Test toJson - verify valid JSON structure
    const json = try v_complex.toJson(allocator);
    defer allocator.free(json);

    // Verify JSON structure
    try std.testing.expect(std.mem.indexOf(u8, json, "\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"Alice\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"age\":30") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"active\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scores\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "[100,95,87]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"metadata\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tags\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "[\"admin\",\"verified\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"score\":4.5") != null);

    // Verify the JSON is parseable (if you want to be thorough)
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

test "types functions" {
    // PathType.getPathType
    try std.testing.expect(PathType.getPathType("/") == .absolute);
    try std.testing.expect(PathType.getPathType("/usr/bin") == .absolute);
    try std.testing.expect(PathType.getPathType("~/path") == .home);
    try std.testing.expect(PathType.getPathType("~") == .home);
    try std.testing.expect(PathType.getPathType("./path") == .relative);
    try std.testing.expect(PathType.getPathType("path") == .relative);
    try std.testing.expect(PathType.getPathType("") == .invalid);
}

test "Value toPrettyString formats nested list/map" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        _ = gpa.deinit();
    }

    var row = try allocator.create(Map);
    row.* = Map.init(allocator);
    try row.put(try allocator.dupe(u8, "name"), Value{ .text = try allocator.dupe(u8, "alice") });
    try row.put(try allocator.dupe(u8, "age"), Value{ .integer = 42 });

    var list = try allocator.create(List);
    list.* = try List.initCapacity(allocator, 2);
    try list.append(allocator, Value{ .map = row });
    try list.append(allocator, Value{ .text = try allocator.dupe(u8, "tail") });

    const value = Value{ .list = list };
    defer value.deinit(allocator);

    const pretty = try value.toPrettyString(allocator);
    defer allocator.free(pretty);

    try std.testing.expect(std.mem.indexOf(u8, pretty, "[\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, pretty, "name: alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, pretty, "age: 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, pretty, "tail") != null);
}

test "Value clone performs deep copy for list and map" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var inner = try allocator.create(Map);
    inner.* = Map.init(allocator);
    try inner.put(try allocator.dupe(u8, "n"), .{ .integer = 7 });

    var list = try allocator.create(List);
    list.* = try List.initCapacity(allocator, 2);
    try list.append(allocator, .{ .text = try allocator.dupe(u8, "x") });
    try list.append(allocator, .{ .map = inner });

    const original = Value{ .list = list };
    defer original.deinit(allocator);

    const copied = try original.clone(allocator);
    defer copied.deinit(allocator);

    try std.testing.expect(copied == .list);
    try std.testing.expect(copied.list.items.len == 2);
    try std.testing.expect(copied.list.items[1] == .map);
    const entry = copied.list.items[1].map.get("n") orelse return error.TestExpectedEqual;
    try std.testing.expect(entry == .integer);
    try std.testing.expectEqual(@as(i64, 7), entry.integer);
}
