const std = @import("std");
const rl = @import("raylib");
const ent = @import("ent.zig");
const wavefront = @import("wavefront.zig");

const Image = ent.Image;

// note(jae): 2023-10-22
// Can't simply use comptime because of parseFloat bug: https://github.com/ziglang/zig/issues/17662
// pub var levels = [_]Level{
//     mustLoadLevel(@embedFile("resources/levels/level_one.obj")),
//     mustLoadLevel(@embedFile("resources/levels/level_two.obj")),
// };
var levels: std.BoundedArray(LevelInfo, 10) = .{};

pub fn loadAllLevels() !void {
    // todo(jae): 2023-11-25
    // Update "try loadLevel(@embedFile("resources/levels/level_one.obj"))" to "try comptime loadLevel(@embedFile("resources/levels/level_one.obj"))"
    // once this bug is fixed and parseFloat works correctly on negative values: https://github.com/ziglang/zig/issues/17662
    //
    // Doing this "fixes" the WASM/Emscripten build by working around whatever bug/issue that seems to be causing in the WASM build. Not sure if it's
    // my code or an issue with WASM codegen but since I'm not practiced/good at memory management, I'm gonna assume it's me until I dig in.

    try levels.append(.{
        // .creator = "SilbinaryWolf", // for debugging the credits system
        .level = try loadLevel(@embedFile("resources/levels/level_one.obj")),
    });
    try levels.append(.{
        .creator = "GebbOs",
        .level = try loadLevel(@embedFile("resources/levels/level_gebbos.obj")),
    });
    try levels.append(.{
        .creator = "Construc_",
        .level = try loadLevel(@embedFile("resources/levels/level_cora.obj")),
    });
    try levels.append(.{
        .level = try loadLevel(@embedFile("resources/levels/level_two.obj")),
    });
    try levels.append(.{
        .level = try loadLevel(@embedFile("resources/levels/level_three.obj")),
    });
    try levels.append(.{
        .level = try loadLevel(@embedFile("resources/levels/level_four.obj")),
    });
    try levels.append(.{
        .creator = "Construc_",
        .level = try loadLevel(@embedFile("resources/levels/level_cora_hard.obj")),
    });
}

pub fn loadDebugLevelIntoFirstSlot(allocator: std.mem.Allocator) !void {
    // Get the path
    var path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const path = try std.fs.realpath("test_level.obj", &path_buffer);

    // Open the file
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    // Read the contents
    const buffer_size = 10 * 1000000; // 10 megabytes
    const file_buffer = try file.readToEndAlloc(allocator, buffer_size);
    defer allocator.free(file_buffer);

    const level = try loadLevel(file_buffer);
    try levels.insert(0, .{
        .level = level,
    });
}

pub fn getLevelCount() u16 {
    return @intCast(levels.len);
}

pub fn getLevelInfoByIndex(index: u16) LevelInfo {
    return levels.slice()[index];
}

const MovingPlatformMap = struct {
    const Self = @This();

    items: std.BoundedArray(MovingPlatformItem, 10) = .{},

    pub fn putStart(self: *Self, key: []const u8, value: ent.MovingPlatform) !void {
        for (self.items.slice()) |*item| {
            if (std.mem.eql(u8, key, item.key)) {
                if (item.start != null) {
                    return error.DuplicateStartKey;
                }
                item.start = value;
                // item.has_start = true;
                return;
            }
        }
        try self.items.append(.{
            .key = key,
            .start = value,
            // .has_start = true,
        });
    }

    pub fn putPosition(self: *Self, key: []const u8, position_index: u8, value: wavefront.Vector3) !void {
        for (self.items.slice()) |*item| {
            if (std.mem.eql(u8, key, item.key)) {
                const curr_pos = item.positions[position_index];
                if (curr_pos.x != -9999 and curr_pos.y != -9999 and curr_pos.z != -9999) {
                    return error.DuplicatePositionKey;
                }
                item.positions[position_index] = value;
                item.positions_len += 1;
                return;
            }
        }
        var positions = [_]wavefront.Vector3{.{ .x = -9999, .y = -9999, .z = -9999 }} ** 8;
        positions[position_index] = value;
        try self.items.append(.{
            .key = key,
            .start = null,
            .positions = positions,
            .positions_len = 1,
        });
    }
};

