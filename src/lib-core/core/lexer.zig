const std = @import("std");
const helpers = @import("helpers.zig");
const Allocator = std.mem.Allocator;

/// Supported token types
pub const TokenKind = enum {
    Command,
    Arg,
    Pipe, // |  - stdin/stdout pipe
    Redirect, // >, >>, 2>
    Bg, // &  - background job
    Semicolon, // ;  - sequence (run next regardless)
    And, // && - run next if success
    Or, // || - run next if failure
    GroupStart, // {
    GroupEnd, // }
    Assignment, // Inline variable assignment X=value
    Expr, // Inline expression for expansion $(...)
    Var, // $VAR
    Void,
    // TODO: more context for tokenization
    //Literal,
    //Operator,
    //FilePath,
};

/// Semantic tokens after parsing input
pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    single_quoted: bool = false,
};

/// Lazy lexer that tokenizes input one string at a time
pub const Lexer = struct {
    input: []const u8,
    pos: usize = 0,

    pub fn init(input: []const u8) Lexer {
        return .{ .input = input };
    }

    // Returns null when done
    pub fn next(self: *Lexer, allocator: Allocator) !?Token {
        // Skip whitespace
        while (self.pos < self.input.len and std.ascii.isWhitespace(self.input[self.pos])) {
            self.pos += 1;
        }
        if (self.pos >= self.input.len) return null;

        const start = self.pos;
        const char = self.input[self.pos];

        // 1. Handle Operators (Fast Path)
        // Check single char operators
        const op_kind: ?TokenKind = switch (char) {
            '|' => if (self.peek(1, "|")) .Or else .Pipe,
            '&' => if (self.peek(1, ">>")) .Redirect // &>>
            else if (self.peek(1, ">")) .Redirect // &>
            else if (self.peek(1, "&")) .And else .Bg,

            ';' => .Semicolon,
            '{' => .GroupStart,
            '}' => .GroupEnd,
            '>' => .Redirect,
            '1' => if (self.peek(1, ">")) .Redirect else null,

            '2' => if (self.peek(1, ">&1")) .Redirect // 2>&1
            else if (self.peek(1, ">>")) .Redirect // 2>>
            else if (self.peek(1, ">")) .Redirect // 2>
            else null,
            '<' => .Redirect, // not impl yet
            else => null,
        };

        if (op_kind) |kind| {
            var len: usize = 1;
            // Check double char ops (||, &&)
            if ((kind == .Or or kind == .And) and self.pos + 1 < self.input.len) {
                len = 2;
            }

            if (kind == .Redirect) {
                if (char == '2') {
                    if (self.peek(2, "&1")) {
                        len = 4;
                    } // 2>&1
                    else if (self.peek(2, ">")) {
                        len = 3;
                    } // 2>>
                    else {
                        len = 2;
                    } // 2>
                } else if (char == '&') {
                    if (self.peek(2, ">")) {
                        len = 3;
                    } // &>>
                    else {
                        len = 2;
                    } // &>
                } else if (char == '1') {
                    if (self.peek(2, ">")) {
                        len = 3;
                    } // 1>>
                    else {
                        len = 2;
                    } // 1>
                } else {
                    // plain > or >>
                    if (self.peek(1, ">")) {
                        len = 2;
                    }
                }
            }

            // Create text slice from original input (Zero Copy)
            const text = self.input[self.pos .. self.pos + len];
            self.pos += len;
            return Token{ .kind = kind, .text = text };
        }

        // 2. Handle Words / Strings / Vars
        return try self.scanWord(allocator, start);
    }

    fn peek(self: *Lexer, offset: usize, match: []const u8) bool {
        if (self.pos + offset >= self.input.len) return false;
        return std.mem.startsWith(u8, self.input[self.pos + offset ..], match);
    }

    fn scanWord(self: *Lexer, allocator: Allocator, start: usize) !Token {
        var in_double_quote = false;
        var in_single_quote = false;
        var paren_depth: usize = 0;
        var needs_processing = false; // Track if we need to allocate/unescape
        var was_single_quoted = false;

        while (self.pos < self.input.len) {
            const c = self.input[self.pos];

            // Complex logic simplified:
            // Just scan for delimiters. If we hit quotes or escapes, mark needs_processing = true
            if (c == '\\') {
                needs_processing = true;
                // Consume escape and, when present, the escaped byte.
                // Clamp at input end to avoid out-of-bounds slicing on trailing '\'.
                if (self.pos + 1 < self.input.len) {
                    self.pos += 2;
                } else {
                    self.pos += 1;
                }
                continue;
            } else if (c == '\'') {
                if (!in_double_quote) {
                    in_single_quote = !in_single_quote;
                    needs_processing = true; // We need to strip the quotes later
                    was_single_quoted = true;
                }
            } else if (c == '"') {
                if (!in_single_quote) {
                    in_double_quote = !in_double_quote;
                    needs_processing = true;
                }
            } else if (c == '$' and !in_single_quote) {
                // Check for $(...)
                if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '(') {
                    paren_depth += 1;
                    self.pos += 1;
                }
            } else if (c == ')' and paren_depth > 0) {
                paren_depth -= 1;
            } else if (std.ascii.isWhitespace(c) or isMetaChar(c)) {
                // End of word (unless quoted or in subshell)
                if (!in_double_quote and !in_single_quote and paren_depth == 0) {
                    break;
                }
            }
            self.pos += 1;
        }

        const raw_slice = self.input[start..self.pos];

        // Optimization: If it was a simple word (ls, -la, /bin/foo), return the slice immediately.
        // No allocation happens here!
        if (!needs_processing) {
            return determineKind(raw_slice);
        }

        // Slow Path: We have quotes or escapes. We must allocate to clean them.
        const cleaned = try self.cleanString(allocator, raw_slice);
        var token = determineKind(cleaned);
        token.single_quoted = was_single_quoted;
        return token;
    }

    fn cleanString(self: *Lexer, allocator: Allocator, raw: []const u8) ![]const u8 {
        _ = self;
        // Pre-allocate buffer to exact size to avoid reallocs
        var token_string = try std.ArrayList(u8).initCapacity(allocator, raw.len);

        var in_double_quotes: bool = false;
        var in_single_quotes: bool = false;
        var is_escaped: bool = false;
        var paren_depth: usize = 0; // Track $() nesting depth

        var i: usize = 0;
        while (i < raw.len) {
            const char = raw[i];

            // In quotes
            if (in_double_quotes) {
                if (char == '"') {
                    if (is_escaped) {
                        try token_string.append(allocator, char);
                        i += 1;
                        is_escaped = false;
                        continue;
                    } else {
                        in_double_quotes = false;
                        i += 1;
                        continue;
                    }
                } else {
                    if (is_escaped) {
                        if (char == '\\') {
                            try token_string.append(allocator, char);
                        } else {
                            try token_string.append(allocator, '\\');
                            try token_string.append(allocator, char);
                        }
                        is_escaped = false;
                        i += 1;
                    } else {
                        if (char == '\\' and i < raw.len - 1) {
                            is_escaped = true;
                            i += 1;
                            continue;
                        }

                        // Track $() even inside double quotes (they expand in double quotes)
                        if (char == '$' and i + 1 < raw.len and raw[i + 1] == '(') {
                            paren_depth += 1;
                            try token_string.append(allocator, char); // append $
                            i += 1;
                            try token_string.append(allocator, raw[i]); // append (
                            i += 1;
                            continue;
                        }

                        if (char == '(' and paren_depth > 0) {
                            paren_depth += 1;
                        } else if (char == ')' and paren_depth > 0) {
                            paren_depth -= 1;
                        }

                        try token_string.append(allocator, char);
                        i += 1;
                    }
                }
            } else if (in_single_quotes) {
                if (char == '\'') {
                    in_single_quotes = false;
                    i += 1;
                } else {
                    try token_string.append(allocator, char);
                    i += 1;
                }
            } else {
                // escaped with \
                if (is_escaped) {
                    try token_string.append(allocator, char);
                    i += 1;
                    is_escaped = false;
                    continue;
                }

                // Not in quotes
                if (char == '"') {
                    in_double_quotes = true;
                    i += 1;
                } else if (char == '\'') {
                    in_single_quotes = true;
                    i += 1;
                } else if (char == '\\') {
                    is_escaped = true;
                    i += 1;
                } else if (char == '$' and i + 1 < raw.len and raw[i + 1] == '(') {
                    // Start of $() expression - track depth
                    paren_depth += 1;
                    try token_string.append(allocator, char); // append $
                    i += 1;
                    try token_string.append(allocator, raw[i]); // append (
                    i += 1;
                } else if (char == '(' and paren_depth > 0) {
                    // Nested ( inside $()
                    paren_depth += 1;
                    try token_string.append(allocator, char);
                    i += 1;
                } else if (char == ')' and paren_depth > 0) {
                    // Closing ) for $()
                    paren_depth -= 1;
                    try token_string.append(allocator, char);
                    i += 1;
                } else if (std.ascii.isWhitespace(char)) {
                    // Only end token if we're not inside $()
                    if (paren_depth == 0) {
                        break;
                    } else {
                        // Inside $(), preserve the whitespace
                        try token_string.append(allocator, char);
                        i += 1;
                    }
                } else {
                    try token_string.append(allocator, char);
                    i += 1;
                }
            }
        }
        return token_string.toOwnedSlice(allocator);
    }
};

