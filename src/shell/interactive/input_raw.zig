/// Raw input mode to handle input key by key including tab complete, history etc..
const std = @import("std");
const autocomplete = @import("autocomplete.zig");
const builtins = @import("../../lib-core/core/builtins.zig");
const config = @import("config.zig");
const prompt_mod = @import("prompt.zig");
const env = @import("../../lib-core/core/context.zig");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Completion = autocomplete.Completion;
const Color = config.Color;

// Escaped key inputs
const BELL = "\x07";
const BACKSPACE = 127;
const CTRL_A = 1;
const DEL = 8;
const CTRL_C = 3;
const CTRL_E = 5;
const CTRL_K = 11;
const CTRL_L = 12;
const CTRL_R = 18;
const CTRL_U = 21;
const CTRL_W = 23;
const ESC = 27;
const CURSOR_LEFT = "\x1b[D";
const CURSOR_RIGHT = "\x1b[C";
const MIN_GHOST_TRIGGER_LEN: usize = 3;
const GHOST_COLOR_ANSI = "90";
const GHOST_MAX_SUGGESTION_LEN: usize = 4096;
const GHOST_SCRATCH_BYTES: usize = 16 * 1024;

const GhostSuggestionState = struct {
    query_hash: u64 = 0,
    cached: bool = false,
    has_suggestion: bool = false,
    suggestion_len: usize = 0,
    suggestion_buf: [GHOST_MAX_SUGGESTION_LEN]u8 = undefined,
};

const PromptRenderCache = prompt_mod.PromptRenderCache;

// Handle input in custom raw mode
pub const RawMode = struct {
    original_terminos: posix.termios,
    fd: posix.fd_t,

    pub fn enable(fd: posix.fd_t) !RawMode {
        const original = try posix.tcgetattr(fd);
        var raw = original;

        // disable canonical mode and echo
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;

        // ISIG for Ctrl C interupts disabled
        raw.lflag.ISIG = false;

        // set read to return with 1 byte after input
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;

        try posix.tcsetattr(fd, .FLUSH, raw);

        return RawMode{
            .original_terminos = original,
            .fd = fd,
        };
    }

    pub fn disable(self: *RawMode) void {
        posix.tcsetattr(self.fd, .FLUSH, self.original_terminos) catch {};
    }
};

/// Helper for determining if multi line input used
fn getTerminalWidth() usize {
    var ws: std.posix.winsize = undefined;
    const err = std.posix.system.ioctl(
        std.posix.STDOUT_FILENO,
        std.posix.T.IOCGWINSZ,
        @intFromPtr(&ws),
    );
    if (err != 0 or ws.col == 0) return 80; // safe default
    return ws.col;
}

fn isSeparatorStart(line: []const u8, i: usize) ?usize {
    if (line[i] == '|') {
        if (i + 1 < line.len and line[i + 1] == '|') return 2;
        return 1;
    }
    if (line[i] == '&') {
        if (i + 1 < line.len and line[i + 1] == '&') return 2;
        return 1;
    }
    if (line[i] == ';') return 1;
    return null;
}

fn isBuiltinCommand(word: []const u8) bool {
    return builtins.isBuiltinCmd(word);
}

fn writeColored(writer: *std.Io.Writer, color: Color, text: []const u8) !void {
    if (text.len == 0) return;
    try writer.print("\x1b[{s}m{s}\x1b[0m", .{ config.getAnsiColorStr(color), text });
}

fn writeHighlightedInput(line: []const u8, writer: *std.Io.Writer) !void {
    var i: usize = 0;
    var expect_command = true;

    while (i < line.len) {
        const ch = line[i];

        if (std.ascii.isWhitespace(ch)) {
            try writer.writeByte(ch);
            i += 1;
            continue;
        }

        if (isSeparatorStart(line, i)) |sep_len| {
            try writeColored(writer, config.SeparatorColor, line[i .. i + sep_len]);
            i += sep_len;
            expect_command = true;
            continue;
        }

        var j = i;
        while (j < line.len and !std.ascii.isWhitespace(line[j]) and isSeparatorStart(line, j) == null) : (j += 1) {}
        const token = line[i..j];

        if (expect_command) {
            const command_color = if (isBuiltinCommand(token)) config.BuiltinCommandColor else config.CommandColor;
            try writeColored(writer, command_color, token);
            expect_command = false;
        } else {
            try writer.writeAll(token);
        }
        i = j;
    }
}

