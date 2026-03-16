/// Contains all code required for the line autocomplete feature
const std = @import("std");
const Allocator = std.mem.Allocator;
const PathType = @import("../../lib-core/core/types.zig").PathType;
const Value = @import("../../lib-core/core/types.zig").Value;
const ShellCtx = @import("../../lib-core/core/context.zig").ShellCtx;
const prompt_mod = @import("prompt.zig");
const builtins_list = @import("../../lib-core/core/builtins.zig").builtins;
const builtins_metadata = @import("../../lib-core/core/builtins.zig").builtins_metadata;
const INIT_CAPACITY = 8; // default ArrayList capacity for completions

const CompletionKind = enum { builtin, alias, exe, arg, file, dir };

pub const Completion = struct {
    text: []const u8,
    display: ?[]const u8,
    kind: CompletionKind,
};

pub const CompletionResult = struct {
    completions: []const Completion,
    common_prefix: []const u8,
};

const CompletionQuery = struct {
    word_start: usize,
    prefix: []const u8,
    is_first_word: bool,
    command_name: ?[]const u8,
};

fn parseCompletionQuery(input: []const u8, cursor_pos: usize) CompletionQuery {
    const word_start = findWordStart(input, cursor_pos);
    const prefix = input[word_start..cursor_pos];
    const is_first_word = isFirstWord(input, word_start);
    return .{
        .word_start = word_start,
        .prefix = prefix,
        .is_first_word = is_first_word,
        .command_name = if (!is_first_word) currentCommand(input, word_start) else null,
    };
}

fn isCmdSeparator(c: u8) bool {
    return c == '|' or c == ';' or c == '&';
}

fn findSegmentStart(input: []const u8, pos: usize) usize {
    var i = pos;
    while (i > 0) : (i -= 1) {
        if (isCmdSeparator(input[i - 1])) return i;
    }
    return 0;
}

fn currentCommand(input: []const u8, word_start: usize) ?[]const u8 {
    const segment_start = findSegmentStart(input, word_start);
    const segment = std.mem.trimStart(u8, input[segment_start..word_start], " \t\r\n");
    if (segment.len == 0) return null;

    for (segment, 0..) |c, idx| {
        if (std.ascii.isWhitespace(c)) return segment[0..idx];
    }
    return segment;
}

fn findBuiltinMeta(name: []const u8) ?@TypeOf(builtins_metadata[0]) {
    for (builtins_metadata) |meta| {
        if (std.mem.eql(u8, meta.name, name)) return meta;
    }
    return null;
}

fn containsCompletion(completions: []const Completion, text: []const u8) bool {
    for (completions) |comp| {
        if (std.mem.eql(u8, comp.text, text)) return true;
    }
    return false;
}

fn shouldSuggestLiteral(token: []const u8) bool {
    if (token.len == 0) return false;
    if (token[0] == '<' or token[0] == '[' or token[0] == '.') return false;
    if (std.mem.indexOfAny(u8, token, "<>[]()")) |_| return false;
    if (std.mem.indexOfScalar(u8, token, '=')) |_| return false;
    return true;
}

fn appendBuiltinHint(
    arena: Allocator,
    matches: *std.ArrayList(Completion),
    token: []const u8,
    prefix: []const u8,
) !void {
    if (!std.mem.startsWith(u8, token, prefix)) return;
    if (containsCompletion(matches.items, token)) return;
    try matches.append(arena, .{
        .text = token,
        .display = null,
        .kind = .arg,
    });
}

fn collectPipeAlternatives(
    arena: Allocator,
    matches: *std.ArrayList(Completion),
    text: []const u8,
    prefix: []const u8,
    include_flags: bool,
    include_literals: bool,
) !void {
    if (std.mem.indexOfScalar(u8, text, '|') == null) return;
    var alt_iter = std.mem.splitScalar(u8, text, '|');
    while (alt_iter.next()) |raw_alt| {
        const alt = std.mem.trim(u8, raw_alt, " \t\r\n");
        if (alt.len == 0) continue;
        if (include_flags and alt[0] == '-') {
            try appendBuiltinHint(arena, matches, alt, prefix);
        } else if (include_literals and shouldSuggestLiteral(alt)) {
            try appendBuiltinHint(arena, matches, alt, prefix);
        }
    }
}

fn collectBuiltinHintsFromDescriptor(
    arena: Allocator,
    matches: *std.ArrayList(Completion),
    descriptor: []const u8,
    prefix: []const u8,
) !void {
    const colon_idx = std.mem.indexOfScalar(u8, descriptor, ':');
    const head = if (colon_idx) |idx| descriptor[0..idx] else descriptor;
    const tail = if (colon_idx) |idx| descriptor[idx + 1 ..] else "";

    var head_tokens = std.mem.tokenizeAny(u8, head, " \t\r\n");
    while (head_tokens.next()) |tok| {
        if (tok.len == 0) continue;
        if (tok[0] == '-') {
            try collectPipeAlternatives(arena, matches, tok, prefix, true, false);
            if (std.mem.indexOfScalar(u8, tok, '|') == null) {
                try appendBuiltinHint(arena, matches, tok, prefix);
            }
        }
    }

    try collectPipeAlternatives(arena, matches, head, prefix, true, true);
    try collectPipeAlternatives(arena, matches, tail, prefix, true, true);
}

fn completeBuiltinArgumentHints(
    arena: Allocator,
    command_name: []const u8,
    prefix: []const u8,
) ![]Completion {
    const meta = findBuiltinMeta(command_name) orelse {
        var empty = try std.ArrayList(Completion).initCapacity(arena, 0);
        return empty.items;
    };

    var matches = try std.ArrayList(Completion).initCapacity(arena, INIT_CAPACITY);
    for (meta.required_args) |desc| {
        try collectBuiltinHintsFromDescriptor(arena, &matches, desc, prefix);
    }
    for (meta.optional_args) |desc| {
        try collectBuiltinHintsFromDescriptor(arena, &matches, desc, prefix);
    }
    return matches.items;
}

