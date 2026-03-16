const std = @import("std");

pub const ShellError = error{
    // --- Parse / syntax ---
    InvalidSyntax,
    TypeMismatch,
    UnexpectedToken,
    UnterminatedQuote,
    EmptyCommand,
    EmptySequence,
    EmptyPipeline,
    InvalidAssignment,
    EmptyTokenSequence,
    InvalidTokenSequence,
    EmptyCommandSequence,
    InvalidToken,
    CommandTypeNotFound,
    InvalidCommandSequence,
    InvalidForHeader,
    MissingInKeyword,
    EmptyLoopVariable,
    InvalidForHeaderFormat,
    UnterminatedControlFlow,
    RedirectMidPipeline,
    AssignmentMidPipeline,
    StateChangeBuiltinInPipeline,
    FailedPipelineGeneration,

    // --- Execution ---
    WriteFailed,
    CommandNotFound,
    PermissionDenied,
    NotExecutable,
    ExecFailed,
    ExternalCommandFailed,
    InvalidBuiltinCommand,
    UnsupportedBuiltinRedirect,
    Unsupported,
    ExportFailed,
    JobNotFound,
    JobSpawnFailed,
    InsufficientArgs,
    MissingArgument,
    UnexpectedEof,
    InvalidIntegerExpression,
    InvalidTestExpression,
    MissingCommand,
    InfiniteLoopDetected,
    Overflow,
    InvalidCharacter,
    RequiresInput,
    DivisionByZero,
    CommandExpansionFailed,
    ExpectedStream,

    // --- IO / environment ---
    FileNotFound,
    DirNotFound,
    PathTooLong,
    InvalidPath,
    NoHomeDir,
    InvalidPathType,
    PathNotFound,
    Unexpected,
    NameTooLong,
    CurrentWorkingDirectoryUnlinked,
    SystemResources,
    IsDir,
    WouldBlock,
    AccessDenied,
    ProcessNotFound,
    Canceled,
    PathAlreadyExists,
    SymLinkLoop,
    NoSpaceLeft,
    NotDir,
    NoDevice,
    NetworkNotFound,
    BadPathName,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    DeviceBusy,
    SharingViolation,
    PipeBusy,
    FileTooBig,
    FileLocksNotSupported,
    FileBusy,
    Streaming,
    ReadFailed,
    EndOfStream,
    InputOutput,
    BrokenPipe,
    LockViolation,
    Unseekable,
    DiskQuota,
    MessageOversize,
    InvalidArgument,
    NotOpenForWriting,
    FileSystem,
    InvalidExe,
    ProcessAlreadyExec,
    InvalidProcessGroupId,
    InvalidWtf8,
    InvalidBatchScriptArg,
    ResourceLimitReached,
    InvalidUserId,
    InvalidName,
    InvalidHandle,
    WaitAbandoned,
    WaitTimeOut,
    UnsupportedClock,
    Timeout,
    NotOpenForReading,
    SocketUnconnected,
    StreamTooLong,
    NoOutputRequired,
    MissingInput,
    UnsupportedPlatform,
    Base64ConversionFailed,

    // --- Resource limits ---
    OutOfMemory,
    TooManyArgs,
    AllocFailed,

    // --- Internal / logic ---
    InternalError,
    FailedIntegerConversion,

    // --- Scripting ----
    ScriptFailed,
    UnterminatedIfBlock,
    UnterminatedForLoop,
    UnterminatedWhileLoop,
    SwitchNoMatch,
};

pub const StructuredError = struct {
    error_code: anyerror,
    code: []const u8,
    category: []const u8,
    message: []const u8,
    hint: ?[]const u8 = null,
};

