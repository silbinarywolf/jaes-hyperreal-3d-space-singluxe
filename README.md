# Jae's Hyperreal 3D Generation: Singluxe

## Description

This is the source code to my first 3D game, released on itch.io [here](https://silbinarywolf.itch.io/jaes-hyperreal-3d-space-singluxe).

## Requirements

- Zig 0.12.0-dev.1685+994e19164
    - [Windows](https://ziglang.org/builds/zig-windows-x86_64-0.12.0-dev.1685+994e19164.zip)
- Emscripten (for the web build)

## Build a debug build

Option 1) Build and run manually

```
zig build && zig-out/bin/3d-raylib
```

Option 2) Build and run via the provided shell script
```
./run_app.sh
```

*Apologies to Linux or Mac folks, 

## Build a web build

Currently broken. Current released web build was achieved by working around a memory bug that I *think* is caused by `wavefront.zig`. I just parse the level data at compile-time and patched the current [parseFloat bug](https://github.com/ziglang/zig/issues/17662) in the std library so that `optimize = false` [here](https://github.com/ziglang/zig/blob/master/lib/std/fmt/parse_float/parse_float.zig#L8).