pub fn completeBuiltin(arena: Allocator, prefix: []const u8) ![]Completion {
    var matches = try std.ArrayList(Completion).initCapacity(arena, builtins_list.len / 2);

    for (builtins_list) |b| {
        if (std.mem.startsWith(u8, b, prefix)) {
            try matches.append(arena, .{
                .text = b,
                .display = null,
                .kind = .builtin,
            });
        }
    }
    return matches.items;
}

fn completeAlias(ctx: *ShellCtx, arena: Allocator, prefix: []const u8) ![]Completion {
    const alias_map = ctx.aliases orelse {
        var empty = try std.ArrayList(Completion).initCapacity(arena, 0);
        return empty.items;
    };

    var matches = try std.ArrayList(Completion).initCapacity(arena, INIT_CAPACITY);
    var iter = alias_map.iterator();
    while (iter.next()) |entry| {
        const alias_name = entry.key_ptr.*;
        if (!std.mem.startsWith(u8, alias_name, prefix)) continue;
        try matches.append(arena, .{
            .text = alias_name,
            .display = null,
            .kind = .alias,
        });
    }
    return matches.items;
}

fn completeExe(ctx: *ShellCtx, arena: Allocator, prefix: []const u8) ![]Completion {
    const io = ctx.io.*;

    var matches = try std.ArrayList(Completion).initCapacity(arena, INIT_CAPACITY);

    // Query env_map directly - no std.posix.getenv needed since env_map
    // was seeded from environ at startup and tracks any shell PATH changes
    const path_val = ctx.env_map.get("PATH") orelse return error.PathNotFound;
    const path_env = path_val.text;

    const sep: u8 = ':';

    var path_iter = std.mem.splitScalar(u8, path_env, sep);
    while (path_iter.next()) |raw_dir_path| {
        const dir_path = std.mem.trim(u8, raw_dir_path, " \t\r\n");

        // PATH can legally contain relative entries and empty segments (cwd).
        // Never call openDirAbsolute on non-absolute entries.
        const maybe_dir = blk: {
            if (dir_path.len == 0) {
                break :blk std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true }) catch null;
            }
            if (std.fs.path.isAbsolute(dir_path)) {
                break :blk std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch null;
            }
            if (dir_path[0] == '~') {
                const home = try ctx.getHomeDirCache();
                const expanded = if (dir_path.len > 1 and (dir_path[1] == '/' or dir_path[1] == '\\'))
                    try std.fs.path.join(arena, &.{ home, dir_path[2..] })
                else
                    home;
                break :blk std.Io.Dir.openDirAbsolute(io, expanded, .{ .iterate = true }) catch null;
            }
            break :blk std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch null;
        };
        if (maybe_dir == null) continue;
        var dir = maybe_dir.?;
        defer dir.close(io);

        var iter = dir.iterate();
        while (iter.next(io) catch continue) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, prefix)) continue;

            const exe_name = try arena.dupe(u8, entry.name);

            try matches.append(arena, .{
                .text = exe_name,
                .display = null,
                .kind = .exe,
            });
        }
    }

    return matches.items;
}

/// Searches a directory for files and folders matching the given prefix.
pub fn completePath(
    ctx: *ShellCtx,
    arena: Allocator,
    search_dir_path: []const u8,
    display_dir_path: []const u8,
    prefix: ?[]const u8,
) ![]Completion {
    const io = ctx.io.*;
    const path_type = PathType.getPathType(search_dir_path);

    var search_dir: std.Io.Dir = switch (path_type) {
        .relative => try std.Io.Dir.cwd().openDir(io, search_dir_path, .{ .iterate = true }),
        .absolute => try std.Io.Dir.openDirAbsolute(io, search_dir_path, .{ .iterate = true }),
        .home => blk: {
            const home = try ctx.getHomeDirCache();
            const path = if (search_dir_path.len > 1 and (search_dir_path[1] == '/' or search_dir_path[1] == '\\'))
                try std.fs.path.join(arena, &.{ home, search_dir_path[2..] })
            else
                home;
            break :blk try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
        },
        .invalid => return error.InvalidPath,
    };
    defer search_dir.close(io);

    var matches = try std.ArrayList(Completion).initCapacity(arena, INIT_CAPACITY);

    var iter = search_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (prefix) |pre| {
            if (!std.mem.startsWith(u8, entry.name, pre)) continue;
        }

        const kind: CompletionKind = switch (entry.kind) {
            .directory => .dir,
            .file => .file,
            else => .arg,
        };

        const joined_display_path = if (display_dir_path.len == 0)
            try arena.dupe(u8, entry.name)
        else
            try std.fs.path.join(arena, &.{ display_dir_path, entry.name });
        const completion_text = if (kind == .dir)
            try std.fmt.allocPrint(arena, "{s}/", .{joined_display_path})
        else
            joined_display_path;

        // with prefix: text=full path, display=null
        // without prefix: text=name only, display=full path (original behaviour)
        const completion: Completion = if (prefix != null) .{
            .text = completion_text,
            .display = null,
            .kind = kind,
        } else .{
            .text = if (kind == .dir)
                try std.fmt.allocPrint(arena, "{s}/", .{entry.name})
            else
                try arena.dupe(u8, entry.name),
            .display = joined_display_path,
            .kind = kind,
        };

        try matches.append(arena, completion);
    }

    return matches.items;
}