const MovingPlatformItem = struct {
    key: []const u8,
    start: ?ent.MovingPlatform,
    positions: [8]wavefront.Vector3 = [_]wavefront.Vector3{.{ .x = -9999, .y = -9999, .z = -9999 }} ** 8,
    positions_len: u8 = 0,
};

pub const LevelInfo = struct {
    creator: [:0]const u8 = "",
    level: Level,
};

pub const Level = struct {
    const Self = @This();

    player_start_position: ent.Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    player_has_start_position: bool = false,

    // exit door
    exit_door: ent.ExitDoor = .{
        // default to being far away if not set
        .x = -9999,
        .y = -9999,
        .z = -9999,
    },

    // level geometry
    cubes: std.BoundedArray(ent.Cube, 96) = .{},
    moving_platforms: std.BoundedArray(ent.MovingPlatform, 10) = .{},

    // gettables
    collectables: std.BoundedArray(ent.Collectable, 20) = .{},

    // time_to_beat_in_seconds is how long the player has to beat the level until they lose
    time_to_beat_in_seconds: i32 = 30,

    // debugLog mostly exists because I noticed a bug where certain objects were further away or longer
    // than they should be. So I needed to observe things.
    //
    // Github Issue: https://github.com/ziglang/zig/issues/17662
    pub fn debugLog(self: *Self) void {
        std.debug.print("Debug Cubes:\n", .{});
        for (self.cubes.slice(), 0..) |*cube, i| {
            std.debug.print("- Cube {} - x: {d:.4}, y: {d:.4}, z: {d:.4}\n", .{ i, cube.x, cube.y, cube.z });
            std.debug.print("           w: {d:.4}, h: {d:.4}, l: {d:.4}\n", .{ cube.width, cube.height, cube.length });
        }
        std.debug.print("Debug Collectables:\n", .{});
        for (self.collectables.slice(), 0..) |collect, i| {
            std.debug.print("- Collect {} - x: {d:.4}, y: {d:.4}, z: {d:.4}\n", .{ i, collect.x, collect.y, collect.z });
        }
    }
};

fn mustLoadLevel(level_data: []const u8) Level {
    const level = loadLevel(level_data) catch |err| {
        std.debug.panic("failed to load level data: {}", err);
    };
    return level;
}