fn suggestionHash(line: []const u8, cursor_pos: usize) u64 {
    const seed: u64 = 0x9E3779B97F4A7C15;
    return std.hash.Wyhash.hash(seed, line) ^ (@as(u64, @intCast(cursor_pos)) *% 0x517CC1B727220A95);
}

fn isValidHistorySuggestion(line: []const u8, history_match: []const u8, max_len: usize) bool {
    return history_match.len > line.len and
        std.mem.startsWith(u8, history_match, line) and
        history_match.len <= max_len;
}

fn buildWordSuggestion(
    line: []const u8,
    cursor_pos: usize,
    completed_word: []const u8,
    out_buf: []u8,
) ?usize {
    const word_start = autocomplete.findWordStart(line, cursor_pos);
    const prefix = line[word_start..cursor_pos];
    if (!std.mem.startsWith(u8, completed_word, prefix)) return null;

    const completed_len = word_start + completed_word.len;
    if (completed_len <= line.len or completed_len > out_buf.len) return null;

    @memcpy(out_buf[0..word_start], line[0..word_start]);
    @memcpy(out_buf[word_start..completed_len], completed_word);
    return completed_len;
}

fn tokenEnd(input: []const u8, start: usize) usize {
    var end = start;
    while (end < input.len and !std.ascii.isWhitespace(input[end]) and isSeparatorStart(input, end) == null) : (end += 1) {}
    return end;
}

fn shouldPreferWordSuggestion(line: []const u8, cursor_pos: usize, history_match: []const u8, completed_word: []const u8) bool {
    const word_start = autocomplete.findWordStart(line, cursor_pos);
    if (word_start == 0) return false;
    if (!std.mem.startsWith(u8, history_match, line)) return false;

    const history_word_end = tokenEnd(history_match, word_start);
    if (history_word_end <= word_start) return false;

    const history_word = history_match[word_start..history_word_end];
    return !std.mem.eql(u8, history_word, completed_word);
}

fn recomputeGhostSuggestion(
    ctx: *env.ShellCtx,
    line: []const u8,
    cursor_pos: usize,
    state: *GhostSuggestionState,
) void {
    const hash = suggestionHash(line, cursor_pos);
    if (state.cached and state.query_hash == hash) return;

    state.query_hash = hash;
    state.cached = true;
    state.has_suggestion = false;
    state.suggestion_len = 0;

    if (cursor_pos != line.len or line.len < MIN_GHOST_TRIGGER_LEN) return;

    // Use stack scratch space for the fallback completion pass so we don't
    // allocate from long-lived REPL memory during keystroke processing.
    var scratch_mem: [GHOST_SCRATCH_BYTES]u8 = undefined;
    var fixed_alloc = std.heap.FixedBufferAllocator.init(&scratch_mem);
    const scratch = fixed_alloc.allocator();

    const word_completion = autocomplete.getGhostCompletion(ctx, scratch, line, cursor_pos) catch null;
    const history_match = ctx.historySuggest(line);

    if (word_completion) |completed_word| {
        var word_buf: [GHOST_MAX_SUGGESTION_LEN]u8 = undefined;
        const completed_len = buildWordSuggestion(line, cursor_pos, completed_word, &word_buf) orelse {
            return;
        };

        if (history_match) |history| {
            if (isValidHistorySuggestion(line, history, state.suggestion_buf.len) and
                !shouldPreferWordSuggestion(line, cursor_pos, history, completed_word))
            {
                @memcpy(state.suggestion_buf[0..history.len], history);
                state.has_suggestion = true;
                state.suggestion_len = history.len;
                return;
            }
        }

        @memcpy(state.suggestion_buf[0..completed_len], word_buf[0..completed_len]);
        state.has_suggestion = true;
        state.suggestion_len = completed_len;
        return;
    }

    if (history_match) |history| {
        if (isValidHistorySuggestion(line, history, state.suggestion_buf.len)) {
            @memcpy(state.suggestion_buf[0..history.len], history);
            state.has_suggestion = true;
            state.suggestion_len = history.len;
        }
    }
}

fn ghostTailForLine(
    ctx: *env.ShellCtx,
    line: []const u8,
    cursor_pos: usize,
    state: *GhostSuggestionState,
) []const u8 {
    recomputeGhostSuggestion(ctx, line, cursor_pos, state);
    if (!state.has_suggestion) return "";
    const suggestion = state.suggestion_buf[0..state.suggestion_len];
    if (!std.mem.startsWith(u8, suggestion, line)) return "";
    return suggestion[line.len..];
}