fn completeEnvVars(ctx: *ShellCtx, arena: Allocator, prefix: []const u8, include_dollar: bool) ![]Completion {
    var matches = try std.ArrayList(Completion).initCapacity(arena, INIT_CAPACITY);
    var iter = ctx.env_map.vars.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        const text = if (include_dollar)
            try std.fmt.allocPrint(arena, "${s}", .{name})
        else
            name;
        try matches.append(arena, .{
            .text = text,
            .display = null,
            .kind = .arg,
        });
    }
    return matches.items;
}

fn isGitBranchCompletionContext(input: []const u8, cursor_pos: usize, prefix: []const u8) bool {
    const segment_start = findSegmentStart(input, cursor_pos);
    const segment = std.mem.trimStart(u8, input[segment_start..cursor_pos], " \t\r\n");
    if (segment.len == 0) return false;

    var tokens: [4][]const u8 = undefined;
    var count: usize = 0;
    var iter = std.mem.tokenizeAny(u8, segment, " \t\r\n");
    while (iter.next()) |tok| {
        if (count == tokens.len) break;
        tokens[count] = tok;
        count += 1;
    }

    if (count < 2) return false;
    if (!std.mem.eql(u8, tokens[0], "git")) return false;
    if (std.mem.eql(u8, tokens[1], "push")) {
        const trailing_space = cursor_pos > 0 and std.ascii.isWhitespace(input[cursor_pos - 1]);
        if (prefix.len == 0) return trailing_space and count == 3;
        return count == 4 and std.mem.eql(u8, tokens[3], prefix);
    }
    if (!std.mem.eql(u8, tokens[1], "checkout") and !std.mem.eql(u8, tokens[1], "merge")) return false;

    const trailing_space = cursor_pos > 0 and std.ascii.isWhitespace(input[cursor_pos - 1]);
    if (prefix.len == 0) return trailing_space and count == 2;
    return count == 3 and std.mem.eql(u8, tokens[2], prefix);
}

fn joinAbsolutePath(arena: Allocator, base: []const u8, child: []const u8) ![]const u8 {
    if (std.mem.eql(u8, base, "/")) return std.fmt.allocPrint(arena, "/{s}", .{child});
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ base, child });
}

fn completeGitRefsHeads(ctx: *ShellCtx, arena: Allocator, prefix: []const u8) ![]Completion {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_n = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_end = std.mem.indexOfScalar(u8, &cwd_buf, 0) orelse cwd_n;
    const cwd = cwd_buf[0..cwd_end];

    const git_dir = try prompt_mod.resolveGitDirForCwd(ctx, arena, cwd);
    if (git_dir == null) {
        var empty = try std.ArrayList(Completion).initCapacity(arena, 0);
        return empty.items;
    }
    defer arena.free(git_dir.?);

    const refs_root = try joinAbsolutePath(arena, git_dir.?, "refs/heads");
    defer arena.free(refs_root);

    const slash_idx = std.mem.findLast(u8, prefix, "/");
    const branch_dir = if (slash_idx) |idx| prefix[0..idx] else "";
    const entry_prefix = if (slash_idx) |idx| prefix[idx + 1 ..] else prefix;

    const search_dir_path = if (branch_dir.len > 0)
        try joinAbsolutePath(arena, refs_root, branch_dir)
    else
        try arena.dupe(u8, refs_root);
    defer arena.free(search_dir_path);

    var search_dir = std.Io.Dir.openDirAbsolute(ctx.io.*, search_dir_path, .{ .iterate = true }) catch {
        var empty = try std.ArrayList(Completion).initCapacity(arena, 0);
        return empty.items;
    };
    defer search_dir.close(ctx.io.*);

    var matches = try std.ArrayList(Completion).initCapacity(arena, INIT_CAPACITY);
    var iter = search_dir.iterate();
    while (try iter.next(ctx.io.*)) |entry| {
        if (entry.kind != .file and entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, entry_prefix)) continue;

        const suffix = if (entry.kind == .directory) "/" else "";
        const text = if (branch_dir.len > 0)
            try std.fmt.allocPrint(arena, "{s}/{s}{s}", .{ branch_dir, entry.name, suffix })
        else
            try std.fmt.allocPrint(arena, "{s}{s}", .{ entry.name, suffix });

        try matches.append(arena, .{
            .text = text,
            .display = null,
            .kind = if (entry.kind == .directory) .dir else .arg,
        });
    }

    return matches.items;
}

fn filterDirectories(arena: Allocator, completions: []const Completion) ![]Completion {
    var dirs = try std.ArrayList(Completion).initCapacity(arena, completions.len);
    for (completions) |comp| {
        if (comp.kind == .dir) {
            try dirs.append(arena, comp);
        }
    }
    return dirs.items;
}

/// Append completions to output, optionally filtering to directories only.
fn appendCompletions(
    arena: Allocator,
    out: *std.ArrayList(Completion),
    completions: []const Completion,
    only_dirs: bool,
) !void {
    if (completions.len == 0) return;
    if (only_dirs) {
        const dir_completions = try filterDirectories(arena, completions);
        if (dir_completions.len > 0) {
            try out.appendSlice(arena, dir_completions);
        }
        return;
    }
    try out.appendSlice(arena, completions);
}

