const std = @import("std");
const rl = @import("raylib");

pub const Image = enum(u8) {
    KevinJamesBooba,
    KevinJamesSwords,
};

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,
};

pub const Cube = struct {
    const Self = @This();

    x: f32,
    y: f32,
    z: f32,
    width: f32,
    height: f32,
    length: f32,
    color: rl.Color = rl.Color.blue,

    pub fn boundingBox(self: *Self) rl.BoundingBox {
        const min = rl.Vector3.init(self.x - (self.width / 2), self.y - (self.height / 2), self.z - (self.length / 2));
        var max = min;
        max.x += self.width;
        max.y += self.height;
        max.z += self.length;
        return rl.BoundingBox{
            .min = min,
            .max = max,
        };
    }

    pub fn boundingBoxOffsetY(self: *Self, y: f32) rl.BoundingBox {
        const min = rl.Vector3.init(self.x - (self.width / 2), self.y - (self.height / 2) + y, self.z - (self.length / 2));
        var max = min;
        max.x += self.width;
        max.y += self.height;
        max.z += self.length;
        return rl.BoundingBox{
            .min = min,
            .max = max,
        };
    }
};

pub const MovingPlatform = struct {
    const Self = @This();

    x: f32,
    y: f32,
    z: f32,
    width: f32,
    height: f32,
    length: f32,
    destination_position: u16 = 1,
    positions: std.BoundedArray(Vec3, 2) = .{},

    pub fn boundingBox(self: *Self) rl.BoundingBox {
        const min = rl.Vector3.init(self.x - (self.width / 2), self.y - (self.height / 2), self.z - (self.length / 2));
        var max = min;
        max.x += self.width;
        max.y += self.height;
        max.z += self.length;
        return rl.BoundingBox{
            .min = min,
            .max = max,
        };
    }
};

pub const Collectable = struct {
    const Self = @This();
    const _size: f32 = 0.75;
    pub const width: f32 = _size;
    pub const height: f32 = _size;
    pub const length: f32 = _size;

    x: f32,
    y: f32,
    z: f32,
    rotate: f32 = 0,
    image: Image = Image.KevinJamesBooba,

    pub fn boundingBox(self: *Self) rl.BoundingBox {
        const min = rl.Vector3.init(self.x - (width / 2), self.y - (height / 2), self.z - (length / 2));
        var max = min;
        max.x += width;
        max.y += height;
        max.z += length;
        return rl.BoundingBox{
            .min = min,
            .max = max,
        };
    }
};

pub const PlayerLevelState = struct {
    beaten: bool = false,
    exit_has_appeared: bool = false,

    fade_tick: i32 = 0,
    is_fading_in: bool = true,

    //
    credit_fade_tick: i32 = 0,
    credit_hold_on_screen_tick: i32 = 0,
    credit_is_fading_in: bool = false,
};

pub const Player = struct {
    const Self = @This();

    pub const gravity: f32 = 0.0030;
    pub const jump_power: f32 = -0.10;
    pub const move_speed: f32 = 0.05;
    pub const size: f32 = 0.5;

    position: rl.Vector3 = .{
        .x = 0,
        .y = 0,
        .z = 0,
    },
    vspeed: f32 = 0,
    jumps_since_last_touched_ground: i8 = 0,

    // controller variables
    level_state: PlayerLevelState = .{},
    time_passed_in_ticks: i32 = 0,

    pub fn isFrozenDueToLevelBeaten(self: *Self) bool {
        return self.level_state.beaten;
    }
};

pub const ExitDoor = struct {
    const Self = @This();

    pub const width: f32 = 1.75;
    pub const height: f32 = 3.0;
    pub const length: f32 = 0.5;

    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,

    pub fn boundingBox(self: *Self) rl.BoundingBox {
        const min = rl.Vector3.init(self.x - (width / 2), self.y - (height / 2), self.z - (length / 2));
        var max = min;
        max.x += width;
        max.y += height;
        max.z += length;
        return rl.BoundingBox{
            .min = min,
            .max = max,
        };
    }

    // note(jae): 2023-10-14
    // this is ineffecient but easy to code so it stays for now.
    // l-o-l
    pub fn getCubes(self: *Self) std.BoundedArray(Cube, 4) {
        var cubes: std.BoundedArray(Cube, 4) = .{};

        // generate walls around door
        const side_width: f32 = 0.25;
        {
            const cube = Cube{
                .x = self.x - (ExitDoor.width / 2) - (side_width / 2),
                .y = self.y,
                .z = self.z,
                .width = side_width,
                .height = ExitDoor.height,
                .length = ExitDoor.length,
                .color = rl.Color.red,
            };
            cubes.appendAssumeCapacity(cube);
        }
        {
            const cube = Cube{
                .x = self.x + (ExitDoor.width / 2) + (side_width / 2),
                .y = self.y,
                .z = self.z,
                .width = side_width,
                .height = ExitDoor.height,
                .length = ExitDoor.length,
                .color = rl.Color.red,
            };
            cubes.appendAssumeCapacity(cube);
        }
        {
            const top_height = side_width;
            const cube = Cube{
                .x = self.x,
                .y = self.y + (ExitDoor.height / 2) + (top_height / 2),
                .z = self.z,
                .width = ExitDoor.height,
                .height = top_height,
                .length = ExitDoor.length,
                .color = rl.Color.red,
            };
            cubes.appendAssumeCapacity(cube);
        }
        return cubes;
    }
};

pub fn moveTowardsDelta(curr: f32, dest: f32, amount: f32) f32 {
    var new_value: f32 = curr;
    if (curr < dest) {
        new_value += amount;
        if (new_value > dest) {
            return new_value - curr;
        }
        return amount;
    }
    if (curr > dest) {
        new_value -= amount;
        if (new_value < dest) {
            return dest - new_value;
        }
        return -amount;
    }
    return 0;
}