/// Map custom errors to structured, user-facing diagnostics.
pub fn toStructured(err: anyerror, allocator: std.mem.Allocator) !StructuredError {
    _ = allocator;
    return switch (err) {
        ShellError.InvalidSyntax => mk(err, "parse", "Invalid syntax.", "Verify separators, redirects, and quoting."),
        ShellError.TypeMismatch => mk(err, "parse", "Type mismatch for the operation.", "Check argument types and transform inputs."),
        ShellError.UnexpectedToken => mk(err, "parse", "Unexpected token in command.", "Check token order near operators such as |, &&, ||, or ;."),
        ShellError.UnterminatedQuote => mk(err, "parse", "Unterminated quote in command.", "Close all quote pairs."),
        ShellError.EmptyCommand => mk(err, "parse", "No command was provided.", "Pass a command after -c or type one in the REPL."),
        ShellError.EmptySequence => mk(err, "parse", "Empty command sequence.", "Remove trailing separators or provide commands between them."),
        ShellError.EmptyPipeline => mk(err, "parse", "Pipeline cannot be empty.", "Add at least one command on each side of pipes."),
        ShellError.InvalidAssignment => mk(err, "parse", "Invalid assignment expression.", "Use NAME=value format."),
        ShellError.EmptyTokenSequence => mk(err, "parse", "Lexer produced no tokens.", "Verify input is not blank or whitespace only."),
        ShellError.InvalidTokenSequence => mk(err, "parse", "Token sequence is invalid.", "Check command ordering around redirects and operators."),
        ShellError.EmptyCommandSequence => mk(err, "parse", "No executable command sequence was built.", "Check parser output and command separators."),
        ShellError.InvalidToken => mk(err, "parse", "Invalid token encountered.", "Remove unsupported characters or malformed operators."),
        ShellError.CommandTypeNotFound => mk(err, "parse", "Unable to determine command type.", "Ensure the command starts with a valid builtin, assignment, or executable."),
        ShellError.InvalidCommandSequence => mk(err, "parse", "Generated command sequence is invalid.", "Check parser and pipeline stage construction."),
        ShellError.InvalidForHeader => mk(err, "parse", "Invalid for-loop header.", "Use: for <var> in <values>."),
        ShellError.MissingInKeyword => mk(err, "parse", "Missing 'in' keyword in for-loop header.", "Use: for <var> in <values>."),
        ShellError.EmptyLoopVariable => mk(err, "parse", "Loop variable name is empty.", "Provide a variable name after 'for'."),
        ShellError.InvalidForHeaderFormat => mk(err, "parse", "For-loop header format is invalid.", "Use: for <var> in <values>."),
        ShellError.UnterminatedControlFlow => mk(err, "parse", "Control-flow block is unterminated.", "Close blocks with the expected terminator."),
        ShellError.RedirectMidPipeline => mk(err, "parse", "Redirect appears in an invalid pipeline position.", "Attach redirects to command boundaries only."),
        ShellError.AssignmentMidPipeline => mk(err, "parse", "Assignments are not allowed in multi-stage pipelines.", "Run assignments separately or before the pipeline."),
        ShellError.StateChangeBuiltinInPipeline => mk(err, "parse", "State-changing builtins cannot run in a pipeline.", "Run commands like cd/export without '|'."),
        ShellError.FailedPipelineGeneration => mk(err, "parse", "Failed to generate command pipeline.", "Inspect command structure and tokenization."),

        ShellError.WriteFailed => mk(err, "execution", "Failed to write command output.", "Check output destination permissions and disk health."),
        ShellError.CommandNotFound => mk(err, "execution", "Command was not found.", "Verify command name and PATH."),
        ShellError.PermissionDenied => mk(err, "execution", "Permission denied while executing command.", "Check file permissions and user privileges."),
        ShellError.NotExecutable => mk(err, "execution", "Target file is not executable.", "Mark file executable or run with an interpreter."),
        ShellError.ExecFailed => mk(err, "execution", "Command execution failed.", "Inspect child process setup and executable path."),
        ShellError.ExternalCommandFailed => mk(err, "execution", "External command exited with an error status.", "Inspect command arguments and referenced paths."),
        ShellError.InvalidBuiltinCommand => mk(err, "execution", "Builtin command is invalid or unsupported.", "Run 'help' to list builtins."),
        ShellError.UnsupportedBuiltinRedirect => mk(err, "execution", "Builtin does not support this redirect pattern.", "Use a supported redirect or command form."),
        ShellError.Unsupported => mk(err, "execution", "Operation is not supported in this mode.", "Try interactive mode or a different command."),
        ShellError.ExportFailed => mk(err, "execution", "Failed to export environment variable.", "Verify variable syntax and environment map state."),
        ShellError.JobNotFound => mk(err, "execution", "Requested job was not found.", "Run 'jobs' to inspect active job IDs."),
        ShellError.JobSpawnFailed => mk(err, "execution", "Failed to spawn or manage background job.", "Check process limits and job control state."),
        ShellError.InsufficientArgs => mk(err, "execution", "Insufficient arguments for command.", "Check command usage and required parameters."),
        ShellError.MissingArgument => mk(err, "execution", "Required argument is missing.", "Run command with required arguments."),
        ShellError.UnexpectedEof => mk(err, "execution", "Unexpected end of input.", "Check scripts and multiline command termination."),
        ShellError.InvalidIntegerExpression => mk(err, "execution", "Invalid integer expression.", "Use valid integers and operators."),
        ShellError.InvalidTestExpression => mk(err, "execution", "Invalid test expression.", "Use a valid test flag and operands."),
        ShellError.MissingCommand => mk(err, "execution", "Expected command was missing.", "Provide a command before executing."),
        ShellError.InfiniteLoopDetected => mk(err, "execution", "Potential infinite loop detected.", "Ensure loop conditions change over time."),
        ShellError.Overflow => mk(err, "execution", "Numeric overflow occurred.", "Use smaller numeric ranges."),
        ShellError.InvalidCharacter => mk(err, "execution", "Invalid character in input.", "Remove unsupported characters."),
        ShellError.RequiresInput => mk(err, "execution", "Command requires input but none was provided.", "Pass stdin or required arguments."),
        ShellError.DivisionByZero => mk(err, "execution", "Division by zero.", "Ensure divisor is non-zero."),
        ShellError.CommandExpansionFailed => mk(err, "execution", "Failed to expand variables or command arguments.", "Validate variable references and path expansions."),
        ShellError.ExpectedStream => mk(err, "execution", "Command expected stream output/input.", "Run command in stream context (pipe or redirect)."),

        ShellError.FileNotFound => mk(err, "io", "File not found.", "Confirm the path exists."),
        ShellError.DirNotFound => mk(err, "io", "Directory not found.", "Confirm the directory exists."),
        ShellError.PathTooLong => mk(err, "io", "Path is too long.", "Use a shorter path."),
        ShellError.InvalidPath => mk(err, "io", "Invalid path.", "Verify path syntax and existence."),
        ShellError.NoHomeDir => mk(err, "io", "Home directory could not be resolved.", "Ensure HOME is set."),
        ShellError.InvalidPathType => mk(err, "io", "Invalid path type.", "Use a file path where a file is expected."),
        ShellError.PathNotFound => mk(err, "io", "Path not found.", "Confirm filesystem location."),
        ShellError.Unexpected => mk(err, "io", "Unexpected I/O error.", "Retry and inspect OS-level errors."),
        ShellError.NameTooLong => mk(err, "io", "File or directory name too long.", "Use a shorter name."),
        ShellError.CurrentWorkingDirectoryUnlinked => mk(err, "io", "Current working directory is unavailable.", "Change to a valid directory."),
        ShellError.SystemResources => mk(err, "io", "Insufficient system resources.", "Close processes or raise limits."),
        ShellError.IsDir => mk(err, "io", "Expected a file but found a directory.", "Pass a file path instead."),
        ShellError.WouldBlock => mk(err, "io", "Operation would block.", "Retry when resource is ready."),
        ShellError.AccessDenied => mk(err, "io", "Access denied.", "Check permissions and ownership."),
        ShellError.ProcessNotFound => mk(err, "io", "Process not found.", "Verify process or job still exists."),
        ShellError.Canceled => mk(err, "io", "Operation was canceled.", "Retry operation if appropriate."),
        ShellError.PathAlreadyExists => mk(err, "io", "Path already exists.", "Use a different path or remove existing file."),
        ShellError.SymLinkLoop => mk(err, "io", "Symbolic link loop detected.", "Fix symlink chain."),
        ShellError.NoSpaceLeft => mk(err, "io", "No space left on device.", "Free disk space."),
        ShellError.NotDir => mk(err, "io", "Expected a directory but found something else.", "Pass a valid directory path."),
        ShellError.NoDevice => mk(err, "io", "Referenced device is unavailable.", "Verify device mount and availability."),
        ShellError.NetworkNotFound => mk(err, "io", "Network resource not found.", "Check network connectivity and destination."),
        ShellError.BadPathName => mk(err, "io", "Malformed path name.", "Use a valid path format."),
        ShellError.ProcessFdQuotaExceeded => mk(err, "io", "Process file descriptor limit exceeded.", "Close files or increase ulimit."),
        ShellError.SystemFdQuotaExceeded => mk(err, "io", "System file descriptor quota exceeded.", "Reduce open descriptors system-wide."),
        ShellError.DeviceBusy => mk(err, "io", "Device is busy.", "Retry when resource is free."),
        ShellError.SharingViolation => mk(err, "io", "Sharing violation on file resource.", "Close conflicting file handles."),
        ShellError.PipeBusy => mk(err, "io", "Pipe is busy.", "Retry after reader/writer state stabilizes."),
        ShellError.FileTooBig => mk(err, "io", "File is too large for this operation.", "Use streaming or split file."),
        ShellError.FileLocksNotSupported => mk(err, "io", "File locking is not supported.", "Avoid lock-based workflow on this filesystem."),
        ShellError.FileBusy => mk(err, "io", "File is busy.", "Retry after other operations complete."),
        ShellError.Streaming => mk(err, "io", "Streaming I/O failure.", "Inspect pipe/stream state."),
        ShellError.ReadFailed => mk(err, "io", "Failed to read input.", "Verify source exists and is readable."),
        ShellError.EndOfStream => mk(err, "io", "Reached end of stream unexpectedly.", "Provide complete input data."),
        ShellError.InputOutput => mk(err, "io", "General input/output failure.", "Check filesystem and descriptor health."),
        ShellError.BrokenPipe => mk(err, "io", "Broken pipe.", "Ensure downstream process is still running."),
        ShellError.LockViolation => mk(err, "io", "Lock violation.", "Release lock from competing process."),
        ShellError.Unseekable => mk(err, "io", "Stream is not seekable.", "Use streaming operations instead of positional I/O."),
        ShellError.DiskQuota => mk(err, "io", "Disk quota exceeded.", "Free quota or request larger allocation."),
        ShellError.MessageOversize => mk(err, "io", "Message or payload is too large.", "Reduce payload size."),
        ShellError.InvalidArgument => mk(err, "io", "Invalid argument for this operation.", "Check command usage and argument types."),
        ShellError.NotOpenForWriting => mk(err, "io", "File is not open for writing.", "Open destination with write access."),
        ShellError.FileSystem => mk(err, "io", "Filesystem operation failed.", "Inspect filesystem state and permissions."),
        ShellError.InvalidExe => mk(err, "io", "Executable format is invalid.", "Use a valid binary or script with shebang."),
        ShellError.ProcessAlreadyExec => mk(err, "io", "Process has already executed.", "Avoid reusing consumed process context."),
        ShellError.InvalidProcessGroupId => mk(err, "io", "Invalid process group ID.", "Verify job/process group lifecycle."),
        ShellError.InvalidWtf8 => mk(err, "io", "Invalid WTF-8 sequence.", "Use valid UTF-8/WTF-8 compatible input."),
        ShellError.InvalidBatchScriptArg => mk(err, "io", "Invalid batch script argument.", "Check script invocation parameters."),
        ShellError.ResourceLimitReached => mk(err, "io", "Resource limit reached.", "Raise limits or reduce workload."),
        ShellError.InvalidUserId => mk(err, "io", "Invalid user ID.", "Verify user identity configuration."),
        ShellError.InvalidName => mk(err, "io", "Invalid name.", "Use valid identifier characters."),
        ShellError.InvalidHandle => mk(err, "io", "Invalid OS/file handle.", "Check descriptor lifecycle."),
        ShellError.WaitAbandoned => mk(err, "io", "Wait operation was abandoned.", "Retry and inspect synchronization state."),
        ShellError.WaitTimeOut => mk(err, "io", "Wait operation timed out.", "Increase timeout or inspect blocking dependency."),
        ShellError.UnsupportedClock => mk(err, "io", "Clock source is unsupported.", "Use a supported timer/clock mode."),
        ShellError.Timeout => mk(err, "io", "Operation timed out.", "Retry with a higher timeout."),
        ShellError.NotOpenForReading => mk(err, "io", "File is not open for reading.", "Open source with read access."),
        ShellError.SocketUnconnected => mk(err, "io", "Socket is not connected.", "Establish connection before use."),
        ShellError.StreamTooLong => mk(err, "io", "Stream exceeded allowed length.", "Limit stream input size."),
        ShellError.NoOutputRequired => mk(err, "io", "Command output is disabled for this context.", "Use capture or stream output mode."),
        ShellError.MissingInput => mk(err, "io", "Missing expected input.", "Provide input via stdin or argument."),
        ShellError.UnsupportedPlatform => mk(err, "io", "Operation is unsupported on this platform.", "Run on a supported platform or disable the feature."),
        ShellError.Base64ConversionFailed => mk(err, "io", "Base64 conversion failed.", "Check encoded input and conversion mode."),

        ShellError.OutOfMemory => mk(err, "resource", "Out of memory.", "Reduce allocation pressure."),
        ShellError.TooManyArgs => mk(err, "resource", "Too many arguments.", "Reduce argument count."),
        ShellError.AllocFailed => mk(err, "resource", "Memory allocation failed.", "Retry with fewer allocations."),

        ShellError.InternalError => mk(err, "internal", "Internal runtime error.", "Check logs and report if persistent."),
        ShellError.FailedIntegerConversion => mk(err, "internal", "Integer conversion failed.", "Verify numeric input ranges and formats."),

        ShellError.ScriptFailed => mk(err, "scripting", "Script execution failed.", "Review script syntax and runtime commands."),
        ShellError.UnterminatedIfBlock => mk(err, "scripting", "Unterminated if block.", "Close with 'fi'."),
        ShellError.UnterminatedForLoop => mk(err, "scripting", "Unterminated for loop.", "Close with 'done'."),
        ShellError.UnterminatedWhileLoop => mk(err, "scripting", "Unterminated while loop.", "Close with 'done'."),
        ShellError.SwitchNoMatch => mk(err, "scripting", "Switch expression matched no case and no default branch exists.", "Add a matching 'case <value>:' or provide a 'default:' branch."),
        else => mk(err, "internal", "Unknown error.", "Inspect error code and call site context."),
    };
}