/// Resolve path-style completion prefix (`./a`, `dir/fi`, `/tmp/x`, `~/p`) and append matches.
fn appendPathCompletions(
    ctx: *ShellCtx,
    arena: Allocator,
    out: *std.ArrayList(Completion),
    path_prefix: []const u8,
    only_dirs: bool,
) !void {
    if (path_prefix.len == 0) return;

    if (std.mem.findLast(u8, path_prefix, "/")) |dir_idx| {
        const split = dir_idx + 1;
        const raw_dir = path_prefix[0..split];
        const remainder = path_prefix[split..];
        const search_dir = if (path_prefix[0] == '.' or path_prefix[0] == '/' or path_prefix[0] == '~')
            raw_dir
        else
            try std.fmt.allocPrint(arena, "./{s}", .{raw_dir});

        if (path_prefix.len > dir_idx + 1) {
            const path_completions = try completePath(ctx, arena, search_dir, raw_dir, remainder);
            try appendCompletions(arena, out, path_completions, only_dirs);
        } else {
            const path_completions = try completePath(ctx, arena, search_dir, raw_dir, "");
            try appendCompletions(arena, out, path_completions, only_dirs);
        }
    } else if (path_prefix.len > 0 and path_prefix[0] == '.') {
        // Relative dot-prefix with no slash, e.g. `.z`.
        const path_completions = try completePath(ctx, arena, "./", "./", path_prefix);
        try appendCompletions(arena, out, path_completions, only_dirs);
    }
}

// get all potential args completions from cwd, when no path provided
pub fn completeAllCwd(ctx: *ShellCtx, arena: Allocator) ![]Completion {
    const io = ctx.io.*;

    var cwd = std.Io.Dir.cwd();
    // cwd() returns the Dir directly, no open/close needed

    var matches = try std.ArrayList(Completion).initCapacity(arena, INIT_CAPACITY);

    var iter = cwd.iterate();
    while (try iter.next(io)) |entry| {
        const complete_path = try std.fs.path.join(arena, &.{ "./", entry.name });
        const text = switch (entry.kind) {
            .directory => try std.fmt.allocPrint(arena, "./{s}/", .{entry.name}),
            else => complete_path,
        };

        try matches.append(arena, .{
            .text = text,
            .display = null,
            .kind = switch (entry.kind) {
                .directory => .dir,
                .file => .file,
                else => .arg,
            },
        });
    }

    return matches.items;
}

// TODO: for commands expecting args, probably needs more thorough type system first
//pub fn completeArg(allocator: Allocator, prefix: []const u8) ![]Completion {}
//
pub fn getCompletions(ctx: *ShellCtx, arena: Allocator, input: []const u8, cursor_pos: usize) !CompletionResult {
    // parse input and determine context for TAB completion
    const query = parseCompletionQuery(input, cursor_pos);
    const prefix = query.prefix;
    const is_first_word = query.is_first_word;
    const command_name = query.command_name;

    var all_matches = try std.ArrayList(Completion).initCapacity(arena, INIT_CAPACITY);

    if (isGitBranchCompletionContext(input, cursor_pos, prefix)) {
        const git_matches = try completeGitRefsHeads(ctx, arena, prefix);
        try appendCompletions(arena, &all_matches, git_matches, false);
        return CompletionResult{
            .completions = all_matches.items,
            .common_prefix = try findCommonPrefix(arena, all_matches.items),
        };
    }

    if (prefix.len == 0) {
        if (command_name) |cmd| {
            const builtin_hints = try completeBuiltinArgumentHints(arena, cmd, "");
            if (builtin_hints.len > 0) {
                try appendCompletions(arena, &all_matches, builtin_hints, false);
                const common_hints = try findCommonPrefix(arena, all_matches.items);
                return CompletionResult{
                    .completions = all_matches.items,
                    .common_prefix = common_hints,
                };
            }
        }
        return CompletionResult{
            .completions = all_matches.items,
            .common_prefix = "",
        };
    }

    if (is_first_word) {
        // first see if a direct path is being provided
        if (prefix.len > 0 and (prefix[0] == '.' or prefix[0] == '/' or prefix[0] == '~' or std.mem.indexOfScalar(u8, prefix, '/') != null)) {
            try appendPathCompletions(ctx, arena, &all_matches, prefix, false);
        } else {
            // try builtins first
            const builtin_completions = try completeBuiltin(arena, prefix);
            const alias_completions = try completeAlias(ctx, arena, prefix);

            if (builtin_completions.len > 0 or alias_completions.len > 0) {
                try appendCompletions(arena, &all_matches, builtin_completions, false);
                try appendCompletions(arena, &all_matches, alias_completions, false);
            } else {
                // try exe commands next
                const exe_completions = try completeExe(ctx, arena, prefix);
                try appendCompletions(arena, &all_matches, exe_completions, false);
            }
        }
    } else {
        // If not a command, try complete the arg based on file path
        const current_arg_prefix = prefix;
        const only_dirs = command_name != null and std.mem.eql(u8, command_name.?, "cd");

        if (command_name) |cmd| {
            const builtin_hints = try completeBuiltinArgumentHints(arena, cmd, current_arg_prefix);
            if (builtin_hints.len > 0) {
                try appendCompletions(arena, &all_matches, builtin_hints, false);
                const common_hints = try findCommonPrefix(arena, all_matches.items);
                return CompletionResult{
                    .completions = all_matches.items,
                    .common_prefix = common_hints,
                };
            }
        }

        // user has provided some input for completion
        if (current_arg_prefix.len > 0) {
            switch (current_arg_prefix[0]) {
                '$' => {
                    const var_completions = try completeEnvVars(ctx, arena, current_arg_prefix[1..], true);
                    try appendCompletions(arena, &all_matches, var_completions, false);
                },
                '.', '/', '~' => {
                    try appendPathCompletions(ctx, arena, &all_matches, current_arg_prefix, only_dirs);
                },
                else => {
                    if (command_name) |cmd| {
                        if ((std.mem.eql(u8, cmd, "export") or std.mem.eql(u8, cmd, "unset")) and std.mem.indexOfScalar(u8, current_arg_prefix, '=') == null) {
                            const var_completions = try completeEnvVars(ctx, arena, current_arg_prefix, false);
                            try appendCompletions(arena, &all_matches, var_completions, false);
                        }
                    }

                    if (std.mem.indexOfScalar(u8, current_arg_prefix, '/') != null) {
                        try appendPathCompletions(ctx, arena, &all_matches, current_arg_prefix, only_dirs);
                    } else {
                        const path_completions = try completePath(ctx, arena, "./", "", current_arg_prefix);
                        try appendCompletions(arena, &all_matches, path_completions, only_dirs);
                    }
                },
            }
        } else {
            // no current arg provided, search cwd for all options
            const path_completions = try completeAllCwd(ctx, arena);
            try appendCompletions(arena, &all_matches, path_completions, only_dirs);
        }
    }
    const common = try findCommonPrefix(arena, all_matches.items);

    return CompletionResult{
        .completions = all_matches.items,
        .common_prefix = common,
    };
}

