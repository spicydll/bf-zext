const std = @import("std");

const BFInterpreterError = error{
    OutOfBounds,
    InvalidSyntax,
    OutOfMemory,
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

const CellSize = enum { c1, c2, c4, c8 };
const Cell = union(CellSize) {
    c1: u8,
    c2: u16,
    c4: u32,
    c8: u64,

    fn get_type(comptime tag: CellSize) type {
        return std.meta.TagPayload(Cell, tag);
    }

    fn get_size(tag: CellSize) usize {
        return switch (tag) {
            inline else => |size| @sizeOf(std.meta.TagPayload(Cell, size)),
        };
    }
};

pub const BFMachine = struct {
    memory: [30000]u8,
    ptr: usize,
    input: std.io.AnyReader,
    output: std.io.AnyWriter,
    allocator: std.mem.Allocator,
    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, input: anytype, output: anytype) BFMachine {
        const memory = [_]u8{0} ** 30000;

        return .{ .memory = memory, .ptr = 0, .input = input.any(), .output = output.any(), .allocator = allocator };
    }

    fn move(self: *Self, cell_size: CellSize, direction: Direction) void {
        const num_cells = Cell.get_size(cell_size);
        switch (direction) {
            .left => {
                self.ptr += num_cells;
                if (self.ptr >= self.memory.len) {
                    self.ptr -= self.memory.len;
                }
            },
            .right => {
                if (num_cells > self.ptr) {
                    self.ptr += self.memory.len;
                }
                self.ptr -= num_cells;
            },
        }
    }

    fn move_right(self: *Self, cell_size: CellSize) void {
        self.move(cell_size, .right);
    }

    fn move_left(self: *Self, cell_size: CellSize) void {
        self.move(cell_size, .left);
    }

    fn load_int(self: *Self, cell_size: CellSize) Cell {
        const size = Cell.get_size(cell_size);
        var bytes: [size]u8 = undefined;
        for (0..size) |idx| {
            var offset = self.ptr + idx;
            if (offset >= self.memory.len) {
                offset -= self.memory.len;
            }
            bytes[idx] = self.memory[offset];
        }
        switch (cell_size) {
            inline else => |cell| return std.mem.readInt(Cell.get_type(cell), @constCast(bytes), .little),
        }
    }

    fn store_int(self: *Self, value: Cell) void {
        switch (value) {
            inline else => |val| {
                const size = @sizeOf(val);
                var bytes: [size]u8 = undefined;
                std.mem.writeInt(@TypeOf(val), &bytes, val, .little);
                for (0..size) |idx| {
                    var offset = self.ptr + idx;
                    if (offset >= self.memory.len) {
                        offset -= self.memory.len;
                    }
                    self.memory[offset] = bytes[idx];
                }
            },
        }
    }

    fn increment(self: *Self, cell_size: CellSize) void {
        var value: Cell = self.load_int(cell_size);
        switch (value) {
            else => |*val| val.* = @addWithOverflow(val, @as(@TypeOf(val), 1))[0],
        }
        self.store_int(value);
    }

    fn decrement(self: *Self, cell_size: CellSize) void {
        var value: Cell = self.load_int(cell_size);
        switch (value) {
            else => |*val| val.* = @subWithOverflow(val, @as(Cell, 1))[0],
        }
        self.store_int(value);
    }

    fn read(self: *Self, cell_size: CellSize) !void {
        const cur_ptr = self.ptr;
        const size = Cell.get_size(cell_size);
        for (0..size) |_| {
            const byte: Cell = try self.input.readByte();
            self.store_int(byte);
            self.move_right(CellSize.c1);
        }
        self.ptr = cur_ptr;
    }

    fn print(self: *Self, cell_size: CellSize) !void {
        const cur_ptr = self.ptr;
        const size = Cell.get_size(cell_size);
        for (0..size) |_| {
            const byte: Cell = self.load_int(CellSize.c1);
            try self.output.writeByte(byte.c1);
            self.move_right(CellSize.c1);
        }
        self.ptr = cur_ptr;
    }

    fn is_zero(self: *Self, cell_size: CellSize) bool {
        return self.load_int(cell_size) == @as(Cell, 0);
    }

    pub fn interpret(self: *Self, code: []const u8) BFInterpreterError!void {
        var code_ptr: usize = 0;
        var mod_on = false;
        var if_stack = std.ArrayList(usize).init(self.allocator);
        defer if_stack.deinit();
        var skip_to_endif = false;
        var skip_to_newline = false;
        var skipped_ifs: usize = 0;
        var cell_size = CellSize.c1;

        while (code_ptr < code.len) : (code_ptr += 1) {
            const cur_command = Command.from_char(code[code_ptr]);

            if (skip_to_newline) {
                skip_to_newline = cur_command != Command.NewLine;
            } else {
                switch (cur_command) {
                    .PtrRight => self.move_right(cell_size),
                    .PtrLeft => self.move_left(cell_size),
                    .Mod2 => cell_size = CellSize.c2,
                    .Mod4 => cell_size = CellSize.c4,
                    .Mod8 => cell_size = CellSize.c8,
                    .Increment => self.increment(cell_size),
                    .Decrement => self.decrement(cell_size),
                    .Read => self.read(cell_size),
                    .Print => self.print(cell_size),
                    .If => {
                        if (skip_to_endif) {
                            skipped_ifs += 1;
                        } else if (self.is_zero(cell_size)) {
                            skip_to_endif = true;
                        } else {
                            try if_stack.append(code_ptr);
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
            if (cell_size != CellSize.c1) {
                mod_on = !mod_on;
                if (!mod_on) {
                    cell_size = CellSize.c1;
                }
            }
        }
    }

    //fn test_interpreter(allocator: std.mem.Allocator, code: []const u8, input: []const u8, output: []u8) BFMachine {

    //}

    test "Basic Features" {
        const allocator = std.testing.allocator;
        const code = ",>,.<.";
        var input = std.io.fixedBufferStream("AB");
        const input_reader = input.reader();
        var output_buf: [2]u8 = undefined;
        var output = std.io.fixedBufferStream(&output_buf);
        const output_writer = output.writer();
        var interpreter = BFMachine.init(allocator, input_reader, output_writer);

        try interpreter.interpret(code);
        try std.testing.expectEqualSlices(u8, "BA", &output_buf);
    }

    test "Increment Decrement" {
        const allocator = std.testing.allocator;
        const code = ",++.--.";
        var input = std.io.fixedBufferStream("A");
        const input_reader = input.reader();
        var output_buf: [2]u8 = undefined;
        var output = std.io.fixedBufferStream(&output_buf);
        const output_writer = output.writer();
        var interpreter = BFMachine.init(allocator, input_reader, output_writer);

        try interpreter.interpret(code);
        try std.testing.expectEqualSlices(u8, "CA", &output_buf);
    }

    test "If loops" {
        const allocator = std.testing.allocator;
        const code = ">++++++[<++++++++++>-]<+++++.";
        var input = std.io.fixedBufferStream("");
        const input_reader = input.reader();
        var output_buf: [1]u8 = undefined;
        var output = std.io.fixedBufferStream(&output_buf);
        const output_writer = output.writer();
        var interpreter = BFMachine.init(allocator, input_reader, output_writer);

        try interpreter.interpret(code);
        try std.testing.expectEqualSlices(u8, "A", &output_buf);
    }
};

test "BF Language Features" {
    std.testing.refAllDecls(@This());
    // TODO:
    // 1. reader from u8[] slice
    // 2. test basic features ",>,<.>."
    // 3. test inc dec ",++.--."
    // 4. test if loops ">+++++[<++++++++++>-]<+++++."
}
