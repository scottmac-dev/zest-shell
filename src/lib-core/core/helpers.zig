/// HELPERS UTILITY FUNCTIONS
const std = @import("std");
const execute = @import("execute.zig");
const env = @import("env.zig");
const fs = std.fs;
const json = @import("../../lib-serialize/json.zig");
const types = @import("types.zig");
const lexer = @import("lexer.zig");
const Allocator = std.mem.Allocator;
const ShellCtx = @import("context.zig").ShellCtx;
const Value = types.Value;

// ---- IO helpers

/// Write bytes to a file from the beginning (offset 0).
pub fn fileWriteAll(io: std.Io, file: std.Io.File, bytes: []const u8) !void {
    // Try streaming first - works for both pipes and regular files
    // Positional writes on pipes silently succeed but write nothing
    //std.debug.print("write all: {s}\n", .{bytes});
    file.writeStreamingAll(io, bytes) catch {
        try file.writePositionalAll(io, bytes, 0);
    };
}

/// Write bytes to a file, appending after existing content.
/// Uses positional write at the current file length.
pub fn fileAppendAll(io: std.Io, file: std.Io.File, bytes: []const u8) !void {
    //std.debug.print("append all: {s}\n", .{bytes});
    const offset = file.length(io) catch {
        // pipe - streaming append is just streaming write
        try file.writeStreamingAll(io, bytes);
        return;
    };
    file.writePositionalAll(io, bytes, offset) catch {
        // Some stream-like fds may report a length but still reject positional writes.
        try file.writeStreamingAll(io, bytes);
    };
}

/// Read entire file into an allocated buffer. Caller owns returned slice.
pub fn fileReadAll(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File) ![]u8 {
    const size = try file.length(io);
    //std.debug.print("file read all: {any}\n", .{size});
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    _ = try file.readPositionalAll(io, buf, 0);
    return buf;
}

/// Read all bytes from a pipe/stream into an allocated buffer.
/// Uses streaming read since pipes have no seekable length.
pub fn pipeReadAll(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File) ![]u8 {
    var buf: [4096]u8 = undefined;
    var result = try std.ArrayList(u8).initCapacity(allocator, 1024);
    errdefer result.deinit(allocator);
    var stream_reader = file.readerStreaming(io, &buf);
    const reader = &stream_reader.interface;
    while (true) {
        const chunk = try reader.readSliceShort(buf[0..]);
        if (chunk == 0) break;
        try result.appendSlice(allocator, buf[0..chunk]);
    }
    //std.debug.print("pipe read all: {s}\n", .{result.items});
    return result.toOwnedSlice(allocator);
}

// ----- PATH / FS ACTIONS

/// Determine if string is a path
pub fn isPath(text: []const u8) bool {
    if (text.len == 0) return false;
    return text[0] == '~' or
        text[0] == '/' or
        text[0] == '\\' or
        (text.len >= 2 and text[0] == '.' and (text[1] == '/' or text[1] == '\\'));
}

/// Returns true when `path` can be executed by the current process.
/// Uses the Io path-based access API to avoid temporary NUL-terminated allocations.
pub fn isExecutablePath(io: *std.Io, path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io.*, path, .{ .execute = true }) catch return false;
    } else {
        std.Io.Dir.cwd().access(io.*, path, .{ .execute = true }) catch return false;
    }
    return true;
}

/// Build `dir/leaf` into `out`, reusing the same buffer across iterations.
pub fn appendPathJoin(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    dir: []const u8,
    leaf: []const u8,
) !void {
    out.clearRetainingCapacity();
    if (dir.len == 0) {
        try out.appendSlice(allocator, leaf);
        return;
    }
    try out.appendSlice(allocator, dir);
    if (out.items[out.items.len - 1] != '/') {
        try out.append(allocator, '/');
    }
    try out.appendSlice(allocator, leaf);
}

/// Determine if a file path has executable permissions
pub fn isExe(ctx: *ShellCtx, allocator: Allocator, path: []const u8) bool {
    if (!isPath(path)) return false;

    const abs = expandPathToAbs(ctx, allocator, path) catch return false;
    defer if (allocator.ptr == ctx.allocator.ptr) {
        ctx.allocator.free(abs);
    };

    return isExecutablePath(ctx.io, abs);
}

