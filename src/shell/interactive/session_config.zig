const std = @import("std");
const helpers = @import("../../lib-core/core/helpers.zig");
const errors = @import("../../lib-core/core/errors.zig");
const ShellCtx = @import("../../lib-core/core/context.zig").ShellCtx;
const ShellError = @import("../../lib-core/core/errors.zig").ShellError;
const Allocator = std.mem.Allocator;

pub const LoadedConfig = struct {
    prompt_template: ?[]const u8 = null,
    alias_count: usize = 0,
};

const ParsedAlias = struct {
    name: []const u8,
    value: []const u8,
};

const ParsedKeyValue = struct {
    key: []const u8,
    value: []const u8,
};

pub fn freeLoadedConfig(allocator: Allocator, loaded: *LoadedConfig) void {
    if (loaded.prompt_template) |template| {
        allocator.free(template);
    }
    loaded.* = .{};
}

pub fn load(ctx: *ShellCtx, allocator: Allocator, file_path: []const u8, aliases: *ShellCtx.AliasMap) !LoadedConfig {
    const content = helpers.readFileFromPath(ctx, allocator, file_path, false) catch |err| {
        if (err == error.FileNotFound) return .{};
        return err;
    };
    defer allocator.free(content);

    return parseContent(allocator, content, aliases);
}

fn parseContent(allocator: Allocator, content: []const u8, aliases: *ShellCtx.AliasMap) !LoadedConfig {
    var loaded = LoadedConfig{};
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;

        if (startsWithAlias(trimmed)) {
            const parsed = parseAlias(trimmed) catch {
                errors.report(ShellError.InvalidSyntax, "parse config alias line", trimmed);
                continue;
            };
            if (parsed.value.len == 0) continue;
            try upsertAlias(allocator, aliases, parsed.name, parsed.value);
            loaded.alias_count += 1;
            continue;
        }

        const key_value = parseKeyValue(trimmed) orelse continue;
        if (std.mem.eql(u8, key_value.key, "prompt")) {
            if (loaded.prompt_template) |prev| allocator.free(prev);
            loaded.prompt_template = try decodePromptTemplate(allocator, key_value.value);
            continue;
        }
    }

    return loaded;
}

fn startsWithAlias(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "alias")) return false;
    if (line.len == "alias".len) return false;
    return std.ascii.isWhitespace(line["alias".len]);
}

fn parseAlias(line: []const u8) !ParsedAlias {
    const remainder = std.mem.trimStart(u8, line["alias".len..], " \t");
    const eq_idx = std.mem.indexOfScalar(u8, remainder, '=') orelse return ShellError.InvalidSyntax;

    const raw_name = std.mem.trim(u8, remainder[0..eq_idx], " \t");
    const raw_value = std.mem.trim(u8, remainder[eq_idx + 1 ..], " \t");
    if (!isValidAliasName(raw_name)) return ShellError.InvalidSyntax;

    return .{
        .name = raw_name,
        .value = stripMatchingQuotes(raw_value),
    };
}

fn parseKeyValue(line: []const u8) ?ParsedKeyValue {
    const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const key = std.mem.trim(u8, line[0..eq_idx], " \t");
    const value = stripMatchingQuotes(std.mem.trim(u8, line[eq_idx + 1 ..], " \t"));
    if (key.len == 0) return null;

    return .{
        .key = key,
        .value = value,
    };
}

fn stripMatchingQuotes(raw: []const u8) []const u8 {
    if (raw.len < 2) return raw;
    if (raw[0] == '"' and raw[raw.len - 1] == '"') return raw[1 .. raw.len - 1];
    if (raw[0] == '\'' and raw[raw.len - 1] == '\'') return raw[1 .. raw.len - 1];
    return raw;
}

fn decodePromptTemplate(allocator: Allocator, raw: []const u8) ![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, raw.len);
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] != '\\' or i + 1 >= raw.len) {
            try out.append(allocator, raw[i]);
            continue;
        }

        i += 1;
        switch (raw[i]) {
            'n' => try out.append(allocator, '\n'),
            't' => try out.append(allocator, '\t'),
            '\\' => try out.append(allocator, '\\'),
            else => {
                try out.append(allocator, '\\');
                try out.append(allocator, raw[i]);
            },
        }
    }

    return out.toOwnedSlice(allocator);
}

fn isValidAliasName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (std.ascii.isWhitespace(c)) return false;
        switch (c) {
            '|', '&', ';', '<', '>', '=' => return false,
            else => {},
        }
    }
    return true;
}

fn upsertAlias(allocator: Allocator, aliases: *ShellCtx.AliasMap, name: []const u8, value: []const u8) !void {
    if (aliases.getPtr(name)) |value_ptr| {
        allocator.free(value_ptr.*);
        value_ptr.* = try allocator.dupe(u8, value);
        return;
    }

    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);

    const value_copy = try allocator.dupe(u8, value);
    errdefer allocator.free(value_copy);

    try aliases.put(name_copy, value_copy);
}

test "parseContent loads aliases and prompt settings" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        _ = gpa.deinit();
    }

    var aliases = ShellCtx.AliasMap.init(allocator);
    defer {
        var iter = aliases.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        aliases.deinit();
    }

    const content =
        \\# zest config
        \\alias gp = git pull
        \\alias ll='ls -la'
        \\prompt = "${user}:${cwd}${git}${status}${prompt_char} "
        \\
    ;
    var loaded = try parseContent(allocator, content, &aliases);
    defer freeLoadedConfig(allocator, &loaded);

    try std.testing.expectEqual(@as(usize, 2), loaded.alias_count);
    try std.testing.expect(std.mem.eql(u8, aliases.get("gp").?, "git pull"));
    try std.testing.expect(std.mem.eql(u8, aliases.get("ll").?, "ls -la"));
    try std.testing.expectEqualStrings("${user}:${cwd}${git}${status}${prompt_char} ", loaded.prompt_template.?);
}

test "parseAlias rejects invalid names" {
    try std.testing.expectError(ShellError.InvalidSyntax, parseAlias("alias bad name = echo hi"));
    try std.testing.expectError(ShellError.InvalidSyntax, parseAlias("alias foo|bar = echo hi"));
}

test "parseContent accepts quoted prompt template" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        _ = gpa.deinit();
    }

    var aliases = ShellCtx.AliasMap.init(allocator);
    defer aliases.deinit();

    const content =
        \\prompt = '${user}@${cwd_base}${git}${prompt_char} '
        \\
    ;
    var loaded = try parseContent(allocator, content, &aliases);
    defer freeLoadedConfig(allocator, &loaded);

    try std.testing.expectEqualStrings("${user}@${cwd_base}${git}${prompt_char} ", loaded.prompt_template.?);
}

test "parseContent decodes escaped prompt newlines" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        _ = gpa.deinit();
    }

    var aliases = ShellCtx.AliasMap.init(allocator);
    defer aliases.deinit();

    const content =
        \\prompt = "${user} ${cwd_base}${git}\n> "
        \\
    ;
    var loaded = try parseContent(allocator, content, &aliases);
    defer freeLoadedConfig(allocator, &loaded);

    try std.testing.expectEqualStrings("${user} ${cwd_base}${git}\n> ", loaded.prompt_template.?);
}
