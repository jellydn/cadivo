#!/bin/sh
# Command Line Tools have no Metal compiler, so SwiftPM builds mlx-swift without its shaders and MLX
# fails at runtime with "Failed to load the default metallib". The Python mlx wheel ships the same
# shaders prebuilt: MLX looks for mlx.metallib next to the binary. Keep MLX_VERSION equal to the MLX
# core inside mlx-swift (Source/Cmlx/mlx, v0.32.4 for mlx-swift 0.33.0). With full Xcode this is not needed.
set -e
MLX_VERSION=0.32.4
CONFIG=${1:-release}
cd "$(dirname "$0")/.."
VENV=.build/mlx-metallib-venv
[ -d "$VENV" ] || uv venv -q -p 3.12 "$VENV"
uv pip install -q -p "$VENV" "mlx==$MLX_VERSION"
cp "$(find "$VENV" -name mlx.metallib | head -1)" ".build/$CONFIG/mlx.metallib"
echo "copied mlx.metallib ($MLX_VERSION) to .build/$CONFIG/"
