const rl = @import("raylib");

pub const Controller = struct {
    config: rl.VrStereoConfig,
    distortion: rl.Shader,
    target: rl.RenderTexture,
};

pub var controller: ?Controller = null;

// init VR simulator
//
// note(jae): 2023-11-05
// Without using something like OpenXR outside of raylib, this just simulates VR and won't
// get us anywhere. I experimented with this for a bit, but didn't end up using it.
pub fn init() void {
    var device: rl.VrDeviceInfo = .{
        // Oculus Rift CV1 parameters for simulator
        .hResolution = 2160, // Horizontal resolution in pixels
        .vResolution = 1200, // Vertical resolution in pixels
        .hScreenSize = 0.133793, // Horizontal size in meters
        .vScreenSize = 0.0669, // Vertical size in meters
        .vScreenCenter = 0.04678, // Screen center in meters
        .eyeToScreenDistance = 0.041, // Distance between eye and display in meters
        .lensSeparationDistance = 0.07, // Lens separation distance in meters
        .interpupillaryDistance = 0.07, // IPD (distance between pupils) in meters

        // NOTE: CV1 uses fresnel-hybrid-asymmetric lenses with specific compute shaders
        // Following parameters are just an approximation to CV1 distortion stereo rendering
        .lensDistortionValues = [4]f32{ 1.0, 0.22, 0.24, 0.0 }, // Lens distortion constant
        .chromaAbCorrection = [4]f32{ 0.996, -0.004, 1.014, 0.0 }, // Chromatic aberration correction
    };
    const config = rl.loadVrStereoConfig(device);

    // #if defined(PLATFORM_DESKTOP)
    //     #define GLSL_VERSION        330
    // #else   // PLATFORM_ANDROID, PLATFORM_WEB
    //     #define GLSL_VERSION        100
    // #endif
    const GLSL_VERSION = 330;

    var distortion: rl.Shader = undefined;
    if (GLSL_VERSION == 330) {
        distortion = rl.loadShaderFromMemory(null, @embedFile("resources/shaders/distortion330.fs"));
    } else {
        @panic("todo: for web");
        //shader = rl.loadShader(0, "resources/distortion110.fs");
        //rl.loadShaderFromMemory(0, fsCode: ?[:0]const u8)
    }

    // Update distortion shader with lens and distortion-scale parameters
    rl.setShaderValue(
        distortion,
        rl.getShaderLocation(distortion, "leftLensCenter"),
        &config.leftLensCenter,
        @intFromEnum(rl.ShaderUniformDataType.shader_uniform_vec2),
    );
    rl.setShaderValue(
        distortion,
        rl.getShaderLocation(distortion, "rightLensCenter"),
        &config.rightLensCenter,
        @intFromEnum(rl.ShaderUniformDataType.shader_uniform_vec2),
    );
    rl.setShaderValue(
        distortion,
        rl.getShaderLocation(distortion, "leftScreenCenter"),
        &config.leftScreenCenter,
        @intFromEnum(rl.ShaderUniformDataType.shader_uniform_vec2),
    );
    rl.setShaderValue(
        distortion,
        rl.getShaderLocation(distortion, "rightScreenCenter"),
        &config.rightScreenCenter,
        @intFromEnum(rl.ShaderUniformDataType.shader_uniform_vec2),
    );
    rl.setShaderValue(
        distortion,
        rl.getShaderLocation(distortion, "scale"),
        &config.scale,
        @intFromEnum(rl.ShaderUniformDataType.shader_uniform_vec2),
    );
    rl.setShaderValue(
        distortion,
        rl.getShaderLocation(distortion, "scaleIn"),
        &config.scaleIn,
        @intFromEnum(rl.ShaderUniformDataType.shader_uniform_vec2),
    );
    rl.setShaderValue(
        distortion,
        rl.getShaderLocation(distortion, "deviceWarpParam"),
        &device.lensDistortionValues,
        @intFromEnum(rl.ShaderUniformDataType.shader_uniform_vec4),
    );
    rl.setShaderValue(
        distortion,
        rl.getShaderLocation(distortion, "chromaAbParam"),
        &device.chromaAbCorrection,
        @intFromEnum(rl.ShaderUniformDataType.shader_uniform_vec4),
    );

    const target = rl.loadRenderTexture(2160, 1200);

    controller = .{
        .config = config,
        .distortion = distortion,
        .target = target,
    };
}
