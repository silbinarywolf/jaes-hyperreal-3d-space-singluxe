#!/bin/bash
set -e

zig build && ./zig-out/bin/jae-3d-hyperreal
