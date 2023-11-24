// Learning notes:
// - https://www.raylib.com/examples/core/loader.html?name=core_3d_camera_first_person
//      - https://github.com/raysan5/raylib/blob/master/examples/core/core_3d_camera_first_person.c
// - https://www.raylib.com/examples/models/loader.html?name=models_mesh_picking
// - The unit of space/length/width/height/etc is in metres. ie. x = 1, 1 = 1 metre, this is the default in Blender too

const std = @import("std");
const rl = @import("raylib");
// const vr = @import("vr.zig"); // not used
const ent = @import("ent.zig");
const lvl = @import("lvl.zig");
const rlx = @import("rlx.zig");
const snd = @import("snd.zig");

// targetTickRate is what all the physics/movement speeds, etc are tied to.
// Use this so that when can loop the simulation logic 2x if the FPS is half or 4x if it's a quarter.
//
// Not using deltatime or variable updating so the sim is simpler to implement and deterministic
const targetTickRate: i32 = 120;

// const WindowSize = enum(u4) {
//     Full = 0,
//     ThreeQuarter = 1,
//     Half = 2,
// };

const Framerate = enum(u4) {
    Auto = 0,
    Rate30 = 1,
    Rate60 = 2,
    Rate120 = 3,
};

const Settings = struct {
    isSoundEnabled: bool = true,
    isMusicEnabled: bool = true,
    frameRate: Framerate = Framerate.Auto,
    // windowSize: WindowSize = WindowSize.Full,

    total_time_passed_in_ticks: i32 = 0,
};

var camera: rl.Camera = .{
    .position = rl.Vector3.init(0.2, 0.4, 0.2),
    .target = rl.Vector3.init(0.185, 0.4, 0.0),
    .up = rl.Vector3.init(0.0, 1.0, 0.0),
    .fovy = 45.0,
    .projection = rl.CameraProjection.camera_perspective,
};

var camera_pitch: rl.Vector3 = rl.Vector3.init(0, 0, 0);

fn resetCamera() void {
    camera = .{
        .position = rl.Vector3.init(0.2, 0.4, 0.2),
        .target = rl.Vector3.init(0.185, 0.4, 0.0),
        .up = rl.Vector3.init(0.0, 1.0, 0.0),
        .fovy = 45.0,
        .projection = rl.CameraProjection.camera_perspective,
    };
    camera_pitch = rl.Vector3.init(0, 0, 0);
}

// debugLevelBuild exists so I could hand out a build of the game to friends
// and get them to make a level if they wanted
const debugLevelBuild = false;

// debugInfoEnabled shows framerate and other things in the top-left corner if enabled
const debugInfoEnabled = false;

var settings: Settings = .{};

// currentLevel is the current state of the level
var currentLevel: lvl.Level = .{};

// currentLevelCreator is the creator of the current level
var currentLevelCreator: [:0]const u8 = "";

// loadedLevel is the loaded level data that hasn't been manipulated
// ie. index maps to the "lvl.levels" array
var currentLevelIndex: u16 = 0;

var player: ent.Player = .{};

var gpa = std.heap.GeneralPurposeAllocator(.{
    .enable_memory_limit = true,
    // note(jae): 2023-08-20
    // Turning this on doesn't free memory so we can catch segfaults
    //.never_unmap = true,
}){
    // limit to 128mb of RAM
    .requested_memory_limit = 128 * 1024 * 1024,
};

fn hasCollisionAtPosition(position: rl.Vector3) bool {
    // Check collision
    for (currentLevel.cubes.slice()) |*cube| {
        if (rl.checkCollisionBoxSphere(cube.boundingBox(), position, @TypeOf(player).size)) {
            return true;
        }
    }
    for (currentLevel.moving_platforms.slice()) |*plat| {
        if (rl.checkCollisionBoxSphere(plat.boundingBox(), position, @TypeOf(player).size)) {
            return true;
        }
    }
    if (currentLevel.collectables.len == 0) {
        var door_cubes = currentLevel.exit_door.getCubes();
        for (door_cubes.slice()) |*cube| {
            if (rl.checkCollisionBoxSphere(cube.boundingBox(), position, @TypeOf(player).size)) {
                return true;
            }
        }
    }
    return false;
}

const InputState = enum(u2) {
    const Self = @This();

    None = 0,
    Pressed = 1,
    Held = 2,
    Released = 3,

    pub fn is_held(self: Self) bool {
        return self == .Pressed or self == .Held;
    }
};

const CameraRotationType = enum(u4) {
    None,
    Mouse,
    Gamepad,
};

const Input = struct {
    move_forward: InputState = InputState.None,
    move_backward: InputState = InputState.None,
    strafe_left: InputState = InputState.None,
    strafe_right: InputState = InputState.None,
    jump: InputState = InputState.None,
    menu: InputState = InputState.None,
    camera_rotation_type: CameraRotationType = .None,
    camera_rotation_delta: ent.Vec3 = .{ .x = 0, .y = 0, .z = 0 },
};

var input: Input = .{};

const Menu = struct {
    const Self = @This();

    const Type = enum(u8) {
        None,
        TitleMenu,
        PauseMenu,
        OptionsMenu,
        CreditsMenu,
        GameBeatenMenu,
    };

    const StackItem = struct {
        item_index: i32,
        menu_type: Type,
    };

    menu_type: Type = Type.None,
    selected_item_index: i32 = 0,
    selected_item_stack: std.BoundedArray(StackItem, 5) = .{},

    pub fn pushType(self: *Self, kind: Type) !void {
        if (kind == .None) {
            return error.CannotPushNone;
        }
        if (self.menu_type != .None) {
            try self.selected_item_stack.append(.{
                .item_index = self.selected_item_index,
                .menu_type = self.menu_type,
            });
        } else {
            rl.enableCursor();
        }
        self.selected_item_index = 0;
        self.menu_type = kind;
    }

    pub fn pop(self: *Self) void {
        if (self.selected_item_stack.len == 0) {
            self.menu_type = .None;
            rl.disableCursor();
            return;
        }
        const prev = self.selected_item_stack.pop();
        self.selected_item_index = prev.item_index;
        self.menu_type = prev.menu_type;
    }
};

var menu: Menu = .{};

var targetFps: i32 = 0;

// setTargetFPS exists as rl.setTargetFPS doesn't provide an API for getting current target FPS
fn setTargetFPS(fps: i32) void {
    rl.setTargetFPS(fps);
    targetFps = fps;
}

pub fn resetGame() !void {
    currentLevelIndex = 0;
    settings.total_time_passed_in_ticks = 0;
    resetLevel();
    try menu.pushType(.TitleMenu);
}

pub fn resetLevel() void {
    // reset level
    const levelInfo = lvl.getLevelInfoByIndex(currentLevelIndex);
    currentLevel = levelInfo.level;
    currentLevelCreator = levelInfo.creator;

    // reset all fields to defaults
    player = .{};

    // set to start position
    player.position = .{
        .x = currentLevel.player_start_position.x,
        .y = currentLevel.player_start_position.y,
        .z = currentLevel.player_start_position.z,
    };

    // Push out of ground if colliding
    while (hasCollisionAtPosition(player.position)) {
        player.position.y += 0.001;
    }

    // reset camera
    resetCamera();
}