/// Distinguish between a file not found or access not allowed by policy
pub fn mapPathOpenError(err: anyerror) ShellError {
    return switch (err) {
        error.FileNotFound => ShellError.FileNotFound,
        error.PathNotFound => ShellError.PathNotFound,
        error.AccessDenied => ShellError.AccessDenied,
        error.NotDir => ShellError.NotDir,
        error.IsDir => ShellError.IsDir,
        error.NameTooLong => ShellError.NameTooLong,
        error.PathAlreadyExists => ShellError.PathAlreadyExists,
        error.NoSpaceLeft => ShellError.NoSpaceLeft,
        error.BadPathName => ShellError.BadPathName,
        error.DeviceBusy => ShellError.DeviceBusy,
        error.FileBusy => ShellError.FileBusy,
        error.SystemResources => ShellError.SystemResources,
        error.ProcessFdQuotaExceeded => ShellError.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => ShellError.SystemFdQuotaExceeded,
        else => ShellError.InvalidPath,
    };
}

/// Distinguish between filesystem policy errors and concrete open/create failures.
pub fn mapRedirectOpenError(err: anyerror) ShellError {
    return mapPathOpenError(err);
}

/// Map zig read errors to custom error type
pub fn mapPolicyReadError(err: anyerror) ShellError {
    return switch (err) {
        error.FileNotFound => ShellError.FileNotFound,
        error.AccessDenied => ShellError.AccessDenied,
        error.IsDir => ShellError.IsDir,
        error.NotDir => ShellError.NotDir,
        error.StreamTooLong => ShellError.StreamTooLong,
        error.InputOutput => ShellError.ReadFailed,
        error.OutOfMemory => ShellError.AllocFailed,
        else => ShellError.ReadFailed,
    };
}