fn normalizeGhostCandidate(prefix: []const u8, candidate: []const u8) []const u8 {
    if (prefix.len == 0) return candidate;
    if ((prefix[0] == '.' or prefix[0] == '/' or prefix[0] == '~')) return candidate;
    if (std.mem.startsWith(u8, candidate, "./")) return candidate[2..];
    return candidate;
}

/// Fast path used by realtime ghost text:
/// - no executable PATH scans for command position
/// - returns only a unique token completion for current word
pub fn getGhostCompletion(
    ctx: *ShellCtx,
    arena: Allocator,
    input: []const u8,
    cursor_pos: usize,
) !?[]const u8 {
    if (cursor_pos != input.len) return null;

    const query = parseCompletionQuery(input, cursor_pos);
    const prefix = query.prefix;
    if (prefix.len == 0) return null;

    const is_first_word = query.is_first_word;
    const command_name = query.command_name;

    var all_matches = try std.ArrayList(Completion).initCapacity(arena, INIT_CAPACITY);

    if (isGitBranchCompletionContext(input, cursor_pos, prefix)) {
        const git_matches = try completeGitRefsHeads(ctx, arena, prefix);
        try appendCompletions(arena, &all_matches, git_matches, false);
    } else if (is_first_word) {
        if (prefix[0] == '.' or prefix[0] == '/' or prefix[0] == '~') {
            try appendPathCompletions(ctx, arena, &all_matches, prefix, false);
        } else {
            const builtin_completions = try completeBuiltin(arena, prefix);
            const alias_completions = try completeAlias(ctx, arena, prefix);
            try appendCompletions(arena, &all_matches, builtin_completions, false);
            try appendCompletions(arena, &all_matches, alias_completions, false);
        }
    } else {
        const only_dirs = command_name != null and std.mem.eql(u8, command_name.?, "cd");

        if (command_name) |cmd| {
            const builtin_hints = try completeBuiltinArgumentHints(arena, cmd, prefix);
            if (builtin_hints.len > 0) {
                try appendCompletions(arena, &all_matches, builtin_hints, false);
            }
        }

        switch (prefix[0]) {
            '$' => {
                const var_completions = try completeEnvVars(ctx, arena, prefix[1..], true);
                try appendCompletions(arena, &all_matches, var_completions, false);
            },
            '.', '/', '~' => {
                try appendPathCompletions(ctx, arena, &all_matches, prefix, only_dirs);
            },
            else => {
                if (command_name) |cmd| {
                    if ((std.mem.eql(u8, cmd, "export") or std.mem.eql(u8, cmd, "unset")) and std.mem.indexOfScalar(u8, prefix, '=') == null) {
                        const var_completions = try completeEnvVars(ctx, arena, prefix, false);
                        try appendCompletions(arena, &all_matches, var_completions, false);
                    }
                }
                if (std.mem.indexOfScalar(u8, prefix, '/') != null) {
                    try appendPathCompletions(ctx, arena, &all_matches, prefix, only_dirs);
                } else {
                    const path_completions = try completePath(ctx, arena, "./", "", prefix);
                    try appendCompletions(arena, &all_matches, path_completions, only_dirs);
                }
            },
        }
    }

    var unique: ?[]const u8 = null;
    for (all_matches.items) |comp| {
        const normalized = normalizeGhostCandidate(prefix, comp.text);
        if (!std.mem.startsWith(u8, normalized, prefix)) continue;
        if (normalized.len <= prefix.len) continue;

        if (unique == null) {
            unique = normalized;
            continue;
        }
        if (!std.mem.eql(u8, unique.?, normalized)) return null;
    }

    return unique;
}

// Helpers
pub fn findWordStart(input: []const u8, cursor_pos: usize) usize {
    var pos = cursor_pos;
    while (pos > 0 and !std.ascii.isWhitespace(input[pos - 1]) and !isCmdSeparator(input[pos - 1])) {
        pos -= 1;
    }
    return pos;
}

fn isFirstWord(input: []const u8, word_start: usize) bool {
    const segment_start = findSegmentStart(input, word_start);
    for (input[segment_start..word_start]) |char| {
        if (!std.ascii.isWhitespace(char)) return false;
    }
    return true;
}

fn findCommonPrefix(arena: Allocator, completions: []const Completion) ![]const u8 {
    if (completions.len == 0) return try arena.dupe(u8, "");
    if (completions.len == 1) return try arena.dupe(u8, completions[0].text);

    var prefix_len: usize = 0;
    const first = completions[0].text;

    outer: while (prefix_len < first.len) {
        const char = first[prefix_len];
        for (completions[1..]) |comp| {
            if (prefix_len >= comp.text.len or comp.text[prefix_len] != char) {
                break :outer;
            }
        }
        prefix_len += 1;
    }
    return try arena.dupe(u8, first[0..prefix_len]);
}

