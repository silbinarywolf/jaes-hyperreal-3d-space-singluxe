const rl = @import("raylib");

var sndBing1: Sound = .{};
var sndBing2: Sound = .{};
var sndBing3: Sound = .{};
var sndBingLow: Sound = .{};
var sndBingHigh: Sound = .{};
// bing_sweeeeeet_charrriot.wav
pub var sndLevelExitAppeared: Sound = .{};

// ding_sounds is rotated through in order each time you collect a collectible
const ding_sounds = [_]*Sound{
    &sndBing1,
    &sndBing2,
    // artistic intent: hear a clear human "ding" after hearing *ding* noises because
    // I thought it'd be funny
    &sndBingLow,
    &sndBing3,
    &sndBing1,
    &sndBing2,
    &sndBingHigh,
    &sndBing3,
    &sndBing1,
    &sndBing2,
    &sndBing3,
    &sndBing1,
    &sndBing2,
};

const all_sounds = [_]*Sound{
    &sndBing1,
    &sndBing2,
    &sndBing3,
    &sndBingLow,
    &sndBingHigh,
    &sndLevelExitAppeared,
};

var isSoundEnabledDefault = false;
var isSoundEnabled: *bool = &isSoundEnabledDefault;

pub fn init(isSoundPlayingRef: *bool) !void {
    isSoundEnabled = isSoundPlayingRef;

    sndBing1 = Sound.init(@embedFile("resources/sounds/bing_1.ogg"), "*ding noise*");
    sndBing2 = Sound.init(@embedFile("resources/sounds/bing_2.ogg"), "*ding noise*");
    sndBing3 = Sound.init(@embedFile("resources/sounds/bing_3.ogg"), "*ding noise*");
    sndBingLow = Sound.init(@embedFile("resources/sounds/bing_low.ogg"), "low pitched human voice: ding");
    sndBingHigh = Sound.init(@embedFile("resources/sounds/bing_high.ogg"), "high pitched human voice: ding");

    sndLevelExitAppeared = Sound.init(@embedFile("resources/sounds/level_exit_appeared.ogg"), "the level exit has appeared, Lachlan's game didn't have this sound effect");
}

pub fn deinit() void {
    for (all_sounds) |sound| {
        if (!sound.loaded) {
            continue;
        }
        rl.unloadSound(sound.sound);
    }
}

pub fn stopAllSounds() void {
    for (all_sounds) |sound| {
        if (!sound.loaded) {
            continue;
        }
        rl.stopSound(sound.sound);
    }
}

var dingIndex: u32 = 0;

pub fn playDing() void {
    const sound = ding_sounds[dingIndex];
    sound.playSound();
    dingIndex += 1;
    if (dingIndex >= ding_sounds.len) {
        dingIndex = 0;
    }
}

pub const Sound = struct {
    const Self = @This();

    loaded: bool = false,
    // subtitle is unused, ended up being out of scope for getting this out the door
    subtitle: []const u8 = &[0]u8{},
    sound: rl.Sound = undefined,

    pub fn init(data: []const u8, subtitle: []const u8) Sound {
        const wavData = rl.loadWaveFromMemory(".ogg", data);
        defer rl.unloadWave(wavData);
        const sndData = rl.loadSoundFromWave(wavData);
        rl.setSoundVolume(sndData, 1.5);
        return .{
            .loaded = true,
            .subtitle = subtitle,
            .sound = sndData,
        };
    }

    pub fn playSound(self: *Self) void {
        if (isSoundEnabled.*) {
            rl.playSound(self.sound);
        }
    }
};