pub fn loadLevel(level_data: []const u8) !Level {
    @setEvalBranchQuota(10000000);

    var level: Level = .{};

    // var buffer: [32000]u8 = undefined;
    // var fba = std.heap.FixedBufferAllocator.init(&buffer);
    // var temp_allocator = fba.allocator();
    // var tempMovingPlatformMap = std.StringArrayHashMap(std.BoundedArray(wavefront.Vector3, 10)).init(temp_allocator);

    var movingPlatformMap: MovingPlatformMap = .{};

    var wfparser = wavefront.Parser.init(level_data);
    while (try wfparser.next()) |obj| {
        if (std.mem.startsWith(u8, obj.object_name, "cube") or
            std.mem.startsWith(u8, obj.object_name, "Cube"))
        {
            // note(jae): 2023-10-08
            // Naively assume everything is a axis-aligned(?) cube and
            // get dimensions
            const bounds = obj.boundingBox();
            const min = bounds.min;
            const max = bounds.max;
            const width = @abs(min.x - max.x);
            const height = @abs(min.y - max.y);
            const length = @abs(min.z - max.z);
            const cube = ent.Cube{
                .x = min.x + (width / 2),
                .y = min.y + (height / 2),
                .z = min.z + (length / 2),
                .width = width,
                .height = height,
                .length = length,
            };
            try level.cubes.append(cube);
        } else if (std.mem.startsWith(u8, obj.object_name, "collect") or
            std.mem.startsWith(u8, obj.object_name, "Collect"))
        {
            var image = Image.KevinJamesSwords;
            if (std.mem.endsWith(u8, obj.object_name, "Boob") or
                std.mem.endsWith(u8, obj.object_name, "boob"))
            {
                image = Image.KevinJamesBooba;
            }
            if (std.mem.endsWith(u8, obj.object_name, "Sword") or
                std.mem.endsWith(u8, obj.object_name, "sword") or
                std.mem.endsWith(u8, obj.object_name, "Swords") or
                std.mem.endsWith(u8, obj.object_name, "swords"))
            {
                image = Image.KevinJamesSwords;
            }
            // Collectibles ignore width/height/length and just use the predefined one
            const vec = obj.getCenter();
            try level.collectables.append(.{
                .x = vec.x,
                .y = vec.y,
                .z = vec.z,
                .image = image,
            });
        } else if (std.mem.startsWith(u8, obj.object_name, "player") or
            std.mem.startsWith(u8, obj.object_name, "Player"))
        {
            // Player ignore width/height/length and just use the predefined one
            const vec = obj.getCenter();
            level.player_start_position = .{
                .x = vec.x,
                .y = vec.y,
                .z = vec.z,
            };
            level.player_has_start_position = true;
        } else if (std.mem.startsWith(u8, obj.object_name, "exitdoor") or
            std.mem.startsWith(u8, obj.object_name, "ExitDoor"))
        {
            // ExitDoor ignore width/height/length and just use the predefined one
            const vec = obj.getCenter();
            level.exit_door = .{
                .x = vec.x,
                .y = vec.y,
                .z = vec.z,
            };
        } else if (std.mem.startsWith(u8, obj.object_name, "MovingPlat_")) {
            const invalid_index = 200;
            var key: []const u8 = &[0]u8{};
            var index: u8 = invalid_index;
            {
                var it = std.mem.split(u8, obj.object_name, "_");
                var i: u32 = 0;
                while (it.next()) |x| {
                    switch (i) {
                        0 => {
                            // do nothing for 'MovingPlat_'
                        },
                        1 => {
                            key = x;
                        },
                        2 => {
                            if (std.mem.startsWith(u8, x, "start")) {
                                index = 0;
                            } else if (std.mem.startsWith(u8, x, "end")) {
                                index = 1;
                            } else {
                                std.debug.panic("unhandled moving platform end mode: {s}, valid: start, end", .{x});
                            }
                        },
                        3 => {
                            // ignore anything after/at the third _
                            // ie. handle cases like "MovingPlat_side_start_Cube.001"
                            break;
                        },
                        else => {
                            std.debug.panic("too many underscores in moving platform name: {s}", .{obj.object_name});
                        },
                    }
                    i += 1;
                }
                if (key.len == 0) {
                    std.debug.panic("invalid key name (after _): {s}", .{obj.object_name});
                }
                if (index == invalid_index) {
                    std.debug.panic("failed parsing moving platform data", .{});
                }
            }
            if (index == 0) {
                // First entry
                const bounds = obj.boundingBox();
                const min = bounds.min;
                const max = bounds.max;
                const width = @abs(min.x - max.x);
                const height = @abs(min.y - max.y);
                const length = @abs(min.z - max.z);
                const entity = ent.MovingPlatform{
                    .x = min.x + (width / 2),
                    .y = min.y + (height / 2),
                    .z = min.z + (length / 2),
                    .width = width,
                    .height = height,
                    .length = length,
                };
                try movingPlatformMap.putStart(key, entity);
            } else {
                try movingPlatformMap.putPosition(key, index - 1, obj.getCenter());
            }
        } else {
            std.debug.panic("unhandled object name: {s}, valid: cube, Cube, collect, Collect, player, Player", .{obj.object_name});
            return error.InvalidObjectName;
        }
    }
    // Create moving platforms
    for (movingPlatformMap.items.slice()) |*item| {
        const start = item.start orelse std.debug.panic("expected moving platform to have start position: {s}", .{item.key});
        if (item.positions_len != 1) {
            std.debug.panic("expected moving platform to have 1 position end position: {s}", .{item.key});
        }
        var new_entity: ent.MovingPlatform = start;
        try new_entity.positions.append(.{
            .x = new_entity.x,
            .y = new_entity.y,
            .z = new_entity.z,
        });
        for (item.positions[0..item.positions_len]) |pos| {
            try new_entity.positions.append(.{
                .x = pos.x,
                .y = pos.y,
                .z = pos.z,
            });
        }
        if (new_entity.positions.len < 2) {
            std.debug.panic("expected moving platform to have 2 positions: {s}", .{item.key});
        }
        try level.moving_platforms.append(new_entity);
        // std.debug.panic("JAE DEBUG: moving platform data: {s}, entity: {?}, end position: {}\n", .{ item.key, item.start, item.positions[0] });
    }
    // If no spawn, put player on first platform found
    if (!level.player_has_start_position and level.cubes.len > 0) {
        const first_cube = level.cubes.get(0);
        level.player_start_position = .{
            .x = first_cube.x,
            .y = first_cube.y,
            .z = first_cube.z,
        };
        level.player_has_start_position = true;
    }
    return level;
}