fn buildPromptRenderCache(ctx: *env.ShellCtx, arena_alloc: Allocator) !PromptRenderCache {
    return prompt_mod.buildPromptRenderCache(ctx, arena_alloc, "");
}

fn redrawLine(
    prompt: *const PromptRenderCache,
    term_width: usize,
    line: []const u8,
    cursor_pos: usize,
    ghost_tail: []const u8,
    writer: *std.Io.Writer,
) !void {

    // How many lines does the current content span?
    const total_len = prompt.visible_len + line.len + ghost_tail.len;
    const lines_above = prompt.lines_before_input + (total_len / term_width);

    // Move up to the first line
    var i: usize = 0;
    while (i < lines_above) : (i += 1) {
        try writer.writeAll("\x1b[A"); // cursor up
    }

    // move cursor beginning of line
    try writer.writeAll("\r");

    // clear line
    try writer.writeAll("\x1b[J");

    // write prompt and line completion
    try writer.writeAll(prompt.rendered);
    try writeHighlightedInput(line, writer);
    if (ghost_tail.len > 0) {
        try writer.print("\x1b[{s}m{s}\x1b[0m", .{ GHOST_COLOR_ANSI, ghost_tail });
    }

    // move cursor to pos
    const offset = (line.len + ghost_tail.len) - cursor_pos;
    if (offset > 0) {
        try writer.print("\x1b[{d}D", .{offset});
    }
    try writer.flush();
}

fn ringBell(writer: *std.Io.Writer) !void {
    try writer.writeAll(BELL);
    try writer.flush();
}

fn redrawWithGhost(
    ctx: *env.ShellCtx,
    prompt: *const PromptRenderCache,
    term_width: usize,
    buffer: *std.ArrayList(u8),
    cursor_pos: usize,
    ghost_state: *GhostSuggestionState,
    writer: *std.Io.Writer,
) !void {
    const ghost_tail = ghostTailForLine(ctx, buffer.items, cursor_pos, ghost_state);
    try redrawLine(prompt, term_width, buffer.items, cursor_pos, ghost_tail, writer);
}

fn redrawFreshLineWithGhost(
    ctx: *env.ShellCtx,
    prompt: *const PromptRenderCache,
    buffer: *std.ArrayList(u8),
    cursor_pos: usize,
    ghost_state: *GhostSuggestionState,
    writer: *std.Io.Writer,
) !void {
    const ghost_tail = ghostTailForLine(ctx, buffer.items, cursor_pos, ghost_state);
    try writer.writeAll(prompt.rendered);
    try writeHighlightedInput(buffer.items, writer);
    if (ghost_tail.len > 0) {
        try writer.print("\x1b[{s}m{s}\x1b[0m", .{ GHOST_COLOR_ANSI, ghost_tail });
    }

    const offset = (buffer.items.len + ghost_tail.len) - cursor_pos;
    if (offset > 0) {
        try writer.print("\x1b[{d}D", .{offset});
    }
    try writer.flush();
}

fn loadHistoryCommand(
    buffer: *std.ArrayList(u8),
    arena_alloc: Allocator,
    cmd: []const u8,
    cursor_pos: *usize,
) !void {
    buffer.clearRetainingCapacity();
    try buffer.appendSlice(arena_alloc, cmd);
    cursor_pos.* = cmd.len;
}

fn replaceWordAtCursor(
    buffer: *std.ArrayList(u8),
    arena: Allocator,
    cursor_pos: *usize,
    word_start: usize,
    replacement: []const u8,
) !void {
    const remove_len = cursor_pos.* - word_start;
    try buffer.replaceRange(arena, word_start, remove_len, replacement);
    cursor_pos.* = word_start + replacement.len;
}

fn insertCharAtCursor(
    buffer: *std.ArrayList(u8),
    arena_alloc: Allocator,
    cursor_pos: *usize,
    char: u8,
) !void {
    if (cursor_pos.* == buffer.items.len) {
        try buffer.append(arena_alloc, char);
    } else {
        try buffer.insert(arena_alloc, cursor_pos.*, char);
    }
    cursor_pos.* += 1;
}