fn mk(err: anyerror, category: []const u8, message: []const u8, hint: ?[]const u8) StructuredError {
    return .{
        .error_code = err,
        .code = @errorName(err),
        .category = category,
        .message = message,
        .hint = hint,
    };
}

pub fn report(err: anyerror, action: []const u8, detail: ?[]const u8) void {
    _ = action;
    _ = detail;
    const diag = toStructured(err, std.heap.page_allocator) catch mk(err, "internal", "Unknown error.", null);
    std.log.err("zest error [{s}/{s}] {s}", .{ diag.category, diag.code, diag.message });
    if (diag.hint) |h| {
        std.log.err("hint: {s}", .{h});
    }
}

pub const InteractiveReportOptions = struct {
    source_line: []const u8,
    source_name: []const u8 = "interactive",
    line_no: usize = 1,
    action: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    command_word: ?[]const u8 = null,
};

const InteractiveSpan = struct {
    start: usize,
    end: usize,
    label: []const u8,
};

const Color = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const red = "\x1b[31m";
    const cyan = "\x1b[36m";
    const yellow = "\x1b[33m";
};

fn writeSpaces(out: anytype, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try out.writeByte(' ');
    }
}

fn firstNonWhitespace(s: []const u8) ?usize {
    for (s, 0..) |c, idx| {
        if (!std.ascii.isWhitespace(c)) return idx;
    }
    return null;
}