pub fn main() anyerror!void {
    // random number generator
    // var rnd = std.rand.DefaultPrng.init(0);
    // _ = rnd;

    // Setup custom allocator
    defer {
        std.debug.print("deinit allocator\n--------------\n", .{});
        _ = gpa.deinit();
    }
    const allocator = gpa.allocator();

    // add anti-aliasing
    rl.setConfigFlags(rl.ConfigFlags.flag_msaa_4x_hint);

    {
        // var screenWidth = rl.getScreenWidth();
        // var screenHeight = rl.getScreenHeight();
        // if (screenWidth == 0 or screenHeight == 0) {
        //     screenWidth = 1280;
        //     screenHeight = 720;
        // }
        rl.initWindow(1280, 720, "Jae's Hyperreal 3D Generation");
    }
    defer rl.closeWindow(); // Close window and OpenGL context

    // initialize vr
    // vr.init();

    rl.initAudioDevice();
    defer rl.closeAudioDevice();

    // load sounds
    try snd.init(&settings.isSoundEnabled);
    defer snd.deinit();

    // load level
    try lvl.loadAllLevels();

    // load debug level
    // ie. test_level.obj
    if (debugLevelBuild) {
        currentLevelIndex = 0;
        settings.isSoundEnabled = false;
        settings.isMusicEnabled = false;
        try lvl.loadDebugLevelIntoFirstSlot(allocator);
    }

    // Load textures
    const texKevinJamesBooba: rl.Texture = blk: {
        var img = rl.loadImageFromMemory(".png", @embedFile("resources/textures/kevin_james_booba.png"));
        // hack: fix textures rendering upside down
        rl.imageFlipVertical(&img);
        defer img.unload();
        break :blk rl.loadTextureFromImage(img);
    };
    defer rl.unloadTexture(texKevinJamesBooba);

    const texKevinJamesSwords: rl.Texture = blk: {
        var img = rl.loadImageFromMemory(".png", @embedFile("resources/textures/kevin_james_swords.png"));
        // hack: fix textures rendering upside down
        rl.imageFlipVertical(&img);
        defer img.unload();
        break :blk rl.loadTextureFromImage(img);
    };
    defer rl.unloadTexture(texKevinJamesSwords);

    // Setup collectable mesh/model with default texture
    const collectableMesh = rl.genMeshCube(ent.Collectable.width, ent.Collectable.height, ent.Collectable.length);
    var collectableModel = rl.loadModelFromMesh(collectableMesh);
    collectableModel.materials[0].maps[@intFromEnum(rl.MATERIAL_MAP_DIFFUSE)].texture = texKevinJamesBooba;

    // load music
    const music: rl.Music = rl.loadMusicStreamFromMemory(".ogg", @embedFile("resources/music/katie.ogg"));
    rl.setMusicVolume(music, 0.65);
    defer rl.unloadMusicStream(music);

    // Limit cursor to relative movement inside the window
    rl.disableCursor();

    // Set our game to run at 120 frames-per-second
    setTargetFPS(120);

    // Reset player
    resetLevel();

    // Delay start-up time to start OBS recording
    // std.time.sleep(5 * std.time.ns_per_s);

    // Experiment with better frame rate detection
    // var fpsStoredPerFrame = [_]i32{targetTickRate} ** targetTickRate;
    // var fpsStoredIndex: u32 = 0;
    // var fpsHasStoredOnce: bool = false;

    // Disable ESC being default exit key
    rl.setExitKey(rl.KeyboardKey.key_null);

    // Show title screen
    if (!debugLevelBuild) {
        try menu.pushType(.TitleMenu);
    }

    // DEBUG: show end screen
    // try menu.pushType(.GameBeatenMenu);

    // Main game loop
    while (!rl.windowShouldClose()) { // Detect window close button or ESC key
        // Experiment with better frame rate detection
        // var averageFps: i32 = 0;
        // {
        //     // Add current FPS to circular array
        //     const fps = rl.getFPS();
        //     if (fps > 0 and fps <= targetTickRate) {
        //         if (!fpsHasStoredOnce) {
        //             fpsStoredPerFrame = [_]i32{fps} ** targetTickRate;
        //             fpsHasStoredOnce = true;
        //         }
        //         fpsStoredPerFrame[fpsStoredIndex] = fps;
        //         fpsStoredIndex += 1;
        //         if (fpsStoredIndex >= fpsStoredPerFrame.len) {
        //             fpsStoredIndex = 0;
        //         }
        //     }
        //     // Compute average
        //     for (fpsStoredPerFrame) |v| {
        //         averageFps += v;
        //     }
        //     averageFps = @divFloor(averageFps, @as(i32, @intCast(fpsStoredPerFrame.len)));
        // }

        if (settings.isMusicEnabled) {
            rl.updateMusicStream(music); // Update music buffer with new stream data
        }

        // Get run game simulation amount depending on set frame rate
        //
        // note(jae): 2023-11-08
        // This can get flakey on flactuating frame rates, so I've added an option in settings
        // so folks can set a fixed frame rate.
        var timesToRunUpdateSim: i32 = 1;
        switch (settings.frameRate) {
            .Auto => {
                // Get rough approximation of current FPS so we can increase how often we simulate
                // each frame
                //
                // This was added as I use software rendering in my browser and noticed the FPS dropped to 30 so
                // I figured I'd keep my determinsitic physics/logic happening but make the game feel better if it's
                // running on a low-end device.
                //
                // I also quickly tested the game on my iPhone 6S in Safari and it gets about 40 FPS.
                // (At time of writing though, I have not added touch inputs so it's unplayable on a phone)
                var fpsBounds = rl.getFPS();
                if (fpsBounds == 0) {
                    // GetFPS starts at 0
                    fpsBounds = targetTickRate;
                }
                if (fpsBounds > 105) {
                    fpsBounds = 120;
                } else if (fpsBounds > 45) {
                    fpsBounds = 60;
                } else if (fpsBounds > 15) {
                    fpsBounds = 30;
                } else if (fpsBounds > 5) {
                    fpsBounds = 15;
                }
                timesToRunUpdateSim = @divFloor(targetTickRate, fpsBounds);
            },
            .Rate30 => {
                timesToRunUpdateSim = targetTickRate / 30;
            },
            .Rate60 => {
                timesToRunUpdateSim = targetTickRate / 60;
            },
            .Rate120 => {
                timesToRunUpdateSim = targetTickRate / 120;
            },
        }

        // Update inputs
        {
            var has_touched = false;
            var touch_move_forward = false;
            var touch_move_backwards = false;
            var touch_strafe_left = false;
            var touch_strafe_right = false;
            {
                const touch_points: u32 = @intCast(rl.getTouchPointCount());
                if (touch_points > 0) {
                    const big_circle = 64;
                    const radius = 32;

                    const x: f32 = big_circle + 32;
                    const y: f32 = @as(f32, @floatFromInt(rl.getScreenHeight())) - 32 - big_circle;
                    for (0..touch_points) |tpi| {
                        has_touched = true;

                        const touch_pos = rl.getTouchPosition(@intCast(tpi));
                        if (rl.checkCollisionPointCircle(touch_pos, .{ .x = x, .y = y - 16 }, radius)) {
                            touch_move_forward = true;
                        } else if (rl.checkCollisionPointCircle(touch_pos, .{ .x = x, .y = y + 16 }, radius)) {
                            touch_move_backwards = true;
                        }
                        if (rl.checkCollisionPointCircle(touch_pos, .{ .x = x - 16, .y = y }, radius)) {
                            touch_strafe_left = true;
                        } else if (rl.checkCollisionPointCircle(touch_pos, .{ .x = x + 16, .y = y }, radius)) {
                            touch_strafe_right = true;
                        }
                    }
                }
            }

            const gamepad_axis_left_x: i32 = 0; // rl.GamepadAxis.gamepad_axis_left_x
            const gamepad_axis_left_y: i32 = 1; // rl.GamepadAxis.gamepad_axis_left_y
            const left_stick_deadzone: f32 = 0.5;
            const gamepad_moving_forward = rl.getGamepadAxisMovement(0, gamepad_axis_left_y) < -left_stick_deadzone;
            const gamepad_moving_backward = rl.getGamepadAxisMovement(0, gamepad_axis_left_y) > left_stick_deadzone;
            const gamepad_strafe_left = rl.getGamepadAxisMovement(0, gamepad_axis_left_x) < -left_stick_deadzone;
            const gamepad_strafe_right = rl.getGamepadAxisMovement(0, gamepad_axis_left_x) > left_stick_deadzone;

            // std.debug.print("left-stick: {d:.4}\n", .{rl.getGamepadAxisMovement(0, gamepad_axis_left_y)});
            if (rl.isKeyDown(rl.KeyboardKey.key_w) or
                rl.isKeyDown(rl.KeyboardKey.key_up) or
                gamepad_moving_forward or
                touch_move_forward)
            {
                switch (input.move_forward) {
                    InputState.None => input.move_forward = InputState.Pressed,
                    InputState.Pressed => input.move_forward = InputState.Held,
                    else => {},
                }
            } else {
                input.move_forward = InputState.None;
            }
            if (rl.isKeyDown(rl.KeyboardKey.key_s) or rl.isKeyDown(rl.KeyboardKey.key_down) or gamepad_moving_backward or touch_move_backwards) {
                switch (input.move_backward) {
                    InputState.None => input.move_backward = InputState.Pressed,
                    InputState.Pressed => input.move_backward = InputState.Held,
                    else => {},
                }
            } else {
                input.move_backward = InputState.None;
            }
            if (rl.isKeyDown(rl.KeyboardKey.key_a) or rl.isKeyDown(rl.KeyboardKey.key_left) or gamepad_strafe_left or touch_strafe_left) {
                input.strafe_left = InputState.Held;
            } else {
                input.strafe_left = InputState.None;
            }
            if (rl.isKeyDown(rl.KeyboardKey.key_d) or rl.isKeyDown(rl.KeyboardKey.key_right) or gamepad_strafe_right or touch_strafe_right) {
                input.strafe_right = InputState.Held;
            } else {
                input.strafe_right = InputState.None;
            }
            if (rl.isKeyDown(rl.KeyboardKey.key_space) or
                rl.isKeyDown(rl.KeyboardKey.key_enter) or
                (!has_touched and rl.isMouseButtonDown(rl.MouseButton.mouse_button_left)) or
                rl.isGamepadButtonDown(0, rl.GamepadButton.gamepad_button_right_face_down) or
                rl.isGamepadButtonDown(0, rl.GamepadButton.gamepad_button_right_trigger_1) or
                rl.isGamepadButtonDown(0, rl.GamepadButton.gamepad_button_right_trigger_2))
            {
                switch (input.jump) {
                    InputState.None => input.jump = InputState.Pressed,
                    InputState.Pressed => input.jump = InputState.Held,
                    else => {},
                }
            } else {
                switch (input.jump) {
                    InputState.Pressed, InputState.Held => input.jump = InputState.Released,
                    InputState.Released => input.jump = InputState.None,
                    else => {},
                }
            }
            if (rl.isKeyDown(rl.KeyboardKey.key_m) or // m = menu
                rl.isKeyDown(rl.KeyboardKey.key_p) or // p = pause
                // note(jae): 2023-11-05
                // On lower FPSes, key_escape seems to not register sometimes
                rl.isKeyDown(rl.KeyboardKey.key_escape) or
                rl.isGamepadButtonDown(0, rl.GamepadButton.gamepad_button_middle_right))
            {
                switch (input.menu) {
                    InputState.None => input.menu = InputState.Pressed,
                    InputState.Pressed => input.menu = InputState.Held,
                    else => {},
                }
            } else {
                switch (input.menu) {
                    InputState.Pressed, InputState.Held => input.menu = InputState.Released,
                    InputState.Released => input.menu = InputState.None,
                    else => {},
                }
            }

            // Update camera rotation delta
            input.camera_rotation_delta = .{ .x = 0, .y = 0, .z = 0 };
            input.camera_rotation_type = .None;
            const mouseDelta = rl.getMouseDelta();
            if (@abs(mouseDelta.x) > 1.0 or @abs(mouseDelta.y) > 1.0) {
                const cameraMouseMoveSensitivity: f32 = 0.03;
                if (mouseDelta.x != 0.0) {
                    input.camera_rotation_delta.x = mouseDelta.x * cameraMouseMoveSensitivity;
                }
                if (mouseDelta.y != 0.0) {
                    input.camera_rotation_delta.y = mouseDelta.y * cameraMouseMoveSensitivity;
                }
                input.camera_rotation_type = .Gamepad;
            } else {
                const gamepadCameraXSensitivity: f32 = 1.5;
                const gamepadCameraYSensitivity: f32 = 0.5;
                const gamepad_axis_right_x: i32 = 2; // rl.GamepadAxis.gamepad_axis_right_x; = 2
                const gamepad_axis_right_y: i32 = 3; // rl.GamepadAxis.gamepad_axis_right_y; = 3
                const gamepad_camera_x = rl.getGamepadAxisMovement(0, gamepad_axis_right_x);
                const gamepad_camera_y = rl.getGamepadAxisMovement(0, gamepad_axis_right_y);
                if (@abs(gamepad_camera_x) > 0.1) {
                    input.camera_rotation_delta.x = gamepad_camera_x * gamepadCameraXSensitivity;
                }
                if (@abs(gamepad_camera_y) > 0.1) {
                    input.camera_rotation_delta.y = gamepad_camera_y * gamepadCameraYSensitivity;
                }
                input.camera_rotation_type = .Gamepad;
            }
        }

        // Open menu
        if (input.menu == InputState.Pressed) {
            if (menu.menu_type == .None) {
                try menu.pushType(.PauseMenu);
                input.menu = InputState.Held;
            }
        }

        // On beaten level, fade in and fade out
        const fade_in_amount: i32 = targetTickRate / 4; // 0.25 seconds
        const credit_fade_in_amount = targetTickRate / 4; // 0.25 seconds
        const credit_hold_on_screen_amount = targetTickRate * 4; // 4 seconds
        if (menu.menu_type == .None) {
            // Make fade in and out between level transitions happen
            if (player.level_state.beaten or player.level_state.fade_tick != 0) {
                if (player.level_state.is_fading_in) {
                    player.level_state.fade_tick += timesToRunUpdateSim;
                    if (player.level_state.fade_tick > fade_in_amount) {
                        // Goto next level
                        currentLevelIndex += 1;
                        if (currentLevelIndex >= lvl.getLevelCount()) {
                            currentLevelIndex = 0;
                        }
                        const old_level_state = player.level_state;
                        resetLevel();
                        player.level_state = old_level_state;
                        player.level_state.beaten = false;
                        player.level_state.exit_has_appeared = false;

                        // stop fade in/out
                        player.level_state.is_fading_in = false;

                        if (currentLevelIndex == 0) {
                            try menu.pushType(.GameBeatenMenu);
                        }
                    }
                } else {
                    player.level_state.fade_tick -= timesToRunUpdateSim;
                    if (player.level_state.fade_tick <= 0) {
                        // Reset level state
                        player.level_state = .{};

                        // Show credits fade in/out (if credits are applied to level)
                        player.level_state.credit_fade_tick = 0;
                        player.level_state.credit_hold_on_screen_tick = 0;
                        player.level_state.credit_is_fading_in = false;
                        if (currentLevelCreator.len > 0) {
                            player.level_state.credit_is_fading_in = true;
                        }
                    }
                }
            }

            // Make fade in and out "Made by [CREATOR]" happen
            if (!player.level_state.beaten and
                (player.level_state.credit_fade_tick != 0 or player.level_state.credit_is_fading_in))
            {
                if (player.level_state.credit_is_fading_in) {
                    player.level_state.credit_fade_tick += timesToRunUpdateSim;
                    if (player.level_state.credit_fade_tick >= fade_in_amount) {
                        // Keep text on screen logic
                        player.level_state.credit_fade_tick = fade_in_amount;
                        player.level_state.credit_hold_on_screen_tick += timesToRunUpdateSim;
                        if (player.level_state.credit_hold_on_screen_tick > credit_hold_on_screen_amount) {
                            // Fade out the credits
                            player.level_state.credit_is_fading_in = false;
                        }
                    }
                } else {
                    player.level_state.credit_fade_tick -= timesToRunUpdateSim;
                    if (player.level_state.credit_fade_tick <= 0) {
                        // reset
                        player.level_state.credit_fade_tick = 0;
                        player.level_state.credit_is_fading_in = false;
                    }
                }
            }

            // ------------------------------------------------------
            // Update
            // ------------------------------------------------------
            {
                // Run simulation
                for (0..@intCast(timesToRunUpdateSim)) |simNumber| {
                    // Update timer
                    var is_level_falling_away = false;
                    if (!player.isFrozenDueToLevelBeaten()) {
                        const time_left_in_seconds: i32 = currentLevel.time_to_beat_in_seconds - @divFloor(player.time_passed_in_ticks, targetTickRate);
                        if (time_left_in_seconds > 0) {
                            // Tick timer
                            player.time_passed_in_ticks += 1;
                            settings.total_time_passed_in_ticks += 1;
                        } else {
                            // Make level fall away when timer runs out
                            const level_move_away_speed: f32 = 0.05;
                            const level_fall_speed: f32 = 0.25;
                            for (currentLevel.cubes.slice()) |*cube| {
                                cube.x += level_move_away_speed;
                                cube.z += level_move_away_speed;
                                cube.y -= level_fall_speed;
                                cube.color = rl.Color.orange;
                            }
                            for (currentLevel.moving_platforms.slice()) |*plat| {
                                plat.x += level_move_away_speed;
                                plat.z += level_move_away_speed;
                                plat.y -= level_fall_speed;
                            }
                            is_level_falling_away = true;
                        }
                    }

                    // Update camera rotation
                    if (!player.isFrozenDueToLevelBeaten()) {
                        var shouldUpdateCamera = false;
                        switch (input.camera_rotation_type) {
                            .None => {},
                            .Gamepad => {
                                shouldUpdateCamera = true;
                            },
                            .Mouse => {
                                // Only update once for mouse movements
                                if (simNumber == 0) {
                                    shouldUpdateCamera = true;
                                }
                            },
                        }
                        if (shouldUpdateCamera) {
                            var rotation = rl.Vector3.init(0, 0, 0);
                            rotation.x = input.camera_rotation_delta.x;
                            rotation.y = input.camera_rotation_delta.y;
                            camera_pitch.y += rotation.y;
                            if (camera_pitch.y < -25) {
                                // Maximum looking up amount
                                camera_pitch.y = -25;
                            }
                            if (camera_pitch.y > 18) {
                                // Maximum looking down amount
                                camera_pitch.y = 18;
                            }
                            rl.updateCameraPro(&camera, rl.Vector3.init(0, 0, 0), rotation, 0);
                        }
                    }

                    // Move character
                    if (!player.isFrozenDueToLevelBeaten()) {
                        const speed: f32 = @TypeOf(player).move_speed;
                        var movement = rl.Vector3.init(0, 0, 0);
                        if (input.move_forward.is_held()) {
                            movement.x += speed;
                        }
                        if (input.move_backward.is_held()) {
                            movement.x -= speed;
                        }
                        if (input.strafe_left.is_held()) {
                            movement.y -= speed;
                        }
                        if (input.strafe_right.is_held()) {
                            movement.y += speed;
                        }
                        var new_position = rlx.moveForward(&camera, player.position, movement.x, true);
                        new_position = rlx.moveRight(&camera, new_position, movement.y, true);
                        if (!hasCollisionAtPosition(new_position)) {
                            player.position = new_position;
                        } else {
                            // If has collision, allow the new position if pushed out reasonably (ie. small staircase)
                            const push_out_step: f32 = 0.01; // 1cm
                            const push_out_limit: f32 = 0.05; // 5cm
                            var push_i = push_out_step;
                            while (push_i < push_out_limit and hasCollisionAtPosition(new_position)) : (push_i += push_out_step) {
                                new_position.y += push_out_step;
                            }
                            if (!hasCollisionAtPosition(new_position)) {
                                player.position = new_position;
                            }
                        }
                    }

                    // Update vspeed
                    if (!player.isFrozenDueToLevelBeaten()) {
                        var is_on_ground = false;
                        {
                            if (player.vspeed == 0) {
                                var ground_check_position = player.position;
                                ground_check_position.y -= 0.01; // 1cm
                                is_on_ground = hasCollisionAtPosition(ground_check_position);
                            }
                        }

                        // Jump
                        if (player.jumps_since_last_touched_ground < 2 and
                            player.vspeed >= 0 and
                            input.jump.is_held())
                        {
                            player.vspeed = @TypeOf(player).jump_power;
                            player.jumps_since_last_touched_ground += 1;
                            // rl.playSound(sndJump);
                        }

                        if (!is_on_ground) {
                            player.vspeed += @TypeOf(player).gravity;
                            if (player.vspeed >= 0.32) {
                                player.vspeed = 0.32;
                            }

                            var new_position = player.position;
                            new_position.y -= player.vspeed;
                            if (!hasCollisionAtPosition(new_position)) {
                                player.position = new_position;
                            } else {
                                if (player.vspeed > 0) {
                                    // If collided when falling, reset fall speed and put inside the ground, then push out
                                    player.position = new_position;
                                    player.vspeed = 0;
                                    player.jumps_since_last_touched_ground = 0;
                                    // Push out of ground if colliding
                                    while (hasCollisionAtPosition(player.position)) {
                                        player.position.y += 0.001; // 0.1cm
                                    }
                                }
                                if (player.vspeed < 0) {
                                    // If collided when jumping
                                    player.position = new_position;
                                    player.vspeed = 0;
                                    // Push out of ground if colliding
                                    while (hasCollisionAtPosition(player.position)) {
                                        player.position.y -= 0.001; // 0.1cm
                                    }
                                }
                            }
                        }

                        // If fallen off edge, restart at level start
                        if (player.position.y < -75) {
                            resetLevel();
                        }
                    }

                    // Move platforms to their next position
                    if (!is_level_falling_away) {
                        var above_check_position = player.position;
                        above_check_position.y -= 0.01; // 1cm
                        for (currentLevel.moving_platforms.slice()) |*plat| {
                            const has_player_above = rl.checkCollisionBoxSphere(plat.boundingBox(), above_check_position, @TypeOf(player).size);
                            const dest_pos = plat.positions.get(plat.destination_position);
                            const dx = ent.moveTowardsDelta(plat.x, dest_pos.x, 0.01);
                            const dy = ent.moveTowardsDelta(plat.y, dest_pos.y, 0.01);
                            const dz = ent.moveTowardsDelta(plat.z, dest_pos.z, 0.01);
                            plat.x += dx;
                            plat.y += dy;
                            plat.z += dz;
                            const is_colliding_with_player = rl.checkCollisionBoxSphere(plat.boundingBox(), player.position, @TypeOf(player).size);
                            if (is_colliding_with_player) {
                                player.position.x += dx;
                                player.position.y += dy;
                                player.position.z += dz;
                            } else if (has_player_above) {
                                player.position.x += dx;
                                player.position.y += dy;
                                player.position.z += dz;
                            }
                            if (plat.x == dest_pos.x and plat.y == dest_pos.y and plat.z == dest_pos.z) {
                                plat.destination_position += 1;
                                if (plat.destination_position >= plat.positions.len) {
                                    plat.destination_position = 0;
                                }
                            }
                        }
                    }

                    // Grab collectable
                    {
                        var i: usize = 0;
                        while (i < currentLevel.collectables.len) {
                            const collectable = &currentLevel.collectables.slice()[i];
                            if (!rl.checkCollisionBoxSphere(collectable.boundingBox(), player.position, @TypeOf(player).size)) {
                                i += 1; // Only increment if no match
                                continue;
                            }
                            _ = currentLevel.collectables.swapRemove(i);
                            snd.playDing();
                            // i += 1; // dont increment as we removed this item
                        }
                        if (currentLevel.collectables.len == 0 and
                            player.level_state.exit_has_appeared == false)
                        {
                            player.level_state.exit_has_appeared = true;
                            snd.sndLevelExitAppeared.playSound();
                        }
                    }

                    // Only allow entering exit door if all collectibles exist
                    if (currentLevel.collectables.len == 0) {
                        if (rl.checkCollisionBoxSphere(currentLevel.exit_door.boundingBox(), player.position, @TypeOf(player).size)) {
                            player.level_state.beaten = true;
                        }
                    }
                }
            }
        }
        // Update camera after movement
        const isFallingToDeath = player.position.y < -10;
        if (!isFallingToDeath) {
            // pull camera X metres back from player
            camera.position = rlx.moveForward(&camera, player.position, -2.75, true);
            // raise camera a bit
            camera.position.y += 0.5;
        }
        camera.target = player.position;
        rl.updateCameraPro(&camera, rl.Vector3.init(0, 0, 0), camera_pitch, 0);

        // First person
        // camera.position = rlx.moveForward(&camera, player.position, -0.1, true);
        // camera.position.y += 0.02;
        // camera.target = player.position;

        // ------------------------------------------------------
        // Draw
        // ------------------------------------------------------
        {
            rl.beginDrawing();
            defer rl.endDrawing();

            rl.clearBackground(rl.Color.white);

            {
                // note(jae): 2023-11-05
                // No VR support in raylib other than the simulator
                // if (vr.controller) |vr_controller| {
                //     rl.beginTextureMode(vr_controller.target);
                //     rl.clearBackground(rl.Color.white);
                //     rl.beginVrStereoMode(vr_controller.config);
                // }
                // defer {
                //     if (vr.controller) |_| {
                //         rl.endVrStereoMode();
                //         rl.endTextureMode();
                //     }
                // }

                rl.beginMode3D(camera);
                defer rl.endMode3D();

                rl.clearBackground(rl.Color.black);

                // draw skybox
                //
                // note(jae): 2023-10-14
                // requires using rlgl.h, so not doing yet
                {
                    // We are inside the cube, we need to disable backface culling!
                    // rl.rlDisableBackfaceCulling();
                    // defer rl.rlEnableBackfaceCulling();
                    // rl.rlDisableDepthMask();
                    // defer rl.rlEnableDepthMask();

                    // rl.drawModel(skybox, rl.Vector3.init(0, 0, 0), 1.0, rl.Color.white);
                }

                // draw player
                rl.drawSphere(player.position, @TypeOf(player).size, rl.Color.red);
                // rl.drawSphereWires(player.position, @TypeOf(player).size, 100, 100, rl.Color.white);

                // draw level
                for (currentLevel.cubes.slice()) |*cube| {
                    const position = rl.Vector3.init(cube.x, cube.y, cube.z);
                    rl.drawCube(
                        position,
                        cube.width,
                        cube.height,
                        cube.length,
                        cube.color,
                    );
                    rl.drawCubeWires(position, cube.width, cube.height, cube.length, rl.Color.white);
                }
                for (currentLevel.moving_platforms.slice()) |*plat| {
                    const position = rl.Vector3.init(plat.x, plat.y, plat.z);
                    rl.drawCube(
                        position,
                        plat.width,
                        plat.height,
                        plat.length,
                        rl.Color.green,
                    );
                    rl.drawCubeWires(position, plat.width, plat.height, plat.length, rl.Color.white);
                }
                for (currentLevel.collectables.slice()) |*collectable| {
                    var cm = collectableModel;
                    switch (collectable.image) {
                        .KevinJamesBooba => {
                            cm.materials[0].maps[@intFromEnum(rl.MATERIAL_MAP_DIFFUSE)].texture = texKevinJamesBooba;
                        },
                        .KevinJamesSwords => {
                            cm.materials[0].maps[@intFromEnum(rl.MATERIAL_MAP_DIFFUSE)].texture = texKevinJamesSwords;
                        },
                    }
                    const position = rl.Vector3.init(collectable.x, collectable.y, collectable.z);
                    collectable.rotate += 0.5 * @as(f32, @floatFromInt(timesToRunUpdateSim));
                    rl.drawModelEx(
                        cm,
                        position,
                        rlx.vector3Normalize(rl.Vector3.init(0, 1, 0)),
                        collectable.rotate,
                        rl.Vector3.init(1, 1, 1),
                        rl.Color.white,
                    );
                    // rl.drawCube(position, collectable.width, collectable.height, collectable.length, collectable.color);
                }
                // Render ExitDoor
                if (currentLevel.collectables.len == 0) {
                    var exit_door = currentLevel.exit_door;
                    {
                        const position = rl.Vector3.init(exit_door.x, exit_door.y, exit_door.z);
                        rl.drawCube(
                            position,
                            @TypeOf(exit_door).width,
                            @TypeOf(exit_door).height,
                            @TypeOf(exit_door).length,
                            rl.Color.purple,
                        );
                    }

                    // Draw the collision around the door
                    const cubes = exit_door.getCubes();
                    for (cubes.slice()) |*cube| {
                        const position = rl.Vector3.init(cube.x, cube.y, cube.z);
                        rl.drawCube(
                            position,
                            cube.width,
                            cube.height,
                            cube.length,
                            cube.color,
                        );
                        rl.drawCubeWires(position, cube.width, cube.height, cube.length, rl.Color.white);
                    }
                }
            }

            // note(jae): 2023-11-05
            // No VR support in raylib other than the simulator
            // if (vr.controller) |vr_controller| {
            //     // The target's height is flipped (in the source Rectangle), due to OpenGL reasons
            //     var sourceRec: rl.Rectangle = .{ .x = 0, .y = 0, .width = @floatFromInt(vr_controller.target.texture.width), .height = @floatFromInt(-vr_controller.target.texture.height) };
            //     var destRec: rl.Rectangle = .{ .x = 0, .y = 0, .width = @floatFromInt(rl.getScreenWidth()), .height = @floatFromInt(rl.getScreenHeight()) };

            //     rl.beginDrawing();
            //     defer rl.endDrawing();
            //     rl.clearBackground(rl.Color.white);
            //     rl.beginShaderMode(vr_controller.distortion);
            //     defer rl.endShaderMode();
            //     rl.drawTexturePro(vr_controller.target.texture, sourceRec, destRec, rl.Vector2{ .x = 0.0, .y = 0.0 }, 0.0, rl.Color.white);
            // }

            // Draw debug text
            if (debugInfoEnabled) {
                var y: i32 = 16;
                try rlx.drawTextf("FPS: {}", .{rl.getFPS()}, 16, y, 20, rl.Color.light_gray);
                y += 24;
                try rlx.drawTextf("Player X/Y/Z: {d:.4} {d:.4} {d:.4}", .{ player.position.x, player.position.y, player.position.z }, 16, y, 20, rl.Color.light_gray);
                y += 24;
                try rlx.drawTextf("Camera Y: {d:.4}", .{camera_pitch.y}, 16, y, 20, rl.Color.light_gray);
                y += 24;
                try rlx.drawTextf("Camera Rotation x/y: {d:.4} {d:.4}\n", .{ input.camera_rotation_delta.x, input.camera_rotation_delta.y }, 16, y, 20, rl.Color.light_gray);
                y += 24;
            }

            // Draw timer
            {
                const font_size = 42;
                const time_left_in_seconds = currentLevel.time_to_beat_in_seconds - @divFloor(player.time_passed_in_ticks, targetTickRate);
                var text_color = rl.Color.white;
                if (time_left_in_seconds < 10) {
                    text_color = rl.Color.red;
                }
                var backing_array = std.BoundedArray(u8, 100){};
                const text = try rlx.textf(&backing_array, "Time remaining: {}", .{time_left_in_seconds});
                const width = rl.measureText(text, font_size);
                rl.drawText(text, @divFloor(rl.getScreenWidth(), 2) - @divFloor(width, 2), 32, font_size, text_color);
                // try rlx.drawTextf("Time remaining: {}", .{time_left_in_seconds}, @divFloor(rl.getScreenWidth(), 2), 32, 42, text_color);
            }

            // Draw
            if (player.level_state.exit_has_appeared) {
                const text = "The level exit has appeared, Lachlan's game didn't have this sound effect";
                const font_size = 32;
                const width = rl.measureText(text, font_size);
                rl.drawText(text, @divFloor(rl.getScreenWidth(), 2) - @divFloor(width, 2), rl.getScreenHeight() - 60, font_size, rl.Color.light_gray);
            }

            // Fade in
            if (player.level_state.fade_tick > 0) {
                var fade_percent: f32 = @as(f32, @floatFromInt(player.level_state.fade_tick)) / @as(f32, @floatFromInt(fade_in_amount));
                fade_percent = fade_percent * 255;
                if (fade_percent >= 255) {
                    fade_percent = 255;
                }
                if (fade_percent <= 0) {
                    fade_percent = 0;
                }
                rl.drawRectangle(0, 0, rl.getScreenWidth(), rl.getScreenHeight(), rl.Color{
                    .r = 0,
                    .g = 0,
                    .b = 0,
                    .a = @intFromFloat(fade_percent),
                });
            }

            // Credit fade in
            if (currentLevelCreator.len > 0 and player.level_state.credit_fade_tick > 0) {
                var fade_percent: f32 = @as(f32, @floatFromInt(player.level_state.credit_fade_tick)) / @as(f32, @floatFromInt(credit_fade_in_amount));
                fade_percent = fade_percent * 255;
                if (fade_percent >= 255) {
                    fade_percent = 255;
                }
                if (fade_percent <= 0) {
                    fade_percent = 0;
                }

                const screen_width: f32 = @floatFromInt(rl.getScreenWidth());
                const screen_height: f32 = @floatFromInt(rl.getScreenHeight());

                var y: f32 = 0;
                {
                    const font_size: f32 = 60;
                    const text = currentLevelCreator;
                    const dimen = rl.measureTextEx(rl.getFontDefault(), text, font_size, 10);
                    y = screen_height - dimen.y;
                    y -= 16;
                    rl.drawText(text, @intFromFloat(screen_width - dimen.x), @intFromFloat(y), font_size, rl.Color{
                        .r = 255,
                        .g = 255,
                        .b = 255,
                        .a = @intFromFloat(fade_percent),
                    });
                }
                {
                    const font_size: f32 = 36;
                    const text = "Level created by";
                    const dimen = rl.measureTextEx(rl.getFontDefault(), text, font_size, 10);
                    y -= dimen.y;
                    rl.drawText(text, @intFromFloat(screen_width - dimen.x), @intFromFloat(y), font_size, rl.Color{
                        .r = 255,
                        .g = 255,
                        .b = 255,
                        .a = @intFromFloat(fade_percent),
                    });
                }
            }

            // Handle/Draw touch
            // const touch_points: u32 = @intCast(rl.getTouchPointCount());
            // if (touch_points > 0) {
            //     const big_circle = 64;
            //     const radius = 32;

            //     const x: f32 = big_circle + 32;
            //     const y: f32 = @as(f32, @floatFromInt(rl.getScreenHeight())) - 32 - big_circle;

            //     for (0..touch_points) |tpi| {
            //         const touch_pos = rl.getTouchPosition(@intCast(tpi));
            //         if (rl.checkCollisionPointCircle(touch_pos, .{ .x = x, .y = y - 16 }, radius)) {
            //             switch (input.move_forward) {
            //                 InputState.None => input.move_forward = InputState.Pressed,
            //                 InputState.Pressed => input.move_forward = InputState.Held,
            //                 else => {},
            //             }
            //         } else {
            //             input.move_forward = InputState.None;
            //         }
            //     }

            //     // Draw
            //     rl.drawCircleLines(big_circle + 32, rl.getScreenHeight() - 32 - big_circle, big_circle, rl.Color.white);
            //     rl.drawCircle(big_circle + 32, rl.getScreenHeight() - 32 - big_circle, radius, rl.Color.white);
            // }

            // Draw menu
            if (menu.menu_type != .None) {
                rl.drawRectangle(0, 0, rl.getScreenWidth(), rl.getScreenHeight(), rl.Color{
                    .r = 0,
                    .g = 0,
                    .b = 0,
                    .a = 190,
                });

                const font = rl.getFontDefault();
                const font_size = 48;
                const spacing: f32 = 10;
                const x: f32 = 48;
                var y: f32 = 96;
                const default_text_color = rl.Color.white;
                const highlight_text_color = rl.Color.black;
                var it_menu_index: @TypeOf(menu.selected_item_index) = 0;

                // Detect mouse
                var has_mouse_moved = false;
                var selected_with_mouse = false;
                const mouse_pos = rl.getMousePosition();
                const mouse_delta = rl.getMouseDelta();
                const is_mouse_pressed = rl.isMouseButtonPressed(rl.MouseButton.mouse_button_left);
                if (@abs(mouse_delta.x) > 1 or @abs(mouse_delta.y) > 1) {
                    has_mouse_moved = true;
                }

                const MenuItem = struct {
                    label: [:0]const u8,
                    options: [][:0]const u8 = &[0][:0]const u8{},
                };

                const OptionsMenuItemKind = enum(u8) {
                    // Windowed,
                    Fullscreen,
                    Sound,
                    Music,
                    Framerate,
                    Back,
                };

                var items: []MenuItem = &[0]MenuItem{};
                switch (menu.menu_type) {
                    .TitleMenu, .PauseMenu => {
                        // Draw header
                        {
                            const header_font_size = 58;
                            const text = switch (menu.menu_type) {
                                .None => unreachable,
                                .TitleMenu => "Jae's Hyperreal 3D Generation: Singluxe",
                                .PauseMenu => "Game Paused",
                                else => unreachable,
                            };
                            const dimen = rl.measureTextEx(font, text, header_font_size, spacing);
                            rl.drawText(text, @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(y)), header_font_size, rl.Color.white);
                            y += dimen.y + 48;
                        }
                        switch (menu.menu_type) {
                            .TitleMenu => {
                                var menu_items = [_]MenuItem{
                                    .{ .label = "Start Game" },
                                    .{ .label = "Options" },
                                    .{ .label = "Credits" },
                                    .{ .label = "Exit" },
                                };
                                items = &menu_items;
                            },
                            .PauseMenu => {
                                var menu_items = [_]MenuItem{
                                    .{ .label = "Resume" },
                                    .{ .label = "Options" },
                                    .{ .label = "Exit" },
                                };
                                items = &menu_items;
                            },
                            else => unreachable,
                        }
                    },
                    .OptionsMenu => {
                        // Draw header
                        {
                            const header_font_size = 64;
                            const text = "Options";
                            const dimen = rl.measureTextEx(font, text, header_font_size, spacing);
                            rl.drawText(text, @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(y)), header_font_size, rl.Color.white);
                            y += dimen.y + 48;
                        }
                        var onOffOptions = [_][:0]const u8{
                            "Off",
                            "On",
                        };
                        // var windowSizeOptions = [_][:0]const u8{
                        //     "Full",
                        //     "3/4",
                        //     "1/2",
                        // };
                        var screenOptions = [_][:0]const u8{
                            "Windowed",
                            "Fullscreen",
                        };
                        var frameRateOptions = [_][:0]const u8{
                            "Auto",
                            "30",
                            "60",
                            "120",
                        };
                        var options = [_]MenuItem{
                            // .{
                            //     .label = "Window Size",
                            //     .options = &windowSizeOptions,
                            // },
                            .{
                                .label = "Fullscreen",
                                .options = &screenOptions,
                            },
                            .{
                                .label = "Sound",
                                .options = &onOffOptions,
                            },
                            .{
                                .label = "Music",
                                .options = &onOffOptions,
                            },
                            .{
                                .label = "Framerate",
                                .options = &frameRateOptions,
                            },
                            .{
                                .label = "Back",
                            },
                        };
                        items = &options;
                    },
                    .CreditsMenu => {
                        y = 48;

                        // Draw header
                        {
                            const header_font_size = 64;
                            const text = "Credits";
                            const dimen = rl.measureTextEx(font, text, header_font_size, spacing);
                            rl.drawText(text, @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(y)), header_font_size, rl.Color.white);
                            y += dimen.y + 48;
                        }
                        const credit_font_size = 24;
                        {
                            const text = "Programmer / Designer / Sound:";
                            const dimen = rl.measureTextEx(font, text, font_size, spacing);
                            rl.drawText(text, @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(y)), font_size, rl.Color.white);
                            y += dimen.y + 24;
                        }
                        {
                            const text = "- SilbinaryWolf (Jae)";
                            const dimen = rl.measureTextEx(font, text, credit_font_size, spacing);
                            rl.drawText(text, @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(y)), credit_font_size, rl.Color.white);
                            y += dimen.y + 24;
                        }

                        // Level design
                        {
                            const text = "Level Design:";
                            const dimen = rl.measureTextEx(font, text, font_size, spacing);
                            rl.drawText(text, @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(y)), font_size, rl.Color.white);
                            y += dimen.y + 24;
                        }
                        {
                            const text = "- SilbinaryWolf (Jae)";
                            const dimen = rl.measureTextEx(font, text, credit_font_size, spacing);
                            rl.drawText(text, @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(y)), credit_font_size, rl.Color.white);
                            y += dimen.y + 24;
                        }
                        {
                            const text = "- Construc_";
                            const dimen = rl.measureTextEx(font, text, credit_font_size, spacing);
                            rl.drawText(text, @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(y)), credit_font_size, rl.Color.white);
                            y += dimen.y + 24;
                        }
                        {
                            const text = "- GebbOs";
                            const dimen = rl.measureTextEx(font, text, credit_font_size, spacing);
                            rl.drawText(text, @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(y)), credit_font_size, rl.Color.white);
                            y += dimen.y + 24;
                        }

                        // Music credits
                        {
                            const text = "Music:";
                            const dimen = rl.measureTextEx(font, text, font_size, spacing);
                            rl.drawText(text, @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(y)), font_size, rl.Color.white);
                            y += dimen.y + 24;
                        }
                        {
                            const text = "- Katie Dey";
                            const dimen = rl.measureTextEx(font, text, credit_font_size, spacing);
                            rl.drawText(text, @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(y)), credit_font_size, rl.Color.white);
                            y += dimen.y + 24;
                        }

                        // Back button
                        y += 24;
                        var options = [_]MenuItem{
                            .{
                                .label = "Back",
                            },
                        };
                        items = &options;
                    },
                    .GameBeatenMenu => {
                        // Draw header
                        {
                            const header_font_size = 64;
                            const text = "Game completed!";
                            const dimen = rl.measureTextEx(font, text, header_font_size, spacing);
                            rl.drawText(text, @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(y)), header_font_size, rl.Color.white);
                            y += dimen.y + 48;
                        }
                        {
                            const time_taken_in_seconds: f64 = @as(f64, @floatFromInt(settings.total_time_passed_in_ticks)) / targetTickRate;
                            var backing_array = std.BoundedArray(u8, 100){};
                            const text = try rlx.textf(&backing_array, "Your total time taken: {d:.4} seconds", .{time_taken_in_seconds});
                            const dimen = rl.measureTextEx(font, text, font_size, spacing);
                            rl.drawText(text, @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(y)), font_size, rl.Color.white);
                            y += dimen.y + 24;
                        }

                        // Add other high scores
                        const highscore_font_size = font_size * 0.75;
                        {
                            var backing_array = std.BoundedArray(u8, 100){};
                            const text = try rlx.textf(&backing_array, "Jae's total time taken: {d:.4} seconds", .{100.5000});
                            const dimen = rl.measureTextEx(font, text, highscore_font_size, spacing);
                            rl.drawText(text, @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(y)), highscore_font_size, rl.Color.white);
                            y += dimen.y + 24;
                        }
                        {
                            var backing_array = std.BoundedArray(u8, 100){};
                            const text = try rlx.textf(&backing_array, "Construc_'s total time taken: {d:.4} seconds", .{114.9167});
                            const dimen = rl.measureTextEx(font, text, highscore_font_size, spacing);
                            rl.drawText(text, @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(y)), highscore_font_size, rl.Color.white);
                            y += dimen.y + 24;
                        }
                        {
                            var backing_array = std.BoundedArray(u8, 100){};
                            const text = try rlx.textf(&backing_array, "GebbOs's total time taken: {d:.4} seconds", .{180.2917});
                            const dimen = rl.measureTextEx(font, text, highscore_font_size, spacing);
                            rl.drawText(text, @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(y)), highscore_font_size, rl.Color.white);
                            y += dimen.y + 24;
                        }

                        // Add options
                        y += 48 + 48;
                        var options = [_]MenuItem{
                            .{
                                .label = "Play ding sound!!!!!!",
                            },
                            .{
                                .label = "Go back to menu",
                            },
                        };
                        items = &options;
                    },
                    .None => unreachable,
                }

                var longest_text_width_in_menu: f32 = 0;
                for (items) |menu_item| {
                    const text = menu_item.label;
                    const dimen = rl.measureTextEx(font, text, font_size, spacing);
                    if (dimen.x > longest_text_width_in_menu) {
                        longest_text_width_in_menu = dimen.x;
                    }
                }
                for (items, 0..) |menu_item, menu_item_index| {
                    const text = menu_item.label;
                    const dimen = rl.measureTextEx(font, text, font_size, spacing);
                    const pos: rl.Vector3 = .{ .x = x - 16, .y = y - 16, .z = 0 };
                    const size: rl.Vector3 = .{ .x = dimen.x + 16, .y = dimen.y + 16, .z = 0 };
                    var text_color = default_text_color;

                    // If hovering on menu item with mouse or clicked on item
                    if ((has_mouse_moved or is_mouse_pressed) and
                        mouse_pos.x > pos.x and mouse_pos.x < pos.x + size.x and
                        mouse_pos.y > pos.y and mouse_pos.y < pos.y + size.y)
                    {
                        menu.selected_item_index = it_menu_index;
                        if (is_mouse_pressed) {
                            selected_with_mouse = true;
                        }
                    }

                    // If menu item selected
                    if (menu.selected_item_index == it_menu_index) {
                        text_color = highlight_text_color;
                        rl.drawRectangle(
                            @intFromFloat(pos.x),
                            @intFromFloat(pos.y),
                            @intFromFloat(size.x),
                            @intFromFloat(size.y),
                            rl.Color.white,
                        );
                    }

                    // Add option
                    if (menu_item.options.len > 0) {
                        var option_index_selected: i32 = -1;

                        switch (menu.menu_type) {
                            .OptionsMenu => {
                                switch (@as(OptionsMenuItemKind, @enumFromInt(menu_item_index))) {
                                    // SubMenuKind.Windowed => {
                                    //     switch (settings.windowSize) {
                                    //         .Full => option_index_selected = 0,
                                    //         .ThreeQuarter => option_index_selected = 1,
                                    //         .Half => option_index_selected = 2,
                                    //     }
                                    // },
                                    .Fullscreen => {
                                        option_index_selected = if (rl.isWindowFullscreen()) 1 else 0;
                                    },
                                    .Sound => option_index_selected = if (settings.isSoundEnabled) 1 else 0,
                                    .Music => option_index_selected = if (settings.isMusicEnabled) 1 else 0,
                                    .Framerate => {
                                        switch (settings.frameRate) {
                                            .Auto => option_index_selected = 0,
                                            .Rate30 => option_index_selected = 1,
                                            .Rate60 => option_index_selected = 2,
                                            .Rate120 => option_index_selected = 3,
                                        }
                                    },
                                    else => {},
                                }
                            },
                            else => unreachable,
                        }

                        // Put options after text
                        var sx = x + longest_text_width_in_menu + 16;
                        for (menu_item.options, 0..) |option, option_index| {
                            var option_font_color = rl.Color.white;
                            const sub_dimen = rl.measureTextEx(font, option, font_size, spacing);
                            if (option_index_selected != -1 and option_index == option_index_selected) {
                                rl.drawRectangle(
                                    @intFromFloat(sx - 16),
                                    @intFromFloat(pos.y),
                                    @intFromFloat(sub_dimen.x + 16),
                                    @intFromFloat(sub_dimen.y + 16),
                                    rl.Color.white,
                                );
                                option_font_color = rl.Color.black;
                            }
                            rl.drawText(option, @intFromFloat(sx), @intFromFloat(pos.y + 16), font_size, option_font_color);
                            sx += sub_dimen.x + 16;
                        }
                    }

                    rl.drawText(text, @intFromFloat(pos.x + 16), @intFromFloat(pos.y + 16), font_size, text_color);
                    y += dimen.y + 24;
                    it_menu_index += 1;
                }

                if (input.menu == InputState.Pressed) {
                    menu.pop();
                } else if (input.move_forward == InputState.Pressed) {
                    // If more than 1 menu item
                    if (it_menu_index > 1) {
                        menu.selected_item_index -= 1;
                        if (menu.selected_item_index < 0) {
                            menu.selected_item_index = it_menu_index - 1;
                        }
                    }
                } else if (input.move_backward == InputState.Pressed) {
                    // If more than 1 menu item
                    if (it_menu_index > 1) {
                        menu.selected_item_index += 1;
                        if (menu.selected_item_index >= it_menu_index) {
                            menu.selected_item_index = 0;
                        }
                    }
                } else {
                    // This logic ensures left-click doesn't work on a menu item
                    // unless you're hovering over it because we've bound jump
                    // to left-click.
                    var do_select = false;
                    if (is_mouse_pressed) {
                        if (selected_with_mouse) {
                            do_select = true;
                        }
                    } else {
                        do_select = input.jump == InputState.Pressed;
                    }
                    if (do_select) {
                        input.jump = InputState.Released;
                        switch (menu.menu_type) {
                            .TitleMenu => {
                                switch (menu.selected_item_index) {
                                    0 => {
                                        menu.pop();
                                        if (settings.isMusicEnabled) {
                                            if (!rl.isMusicStreamPlaying(music)) {
                                                rl.playMusicStream(music);
                                            }
                                        }
                                    },
                                    1 => {
                                        try menu.pushType(Menu.Type.OptionsMenu);
                                    },
                                    2 => {
                                        try menu.pushType(Menu.Type.CreditsMenu);
                                    },
                                    3 => {
                                        rl.closeWindow();
                                    },
                                    else => unreachable,
                                }
                            },
                            .PauseMenu => {
                                switch (menu.selected_item_index) {
                                    0 => {
                                        menu.pop();
                                    },
                                    1 => {
                                        try menu.pushType(Menu.Type.OptionsMenu);
                                    },
                                    2 => {
                                        rl.closeWindow();
                                    },
                                    else => unreachable,
                                }
                            },
                            .OptionsMenu => {
                                switch (@as(OptionsMenuItemKind, @enumFromInt(menu.selected_item_index))) {
                                    // SubMenuKind.Windowed => {
                                    //     switch (settings.windowSize) {
                                    //         .Full => settings.windowSize = .ThreeQuarter,
                                    //         .ThreeQuarter => settings.windowSize = .Half,
                                    //         .Half => settings.windowSize = .Full,
                                    //     }
                                    //     var screenWidth: f32 = @floatFromInt(rl.getScreenWidth());
                                    //     var screenHeight: f32 = @floatFromInt(rl.getScreenHeight());
                                    //     switch (settings.windowSize) {
                                    //         .Full => {
                                    //             // do nothing
                                    //         },
                                    //         .ThreeQuarter => {
                                    //             screenWidth *= 0.75;
                                    //             screenHeight *= 0.75;
                                    //         },
                                    //         .Half => {
                                    //             screenWidth *= 0.5;
                                    //             screenHeight *= 0.5;
                                    //         },
                                    //     }
                                    //     rl.setWindowSize(@intFromFloat(screenWidth), @intFromFloat(screenHeight));
                                    // },
                                    .Fullscreen => rl.toggleFullscreen(),
                                    .Sound => {
                                        settings.isSoundEnabled = !settings.isSoundEnabled;
                                        if (!settings.isSoundEnabled) {
                                            snd.stopAllSounds();
                                        }
                                    },
                                    .Music => {
                                        settings.isMusicEnabled = !settings.isMusicEnabled;
                                        if (!settings.isMusicEnabled) {
                                            rl.stopMusicStream(music);
                                        } else {
                                            rl.playMusicStream(music);
                                        }
                                    },
                                    .Framerate => {
                                        switch (settings.frameRate) {
                                            .Auto => settings.frameRate = .Rate30,
                                            .Rate30 => settings.frameRate = .Rate60,
                                            .Rate60 => settings.frameRate = .Rate120,
                                            .Rate120 => settings.frameRate = .Auto,
                                        }
                                        switch (settings.frameRate) {
                                            .Auto => rl.setTargetFPS(targetTickRate),
                                            .Rate30 => rl.setTargetFPS(30),
                                            .Rate60 => rl.setTargetFPS(60),
                                            .Rate120 => rl.setTargetFPS(120),
                                        }
                                    },
                                    .Back => {
                                        menu.pop();
                                    },
                                }
                            },
                            .CreditsMenu => {
                                menu.pop();
                            },
                            .GameBeatenMenu => {
                                switch (menu.selected_item_index) {
                                    0 => {
                                        // If user disabled sound but explicitly pressed here to hear
                                        // a ding sound, then play it.
                                        const prevSoundEnabled = settings.isSoundEnabled;
                                        settings.isSoundEnabled = true;
                                        snd.playDing();
                                        settings.isSoundEnabled = prevSoundEnabled;
                                    },
                                    1 => {
                                        menu.pop();
                                        try resetGame();
                                    },
                                    else => unreachable,
                                }
                            },
                            .None => unreachable,
                        }
                    }
                }
            }
        }
    }
}