fn backspaceAtCursor(buffer: *std.ArrayList(u8), cursor_pos: *usize) void {
    if (cursor_pos.* == 0) return;
    cursor_pos.* -= 1;

    if (cursor_pos.* == buffer.items.len - 1) {
        _ = buffer.pop();
    } else {
        _ = buffer.orderedRemove(cursor_pos.*);
    }
}

fn loadAndRedrawHistoryCommand(
    ctx: *env.ShellCtx,
    prompt: *const PromptRenderCache,
    term_width: usize,
    buffer: *std.ArrayList(u8),
    arena_alloc: Allocator,
    cmd: []const u8,
    cursor_pos: *usize,
    ghost_state: *GhostSuggestionState,
    writer: *std.Io.Writer,
) !void {
    try loadHistoryCommand(buffer, arena_alloc, cmd, cursor_pos);
    try redrawWithGhost(ctx, prompt, term_width, buffer, cursor_pos.*, ghost_state, writer);
}

fn historyPrefixMatches(filter: ?[]const u8, cmd: []const u8) bool {
    if (filter) |prefix| {
        if (prefix.len == 0) return true;
        return std.mem.startsWith(u8, cmd, prefix);
    }
    return true;
}

fn effectiveHistoryFilter(filter_text: []const u8) ?[]const u8 {
    return if (filter_text.len == 0) null else filter_text;
}

inline fn cursorHomeTarget() usize {
    return 0;
}

inline fn cursorEndTarget(line_len: usize) usize {
    return line_len;
}

fn killToLineStart(buffer: *std.ArrayList(u8), cursor_pos: *usize) void {
    if (cursor_pos.* == 0) return;
    buffer.replaceRangeAssumeCapacity(0, cursor_pos.*, &.{});
    cursor_pos.* = 0;
}

fn killToLineEnd(buffer: *std.ArrayList(u8), cursor_pos: usize) void {
    if (cursor_pos >= buffer.items.len) return;
    buffer.shrinkRetainingCapacity(cursor_pos);
}

fn deletePreviousWord(buffer: *std.ArrayList(u8), cursor_pos: *usize) void {
    if (cursor_pos.* == 0) return;
    var start = cursor_pos.*;

    while (start > 0 and std.ascii.isWhitespace(buffer.items[start - 1])) : (start -= 1) {}
    while (start > 0 and !std.ascii.isWhitespace(buffer.items[start - 1])) : (start -= 1) {}

    if (start < cursor_pos.*) {
        buffer.replaceRangeAssumeCapacity(start, cursor_pos.* - start, &.{});
        cursor_pos.* = start;
    }
}

fn findPreviousHistoryIndex(ctx: *env.ShellCtx, start_idx: usize, filter: ?[]const u8) ?usize {
    var idx = start_idx;
    while (idx > 0) {
        idx -= 1;
        const cmd = ctx.historyAt(idx) orelse continue;
        if (!historyPrefixMatches(filter, cmd)) continue;
        return idx;
    }
    return null;
}

fn findNextHistoryIndex(ctx: *env.ShellCtx, start_idx: usize, history_size: usize, filter: ?[]const u8) ?usize {
    var idx = start_idx + 1;
    while (idx < history_size) : (idx += 1) {
        const cmd = ctx.historyAt(idx) orelse continue;
        if (!historyPrefixMatches(filter, cmd)) continue;
        return idx;
    }
    return null;
}

