#!/bin/bash
# This has only been tested to run via Git Bash Windows and expects your "emsdk" folder
# to be in your PATH environment variable
set -e

if !command -v emsdk &> /dev/null
then
    echo "unable to find emsdk, is it in your path?"
    exit 1
fi
source emsdk_env.sh --build=Release
EMSCRIPTEN_PATH="$(dirname $(which emsdk))"
# note(jae): 2023-11-20
# ReleaseSafe is currently broken for wasm in Zig 0.12.0-dev.1645+7b99189f1 OR my code is broken in a way that
# doesn't show up in release builds. Who knows.
zig build -Doptimize=ReleaseSafe -Dtarget=wasm32-emscripten --sysroot $EMSCRIPTEN_PATH/upstream/emscripten
#zig build -Doptimize=Debug -Dtarget=wasm32-emscripten --sysroot $EMSCRIPTEN_PATH/upstream/emscripten
if ! emrun ./zig-out/htmlout/index.html
then
    echo "failed to run emrun"
    exit 1
fi