/// Table containing valid token sequences
const ValidTransitions = struct {
    // Lookup table: [from_state][to_state] -> is_valid
    const allowed = init: {
        @setEvalBranchQuota(10000);
        const kind_count = @typeInfo(TokenKind).@"enum".fields.len;
        var table: [kind_count][kind_count]bool = undefined;

        // Initialize all to false
        for (&table) |*row| {
            for (row) |*cell| {
                cell.* = false;
            }
        }

        const V = @intFromEnum(TokenKind.Void);
        const C = @intFromEnum(TokenKind.Command);
        const A = @intFromEnum(TokenKind.Arg);
        const P = @intFromEnum(TokenKind.Pipe);
        const S = @intFromEnum(TokenKind.Semicolon);
        const And = @intFromEnum(TokenKind.And);
        const Or = @intFromEnum(TokenKind.Or);
        const R = @intFromEnum(TokenKind.Redirect);
        const B = @intFromEnum(TokenKind.Bg);
        const Gs = @intFromEnum(TokenKind.GroupStart);
        const Ge = @intFromEnum(TokenKind.GroupEnd);
        const Assign = @intFromEnum(TokenKind.Assignment);
        const Expr = @intFromEnum(TokenKind.Expr);
        const Var = @intFromEnum(TokenKind.Var);

        // From Void (start): only Command, Assignment, Var, Expr
        table[V][C] = true;
        table[V][Assign] = true;
        table[V][Var] = true;
        table[V][Expr] = true;

        // From Command: Arg, Pipe, Semicolon, And, Or, Redirect, Bg, Expr, Var, Assignment (for export)
        table[C][A] = true;
        table[C][P] = true;
        table[C][S] = true;
        table[C][And] = true;
        table[C][Or] = true;
        table[C][R] = true;
        table[C][B] = true;
        table[C][Expr] = true;
        table[C][Var] = true;
        table[C][Assign] = true;

        // From Assignment:
        // - command prefixes (X=1 cmd)
        // - standalone assignment chains (X=1 Y=2)
        // - list operators when assignment is the full command
        table[Assign][C] = true;
        table[Assign][Assign] = true;
        table[Assign][P] = true;
        table[Assign][S] = true;
        table[Assign][And] = true;
        table[Assign][Or] = true;

        // From Arg: Arg, Pipe, Semicolon, And, Or, Redirect, Bg, Expr, Var
        table[A][A] = true;
        table[A][P] = true;
        table[A][S] = true;
        table[A][And] = true;
        table[A][Or] = true;
        table[A][R] = true;
        table[A][B] = true;
        table[A][Expr] = true;
        table[A][Var] = true;

        // From Pipe: Command, Expr, Var, Assignment
        table[P][C] = true;
        table[P][Assign] = true;
        table[P][Expr] = true;
        table[P][Var] = true;

        // From Semicolon: Command, Expr, Var, Assignment
        table[S][C] = true;
        table[S][Assign] = true;
        table[S][Expr] = true;
        table[S][Var] = true;

        // From And: Command, Expr, Var, Assignment
        table[And][C] = true;
        table[And][Assign] = true;
        table[And][Expr] = true;
        table[And][Var] = true;

        // From Or: Command, Expr, Var, Assignment
        table[Or][C] = true;
        table[Or][Assign] = true;
        table[Or][Expr] = true;
        table[Or][Var] = true;

        // From Redirect:
        // - path-bearing redirects require a following target token (validated below)
        // - merge redirect (2>&1) may be followed by another redirect or operators
        table[R][A] = true;
        table[R][Var] = true;
        table[R][Expr] = true;
        table[R][R] = true;
        table[R][P] = true;
        table[R][S] = true;
        table[R][And] = true;
        table[R][Or] = true;
        table[R][B] = true;

        // From Expr: all allowed except Void, Command, Assign
        table[Expr][A] = true;
        table[Expr][P] = true;
        table[Expr][S] = true;
        table[Expr][And] = true;
        table[Expr][Or] = true;
        table[Expr][R] = true;
        table[Expr][B] = true;
        table[Expr][Expr] = true;
        table[Expr][Var] = true;

        // From Var: all allowed except Void, Command, Assign
        table[Var][A] = true;
        table[Var][P] = true;
        table[Var][S] = true;
        table[Var][And] = true;
        table[Var][Or] = true;
        table[Var][R] = true;
        table[Var][B] = true;
        table[Var][Expr] = true;
        table[Var][Var] = true;

        // From Bg: nothing allowed (must be last)
        // (all remain false)
        _ = Gs;
        _ = Ge;

        break :init table;
    };

    // Additional context-aware checks that can't be expressed in simple transition table
    inline fn isValidPosition(kind: TokenKind, idx: usize, len: usize) bool {
        return switch (kind) {
            .Pipe, .And, .Or => idx != 0 and idx != len - 1,
            .Bg => idx == len - 1,
            .Semicolon => idx != 0,
            .GroupStart, .GroupEnd => false,
            else => true,
        };
    }
};

