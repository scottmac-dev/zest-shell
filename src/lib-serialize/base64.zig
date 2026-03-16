const std = @import("std");

// BASE64 inclusive of A-Z, a-z, 0-9, +/
// = used for end of string and null values

pub const Base64 = struct {
    _table: *const [64]u8, // all potential bas64 chars

    pub fn init() Base64 {
        const upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
        const lower = "abcdefghijklmnopqrstuvwxyz";
        const numbers_symb = "0123456789+/";
        return Base64{
            ._table = upper ++ lower ++ numbers_symb,
        };
    }

    // get char at index
    pub fn _char_at(self: Base64, index: usize) u8 {
        return self._table[index];
    }

    // get index of char
    pub fn _char_index(self: Base64, char: u8) u8 {
        if (char == '=')
            return 64;
        var idx: u8 = 0;
        for (0..63) |i| {
            if (self._char_at(i) == char)
                break;
            idx += 1;
        }
        return idx;
    }

    fn _calc_encode_length(input: []const u8) !usize {
        if (input.len < 3) {
            return 4;
        }
        const n_groups: usize = try std.math.divCeil(usize, input.len, 3);
        return n_groups * 4;
    }

    fn _calc_decode_length(input: []const u8) !usize {
        if (input.len < 4) {
            return 3;
        }
        const n_groups: usize = try std.math.divFloor(usize, input.len, 4);
        var multiple_groups: usize = n_groups * 3;
        var i: usize = input.len - 1;
        // handle null character/'s '=' at end of decode input
        while (i > 0) : (i -= 1) {
            if (input[i] == '=') {
                multiple_groups -= 1;
            } else {
                break;
            }
        }

        return multiple_groups;
    }

    pub fn encode(self: Base64, alloc: std.mem.Allocator, input: []const u8) ![]u8 {
        if (input.len == 0) {
            return "";
        }

        // allocate heap mem space for output
        const n_out = try _calc_encode_length(input);
        var out = try alloc.alloc(u8, n_out);

        // process and encode 3 bytes of input at a time until completion
        var buf = [3]u8{ 0, 0, 0 };
        var count: u8 = 0;
        var iout: u64 = 0;

        for (input, 0..) |_, i| {
            buf[count] = input[i]; // get char byte
            count += 1;
            // case: full 3 bytes
            if (count == 3) {
                out[iout] = self._char_at(buf[0] >> 2);
                out[iout + 1] = self._char_at(((buf[0] & 0x03) << 4) + (buf[1] >> 4));
                out[iout + 2] = self._char_at(((buf[1] & 0x0f) << 2) + (buf[2] >> 6));
                out[iout + 3] = self._char_at(buf[2] & 0x3f);
                iout += 4; // running sum of output index
                count = 0; // reset for next 3 bytes processing
            }
        }

        // Remainder bytes cases
        // 1 byte remaining
        if (count == 1) {
            out[iout] = self._char_at(buf[0] >> 2);
            out[iout + 1] = self._char_at((buf[0] & 0x03) << 4 // remainder 2 bits from shift
            );
            out[iout + 2] = '='; // null
            out[iout + 3] = '='; // null
        }

        // 2 bytes remaining
        if (count == 2) {
            out[iout] = self._char_at(buf[0] >> 2);
            out[iout + 1] = self._char_at((buf[0] & 0x03) << 4) + (buf[1] >> 4);
            out[iout + 2] = self._char_at((buf[1] & 0x0f) << 2 // remainder 4 bits from shift
            );
            out[iout + 3] = '='; // null
            iout += 4;
        }

        return out;
    }

    pub fn decode(self: Base64, alloc: std.mem.Allocator, input: []const u8) ![]u8 {
        if (input.len == 0) {
            return "";
        }

        // create output buffer
        const n_output = try _calc_decode_length(input);
        var output = try alloc.alloc(u8, n_output);

        var count: u8 = 0; // loop count
        var iout: u64 = 0; // output index tracker
        var buf = [4]u8{ 0, 0, 0, 0 }; // decode 4 bytes at a time

        for (0..input.len) |i| {
            // convert base64 to index for reverse engineering encoding
            buf[count] = self._char_index(input[i]);
            count += 1;

            // work in groups of 4 bytes to convert back to original 3 bytes
            if (count == 4) {
                output[iout] = (buf[0] << 2) + (buf[1] >> 4);

                // ignore 64 index '=' which are null placeholders
                if (buf[2] != 64) {
                    output[iout + 1] = (buf[1] << 4) + (buf[2] >> 2);
                }
                if (buf[3] != 64) {
                    output[iout + 2] = (buf[2] << 6) + buf[3];
                }
                iout += 3; // increment output
                count = 0; // reset count for next loop
            }
        }
        return output;
    }
};

