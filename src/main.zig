// ============================================================================
// ZEST ENTRY POINT
// Responsibilities: parse args, determine mode, dispatch. Nothing else.
// ============================================================================
const std = @import("std");
const config = @import("shell/interactive/config.zig");
const engine = @import("lib-core/engine.zig");
const shell = @import("shell/shell.zig");
const errors = @import("lib-core/core/errors.zig");
const ShellError = errors.ShellError;

const Mode = union(enum) {
    engine: engine.EngineConfig,
    interactive: shell.InteractiveConfig,
    help,
};

const detail_removed_audit_options = "audit-related options have been removed";
const detail_single_input_only = "only one input source is allowed (-c or --input)";
const detail_empty_command = "flag -c requires a non-empty argument";
const detail_engine_only_flags = "--json/--profile/--plan-json require -c <command> or --input <file>";

fn inferInputFromPath(path: []const u8) ShellError!engine.EngineConfig.Input {
    if (std.mem.endsWith(u8, path, ".json")) return .{ .json_file = path };
    if (std.mem.endsWith(u8, path, ".sh")) return .{ .script_file = path };
    return ShellError.InvalidPathType;
}

fn nextArgValue(args: []const [:0]const u8, idx: *usize) ShellError![]const u8 {
    if (idx.* + 1 >= args.len) return ShellError.MissingArgument;
    idx.* += 1;
    return args[idx.*];
}

fn requireArgValueFor(
    comptime flag_name: []const u8,
    args: []const [:0]const u8,
    idx: *usize,
    detail_out: *?[]const u8,
) ShellError![]const u8 {
    return nextArgValue(args, idx) catch |err| switch (err) {
        ShellError.MissingArgument => {
            detail_out.* = "missing value for " ++ flag_name;
            return ShellError.MissingArgument;
        },
        else => return err,
    };
}

fn ensureNoEngineInput(input: ?engine.EngineConfig.Input, detail_out: *?[]const u8) ShellError!void {
    if (input != null) {
        detail_out.* = detail_single_input_only;
        return ShellError.InvalidArgument;
    }
}

fn parseCommandInputArg(
    args: []const [:0]const u8,
    idx: *usize,
    detail_out: *?[]const u8,
) ShellError!engine.EngineConfig.Input {
    const command = requireArgValueFor("-c", args, idx, detail_out) catch |err| switch (err) {
        ShellError.MissingArgument => {
            detail_out.* = detail_empty_command;
            return ShellError.EmptyCommand;
        },
        else => return err,
    };
    if (command.len == 0) {
        detail_out.* = detail_empty_command;
        return ShellError.EmptyCommand;
    }
    return .{ .command = command };
}

fn route(args: []const [:0]const u8, detail_out: *?[]const u8) !Mode {
    detail_out.* = null;
    var i: usize = 1;
    var output_format: engine.EngineConfig.OutputFormat = .text;
    var profile = false;
    var plan_json = false;
    var input: ?engine.EngineConfig.Input = null;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return .help;
        } else if (std.mem.eql(u8, arg, "--json")) {
            output_format = .json;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            profile = true;
        } else if (std.mem.eql(u8, arg, "--plan-json")) {
            plan_json = true;
        } else if (std.mem.eql(u8, arg, "--session-id") or
            std.mem.eql(u8, arg, "--audit") or
            std.mem.eql(u8, arg, "--audit-dir"))
        {
            detail_out.* = detail_removed_audit_options;
            return ShellError.Unsupported;
        } else if (std.mem.eql(u8, arg, "--input")) {
            try ensureNoEngineInput(input, detail_out);
            const path = try requireArgValueFor("--input", args, &i, detail_out);
            input = inferInputFromPath(path) catch |err| switch (err) {
                ShellError.InvalidPathType => {
                    detail_out.* = path;
                    return err;
                },
                else => return err,
            };
        } else if (std.mem.eql(u8, arg, "-c")) {
            try ensureNoEngineInput(input, detail_out);
            input = try parseCommandInputArg(args, &i, detail_out);
        } else {
            detail_out.* = arg;
            return ShellError.InvalidArgument;
        }
    }

    if (input) |resolved| {
        if (plan_json and switch (resolved) {
            .script_file => true,
            else => false,
        }) {
            detail_out.* = "--plan-json supports -c or --input <file.json>";
            return ShellError.Unsupported;
        }
        return .{ .engine = .{
            .input = resolved,
            .output_format = output_format,
            .profile = profile,
            .plan_json = plan_json,
        } };
    }

    if (output_format != .text or profile or plan_json) {
        detail_out.* = detail_engine_only_flags;
        return ShellError.MissingInput;
    }

    return .{ .interactive = .{} };
}