fn handleTabCompletion(
    ctx: *env.ShellCtx,
    prompt: *const PromptRenderCache,
    term_width: usize,
    arena: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    cursor_pos: *usize,
    ghost_state: *GhostSuggestionState,
    writer: *std.Io.Writer,
) !void {
    var result = try autocomplete.getCompletions(ctx, arena, buffer.items, cursor_pos.*);

    // CASE: no results, send bell sound escape ASCII
    if (result.completions.len == 0) {
        try ringBell(writer);
        //std.debug.print("NONE\n", .{});
    }

    // CASE: only one result, complete command in cli
    else if (result.completions.len == 1) {
        //std.debug.print("ONE\n", .{});
        // single match = compete immediately
        const completion = result.completions[0].text;

        // get word bounds
        const word_start = autocomplete.findWordStart(buffer.items, cursor_pos.*);
        try replaceWordAtCursor(buffer, arena, cursor_pos, word_start, completion);

        // add default space for non dir completions
        if (result.completions[0].kind != .dir) {
            try buffer.insert(arena, cursor_pos.*, ' ');
            cursor_pos.* += 1;
        }
        // redraw
        try redrawWithGhost(ctx, prompt, term_width, buffer, cursor_pos.*, ghost_state, writer);
    }

    // CASE: more than 10 completions, print out warning and fill prefix only
    else if (result.completions.len > 10) {
        //std.debug.print("> 10\n", .{});
        try writer.writeByte('\n');
        try writer.print("{d} matches for prefix {s}\n", .{ result.completions.len, result.common_prefix });
        try writer.flush();

        // write the common prefix to line for user to complete
        const word_start = autocomplete.findWordStart(buffer.items, cursor_pos.*);
        const current_prefix = buffer.items[word_start..cursor_pos.*];

        if (result.common_prefix.len > current_prefix.len) {
            try replaceWordAtCursor(buffer, arena, cursor_pos, word_start, result.common_prefix);
        }

        try redrawFreshLineWithGhost(ctx, prompt, buffer, cursor_pos.*, ghost_state, writer);
    }
    // CASE: between 2 -> 10 matches, print out options and fill prefix
    else {

        // copy completions to sort them alphabetically
        const completions = try arena.dupe(Completion, result.completions);

        // sort in alphabetical order
        std.mem.sort(Completion, completions, {}, struct {
            fn lessThan(_: void, a: Completion, b: Completion) bool {
                return std.mem.order(u8, a.text, b.text) == .lt;
            }
        }.lessThan);

        // write the common prefix to line for user to complete
        const word_start = autocomplete.findWordStart(buffer.items, cursor_pos.*);
        const current_prefix = buffer.items[word_start..cursor_pos.*];

        const prefix_extended: bool = result.common_prefix.len > current_prefix.len;

        if (prefix_extended) {
            try replaceWordAtCursor(buffer, arena, cursor_pos, word_start, result.common_prefix);
        }

        // multiple matches - always print to cli
        try writer.writeByte('\n');
        for (completions) |comp| {
            try writer.print("{s}  ", .{completionListLabel(comp)});
        }
        try writer.writeByte('\n');
        try writer.flush();

        try redrawFreshLineWithGhost(ctx, prompt, buffer, cursor_pos.*, ghost_state, writer);
    }
}

fn completionListLabel(completion: Completion) []const u8 {
    if (completion.kind != .file and completion.kind != .dir) return completion.text;

    const trimmed = std.mem.trimEnd(u8, completion.text, "/");
    if (trimmed.len == 0) return completion.text;

    const last_sep = std.mem.lastIndexOfScalar(u8, trimmed, '/');
    return if (last_sep) |idx| trimmed[idx + 1 ..] else trimmed;
}

