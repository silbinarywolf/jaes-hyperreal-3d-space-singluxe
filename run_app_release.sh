#!/bin/bash
set -e

zig build -Doptimize=ReleaseSafe && ./zig-out/bin/jae-3d-hyperreal
