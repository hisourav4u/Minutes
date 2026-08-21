#!/usr/bin/env bash
# setup.sh - one-time dependencies for Minutes: whisper.cpp and a model.
# Idempotent; re-running skips whatever is already in place.

set -euo pipefail

MODELS_DIR="$HOME/Library/Application Support/Minutes/models"
MODEL="${1:-large-v3-turbo}"   # tiny | base | small | medium | large-v3-turbo | large-v3
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${MODEL}.bin"

# -- whisper.cpp ----------------------------------------------------------------
if command -v whisper-cli >/dev/null 2>&1; then
    echo "whisper-cli: already installed ($(command -v whisper-cli))"
else
    echo "Installing whisper.cpp via Homebrew..."
    brew install whisper-cpp
fi

# -- model ----------------------------------------------------------------------
mkdir -p "$MODELS_DIR"
DEST="$MODELS_DIR/ggml-${MODEL}.bin"
if [[ -f "$DEST" ]]; then
    echo "model: ggml-${MODEL}.bin already present"
else
    echo "Downloading ggml-${MODEL}.bin (this can be several hundred MB)..."
    curl -L --fail --progress-bar -o "${DEST}.part" "$URL"
    mv "${DEST}.part" "$DEST"
    echo "model saved to $DEST"
fi

# -- claude CLI (summaries) -------------------------------------------------------
if command -v claude >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/claude" ]]; then
    echo "claude CLI: found (summaries enabled)"
else
    echo "claude CLI: NOT found - notes will contain the transcript only."
fi

echo "Setup complete. Build the app with ./build_and_run.sh"
