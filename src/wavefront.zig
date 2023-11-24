const std = @import("std");
const ascii = @import("std").ascii;

pub const Vector3 = struct {
    x: f32,
    y: f32,
    z: f32,
};

const BoundingBox = struct {
    min: Vector3,
    max: Vector3,
};

const Object = struct {
    const Self = @This();

    // object_name is mapped from "o"
    object_name: []const u8 = &[0]u8{},
    // vertices is mapped from each "v"
    vertices: []const Vector3 = &[0]Vector3{},

    pub fn getCenter(self: *Self) Vector3 {
        const bounds = self.boundingBox();
        const min = bounds.min;
        const max = bounds.max;
        const width = @abs(min.x - max.x);
        const height = @abs(min.y - max.y);
        const length = @abs(min.z - max.z);
        return .{
            .x = min.x + (width / 2),
            .y = min.y + (height / 2),
            .z = min.z + (length / 2),
        };
    }

    pub fn boundingBox(self: *Self) BoundingBox {
        var min: Vector3 = .{
            .x = std.math.floatMax(f32),
            .y = std.math.floatMax(f32),
            .z = std.math.floatMax(f32),
        };
        var max: Vector3 = .{
            .x = -std.math.floatMax(f32),
            .y = -std.math.floatMax(f32),
            .z = -std.math.floatMax(f32),
        };
        for (self.vertices) |vertex| {
            // get min bounds
            min.x = @min(min.x, vertex.x);
            min.y = @min(min.y, vertex.y);
            min.z = @min(min.z, vertex.z);
            // get max bounds
            max.x = @max(max.x, vertex.x);
            max.y = @max(max.y, vertex.y);
            max.z = @max(max.z, vertex.z);
        }
        return BoundingBox{
            .min = min,
            .max = max,
        };
    }
};

const TemporaryData = struct {
    obj: Object = .{},
    // vertices are placed onto the current object being iterated on
    vertices: std.BoundedArray(Vector3, 1024) = .{},
};

pub const Parser = struct {
    const Self = @This();

    data: []const u8,
    index: u32,
    temp: TemporaryData,

    pub fn init(data: []const u8) Parser {
        return .{
            .data = data,
            .index = 0,
            .temp = .{},
        };
    }

    // next will give you a parsed Wavefront *.obj that will ONLY exist within the scope
    // of where you called next. That means if you want to keep any of the data you need to copy it out.
    pub fn next(self: *Self) anyerror!?*Object {
        var scanner: Scanner = .{
            .data = self.data,
            .i = self.index,
        };

        // reset temporary data from previous iteration
        self.temp = .{};
        var found_obj = false;
        var obj: *Object = &self.temp.obj;

        parse_loop: while (true) {
            const prev_index = scanner.i;
            const top_token = try scanner.nextToken();
            // std.debug.print("Token = Kind: {}, Data: {s}\n", .{ top_token.kind, top_token.data });
            switch (top_token.kind) {
                .Identifier => {
                    if (std.mem.eql(u8, top_token.data, "mtllib")) {
                        // Skip mtllib
                        const value = try scanner.nextToken(); // ie. level_one.mtl
                        _ = value;
                    } else if (std.mem.eql(u8, top_token.data, "o")) {
                        if (found_obj) {
                            // If already found object, then we've hit the next object
                            // exit early and return
                            scanner.i = prev_index; // rewind scanner before this token
                            break :parse_loop;
                        }
                        found_obj = true;
                        const name = try scanner.nextToken(); // ie. Cube or Cube2
                        if (name.kind != .Identifier) {
                            return error.ExpectedIdentAfterObjectName;
                        }
                        obj.object_name = name.data; // ie. Cube or Cube2
                    } else if (std.mem.eql(u8, top_token.data, "v")) {
                        const xTok = try scanner.nextToken(); // ie. 4.000000
                        if (xTok.kind != .Number) {
                            return error.ExpectedVertexXToBeNumber;
                        }
                        const yTok = try scanner.nextToken(); // ie. 1.000000
                        if (yTok.kind != .Number) {
                            return error.ExpectedVertexYToBeNumber;
                        }
                        const zTok = try scanner.nextToken(); // ie. 2.000000
                        if (zTok.kind != .Number) {
                            return error.ExpectedVertexZToBeNumber;
                        }
                        const vertex: Vector3 = .{
                            .x = try std.fmt.parseFloat(f32, xTok.data),
                            .y = try std.fmt.parseFloat(f32, yTok.data),
                            .z = try std.fmt.parseFloat(f32, zTok.data),
                        };
                        try self.temp.vertices.append(vertex);
                        // note(jae): 2023-10-08
                        // If someone tries to use a sphere or something more complex
                        // for now catch it here
                        if (self.temp.vertices.len > 50) {
                            if (obj.object_name.len == 0) {
                                std.debug.panic("missing object name, should have parsed before vertices. Are your Blender .obj exports using defaults?", .{});
                                return error.MissingNameAndOverLimit;
                            }
                            std.debug.panic("cannot have over {} vertices: {s}", .{ 50, obj.object_name });
                            return error.CannotHaveOver50Vertices;
                        }
                    } else if (std.mem.eql(u8, top_token.data, "vn")) {
                        try scanner.assertNextToken(.Number); // skip x
                        try scanner.assertNextToken(.Number); // skip y
                        try scanner.assertNextToken(.Number); // skip z
                    } else if (std.mem.eql(u8, top_token.data, "vt")) {
                        try scanner.assertNextToken(.Number); // skip u
                        try scanner.assertNextToken(.Number); // skip v
                    } else if (std.mem.eql(u8, top_token.data, "s")) {
                        const tok = try scanner.nextToken(); // can be number or identifier ("off")
                        if (tok.kind != .Number and tok.kind != .Identifier) {
                            std.debug.panic("[DEBUG] Line {}, Expected token number/ident but got {}", .{ scanner.getLine(), tok.kind });
                        }
                    } else if (std.mem.eql(u8, top_token.data, "usemtl")) {
                        try scanner.assertNextToken(.Identifier); // ie. Material, not using
                    } else if (std.mem.eql(u8, top_token.data, "f")) {
                        try scanner.assertNextToken(.Number); // ie. 1/1/1
                        try scanner.assertNextToken(.Number); // ie. 5/5/1
                        try scanner.assertNextToken(.Number); // ie. 7/9/1
                        try scanner.assertNextToken(.Number); // ie. 3/3/1

                        // todo(jae): 2023-10-08
                        // Spheres support 3 or 4 "f" values so this currently breaks for those
                    } else if (std.mem.eql(u8, top_token.data, "f")) {
                        try scanner.assertNextToken(.Number); // ie. 1/1/1
                        try scanner.assertNextToken(.Number); // ie. 5/5/1
                        try scanner.assertNextToken(.Number); // ie. 7/9/1
                        try scanner.assertNextToken(.Number); // ie. 3/3/1

                        // todo(jae): 2023-10-08
                        // Spheres support 3 or 4 "f" values so this currently breaks for those
                    } else {
                        std.debug.panic("unhandled identifier: {s}", .{top_token.data});
                    }
                },
                .EOF => {
                    break :parse_loop;
                },
                else => {
                    std.debug.panic("unhandled token kind: {}", .{top_token.kind});
                },
            }
        }
        self.index = scanner.i;
        if (!found_obj) {
            return null;
        }
        obj.vertices = self.temp.vertices.slice();
        return obj;
    }
};

