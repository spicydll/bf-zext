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
            else => Command.Comment,
        };
    }
};

const Direction = enum { left, right };

const BFMachine = struct {
    memory: [30000]u8,
    ptr: usize,
    input: std.io.AnyReader,
    output: std.io.AnyWriter,
    const Self = @This();

    pub fn init(input: std.io.AnyReader, output: std.io.AnyWriter) BFMachine {
        const memory = [_]u8{0} ** 30000;

        return .{ .memory = memory, .ptr = 0, .input = input, .output = output };
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

    pub fn interpret(self: *Self, code: []u8) BFInterpreterError!void {
        var code_ptr: usize = 0;
        var int_type: comptime_int = u8;
        var mod_on = false;

        while (code_ptr < code.len) : (code_ptr += 1) {
            const cur_command = Command.from_char(code[code_ptr]);

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
                else => {},
            }

            if (int_type != u8) {
                mod_on = !mod_on;
                if (!mod_on) {
                    int_type = u8;
                }
            }
        }
    }
};