/// Return true if file exists in filesystem
pub fn fileExists(io: *std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io.*, path, .{}) catch return false;
    return true;
}

/// Return true if directory exists in filesystem
pub fn dirExists(ctx: *ShellCtx, path: []const u8) bool {
    // access alone can't distinguish file vs dir, so open and check kind
    const stat = std.Io.Dir.cwd().statFile(ctx.io.*, path, .{}) catch return false;
    return stat.kind == .directory;
}

/// Ensures parent directories exist for a given file path
pub fn ensureDirPath(ctx: *ShellCtx, file_path: []const u8) !void {
    if (std.fs.path.dirname(file_path)) |dir_path| {
        try std.Io.Dir.cwd().createDirPath(ctx.io.*, dir_path);
    }
}

/// Returns an open file from an absolute path via the Io backend
pub fn getFileFromPath(
    ctx: *ShellCtx,
    allocator: Allocator,
    path: []const u8,
    opts: struct {
        write: bool = false, // open for writing
        truncate: bool = true, // overwrite by default
        pre_expanded: bool = false, // skip path expansion
    },
) !std.Io.File {
    const expanded_path = if (opts.pre_expanded) path else try expandPathToAbs(ctx, allocator, path);
    defer if (!opts.pre_expanded and allocator.ptr == ctx.allocator.ptr) {
        ctx.allocator.free(expanded_path);
    };

    if (opts.write) {
        // For append we must NOT truncate, for normal write truncate per caller's request
        return try std.Io.Dir.createFileAbsolute(ctx.io.*, expanded_path, .{
            .truncate = opts.truncate,
        });
    } else {
        return try std.Io.Dir.openFileAbsolute(ctx.io.*, expanded_path, .{ .mode = .read_only });
    }
}

/// Open a file path for reading and return the full contents.
/// Callers keep the read/open error mapping so they can translate it into
/// feature-specific diagnostics.
pub fn readFileFromPath(
    ctx: *ShellCtx,
    allocator: Allocator,
    path: []const u8,
    pre_expanded: bool,
) ![]u8 {
    var file = try getFileFromPath(ctx, allocator, path, .{
        .write = false,
        .truncate = false,
        .pre_expanded = pre_expanded,
    });
    defer file.close(ctx.io.*);

    return try fileReadAll(ctx.io.*, allocator, file);
}

// ---- TIME HELPERS

pub const TimingProfile = struct {
    real_ns: i96,
    user_ns: i128,
    system_ns: i128,
    exit_code: u8,
};

fn timevalToNs(tv: std.posix.timeval) i128 {
    return @as(i128, tv.sec) * std.time.ns_per_s + @as(i128, tv.usec) * std.time.ns_per_us;
}

pub fn buildTimingProfile(
    start_rusage: std.posix.rusage,
    end_rusage: std.posix.rusage,
    duration_ns: i96,
    exit_code: u8,
) TimingProfile {
    const user_ns = timevalToNs(end_rusage.utime) - timevalToNs(start_rusage.utime);
    const system_ns = timevalToNs(end_rusage.stime) - timevalToNs(start_rusage.stime);
    return .{
        .real_ns = @max(0, duration_ns),
        .user_ns = @max(0, user_ns),
        .system_ns = @max(0, system_ns),
        .exit_code = exit_code,
    };
}

pub fn printTimingProfile(ctx: *ShellCtx, allocator: Allocator, profile: TimingProfile) void {
    _ = allocator;
    _ = profile.exit_code;
    const real_s = @as(f64, @floatFromInt(profile.real_ns)) / @as(f64, std.time.ns_per_s);
    const user_s = @as(f64, @floatFromInt(profile.user_ns)) / @as(f64, std.time.ns_per_s);
    const sys_s = @as(f64, @floatFromInt(profile.system_ns)) / @as(f64, std.time.ns_per_s);
    ctx.print("real\t{d:.3}s\nuser\t{d:.3}s\nsys\t{d:.3}s\n", .{ real_s, user_s, sys_s });
}

// ---- PARSE AND EXPAND HELPERS