pub fn read(ctx: *env.ShellCtx, arena_alloc: std.mem.Allocator) ![]u8 {
    const io = ctx.io.*;
    var i_buf: [512]u8 = undefined;
    const stdin_file = std.Io.File.stdin();
    var stdin_reader = stdin_file.reader(io, &i_buf);
    const stdin = &stdin_reader.interface;

    const fd = stdin_file.handle;
    var raw_mode = try RawMode.enable(fd);
    defer raw_mode.disable();

    // stdin
    var buffer = try std.ArrayList(u8).initCapacity(arena_alloc, 64);

    var cursor_pos: usize = 0;

    // stdout
    var o_buf: [1024]u8 = undefined;
    var writer = ctx.stdout.writer(ctx.io.*, &o_buf);
    const stdout = &writer.interface;
    const prompt = try buildPromptRenderCache(ctx, arena_alloc);
    var term_width = getTerminalWidth();
    try stdout.writeAll(prompt.rendered);
    try stdout.flush();

    // track command history postion
    const history_size = ctx.historySize();
    const has_history: bool = history_size > 0;
    var h_idx: ?usize = null;

    // start from end (most recent cmd)
    if (has_history) {
        h_idx = history_size; // last element
    }

    var completion_active: bool = false;
    var ghost_state = GhostSuggestionState{};
    var history_prefix_filter: ?[]const u8 = null;
    var reverse_search_query: ?[]const u8 = null;

    while (true) {
        const char = stdin.takeByte() catch |err| switch (err) {
            error.EndOfStream => {
                // treat like Ctrl+D
                return try arena_alloc.dupe(u8, "");
            },
            error.ReadFailed => {
                // VERY COMMON for terminals → treat like EOF
                return try arena_alloc.dupe(u8, "");
            },
        };

        // handle key input
        switch (char) {
            // newline
            '\n', '\r' => {
                try stdout.writeByte('\n');
                try stdout.flush();
                break;
            },
            // tab
            '\t' => {
                // prevent repetitive TAB without modification
                if (completion_active) {
                    try ringBell(stdout);
                    continue;
                }
                try handleTabCompletion(ctx, &prompt, term_width, arena_alloc, &buffer, &cursor_pos, &ghost_state, stdout);
                completion_active = true;
                history_prefix_filter = null;
                reverse_search_query = null;
            },
            // backspace || delete
            BACKSPACE, DEL => {
                if (cursor_pos > 0) {
                    backspaceAtCursor(&buffer, &cursor_pos);
                    try redrawWithGhost(ctx, &prompt, term_width, &buffer, cursor_pos, &ghost_state, stdout);
                    history_prefix_filter = null;
                    reverse_search_query = null;
                }
            },
            // Ctrl+C - Cancel current line
            CTRL_C => {
                try stdout.writeAll("^C\n");
                try stdout.flush();

                // Clear the buffer and return empty string
                buffer.clearAndFree(arena_alloc);
                return try arena_alloc.dupe(u8, "");
            },
            // Ctrl+L- Clear screen
            CTRL_L => {
                try stdout.writeAll("\x1b[2J\x1b[H"); // Clear screen and move to top
                term_width = getTerminalWidth();
                try redrawWithGhost(ctx, &prompt, term_width, &buffer, cursor_pos, &ghost_state, stdout);
                reverse_search_query = null;
            },
            CTRL_A => {
                if (cursor_pos != 0) {
                    cursor_pos = cursorHomeTarget();
                    try redrawWithGhost(ctx, &prompt, term_width, &buffer, cursor_pos, &ghost_state, stdout);
                }
                history_prefix_filter = null;
                reverse_search_query = null;
            },
            CTRL_E => {
                const target = cursorEndTarget(buffer.items.len);
                if (cursor_pos != target) {
                    cursor_pos = target;
                    try redrawWithGhost(ctx, &prompt, term_width, &buffer, cursor_pos, &ghost_state, stdout);
                }
                history_prefix_filter = null;
                reverse_search_query = null;
            },
            CTRL_U => {
                if (cursor_pos > 0) {
                    killToLineStart(&buffer, &cursor_pos);
                    try redrawWithGhost(ctx, &prompt, term_width, &buffer, cursor_pos, &ghost_state, stdout);
                }
                history_prefix_filter = null;
                reverse_search_query = null;
            },
            CTRL_K => {
                if (cursor_pos < buffer.items.len) {
                    killToLineEnd(&buffer, cursor_pos);
                    try redrawWithGhost(ctx, &prompt, term_width, &buffer, cursor_pos, &ghost_state, stdout);
                }
                history_prefix_filter = null;
                reverse_search_query = null;
            },
            CTRL_W => {
                if (cursor_pos > 0) {
                    deletePreviousWord(&buffer, &cursor_pos);
                    try redrawWithGhost(ctx, &prompt, term_width, &buffer, cursor_pos, &ghost_state, stdout);
                }
                history_prefix_filter = null;
                reverse_search_query = null;
            },
            // Ctrl+R - reverse search through history
            CTRL_R => {
                if (!has_history) {
                    try ringBell(stdout);
                    continue;
                }
                if (reverse_search_query == null) {
                    reverse_search_query = try arena_alloc.dupe(u8, buffer.items);
                }
                const query = reverse_search_query.?;
                const start_idx = h_idx orelse history_size;
                const filter = effectiveHistoryFilter(query);

                if (findPreviousHistoryIndex(ctx, start_idx, filter)) |match_idx| {
                    h_idx = match_idx;
                    const cmd = ctx.historyAt(match_idx) orelse {
                        try ringBell(stdout);
                        continue;
                    };
                    try loadAndRedrawHistoryCommand(
                        ctx,
                        &prompt,
                        term_width,
                        &buffer,
                        arena_alloc,
                        cmd,
                        &cursor_pos,
                        &ghost_state,
                        stdout,
                    );
                } else {
                    try ringBell(stdout);
                }
            },
            // escape char to check for arrow key press
            ESC => {
                // read next two bytes
                const escaped = try stdin.take(2);

                if (escaped[0] == '[') {
                    reverse_search_query = null;
                    switch (escaped[1]) {
                        // LEFT
                        'D' => {
                            if (cursor_pos > 0) {
                                const was_at_end = cursor_pos == buffer.items.len;
                                const had_ghost = was_at_end and ghostTailForLine(ctx, buffer.items, cursor_pos, &ghost_state).len > 0;
                                cursor_pos -= 1;
                                if (had_ghost) {
                                    try redrawWithGhost(ctx, &prompt, term_width, &buffer, cursor_pos, &ghost_state, stdout);
                                } else {
                                    try stdout.writeAll(CURSOR_LEFT);
                                    try stdout.flush();
                                }
                            }
                        },
                        // RIGHT
                        'C' => {
                            const ghost_tail = ghostTailForLine(ctx, buffer.items, cursor_pos, &ghost_state);
                            if (cursor_pos == buffer.items.len and ghost_tail.len > 0) {
                                try buffer.appendSlice(arena_alloc, ghost_tail);
                                cursor_pos = buffer.items.len;
                                try redrawWithGhost(ctx, &prompt, term_width, &buffer, cursor_pos, &ghost_state, stdout);
                            } else if (cursor_pos < buffer.items.len) {
                                cursor_pos += 1;
                                if (cursor_pos == buffer.items.len and ghostTailForLine(ctx, buffer.items, cursor_pos, &ghost_state).len > 0) {
                                    try redrawWithGhost(ctx, &prompt, term_width, &buffer, cursor_pos, &ghost_state, stdout);
                                } else {
                                    try stdout.writeAll(CURSOR_RIGHT);
                                    try stdout.flush();
                                }
                            }
                        },
                        // UP history
                        'A' => {
                            if (h_idx) |idx| {
                                if (idx == history_size and history_prefix_filter == null and buffer.items.len > 0) {
                                    history_prefix_filter = try arena_alloc.dupe(u8, buffer.items);
                                }

                                if (findPreviousHistoryIndex(ctx, idx, history_prefix_filter)) |match_idx| {
                                    h_idx.? = match_idx;
                                    const cmd = ctx.historyAt(match_idx) orelse {
                                        try ringBell(stdout);
                                        continue;
                                    };

                                    try loadAndRedrawHistoryCommand(
                                        ctx,
                                        &prompt,
                                        term_width,
                                        &buffer,
                                        arena_alloc,
                                        cmd,
                                        &cursor_pos,
                                        &ghost_state,
                                        stdout,
                                    );
                                } else {
                                    try ringBell(stdout);
                                }
                            } else {
                                // NO HISTORY, BELL ALERT
                                try ringBell(stdout);
                            }
                        },
                        // DOWN history
                        'B' => {
                            if (h_idx) |idx| {
                                if (idx < history_size) {
                                    if (findNextHistoryIndex(ctx, idx, history_size, history_prefix_filter)) |match_idx| {
                                        h_idx.? = match_idx;

                                        const cmd = ctx.historyAt(match_idx) orelse {
                                            try ringBell(stdout);
                                            continue;
                                        };

                                        try loadAndRedrawHistoryCommand(
                                            ctx,
                                            &prompt,
                                            term_width,
                                            &buffer,
                                            arena_alloc,
                                            cmd,
                                            &cursor_pos,
                                            &ghost_state,
                                            stdout,
                                        );
                                    } else {
                                        buffer.clearAndFree(arena_alloc);
                                        if (history_prefix_filter) |prefix| {
                                            try buffer.appendSlice(arena_alloc, prefix);
                                        }
                                        cursor_pos = buffer.items.len;
                                        h_idx.? = history_size;
                                        history_prefix_filter = null;
                                        reverse_search_query = null;
                                        try redrawWithGhost(ctx, &prompt, term_width, &buffer, cursor_pos, &ghost_state, stdout);
                                    }
                                } else {
                                    try ringBell(stdout);
                                }
                            } else {
                                // NO HISTORY, BELL ALERT
                                try ringBell(stdout);
                            }
                        },
                        else => {},
                    }
                }
            },
            // any other printable ASCII character
            else => {
                if (char >= 32 and char < 127) {
                    try insertCharAtCursor(&buffer, arena_alloc, &cursor_pos, char);
                    // Always redraw so inline highlighting stays current.
                    try redrawWithGhost(ctx, &prompt, term_width, &buffer, cursor_pos, &ghost_state, stdout);
                    history_prefix_filter = null;
                    reverse_search_query = null;
                }
            },
        }

        // keep TAB behavior fish-like: a second immediate TAB rings until
        // another key mutates state.
        if (completion_active and char != '\t') {
            completion_active = false;
        }
    }
    return buffer.items;
}