pub fn printUsage() void {
    std.log.info(
        \\{s} v{s} - A modern shell written in Zig
        \\
        \\USAGE:
        \\    zest
        \\    zest -c "<command>" [OPTIONS]
        \\    zest --input <file> [OPTIONS]
        \\
        \\OPTIONS:
        \\    -c <cmd>                 Engine mode: execute command and exit
        \\    --input <file>           Engine mode: input file (.json => JSON pipeline, .sh => script)
        \\    --json                   Engine mode only: return JSON result (default output is text)
        \\    --profile                Engine mode only: print basic timing after execution
        \\    --plan-json              Engine mode only: generate JSON pipeline input from parsed command/plan
        \\    -h, --help               Display this help message
        \\
        \\NOTES:
        \\    - If neither -c nor --input is provided, zest starts interactive mode.
        \\    - --json, --profile, and --plan-json only apply to engine mode.
        \\    - --input infers format by extension: *.json => JSON pipeline, *.sh => script.
        \\    - Interactive mode loads ~/.config/zest/config.txt.
        \\
        \\EXAMPLES:
        \\    zest
        \\    zest -c "echo hello"
        \\    zest -c "profile echo hello"
        \\    zest --input ./pipeline.json --json
        \\    zest --input ./deploy.sh
        \\
    , .{ config.SHELL_NAME, config.VERSION });
}

pub fn main(init: std.process.Init) !u8 {
    var route_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer route_arena.deinit();
    const route_alloc = route_arena.allocator();

    const args = try init.minimal.args.toSlice(route_alloc);

    var route_detail: ?[]const u8 = null;
    const mode = route(args, &route_detail) catch |err| {
        const fallback_detail = route_detail orelse switch (err) {
            ShellError.MissingArgument => "missing required value for a flag",
            ShellError.InvalidArgument => "invalid CLI argument or combination",
            ShellError.Unsupported => "unsupported argument combination",
            else => null,
        };
        errors.report(err, "route CLI arguments", fallback_detail);
        return 2;
    };

    return switch (mode) {
        .help => {
            printUsage();
            return 0;
        },
        .engine => |cfg| engine.run(cfg, init.minimal),
        .interactive => |cfg| shell.run(cfg, init.minimal),
    };
}

test "route defaults to interactive mode" {
    var detail: ?[]const u8 = null;
    const args = [_][:0]const u8{"zest"};
    const mode = try route(args[0..], &detail);
    try std.testing.expect(detail == null);

    switch (mode) {
        .interactive => {},
        else => return error.TestExpectedEqual,
    }
}

test "route selects command engine mode for -c" {
    var detail: ?[]const u8 = null;
    const args = [_][:0]const u8{ "zest", "-c", "echo hi" };
    const mode = try route(args[0..], &detail);
    try std.testing.expect(detail == null);

    switch (mode) {
        .engine => |cfg| switch (cfg.input) {
            .command => |cmd| try std.testing.expectEqualStrings("echo hi", cmd),
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "route selects script mode for --input .sh" {
    var detail: ?[]const u8 = null;
    const args = [_][:0]const u8{ "zest", "--input", "./scripts/test.sh" };
    const mode = try route(args[0..], &detail);
    try std.testing.expect(detail == null);

    switch (mode) {
        .engine => |cfg| switch (cfg.input) {
            .script_file => |path| try std.testing.expectEqualStrings("./scripts/test.sh", path),
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "route rejects invalid input extension with explicit detail" {
    var detail: ?[]const u8 = null;
    const args = [_][:0]const u8{ "zest", "--input", "./scripts/test.txt" };
    try std.testing.expectError(ShellError.InvalidPathType, route(args[0..], &detail));
    try std.testing.expect(detail != null);
    try std.testing.expectEqualStrings("./scripts/test.txt", detail.?);
}

test "route rejects json output without engine input" {
    var detail: ?[]const u8 = null;
    const args = [_][:0]const u8{ "zest", "--json" };
    try std.testing.expectError(ShellError.MissingInput, route(args[0..], &detail));
    try std.testing.expect(detail != null);
    try std.testing.expectEqualStrings(detail_engine_only_flags, detail.?);
}