/// Extract variable name and value from assignment
pub fn parseAssignment(input: []const u8) ?struct { name: []const u8, value: []const u8 } {
    const eq_pos = std.mem.indexOfScalar(u8, input, '=') orelse return null;
    return .{
        .name = input[0..eq_pos],
        .value = input[eq_pos + 1 ..],
    };
}

/// Helper to match shell's definition of an assignment, eg VAR=value
pub fn isAssignment(text: []const u8) bool {
    const eq_index = std.mem.indexOfScalar(u8, text, '=') orelse return false;
    if (eq_index == 0) return false; // "=value" is not an assignment

    // (alphanumeric + underscore).
    // This prevents "--flag=value" from becoming an Assignment token.
    for (text[0..eq_index]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') {
            return false;
        }
    }
    return true;
}

// Glob expansion helpers for pattern matching on ? *
/// Check if a pattern contains glob characters
pub fn hasGlobChars(pattern: []const u8) bool {
    return std.mem.indexOfAny(u8, pattern, "*?[") != null;
}

/// Match a single glob pattern against a filename
fn matchPattern(pattern: []const u8, name: []const u8) bool {
    var p_idx: usize = 0;
    var n_idx: usize = 0;

    var star_p: ?usize = null;
    var star_n: ?usize = null;

    while (n_idx < name.len) {
        if (p_idx < pattern.len) {
            const p = pattern[p_idx];
            const n = name[n_idx];

            switch (p) {
                '*' => {
                    // Remember position of * for backtracking
                    star_p = p_idx;
                    star_n = n_idx;
                    p_idx += 1;
                    // Don't advance n_idx - * can match zero chars
                    continue;
                },
                '?' => {
                    // ? matches any single character
                    p_idx += 1;
                    n_idx += 1;
                },
                '[' => {
                    // Character class: [abc] or [a-z]
                    p_idx += 1;
                    var matched = false;
                    var negate = false;

                    // Check for negation [!abc]
                    if (p_idx < pattern.len and pattern[p_idx] == '!') {
                        negate = true;
                        p_idx += 1;
                    }

                    while (p_idx < pattern.len and pattern[p_idx] != ']') {
                        const class_char = pattern[p_idx];

                        // Check for range a-z
                        if (p_idx + 2 < pattern.len and pattern[p_idx + 1] == '-') {
                            const range_start = class_char;
                            const range_end = pattern[p_idx + 2];
                            if (n >= range_start and n <= range_end) {
                                matched = true;
                            }
                            p_idx += 3;
                        } else {
                            if (n == class_char) {
                                matched = true;
                            }
                            p_idx += 1;
                        }
                    }

                    if (p_idx < pattern.len and pattern[p_idx] == ']') {
                        p_idx += 1;
                    }

                    // Apply negation
                    if (negate) matched = !matched;

                    if (matched) {
                        n_idx += 1;
                    } else {
                        // No match - backtrack to * if we have one
                        if (star_p) |sp| {
                            p_idx = sp + 1;
                            star_n = star_n.? + 1;
                            n_idx = star_n.?;
                        } else {
                            return false;
                        }
                    }
                },
                else => {
                    // Literal character must match
                    if (p == n) {
                        p_idx += 1;
                        n_idx += 1;
                    } else {
                        // No match - backtrack to * if we have one
                        if (star_p) |sp| {
                            p_idx = sp + 1;
                            star_n = star_n.? + 1;
                            n_idx = star_n.?;
                        } else {
                            return false;
                        }
                    }
                },
            }
        } else {
            // Pattern exhausted but name continues - backtrack if we have *
            if (star_p) |sp| {
                p_idx = sp + 1;
                star_n = star_n.? + 1;
                n_idx = star_n.?;
            } else {
                return false;
            }
        }
    }

    // Consume any trailing *
    while (p_idx < pattern.len and pattern[p_idx] == '*') {
        p_idx += 1;
    }

    return p_idx == pattern.len;
}