test "isBuiltinCommand highlights known builtin names" {
    try std.testing.expect(isBuiltinCommand("echo"));
    try std.testing.expect(!isBuiltinCommand("not-a-command"));
}

test "replaceWordAtCursor replaces current prefix in-place" {
    var buf = try std.ArrayList(u8).initCapacity(std.testing.allocator, 16);
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, "git st");
    var cursor_pos: usize = buf.items.len;

    try replaceWordAtCursor(&buf, std.testing.allocator, &cursor_pos, 4, "status");
    try std.testing.expectEqualStrings("git status", buf.items);
    try std.testing.expectEqual(@as(usize, 10), cursor_pos);
}

test "isSeparatorStart detects pipeline and control separators" {
    try std.testing.expectEqual(@as(?usize, 1), isSeparatorStart("|", 0));
    try std.testing.expectEqual(@as(?usize, 2), isSeparatorStart("||", 0));
    try std.testing.expectEqual(@as(?usize, 2), isSeparatorStart("&&", 0));
    try std.testing.expectEqual(@as(?usize, 1), isSeparatorStart(";", 0));
}

test "historyPrefixMatches honors optional prefix filter" {
    try std.testing.expect(historyPrefixMatches(null, "echo hello"));
    try std.testing.expect(historyPrefixMatches("", "echo hello"));
    try std.testing.expect(historyPrefixMatches("echo", "echo hello"));
    try std.testing.expect(!historyPrefixMatches("git", "echo hello"));
}