fn lastNonWhitespace(s: []const u8) ?usize {
    if (s.len == 0) return null;
    var i = s.len;
    while (i > 0) {
        i -= 1;
        if (!std.ascii.isWhitespace(s[i])) return i;
    }
    return null;
}

fn isOperatorByte(c: u8) bool {
    return switch (c) {
        '|', '&', ';', '>', '<' => true,
        else => false,
    };
}

fn operatorLenAt(line: []const u8, idx: usize) usize {
    if (idx >= line.len) return 1;
    if (line[idx] == '2' and idx + 3 < line.len and std.mem.eql(u8, line[idx .. idx + 4], "2>&1")) return 4;
    if (line[idx] == '&' and idx + 2 < line.len and std.mem.eql(u8, line[idx .. idx + 3], "&>>")) return 3;
    if (line[idx] == '1' and idx + 2 < line.len and std.mem.eql(u8, line[idx .. idx + 3], "1>>")) return 3;
    if (line[idx] == '2' and idx + 2 < line.len and std.mem.eql(u8, line[idx .. idx + 3], "2>>")) return 3;
    if (line[idx] == '&' and idx + 1 < line.len and std.mem.eql(u8, line[idx .. idx + 2], "&>")) return 2;
    if (line[idx] == '1' and idx + 1 < line.len and std.mem.eql(u8, line[idx .. idx + 2], "1>")) return 2;
    if (line[idx] == '2' and idx + 1 < line.len and std.mem.eql(u8, line[idx .. idx + 2], "2>")) return 2;
    if (idx + 1 < line.len and std.mem.eql(u8, line[idx .. idx + 2], "||")) return 2;
    if (idx + 1 < line.len and std.mem.eql(u8, line[idx .. idx + 2], "&&")) return 2;
    if (idx + 1 < line.len and std.mem.eql(u8, line[idx .. idx + 2], ">>")) return 2;
    return 1;
}

