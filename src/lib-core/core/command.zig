const std = @import("std");
const builtins = @import("builtins.zig");
const helpers = @import("helpers.zig");
const types = @import("types.zig");
const Allocator = std.mem.Allocator;
const ShellCtx = @import("context.zig").ShellCtx;
const Token = @import("lexer.zig").Token;

const TypeTag = types.TypeTag;
const Value = types.Value;
const INIT_CAPACITY = 4; // default for command stages

pub const StdConfig = enum { inherit, ignore, pipe };

pub const ExecInput = union(enum) {
    none,
    value: Value,
    stream: std.Io.File,
};

pub const ExecOutput = union(enum) {
    none,
    capture, // return Value
    stream: std.Io.File, // write to pipe/stdout
};

pub const ExecErr = union(enum) {
    none,
    stream: std.Io.File, // write to pipe/stdout
};

pub const ExecContext = struct {
    shell_ctx: *ShellCtx,
    allocator: Allocator,
    input: ExecInput = .none,
    output: ExecOutput = .none,
    err: ExecErr = .none,
    append: bool = false, // for stdout stream to overwrite or append to file
    is_pipe: bool = false, // in pipelines must use pipeRealAll not fileReadAll
};

/// Defines custom exe config behaviour
pub const RedirConfig = struct {
    stdin: StdConfig = .inherit,
    stdout: StdConfig = .inherit,
    stderr: StdConfig = .inherit,
    stdin_path: ?[]const u8 = null,
    stdout_path: ?[]const u8 = null,
    stderr_path: ?[]const u8 = null,
    stdout_truncate: bool = true,
    stderr_truncate: bool = true,
    merge_stderr_to_stdout: bool = false,

    /// Apply a redirect symbol to the config, accumulating multiple redirects
    pub fn applySymbol(self: *RedirConfig, symbol: []const u8) void {
        if (std.mem.eql(u8, symbol, ">") or std.mem.eql(u8, symbol, "1>")) {
            self.stdout = .pipe;
            self.stdout_truncate = true;
        } else if (std.mem.eql(u8, symbol, ">>") or std.mem.eql(u8, symbol, "1>>")) {
            self.stdout = .pipe;
            self.stdout_truncate = false;
        } else if (std.mem.eql(u8, symbol, "2>")) {
            self.stderr = .pipe;
            self.stderr_truncate = true;
        } else if (std.mem.eql(u8, symbol, "2>>")) {
            self.stderr = .pipe;
            self.stderr_truncate = false;
        } else if (std.mem.eql(u8, symbol, "<")) {
            self.stdin = .pipe;
        } else if (std.mem.eql(u8, symbol, "2>&1")) {
            self.merge_stderr_to_stdout = true;
        } else if (std.mem.eql(u8, symbol, "&>")) {
            self.stdout = .pipe;
            self.stderr = .pipe;
            self.stdout_truncate = true;
            self.merge_stderr_to_stdout = true;
        } else if (std.mem.eql(u8, symbol, "&>>")) {
            self.stdout = .pipe;
            self.stderr = .pipe;
            self.stdout_truncate = false;
            self.merge_stderr_to_stdout = true;
        }
    }

    pub fn hasAnyRedirect(self: *const RedirConfig) bool {
        return self.stdin != .inherit or
            self.stdout != .inherit or
            self.stderr != .inherit or
            self.merge_stderr_to_stdout;
    }
};

pub const CmdType = enum { builtin, external, assignment };

pub const Command = struct {
    const Self = @This();
    args: []Token,
    cmd_type: CmdType,
    input_type: TypeTag,
    output_type: TypeTag,

    /// Expand all arguments to their final string values
    /// Caller owns returned memory and must free each string + the slice
    pub fn getExpandedArgs(self: *const Self, ctx: *ShellCtx, arena_alloc: Allocator) ![][]const u8 {
        var args = try std.ArrayList([]const u8).initCapacity(arena_alloc, self.args.len);

        for (self.args) |arg_token| {
            try appendExpandedArgValues(&args, ctx, arena_alloc, arg_token);
        }

        return args.toOwnedSlice(arena_alloc);
    }
};

/// Expand a single token into one-or-many final argument values.
fn appendExpandedArgValues(
    out: *std.ArrayList([]const u8),
    ctx: *ShellCtx,
    arena_alloc: Allocator,
    token: Token,
) !void {
    const expanded = if (!token.single_quoted and std.mem.indexOfScalar(u8, token.text, '$') != null)
        try helpers.expandVariables(ctx, arena_alloc, token.text)
    else
        token.text;

    if (!token.single_quoted and helpers.hasGlobChars(expanded)) {
        const matches = try helpers.expandGlob(ctx.io, arena_alloc, expanded);
        defer arena_alloc.free(matches);
        try out.appendSlice(arena_alloc, matches);
        return;
    }

    const value: []const u8 = if (helpers.isPath(expanded))
        try helpers.expandPathToAbs(ctx, arena_alloc, expanded)
    else
        try arena_alloc.dupe(u8, expanded);
    try out.append(arena_alloc, value);
}

test "getExpandedArgs expands interactive globs" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        _ = gpa.deinit();
    }

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();

    var env_map = try @import("env.zig").EnvMap.init(allocator);
    defer env_map.deinit();

    var shell_ctx = try @import("context.zig").ShellCtx.initEngine(&io, allocator, env_map);
    defer shell_ctx.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var one_file = try tmp_dir.dir.createFile(io, "one.txt", .{});
    defer one_file.close(io);
    try helpers.fileWriteAll(io, one_file, "a");

    var two_file = try tmp_dir.dir.createFile(io, "two.txt", .{});
    defer two_file.close(io);
    try helpers.fileWriteAll(io, two_file, "b");

    var skip_file = try tmp_dir.dir.createFile(io, "skip.md", .{});
    defer skip_file.close(io);
    try helpers.fileWriteAll(io, skip_file, "c");

    const pattern = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/*.txt", .{tmp_dir.sub_path[0..]});
    defer allocator.free(pattern);

    var toks = [_]Token{
        .{ .kind = .Command, .text = "rm" },
        .{ .kind = .Arg, .text = pattern },
    };
    const cmd = Command{
        .args = toks[0..],
        .cmd_type = .external,
        .input_type = .void,
        .output_type = .void,
    };

    const expanded = try cmd.getExpandedArgs(&shell_ctx, allocator);
    defer {
        for (expanded) |arg| allocator.free(arg);
        allocator.free(expanded);
    }
    try std.testing.expect(expanded.len == 3);
    try std.testing.expect(std.mem.eql(u8, expanded[0], "rm"));
    const one_match = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/one.txt", .{tmp_dir.sub_path[0..]});
    defer allocator.free(one_match);
    const two_match = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/two.txt", .{tmp_dir.sub_path[0..]});
    defer allocator.free(two_match);
    try std.testing.expect(std.mem.eql(u8, expanded[1], one_match));
    try std.testing.expect(std.mem.eql(u8, expanded[2], two_match));
}