/// Validation of token sequence using ValidTransitions table
pub fn validateTokenSequence(tokens: []const Token) !void {
    if (tokens.len == 0) return error.EmptyTokenSequence;
    var prev_kind: TokenKind = .Void;

    for (tokens, 0..) |token, idx| {
        const curr_kind = token.kind;
        if (!ValidTransitions.isValidPosition(curr_kind, idx, tokens.len))
            return error.InvalidTokenSequence;
        const from = @intFromEnum(prev_kind);
        const to = @intFromEnum(curr_kind);
        if (!ValidTransitions.allowed[from][to])
            return error.InvalidTokenSequence;

        // Redirect must be followed by a path token, except merge redirects (2>&1)
        if (curr_kind == .Redirect and !std.mem.eql(u8, token.text, "2>&1")) {
            if (idx + 1 >= tokens.len) return error.InvalidTokenSequence;
            const next_kind = tokens[idx + 1].kind;
            if (next_kind != .Arg and next_kind != .Var and next_kind != .Expr) return error.InvalidTokenSequence;
        }

        prev_kind = curr_kind;
    }
}

// ---- INTERNAL HELPERS FOR LEXER

fn isMetaChar(c: u8) bool {
    return switch (c) {
        '|', '&', ';', '>', '<' => true,
        '{', '}' => true,
        else => false,
    };
}

