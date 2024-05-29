const std = @import("std");

const BFInterpreterError = error{
    OutOfBounds,
    InvalidSyntax,
};

const Command = enum {
    PtrRight,
    PtrLeft,
    Increment,
    Decrement,
    Print,
    Read,
    If,
    EndIf,
    Comment,
    LineComment,
    NewLine,
    Mod2,
    Mod4,
    Mod8,

    pub fn from_char(c: u8) Command {
        return switch (c) {
            '>' => Command.PtrRight,
            '<' => Command.PtrLeft,
            '+' => Command.Increment,
            '-' => Command.Decrement,
            '.' => Command.Print,
            ',' => Command.Read,
            '[' => Command.If,
            ']' => Command.EndIf,
            '2' => Command.Mod2,
            '4' => Command.Mod4,
            '8' => Command.Mod8,
            ';' => Command.LineComment,
            '\n' => Command.NewLine,
            else => Command.Comment,
        };
    }
};

const Direction = enum { left, right };

const BFMachine = struct {
    memory: [30000]u8,
    ptr: usize,
    input: std.io.AnyReader,
    output: anyopaque,
    allocator: std.mem.Allocator,
    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, input: std.io.AnyReader, output: anyopaque) BFMachine {
        const memory = [_]u8{0} ** 30000;

        return .{ .memory = memory, .ptr = 0, .input = input, .output = output, .allocator = allocator };
    }

    fn move(self: *Self, int_type: comptime_int, direction: Direction) void {
        switch (direction) {
            .left => {
                self.ptr += @sizeOf(int_type);
                if (self.ptr >= self.memory.len) {
                    self.ptr -= self.memory.len;
                }
            },
            .right => {
                if (@sizeOf(int_type) > self.ptr) {
                    self.ptr += self.memory.len;
                }
                self.ptr -= @sizeOf(int_type);
            },
        }
    }

    fn move_right(self: *Self, int_type: comptime_int) void {
        self.move(int_type, .right);
    }

    fn move_left(self: *Self, int_type: comptime_int) void {
        self.move(int_type, .left);
    }

    fn load_int(self: *Self, int_type: comptime_int) int_type {
        if (int_type == u8) {
            return self.memory[self.ptr];
        }

        const size = @sizeOf(int_type);
        var bytes: [size]u8 = undefined;
        for (0..size) |idx| {
            var offset = self.ptr + idx;
            if (offset >= self.memory.len) {
                offset -= self.memory.len;
            }
            bytes[idx] = self.memory[offset];
        }
        return std.mem.readInt(int_type, @constCast(bytes), .little);
    }

    fn store_int(self: *Self, int_type: comptime_int, value: int_type) void {
        if (int_type == u8) {
            self.memory[self.ptr] = value;
        } else {
            const size = @sizeOf(int_type);
            var bytes: [size]u8 = undefined;
            std.mem.writeInt(int_type, &bytes, value, .little);
            for (0..size) |idx| {
                var offset = self.ptr + idx;
                if (offset >= self.memory.len) {
                    offset -= self.memory.len;
                }
                self.memory[offset] = bytes[idx];
            }
        }
    }

    fn increment(self: *Self, int_type: comptime_int) void {
        var value: int_type = self.load_int(int_type);
        value = @addWithOverflow(value, 1)[0];
        self.store_int(int_type, value);
    }

    fn decrement(self: *Self, int_type: comptime_int) void {
        var value: int_type = self.load_int(int_type);
        value = @subWithOverflow(value, 1)[0];
        self.store_int(int_type, value);
    }

    fn read(self: *Self, int_type: comptime_int) !void {
        const cur_ptr = self.ptr;
        for (0..@sizeOf(int_type)) |_| {
            const byte = try self.input.readByte();
            self.store_int(u8, byte);
            self.move_right(u8);
        }
        self.ptr = cur_ptr;
    }

    fn print(self: *Self, int_type: comptime_int) !void {
        const cur_ptr = self.ptr;
        for (0..@sizeOf(int_type)) |_| {
            const byte = self.load_int(u8);
            try self.output.writeByte(byte);
            self.move_right(u8);
        }
        self.ptr = cur_ptr;
    }

    fn is_zero(self: *Self, int_type: comptime_int) bool {
        return self.load_int(int_type) == 0;
    }

    pub fn interpret(self: *Self, code: []const u8) BFInterpreterError!void {
        var code_ptr: usize = 0;
        var int_type: comptime_int = u8;
        var mod_on = false;
        var if_stack = std.ArrayList(usize).init(self.allocator);
        defer if_stack.deinit();
        var skip_to_endif = false;
        var skip_to_newline = false;
        var skipped_ifs: usize = 0;

        while (code_ptr < code.len) : (code_ptr += 1) {
            const cur_command = Command.from_char(code[code_ptr]);

            if (skip_to_newline) {
                skip_to_newline = cur_command != Command.NewLine;
            } else {
                switch (cur_command) {
                    .PtrRight => self.move_right(int_type),
                    .PtrLeft => self.move_left(int_type),
                    .Mod2 => int_type = u16,
                    .Mod4 => int_type = u32,
                    .Mod8 => int_type = u64,
                    .Increment => self.increment(int_type),
                    .Decrement => self.decrement(int_type),
                    .Read => self.read(int_type),
                    .Print => self.print(int_type),
                    .If => {
                        if (skip_to_endif) {
                            skipped_ifs += 1;
                        } else if (self.is_zero(int_type)) {
                            skip_to_endif = true;
                        } else {
                            if_stack.append(code_ptr);
                        }
                    },
                    .EndIf => {
                        if (skip_to_endif) {
                            if (skipped_ifs == 0) {
                                skip_to_endif = false;
                            } else {
                                skipped_ifs -= 1;
                            }
                        } else {
                            code_ptr = if_stack.popOrNull() orelse return BFInterpreterError.InvalidSyntax;
                        }
                    },
                    .LineComment => {
                        skip_to_newline = true;
                    },
                    else => {},
                }
            }
            if (int_type != u8) {
                mod_on = !mod_on;
                if (!mod_on) {
                    int_type = u8;
                }
            }
        }
    }

    //fn test_interpreter(allocator: std.mem.Allocator, code: []const u8, input: []const u8, output: []u8) BFMachine {

    //}

    test "Basic Features" {
        const allocator = std.testing.allocator;
        const code = ",>,.<.";
        const input = std.io.fixedBufferStream("AB").reader();
        var output_buf: [2]u8 = undefined;
        const output = std.io.fixedBufferStream(&output_buf).writer();
        var interpreter = BFMachine.init(allocator, input, output);

        try interpreter.interpret(code);
        try std.testing.expectEqualSlices(u8, "BA", output_buf);
    }

    test "Increment Decrement" {
        const allocator = std.testing.allocator;
        const code = ",++.--.";
        const input = std.io.fixedBufferStream("A").reader();
        var output_buf: [2]u8 = undefined;
        const output = std.io.fixedBufferStream(&output_buf).writer();
        var interpreter = BFMachine.init(allocator, input, output);

        try interpreter.interpret(code);
        try std.testing.expectEqualSlices(u8, "CA", output_buf);
    }

    test "If loops" {
        const allocator = std.testing.allocator;
        const code = ">++++++[<++++++++++>-]<+++++.";
        const input = std.io.fixedBufferStream("").reader();
        var output_buf: [1]u8 = undefined;
        const output = std.io.fixedBufferStream(&output_buf).writer();
        var interpreter = BFMachine.init(allocator, input, output);

        try interpreter.interpret(code);
        try std.testing.expectEqualSlices(u8, "A", output_buf);
    }
};

test "BF Language Features" {
    std.testing.refAllDecls(BFMachine);
    // TODO:
    // 1. reader from u8[] slice
    // 2. test basic features ",>,<.>."
    // 3. test inc dec ",++.--."
    // 4. test if loops ">+++++[<++++++++++>-]<+++++."
}