fn initInteractiveTestCtx(
    allocator: Allocator,
    threaded: *std.Io.Threaded,
    io: *std.Io,
    env_map: **@import("../../lib-core/core/env.zig").EnvMap,
    shell_ctx: *@import("../../lib-core/core/context.zig").ShellCtx,
) !void {
    threaded.* = .init(allocator, .{});
    io.* = threaded.io();
    env_map.* = try @import("../../lib-core/core/env.zig").EnvMap.init(allocator);
    shell_ctx.* = try @import("../../lib-core/core/context.zig").ShellCtx.initEngine(io, allocator, env_map.*);
    shell_ctx.exe_mode = .interactive;
}

fn deinitInteractiveTestCtx(
    threaded: *std.Io.Threaded,
    env_map: *@import("../../lib-core/core/env.zig").EnvMap,
    shell_ctx: *@import("../../lib-core/core/context.zig").ShellCtx,
) void {
    shell_ctx.deinit();
    env_map.deinit();
    threaded.deinit();
}

test "findWordStart treats separators as boundaries" {
    const input = "echo hi|gre";
    const start = findWordStart(input, input.len);
    try std.testing.expectEqual(@as(usize, 8), start);
    try std.testing.expect(std.mem.eql(u8, input[start..], "gre"));
}

test "isFirstWord detects command position after separators" {
    const input = "echo hi &&  gr";
    const word_start: usize = 12;
    try std.testing.expect(isFirstWord(input, word_start));
}

test "currentCommand resolves active command in pipeline segment" {
    const input = "echo hi | cd ./wo";
    const word_start = findWordStart(input, input.len);
    const cmd = currentCommand(input, word_start) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.eql(u8, cmd, "cd"));
}

test "appendPathCompletions resolves dot-prefix without slash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var threaded: std.Io.Threaded = undefined;
    var io: std.Io = undefined;
    var env_map: *@import("../../lib-core/core/env.zig").EnvMap = undefined;
    var shell_ctx: @import("../../lib-core/core/context.zig").ShellCtx = undefined;
    try initInteractiveTestCtx(allocator, &threaded, &io, &env_map, &shell_ctx);
    defer deinitInteractiveTestCtx(&threaded, env_map, &shell_ctx);

    var name_buf: [96]u8 = undefined;
    const unique_name = try std.fmt.bufPrint(&name_buf, ".zest-autocomplete-test-{d}", .{std.os.linux.getpid()});
    var file = try std.Io.Dir.cwd().createFile(io, unique_name, .{});
    defer file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, unique_name) catch {};

    const prefix = unique_name[0..@min(4, unique_name.len)];

    var all_matches = try std.ArrayList(Completion).initCapacity(allocator, INIT_CAPACITY);
    try appendPathCompletions(&shell_ctx, allocator, &all_matches, prefix, false);
    try std.testing.expect(all_matches.items.len > 0);
}