fn determineKind(text: []const u8) Token {
    if (std.mem.startsWith(u8, text, "$(")) return .{ .kind = .Expr, .text = text };

    // Vars start with $, but not $(
    if (std.mem.startsWith(u8, text, "$")) return .{ .kind = .Var, .text = text };

    // Check for Assignment: Must contain '=' but not start with it
    if (helpers.isAssignment(text)) {
        return .{ .kind = .Assignment, .text = text };
    }

    // Default to Arg (Will be upgraded to Command by the loop if needed)
    return .{ .kind = .Arg, .text = text };
}

//
// ----- TESTS ----- //
//

test "lexer functions" {
    // determineKind
    try std.testing.expect(determineKind("VAR=value").kind == .Assignment);
    try std.testing.expect(determineKind("$VAR").kind == .Var);
    try std.testing.expect(determineKind("$(expr 1 + 1)").kind == .Expr);
    try std.testing.expect(determineKind("command").kind == .Arg);
    try std.testing.expect(determineKind("-arg").kind == .Arg);

    // isMetaChar
    try std.testing.expect(isMetaChar('|'));
    try std.testing.expect(isMetaChar('&'));
    try std.testing.expect(isMetaChar(';'));
    try std.testing.expect(isMetaChar('>'));
    try std.testing.expect(isMetaChar('<'));
    try std.testing.expect(isMetaChar('{'));
    try std.testing.expect(isMetaChar('}'));
    try std.testing.expect(!isMetaChar('a'));
    try std.testing.expect(!isMetaChar('1'));
}