/// Expand a glob pattern into a list of matching files
pub fn expandGlob(io: *std.Io, allocator: Allocator, pattern: []const u8) ![][]const u8 {
    // Parse the pattern to separate directory path from filename pattern
    var dir_path: []const u8 = ".";
    var file_pattern: []const u8 = pattern;

    // Find the last directory separator
    if (std.mem.lastIndexOfScalar(u8, pattern, '/')) |last_slash| {
        dir_path = pattern[0..last_slash];
        if (last_slash + 1 < pattern.len) {
            file_pattern = pattern[last_slash + 1 ..];
        } else {
            file_pattern = "*"; // Pattern ends with /, match all
        }

        // Handle empty dir_path (pattern started with /)
        if (dir_path.len == 0) {
            dir_path = "/";
        }
    }

    // Open directory
    var dir = std.Io.Dir.cwd().openDir(io.*, dir_path, .{ .iterate = true }) catch {
        // Directory doesn't exist - return pattern as-is (bash behavior)
        var result = try allocator.alloc([]const u8, 1);
        result[0] = try allocator.dupe(u8, pattern);
        return result;
    };
    defer dir.close(io.*);

    // Iterate and match files
    var matches = try std.ArrayList([]const u8).initCapacity(allocator, 8);
    errdefer {
        for (matches.items) |match| allocator.free(match);
        matches.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next(io.*)) |entry| {
        // Skip hidden files unless pattern explicitly starts with .
        if (entry.name[0] == '.' and file_pattern[0] != '.') {
            continue;
        }

        // Match the filename against the pattern
        if (matchPattern(file_pattern, entry.name)) {
            // Build full path
            const full_path = if (std.mem.eql(u8, dir_path, "."))
                try allocator.dupe(u8, entry.name)
            else
                try std.fs.path.join(allocator, &.{ dir_path, entry.name });

            try matches.append(allocator, full_path);
        }
    }

    // If no matches, return pattern as-is (bash behavior)
    if (matches.items.len == 0) {
        try matches.append(allocator, try allocator.dupe(u8, pattern));
    } else {
        // Sort matches alphabetically (bash behavior)
        std.mem.sort([]const u8, matches.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
    }

    return matches.toOwnedSlice(allocator);
}

/// Expand multiple patterns (for use in for loops)
pub fn expandGlobList(io: *std.Io, allocator: Allocator, patterns: []const []const u8) ![][]const u8 {
    var all_matches = try std.ArrayList([]const u8).initCapacity(allocator, 8);
    errdefer {
        for (all_matches.items) |match| allocator.free(match);
        all_matches.deinit(allocator);
    }

    for (patterns) |pattern| {
        if (hasGlobChars(pattern)) {
            // Pattern contains globs - expand it
            const matches = try expandGlob(io, allocator, pattern);
            defer allocator.free(matches);

            for (matches) |match| {
                try all_matches.append(allocator, match);
            }
        } else {
            // No globs - use as-is
            try all_matches.append(allocator, try allocator.dupe(u8, pattern));
        }
    }

    return all_matches.toOwnedSlice(allocator);
}

/// Expands path to absolute path using provided allocator
/// Caller owns returned memory (if using arena, it's auto-freed)
pub fn expandPathToAbs(
    ctx: *ShellCtx,
    allocator: Allocator,
    path: []const u8,
) ![]const u8 {
    const path_type = types.PathType.getPathType(path);

    switch (path_type) {
        .absolute => {
            return try allocator.dupe(u8, path);
        },
        .home => {
            const home = try ctx.getHomeDirCache();

            // Just "~" → return home
            if (path.len == 1) {
                return try allocator.dupe(u8, home);
            }

            // "~/..." → join home with rest of path (skip "~/")
            const rest = if (path[1] == '/' or path[1] == '\\')
                path[2..]
            else
                path[1..];

            return try std.fs.path.join(allocator, &.{ home, rest });
        },
        .relative => {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = std.os.linux.getcwd(&buf, buf.len);

            // Handle "./" and "../" properly
            const path_len = cwd; // this is actually the raw syscall return
            const cwd_str = buf[0 .. path_len - 1]; // trim null terminator
            const rest = if (path.len >= 2 and path[0] == '.' and
                (path[1] == '/' or path[1] == '\\'))
                path[2..]
            else
                path;
            return try std.fs.path.join(allocator, &.{ cwd_str, rest });
        },
        else => {
            return error.InvalidPathType;
        },
    }
}

fn appendExpandedExitCode(ctx: *ShellCtx, result: *std.ArrayList(u8), allocator: Allocator) !void {
    var buf: [24]u8 = undefined;
    const exit_str = std.fmt.bufPrint(&buf, "{d}", .{ctx.last_exit_code}) catch unreachable;
    try result.appendSlice(allocator, exit_str);
}

fn appendExpandedVar(
    ctx: *ShellCtx,
    result: *std.ArrayList(u8),
    allocator: Allocator,
    input: []const u8,
    start: usize,
) !usize {
    const var_end = findVarEnd(input, start);
    const var_name = input[start..var_end];
    if (ctx.env_map.get(var_name)) |value| {
        try appendValueAsText(result, allocator, value);
    }
    return var_end;
}

fn appendValueAsText(
    result: *std.ArrayList(u8),
    allocator: Allocator,
    value: Value,
) !void {
    switch (value) {
        .text => |text| try result.appendSlice(allocator, text),
        else => {
            const value_text = try value.toString(allocator);
            defer allocator.free(value_text);
            try result.appendSlice(allocator, value_text);
        },
    }
}

fn findSubshellEnd(input: []const u8, start: usize) ?usize {
    var j = start;
    var depth: usize = 1;
    while (j < input.len) : (j += 1) {
        if (input[j] == '(') depth += 1;
        if (input[j] == ')') depth -= 1;
        if (depth == 0) return j;
    }
    return null;
}

fn appendExpandedSubshell(
    ctx: *ShellCtx,
    result: *std.ArrayList(u8),
    allocator: Allocator,
    input: []const u8,
    start: usize,
) anyerror!usize {
    const end = findSubshellEnd(input, start) orelse {
        try result.appendSlice(allocator, "$(");
        return start;
    };

    const raw_inner = input[start..end];
    const inner_trimmed = std.mem.trim(u8, raw_inner, " \t");
    // Recursively expand nested substitutions/vars before executing the subshell command.
    const expanded_inner = try expandVariables(ctx, allocator, inner_trimmed);
    const captured_value = execute.captureSubshellForExpansion(ctx, allocator, expanded_inner) catch
        types.Value{ .text = try allocator.dupe(u8, "") };
    defer captured_value.deinit(allocator);

    const substitution = captured_value.toString(allocator) catch return error.AllocFailed;
    defer allocator.free(substitution);
    try result.appendSlice(allocator, substitution);
    return end + 1;
}

/// Expands ~, $ and $(..) text tokens
pub fn expandVariables(ctx: *ShellCtx, arena_alloc: Allocator, input: []const u8) anyerror![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(arena_alloc, input.len + (input.len / 2));

    var i: usize = 0;
    while (i < input.len) {
        // Handle tilde expansion
        if (input[i] == '~' and shouldExpandTilde(input, i)) {
            const home = try ctx.getHomeDirCache();
            try result.appendSlice(arena_alloc, home);
            i += 1;
            continue;
        }

        // Handle $ expansion.
        // Unknown forms must still advance the cursor as a literal '$' to avoid infinite loops.
        if (input[i] == '$') {
            if (i + 1 >= input.len) {
                try result.append(arena_alloc, '$');
                i += 1;
                continue;
            }

            if (input[i + 1] == '?') {
                try appendExpandedExitCode(ctx, &result, arena_alloc);
                i += 2;
                continue;
            }

            if (input[i + 1] == '(') {
                i = try appendExpandedSubshell(ctx, &result, arena_alloc, input, i + 2);
                continue;
            }

            // Brace form: ${VAR} and best-effort ${VAR[index]} compatibility.
            if (input[i + 1] == '{') {
                if (std.mem.indexOfScalarPos(u8, input, i + 2, '}')) |close_idx| {
                    const raw = input[i + 2 .. close_idx];
                    const name = if (std.mem.indexOfScalar(u8, raw, '[')) |arr_idx| raw[0..arr_idx] else raw;
                    if (name.len > 0) {
                        if (ctx.env_map.get(name)) |value| {
                            try appendValueAsText(&result, arena_alloc, value);
                        }
                    }
                    i = close_idx + 1;
                    continue;
                }
            }

            if (isValidVarChar(input[i + 1])) {
                i = try appendExpandedVar(ctx, &result, arena_alloc, input, i + 1);
                continue;
            }

            // Literal fallback for unsupported '$' forms (eg "${...}" missing '}', "$-").
            try result.append(arena_alloc, '$');
            i += 1;
            continue;
        }

        const start = i;
        while (i < input.len and input[i] != '$' and input[i] != '~') {
            i += 1;
        }
        if (i > start) {
            try result.appendSlice(arena_alloc, input[start..i]);
        }
    }

    return result.items;
}

/// Determines if a string is a path with home ~ tilde
inline fn shouldExpandTilde(input: []const u8, pos: usize) bool {
    const at_word_start = pos == 0 or std.ascii.isWhitespace(input[pos - 1]);
    if (!at_word_start) return false;

    return pos + 1 >= input.len or
        input[pos + 1] == '/' or
        std.ascii.isWhitespace(input[pos + 1]);
}

/// -- Helper functions for lexing methods
/// Check if character is valid in a variable name (a-z, A-Z, 0-9, _)
inline fn isValidVarChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Get length of an inline string variable
inline fn findVarEnd(input: []const u8, start: usize) usize {
    var end = start;
    while (end < input.len and isValidVarChar(input[end])) : (end += 1) {}
    return end;
}

//
// ----- TESTS ----- //
//

test "helpers functions" {
    // isPath
    try std.testing.expect(isPath("~/some/path"));
    try std.testing.expect(isPath("/some/path"));
    try std.testing.expect(isPath("./some/path"));
    try std.testing.expect(!isPath("some/path"));
    try std.testing.expect(!isPath(""));

    // isAssignment
    try std.testing.expect(isAssignment("a=b"));
    try std.testing.expect(isAssignment("a="));
    try std.testing.expect(!isAssignment("=b"));
    try std.testing.expect(!isAssignment("a"));
    try std.testing.expect(!isAssignment(""));
}

test "buildTimingProfile computes resource deltas" {
    var start = std.mem.zeroes(std.posix.rusage);
    start.utime = .{ .sec = 1, .usec = 250_000 };
    start.stime = .{ .sec = 0, .usec = 500_000 };
    start.minflt = 10;
    start.majflt = 1;
    start.inblock = 2;
    start.oublock = 3;
    start.nvcsw = 4;
    start.nivcsw = 5;

    var end = start;
    end.utime = .{ .sec = 1, .usec = 750_000 };
    end.stime = .{ .sec = 1, .usec = 0 };
    end.maxrss = 2048;
    end.minflt = 17;
    end.majflt = 2;
    end.inblock = 4;
    end.oublock = 8;
    end.nvcsw = 9;
    end.nivcsw = 11;

    const profile = buildTimingProfile(start, end, 42_000_000, 0);
    try std.testing.expectEqual(@as(i96, 42_000_000), profile.real_ns);
    try std.testing.expectEqual(@as(i128, 500_000_000), profile.user_ns);
    try std.testing.expectEqual(@as(i128, 500_000_000), profile.system_ns);
    try std.testing.expectEqual(@as(u8, 0), profile.exit_code);
}

test "expandVariables handles brace form and literal dollar fallbacks" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("env.zig").EnvMap.init(allocator);
    defer env_map.deinit();
    try env_map.putShell("FOO", .{ .text = "bar" });

    var ctx = try @import("context.zig").ShellCtx.initEngine(&io, allocator, env_map);
    defer ctx.deinit();

    const brace_hit = try expandVariables(&ctx, arena_alloc, "${FOO}");
    try std.testing.expectEqualStrings("bar", brace_hit);

    const brace_miss = try expandVariables(&ctx, arena_alloc, "${MISSING}");
    try std.testing.expectEqualStrings("", brace_miss);

    const literal_dollar = try expandVariables(&ctx, arena_alloc, "$-");
    try std.testing.expectEqualStrings("$-", literal_dollar);

    const trailing_dollar = try expandVariables(&ctx, arena_alloc, "value$");
    try std.testing.expectEqualStrings("value$", trailing_dollar);
}