test "appendPathCompletions keeps directory prefix when prefix ends with slash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var threaded: std.Io.Threaded = undefined;
    var io: std.Io = undefined;
    var env_map: *@import("../../lib-core/core/env.zig").EnvMap = undefined;
    var shell_ctx: @import("../../lib-core/core/context.zig").ShellCtx = undefined;
    try initInteractiveTestCtx(allocator, &threaded, &io, &env_map, &shell_ctx);
    defer deinitInteractiveTestCtx(&threaded, env_map, &shell_ctx);

    var dir_buf: [128]u8 = undefined;
    var file_buf: [196]u8 = undefined;
    const rel_dir = try std.fmt.bufPrint(&dir_buf, ".zest-dir-root-{d}", .{std.os.linux.getpid()});
    const rel_file = try std.fmt.bufPrint(&file_buf, "{s}/child.txt", .{rel_dir});

    try std.Io.Dir.cwd().createDirPath(io, rel_dir);
    defer std.Io.Dir.cwd().deleteDir(io, rel_dir) catch {};

    var file = try std.Io.Dir.cwd().createFile(io, rel_file, .{});
    defer file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, rel_file) catch {};

    const prefix = try std.fmt.allocPrint(allocator, "{s}/", .{rel_dir});
    var all_matches = try std.ArrayList(Completion).initCapacity(allocator, INIT_CAPACITY);
    try appendPathCompletions(&shell_ctx, allocator, &all_matches, prefix, false);

    var found = false;
    const expected = try std.fmt.allocPrint(allocator, "{s}/child.txt", .{rel_dir});
    for (all_matches.items) |comp| {
        if (std.mem.eql(u8, comp.text, expected)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "appendPathCompletions treats slash without dot as cwd-relative" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var threaded: std.Io.Threaded = undefined;
    var io: std.Io = undefined;
    var env_map: *@import("../../lib-core/core/env.zig").EnvMap = undefined;
    var shell_ctx: @import("../../lib-core/core/context.zig").ShellCtx = undefined;
    try initInteractiveTestCtx(allocator, &threaded, &io, &env_map, &shell_ctx);
    defer deinitInteractiveTestCtx(&threaded, env_map, &shell_ctx);

    try std.Io.Dir.cwd().createDirPath(io, "zest-ac-dir/nested");
    defer std.Io.Dir.cwd().deleteTree(io, "zest-ac-dir") catch {};

    var file = try std.Io.Dir.cwd().createFile(io, "zest-ac-dir/nested/file.txt", .{});
    defer file.close(io);

    var all_matches = try std.ArrayList(Completion).initCapacity(allocator, INIT_CAPACITY);
    try appendPathCompletions(&shell_ctx, allocator, &all_matches, "zest-ac-dir/", false);

    var found = false;
    for (all_matches.items) |comp| {
        if (std.mem.eql(u8, comp.text, "zest-ac-dir/nested/")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "getCompletions returns cwd-relative dir with trailing slash for unique match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var threaded: std.Io.Threaded = undefined;
    var io: std.Io = undefined;
    var env_map: *@import("../../lib-core/core/env.zig").EnvMap = undefined;
    var shell_ctx: @import("../../lib-core/core/context.zig").ShellCtx = undefined;
    try initInteractiveTestCtx(allocator, &threaded, &io, &env_map, &shell_ctx);
    defer deinitInteractiveTestCtx(&threaded, env_map, &shell_ctx);

    try std.Io.Dir.cwd().createDirPath(io, "src");
    defer std.Io.Dir.cwd().deleteDir(io, "src") catch {};

    const result = try getCompletions(&shell_ctx, allocator, "cd sr", "cd sr".len);
    try std.testing.expectEqual(@as(usize, 1), result.completions.len);
    try std.testing.expectEqualStrings("src/", result.completions[0].text);
    try std.testing.expectEqualStrings("src/", result.common_prefix);
}

test "completeBuiltinArgumentHints suggests help flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const hints = try completeBuiltinArgumentHints(allocator, "help", "--");
    try std.testing.expect(hints.len >= 2);

    var has_summary = false;
    var has_all = false;
    for (hints) |hint| {
        if (std.mem.eql(u8, hint.text, "--summary")) has_summary = true;
        if (std.mem.eql(u8, hint.text, "--all")) has_all = true;
    }
    try std.testing.expect(has_summary);
    try std.testing.expect(has_all);
}

test "getCompletions includes alias names for first word" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var threaded: std.Io.Threaded = undefined;
    var io: std.Io = undefined;
    var env_map: *@import("../../lib-core/core/env.zig").EnvMap = undefined;
    var shell_ctx: @import("../../lib-core/core/context.zig").ShellCtx = undefined;
    try initInteractiveTestCtx(allocator, &threaded, &io, &env_map, &shell_ctx);
    defer deinitInteractiveTestCtx(&threaded, env_map, &shell_ctx);

    var aliases = @import("../../lib-core/core/context.zig").ShellCtx.AliasMap.init(allocator);
    defer aliases.deinit();

    try aliases.put(try allocator.dupe(u8, "gp"), try allocator.dupe(u8, "git pull"));
    shell_ctx.aliases = &aliases;

    const result = try getCompletions(&shell_ctx, allocator, "g", 1);

    var found = false;
    for (result.completions) |comp| {
        if (std.mem.eql(u8, comp.text, "gp")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "completeExe supports relative PATH entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var threaded: std.Io.Threaded = undefined;
    var io: std.Io = undefined;
    var env_map: *@import("../../lib-core/core/env.zig").EnvMap = undefined;
    var shell_ctx: @import("../../lib-core/core/context.zig").ShellCtx = undefined;
    try initInteractiveTestCtx(allocator, &threaded, &io, &env_map, &shell_ctx);
    defer deinitInteractiveTestCtx(&threaded, env_map, &shell_ctx);

    var dir_buf: [128]u8 = undefined;
    var file_buf: [196]u8 = undefined;
    const rel_dir = try std.fmt.bufPrint(&dir_buf, ".zest-exe-path-{d}", .{std.os.linux.getpid()});
    const rel_file = try std.fmt.bufPrint(&file_buf, "{s}/zest-rel-cmd", .{rel_dir});

    try std.Io.Dir.cwd().createDirPath(io, rel_dir);
    defer std.Io.Dir.cwd().deleteDir(io, rel_dir) catch {};

    var file = try std.Io.Dir.cwd().createFile(io, rel_file, .{});
    defer file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, rel_file) catch {};

    try env_map.putExported("PATH", Value{ .text = rel_dir });

    const completions = try completeExe(&shell_ctx, allocator, "zest-rel");
    var found = false;
    for (completions) |comp| {
        if (std.mem.eql(u8, comp.text, "zest-rel-cmd")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "getGhostCompletion returns builtin completion and skips exe lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var threaded: std.Io.Threaded = undefined;
    var io: std.Io = undefined;
    var env_map: *@import("../../lib-core/core/env.zig").EnvMap = undefined;
    var shell_ctx: @import("../../lib-core/core/context.zig").ShellCtx = undefined;
    try initInteractiveTestCtx(allocator, &threaded, &io, &env_map, &shell_ctx);
    defer deinitInteractiveTestCtx(&threaded, env_map, &shell_ctx);

    const completion = try getGhostCompletion(&shell_ctx, allocator, "ec", 2);
    try std.testing.expect(completion != null);
    try std.testing.expect(std.mem.eql(u8, completion.?, "echo"));
}

test "getGhostCompletion normalizes ./ path prefix for simple args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var threaded: std.Io.Threaded = undefined;
    var io: std.Io = undefined;
    var env_map: *@import("../../lib-core/core/env.zig").EnvMap = undefined;
    var shell_ctx: @import("../../lib-core/core/context.zig").ShellCtx = undefined;
    try initInteractiveTestCtx(allocator, &threaded, &io, &env_map, &shell_ctx);
    defer deinitInteractiveTestCtx(&threaded, env_map, &shell_ctx);

    var name_buf: [128]u8 = undefined;
    const unique_name = try std.fmt.bufPrint(&name_buf, "zest-ghost-path-test-{d}.txt", .{std.os.linux.getpid()});
    var file = try std.Io.Dir.cwd().createFile(io, unique_name, .{});
    defer file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, unique_name) catch {};

    const input = try std.fmt.allocPrint(allocator, "read {s}", .{unique_name[0..6]});

    const completion = try getGhostCompletion(&shell_ctx, allocator, input, input.len);
    try std.testing.expect(completion != null);
    try std.testing.expect(std.mem.eql(u8, completion.?, unique_name));
}

test "getGhostCompletion returns null for ambiguous path candidates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var threaded: std.Io.Threaded = undefined;
    var io: std.Io = undefined;
    var env_map: *@import("../../lib-core/core/env.zig").EnvMap = undefined;
    var shell_ctx: @import("../../lib-core/core/context.zig").ShellCtx = undefined;
    try initInteractiveTestCtx(allocator, &threaded, &io, &env_map, &shell_ctx);
    defer deinitInteractiveTestCtx(&threaded, env_map, &shell_ctx);

    var base_buf: [128]u8 = undefined;
    var name1_buf: [128]u8 = undefined;
    var name2_buf: [128]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "zest-ghost-ambig-{d}", .{std.os.linux.getpid()});
    const file_a_name = try std.fmt.bufPrint(&name1_buf, "{s}-a.txt", .{base});
    const file_b_name = try std.fmt.bufPrint(&name2_buf, "{s}-b.txt", .{base});

    var file_a = try std.Io.Dir.cwd().createFile(io, file_a_name, .{});
    defer file_a.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, file_a_name) catch {};

    var file_b = try std.Io.Dir.cwd().createFile(io, file_b_name, .{});
    defer file_b.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, file_b_name) catch {};

    const prefix = file_a_name[0 .. file_a_name.len - "-a.txt".len];
    const input = try std.fmt.allocPrint(allocator, "read {s}", .{prefix});
    const completion = try getGhostCompletion(&shell_ctx, allocator, input, input.len);
    try std.testing.expect(completion == null);
}