//pub fn main() !void {}

test "test char_at" {
    var base64 = Base64.init();
    const res: [4]u8 = "A/f4".*;
    try std.testing.expectEqual(base64._char_at(0), res[0]);
    try std.testing.expectEqual(base64._char_at(63), res[1]);
    try std.testing.expectEqual(base64._char_at(31), res[2]);
    try std.testing.expectEqual(base64._char_at(56), res[3]);
}

test "test encode" {
    var base64 = Base64.init();
    const alloc = std.testing.allocator;

    // inputs
    const t1: []const u8 = "Hello";
    const t2: []const u8 = "a longer test string";
    const t3: []const u8 = "password456";
    const t4: []const u8 = "!";
    const t5: []const u8 = "";

    // expected outputs
    const r1: []const u8 = "SGVsbG8=";
    const r2: []const u8 = "YSBsb25nZXIgdGVzdCBzdHJpbmc=";
    const r3: []const u8 = "cGFzc3dvcmQ0NTY=";
    const r4: []const u8 = "IQ==";
    const r5: []const u8 = "";

    {
        const o1 = try base64.encode(alloc, t1);
        defer alloc.free(o1);
        try std.testing.expectEqualStrings(o1, r1);
    }
    {
        const o2 = try base64.encode(alloc, t2);
        defer alloc.free(o2);
        try std.testing.expectEqualStrings(o2, r2);
    }
    {
        const o3 = try base64.encode(alloc, t3);
        defer alloc.free(o3);
        try std.testing.expectEqualStrings(o3, r3);
    }
    {
        const o4 = try base64.encode(alloc, t4);
        defer alloc.free(o4);
        try std.testing.expectEqualStrings(o4, r4);
    }
    {
        const o5 = try base64.encode(alloc, t5);
        defer alloc.free(o5);
        try std.testing.expectEqualStrings(o5, r5);
    }
}
test "test decode" {
    var base64 = Base64.init();
    const alloc = std.testing.allocator;

    // inputs
    const t1: []const u8 = "Hello";
    const t2: []const u8 = "a longer test string";
    const t3: []const u8 = "password456";
    const t4: []const u8 = "!";
    const t5: []const u8 = "";

    // expected outputs
    const r1: []const u8 = "SGVsbG8=";
    const r2: []const u8 = "YSBsb25nZXIgdGVzdCBzdHJpbmc=";
    const r3: []const u8 = "cGFzc3dvcmQ0NTY=";
    const r4: []const u8 = "IQ==";
    const r5: []const u8 = "";

    {
        const o1 = try base64.decode(alloc, r1);
        defer alloc.free(o1);
        try std.testing.expectEqualStrings(o1, t1);
    }
    {
        const o2 = try base64.decode(alloc, r2);
        defer alloc.free(o2);
        try std.testing.expectEqualStrings(o2, t2);
    }
    {
        const o3 = try base64.decode(alloc, r3);
        defer alloc.free(o3);
        try std.testing.expectEqualStrings(o3, t3);
    }
    {
        const o4 = try base64.decode(alloc, r4);
        defer alloc.free(o4);
        try std.testing.expectEqualStrings(o4, t4);
    }
    {
        const o5 = try base64.decode(alloc, r5);
        defer alloc.free(o5);
        try std.testing.expectEqualStrings(o5, t5);
    }
}