const TokenKind = enum {
    Identifier,
    Number,
    String,
    EOF,
};

const Token = struct {
    kind: TokenKind,
    data: []const u8 = &[0]u8{},
};

const Scanner = struct {
    const Self = @This();

    i: u32,
    data: []const u8,

    pub fn assertNextToken(self: *Self, kind: TokenKind) !void {
        const tok = try self.nextToken();
        if (tok.kind != kind) {
            std.debug.panic("[DEBUG] Line {}, Expected token {} but got {}", .{ self.getLine(), kind, tok.kind });
            // std.debug.print("[DEBUG] Expected token {} but got {}", .{ kind, tok.kind });
            return error.AssertTokenFailed;
        }
    }

    pub fn getLine(self: *Self) u32 {
        var i: @TypeOf(self.i) = 0;
        var lines: u32 = 1;
        while (i < self.i) : (i += 1) {
            const c = self.data[i];
            if (c == '\n') {
                lines += 1;
            }
        }
        return lines;
    }

    pub fn nextToken(self: *Self) !Token {
        while (self.i < self.data.len) {
            // skip whitespace
            {
                var c = self.getChar();
                while (self.i < self.data.len and ascii.isWhitespace(c)) {
                    self.i += 1;
                    c = self.getChar();
                    debugLog("[DEBUG] skipping whitespace\n", .{});
                }
                if (self.i >= self.data.len) {
                    // exit if consuming the last of the whitespace got us
                    // to the end of the file
                    break;
                }
            }

            const start_index = self.i;
            const top_char = self.getChar();
            debugLog("[DEBUG] core loop\n", .{});
            switch (top_char) {
                '#' => {
                    // Skip comments
                    var c = self.nextChar();
                    while (c != 0 and c != '\n') {
                        c = self.nextChar();
                        debugLog("[DEBUG] ignore comments til newline\n", .{});
                    }
                    continue;
                },
                else => {
                    var c = top_char;
                    if (isIdentChar(c)) {
                        while (c != 0 and !ascii.isWhitespace(c)) {
                            c = self.nextChar();
                            debugLog("[DEBUG] get ident\n", .{});
                        }
                        return Token{
                            .kind = .Identifier,
                            .data = self.data[start_index..self.i],
                        };
                    } else if (ascii.isDigit(c) or c == '-' or c == '+') {
                        while (c != 0 and !ascii.isWhitespace(c)) {
                            c = self.nextChar();
                            debugLog("[DEBUG] get decimal number\n", .{});
                        }
                        return Token{
                            .kind = .Number,
                            .data = self.data[start_index..self.i],
                        };
                    } else {
                        std.debug.panic("unhandled char: {c}", .{c});
                        return error.UnhandledElse;
                    }
                },
            }
            unreachable;
        }
        return Token{
            .kind = .EOF,
        };
    }

    fn getChar(self: *Self) u8 {
        if (self.i >= self.data.len) {
            return 0;
        }
        return self.data[self.i];
    }

    fn nextChar(self: *Self) u8 {
        self.i += 1;
        if (self.i >= self.data.len) {
            return 0;
        }
        return self.data[self.i];
    }

    fn debugLog(comptime fmt: []const u8, args: anytype) void {
        _ = args;
        _ = fmt;
        // std.debug.print("[DEBUG] ");
        // std.debug.print(fmt, args);
    }
};

fn isIdentChar(c: u8) bool {
    return ascii.isAlphabetic(c) or c == '_' or c == '.';
}

// test "load level" {
//     const level_data = @embedFile("resources/level_one.obj");
//     var level = try parseQuake2Map(std.testing.allocator, level_data);
//     _ = level;
// }