test "getCompletions suggests git branch directories and nested heads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var threaded: std.Io.Threaded = undefined;
    var io: std.Io = undefined;
    var env_map: *@import("../../lib-core/core/env.zig").EnvMap = undefined;
    var shell_ctx: @import("../../lib-core/core/context.zig").ShellCtx = undefined;
    try initInteractiveTestCtx(allocator, &threaded, &io, &env_map, &shell_ctx);
    defer deinitInteractiveTestCtx(&threaded, env_map, &shell_ctx);

    var old_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const old_cwd_n = std.os.linux.getcwd(&old_cwd_buf, old_cwd_buf.len);
    const old_cwd_end = std.mem.indexOfScalar(u8, &old_cwd_buf, 0) orelse old_cwd_n;
    const old_cwd = try allocator.dupeZ(u8, old_cwd_buf[0..old_cwd_end]);
    defer allocator.free(old_cwd);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(io, "repo/.git/refs/heads/feature");
    var root_head = try tmp_dir.dir.createFile(io, "repo/.git/refs/heads/main", .{});
    defer root_head.close(io);
    var nested_head = try tmp_dir.dir.createFile(io, "repo/.git/refs/heads/feature/demo", .{});
    defer nested_head.close(io);

    const repo_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/repo", .{tmp_dir.sub_path[0..]});
    defer allocator.free(repo_path);
    const repo_path_z = try allocator.dupeZ(u8, repo_path);
    defer allocator.free(repo_path_z);
    _ = std.os.linux.chdir(repo_path_z);
    defer _ = std.os.linux.chdir(old_cwd);

    const root_input = "git checkout fe";
    const root_result = try getCompletions(&shell_ctx, allocator, root_input, root_input.len);
    var found_dir = false;
    for (root_result.completions) |comp| {
        if (std.mem.eql(u8, comp.text, "feature/")) found_dir = true;
    }
    try std.testing.expect(found_dir);

    const nested_input = "git checkout feature/";
    const nested_result = try getCompletions(&shell_ctx, allocator, nested_input, nested_input.len);
    var found_branch = false;
    for (nested_result.completions) |comp| {
        if (std.mem.eql(u8, comp.text, "feature/demo")) found_branch = true;
    }
    try std.testing.expect(found_branch);

    const push_input = "git push origin fe";
    const push_result = try getCompletions(&shell_ctx, allocator, push_input, push_input.len);
    var found_push_dir = false;
    for (push_result.completions) |comp| {
        if (std.mem.eql(u8, comp.text, "feature/")) found_push_dir = true;
    }
    try std.testing.expect(found_push_dir);
}

test "getCompletions returns no git branch completions outside git repos" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var threaded: std.Io.Threaded = undefined;
    var io: std.Io = undefined;
    var env_map: *@import("../../lib-core/core/env.zig").EnvMap = undefined;
    var shell_ctx: @import("../../lib-core/core/context.zig").ShellCtx = undefined;
    try initInteractiveTestCtx(allocator, &threaded, &io, &env_map, &shell_ctx);
    defer deinitInteractiveTestCtx(&threaded, env_map, &shell_ctx);

    var old_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const old_cwd_n = std.os.linux.getcwd(&old_cwd_buf, old_cwd_buf.len);
    const old_cwd_end = std.mem.indexOfScalar(u8, &old_cwd_buf, 0) orelse old_cwd_n;
    const old_cwd = try allocator.dupeZ(u8, old_cwd_buf[0..old_cwd_end]);
    defer allocator.free(old_cwd);
    _ = std.os.linux.chdir("/tmp");
    defer _ = std.os.linux.chdir(old_cwd);

    const input = "git merge ma";
    const result = try getCompletions(&shell_ctx, allocator, input, input.len);
    try std.testing.expectEqual(@as(usize, 0), result.completions.len);
}