fn firstWordSpan(line: []const u8, label: []const u8) InteractiveSpan {
    const start = firstNonWhitespace(line) orelse return .{ .start = 0, .end = 1, .label = label };
    var end = start;
    while (end < line.len and !std.ascii.isWhitespace(line[end])) : (end += 1) {}
    return .{ .start = start, .end = @max(start + 1, end), .label = label };
}

fn findNeedleSpan(line: []const u8, needle: []const u8, label: []const u8) ?InteractiveSpan {
    if (needle.len == 0) return null;
    const idx = std.mem.indexOf(u8, line, needle) orelse return null;
    return .{
        .start = idx,
        .end = idx + needle.len,
        .label = label,
    };
}

fn commandOrFirstWordSpan(line: []const u8, command_word: ?[]const u8, label: []const u8) InteractiveSpan {
    if (command_word) |word| {
        if (findNeedleSpan(line, word, label)) |span| return span;
    }
    return firstWordSpan(line, label);
}

fn inferInteractiveSpan(err: anyerror, line: []const u8, command_word: ?[]const u8, detail: ?[]const u8) InteractiveSpan {
    _ = detail;
    if (line.len == 0) return .{ .start = 0, .end = 1, .label = "error near this input" };

    switch (err) {
        ShellError.InvalidTokenSequence, ShellError.UnexpectedToken => {
            if (firstNonWhitespace(line)) |start| {
                if (isOperatorByte(line[start])) {
                    const len = operatorLenAt(line, start);
                    return .{
                        .start = start,
                        .end = @min(line.len, start + len),
                        .label = "operator cannot start a command",
                    };
                }
            }
            if (lastNonWhitespace(line)) |last| {
                if (isOperatorByte(line[last])) {
                    var start = last;
                    while (start > 0 and isOperatorByte(line[start - 1])) : (start -= 1) {}
                    return .{
                        .start = start,
                        .end = last + 1,
                        .label = "operator is missing a command operand",
                    };
                }
            }
            if (std.mem.indexOf(u8, line, "| |")) |idx| {
                return .{ .start = idx + 2, .end = idx + 3, .label = "unexpected pipe operator" };
            }
            if (std.mem.indexOf(u8, line, "|| ||")) |idx| {
                return .{ .start = idx + 3, .end = idx + 5, .label = "unexpected logical-or operator" };
            }
            if (std.mem.indexOf(u8, line, "&& &&")) |idx| {
                return .{ .start = idx + 3, .end = idx + 5, .label = "unexpected logical-and operator" };
            }
            if (std.mem.indexOfAny(u8, line, "|&;><")) |idx| {
                return .{
                    .start = idx,
                    .end = @min(line.len, idx + operatorLenAt(line, idx)),
                    .label = "problematic operator usage",
                };
            }
            return commandOrFirstWordSpan(line, command_word, "token ordering is invalid around this segment");
        },
        ShellError.InvalidSyntax => {
            if (std.mem.indexOfAny(u8, line, "|&;><")) |idx| {
                return .{
                    .start = idx,
                    .end = @min(line.len, idx + operatorLenAt(line, idx)),
                    .label = "syntax issue near this token",
                };
            }
            return commandOrFirstWordSpan(line, command_word, "syntax issue near this token");
        },
        ShellError.InvalidAssignment => {
            if (std.mem.indexOfScalar(u8, line, '=')) |eq_idx| {
                var start = eq_idx;
                var end = eq_idx + 1;
                while (start > 0 and !std.ascii.isWhitespace(line[start - 1])) : (start -= 1) {}
                while (end < line.len and !std.ascii.isWhitespace(line[end])) : (end += 1) {}
                return .{ .start = start, .end = @max(start + 1, end), .label = "assignment syntax is invalid" };
            }
            return commandOrFirstWordSpan(line, command_word, "assignment syntax is invalid");
        },
        ShellError.RedirectMidPipeline, ShellError.UnsupportedBuiltinRedirect => {
            if (std.mem.indexOfAny(u8, line, "><")) |idx| {
                return .{
                    .start = idx,
                    .end = @min(line.len, idx + operatorLenAt(line, idx)),
                    .label = "redirect placement is invalid here",
                };
            }
            return commandOrFirstWordSpan(line, command_word, "redirect placement is invalid here");
        },
        ShellError.AssignmentMidPipeline => return commandOrFirstWordSpan(line, command_word, "assignment cannot be used in this pipeline position"),
        ShellError.StateChangeBuiltinInPipeline => return commandOrFirstWordSpan(line, command_word, "state-changing builtin is incompatible with pipeline execution"),
        ShellError.CommandNotFound, ShellError.InvalidBuiltinCommand => return commandOrFirstWordSpan(line, command_word, "command could not be resolved"),
        ShellError.ExternalCommandFailed => return commandOrFirstWordSpan(line, command_word, "external command returned a failing status"),
        ShellError.TypeMismatch => return commandOrFirstWordSpan(line, command_word, "type compatibility error near this command"),
        ShellError.MissingArgument, ShellError.InsufficientArgs => return commandOrFirstWordSpan(line, command_word, "required argument is missing here"),
        ShellError.TooManyArgs => return commandOrFirstWordSpan(line, command_word, "too many arguments for this command"),
        ShellError.InvalidArgument => return commandOrFirstWordSpan(line, command_word, "invalid argument near this segment"),
        ShellError.Unsupported => return commandOrFirstWordSpan(line, command_word, "this command is incompatible with current mode or context"),
        else => return commandOrFirstWordSpan(line, command_word, "error occurred while executing this command"),
    }
}