test "buildWordSuggestion expands only the active token" {
    var buf: [GHOST_MAX_SUGGESTION_LEN]u8 = undefined;
    const len = buildWordSuggestion("cd e", 4, "embedded/", &buf) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("cd embedded/", buf[0..len]);
}

test "shouldPreferWordSuggestion prefers argument completion over mismatched history token" {
    try std.testing.expect(shouldPreferWordSuggestion("cd ./e", 6, "cd ./embedded", "embedded/"));
}

test "shouldPreferWordSuggestion keeps history priority for first-word completions and matching tokens" {
    try std.testing.expect(!shouldPreferWordSuggestion("ec", 2, "echo hello", "echo"));
    try std.testing.expect(!shouldPreferWordSuggestion("git ch", 6, "git checkout main", "checkout"));
}

test "effectiveHistoryFilter maps empty query to null" {
    try std.testing.expect(effectiveHistoryFilter("") == null);
    const filter = effectiveHistoryFilter("echo") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("echo", filter);
}

test "cursor target helpers return expected positions" {
    try std.testing.expectEqual(@as(usize, 0), cursorHomeTarget());
    try std.testing.expectEqual(@as(usize, 7), cursorEndTarget(7));
}

test "killToLineStart removes prefix before cursor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf = std.ArrayList(u8).initCapacity(arena.allocator(), 8) catch unreachable;
    defer buf.deinit(arena.allocator());
    buf.appendSlice(arena.allocator(), "echo test") catch unreachable;
    var cursor: usize = 5;

    killToLineStart(&buf, &cursor);
    try std.testing.expectEqual(@as(usize, 0), cursor);
    try std.testing.expectEqualStrings("test", buf.items);
}

test "killToLineEnd removes suffix after cursor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf = std.ArrayList(u8).initCapacity(arena.allocator(), 8) catch unreachable;
    defer buf.deinit(arena.allocator());
    buf.appendSlice(arena.allocator(), "echo test") catch unreachable;

    killToLineEnd(&buf, 4);
    try std.testing.expectEqualStrings("echo", buf.items);
}

test "deletePreviousWord removes previous token and spaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf = std.ArrayList(u8).initCapacity(arena.allocator(), 16) catch unreachable;
    defer buf.deinit(arena.allocator());
    buf.appendSlice(arena.allocator(), "echo hello world") catch unreachable;
    var cursor = buf.items.len;

    deletePreviousWord(&buf, &cursor);
    try std.testing.expectEqualStrings("echo hello ", buf.items);
}