test "lexer tokenizes command groups" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var lex = Lexer.init("{ls; ls} >> out");

    const tok0 = (try lex.next(allocator)).?;
    try std.testing.expectEqual(TokenKind.GroupStart, tok0.kind);

    const tok1 = (try lex.next(allocator)).?;
    try std.testing.expectEqual(TokenKind.Arg, tok1.kind);
    try std.testing.expectEqualStrings("ls", tok1.text);

    const tok2 = (try lex.next(allocator)).?;
    try std.testing.expectEqual(TokenKind.Semicolon, tok2.kind);

    const tok3 = (try lex.next(allocator)).?;
    try std.testing.expectEqual(TokenKind.Arg, tok3.kind);
    try std.testing.expectEqualStrings("ls", tok3.text);

    const tok4 = (try lex.next(allocator)).?;
    try std.testing.expectEqual(TokenKind.GroupEnd, tok4.kind);

    const tok5 = (try lex.next(allocator)).?;
    try std.testing.expectEqual(TokenKind.Redirect, tok5.kind);
    try std.testing.expectEqualStrings(">>", tok5.text);

    const tok6 = (try lex.next(allocator)).?;
    try std.testing.expectEqual(TokenKind.Arg, tok6.kind);
    try std.testing.expectEqualStrings("out", tok6.text);

    try std.testing.expect((try lex.next(allocator)) == null);
}

test "validateTokenSequence allows merge redirect before list operator" {
    const tokens = [_]Token{
        .{ .kind = .Command, .text = "ls" },
        .{ .kind = .Arg, .text = "/missing" },
        .{ .kind = .Redirect, .text = ">" },
        .{ .kind = .Arg, .text = "/dev/null" },
        .{ .kind = .Redirect, .text = "2>&1" },
        .{ .kind = .Or, .text = "||" },
        .{ .kind = .Command, .text = "echo" },
        .{ .kind = .Arg, .text = "fallback" },
    };
    try validateTokenSequence(tokens[0..]);
}

test "lexer handles trailing backslash without panic" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    {
        var lex = Lexer.init("\\");
        const tok = try lex.next(allocator);
        try std.testing.expect(tok != null);
        try std.testing.expectEqual(@as(usize, 1), lex.pos);
        try std.testing.expect((try lex.next(allocator)) == null);
    }

    {
        var lex = Lexer.init("echo hi\\");
        const tok0 = (try lex.next(allocator)).?;
        try std.testing.expectEqual(TokenKind.Arg, tok0.kind);
        try std.testing.expectEqualStrings("echo", tok0.text);

        const tok1 = (try lex.next(allocator)).?;
        try std.testing.expectEqual(TokenKind.Arg, tok1.kind);
        try std.testing.expectEqual(@as(usize, 8), lex.pos);
        try std.testing.expect((try lex.next(allocator)) == null);
    }
}