pub fn reportInteractive(err: anyerror, io: std.Io, out_file: std.Io.File, opts: InteractiveReportOptions) void {
    const diag = toStructured(err, std.heap.page_allocator) catch mk(err, "internal", "Unknown error.", null);
    const span = inferInteractiveSpan(err, opts.source_line, opts.command_word, opts.detail);
    const start = @min(span.start, opts.source_line.len);
    const safe_end = if (opts.source_line.len == 0)
        0
    else
        @min(opts.source_line.len, @max(start + 1, span.end));
    const caret_len = @max(@as(usize, 1), safe_end - start);
    const col = start + 1;

    var buf: [8192]u8 = undefined;
    var writer = out_file.writer(io, &buf);
    const out = &writer.interface;
    defer out.flush() catch {};

    out.print(
        "{s}{s}error{s}: [{s}/{s}] {s}\n",
        .{ Color.bold, Color.red, Color.reset, diag.category, diag.code, diag.message },
    ) catch return;
    out.print(
        "{s} --> {s}:{d}:{d}{s}\n",
        .{ Color.dim, opts.source_name, opts.line_no, col, Color.reset },
    ) catch return;
    out.print("{s}  |{s}\n", .{ Color.dim, Color.reset }) catch return;

    const before = opts.source_line[0..start];
    const highlight = opts.source_line[start..safe_end];
    const after = opts.source_line[safe_end..];
    out.print(
        "{s}{d} | {s}{s}{s}{s}{s}\n",
        .{ Color.dim, opts.line_no, before, Color.bold ++ Color.red, highlight, Color.reset, after },
    ) catch return;
    out.print("{s}  | {s}", .{ Color.dim, Color.reset }) catch return;
    writeSpaces(out, start) catch return;
    out.print("{s}", .{Color.red}) catch return;
    var i: usize = 0;
    while (i < caret_len) : (i += 1) {
        out.writeByte('^') catch return;
    }
    out.print("{s} {s}\n", .{ Color.reset, span.label }) catch return;
    out.print("{s}  |{s}\n", .{ Color.dim, Color.reset }) catch return;

    if (diag.hint) |hint| {
        out.print("{s}  = hint:{s} {s}\n", .{ Color.yellow, Color.reset, hint }) catch return;
    }
}

test "inferInteractiveSpan points to leading operator for InvalidTokenSequence" {
    const span = inferInteractiveSpan(
        ShellError.InvalidTokenSequence,
        "|| echo bad",
        null,
        null,
    );
    try std.testing.expectEqual(@as(usize, 0), span.start);
    try std.testing.expectEqual(@as(usize, 2), span.end);
}

test "inferInteractiveSpan points to command word for MissingArgument" {
    const span = inferInteractiveSpan(
        ShellError.MissingArgument,
        "cd",
        "cd",
        null,
    );
    try std.testing.expectEqual(@as(usize, 0), span.start);
    try std.testing.expectEqual(@as(usize, 2), span.end);
}
