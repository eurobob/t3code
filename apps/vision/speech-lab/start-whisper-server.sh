#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
lab_dir="${T3_SPEECH_LAB_DIR:-$repo_root/.t3/speech-lab-server}"
source_dir="$lab_dir/whisper.cpp"
build_dir="$source_dir/build"
model_dir="$lab_dir/models"
revision="v1.9.2"
model="large-v3-turbo"
host="${T3_SPEECH_LAB_HOST:-127.0.0.1}"
port="${T3_SPEECH_LAB_PORT:-8085}"
threads="${T3_SPEECH_LAB_THREADS:-6}"
prepare_only=false

case "${1:-}" in
  "") ;;
  --prepare-only) prepare_only=true ;;
  --help)
    echo "Usage: start-whisper-server.sh [--prepare-only]"
    echo "Configure with T3_SPEECH_LAB_HOST, T3_SPEECH_LAB_PORT, T3_SPEECH_LAB_THREADS, and T3_SPEECH_LAB_DIR."
    exit 0
    ;;
  *)
    echo "Unknown argument: $1" >&2
    exit 2
    ;;
esac

for dependency in git cmake curl; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "Missing required command: $dependency" >&2
    exit 1
  fi
done

if [[ "$host" == "0.0.0.0" || "$host" == "::" ]]; then
  echo "Refusing to expose whisper-server on every interface; it has no authentication." >&2
  echo "Set T3_SPEECH_LAB_HOST to a specific LAN or Tailscale address." >&2
  exit 1
fi

mkdir -p "$lab_dir" "$model_dir"

if [[ ! -d "$source_dir/.git" ]]; then
  git clone --depth 1 --branch "$revision" \
    https://github.com/ggml-org/whisper.cpp.git "$source_dir"
elif [[ "$(git -C "$source_dir" describe --tags --exact-match 2>/dev/null || true)" != "$revision" ]]; then
  echo "$source_dir exists but is not checked out at $revision." >&2
  echo "Use a different T3_SPEECH_LAB_DIR or update that checkout explicitly." >&2
  exit 1
fi

cmake -S "$source_dir" -B "$build_dir" \
  -DCMAKE_BUILD_TYPE=Release \
  -DWHISPER_BUILD_SERVER=ON \
  -DGGML_NATIVE=ON
cmake --build "$build_dir" --config Release --target whisper-server --parallel "$threads"

model_path="$model_dir/ggml-$model.bin"
if [[ ! -f "$model_path" ]]; then
  "$source_dir/models/download-ggml-model.sh" "$model" "$model_dir"
fi

if [[ "$prepare_only" == true ]]; then
  echo "Speech Lab server is prepared at $lab_dir"
  exit 0
fi

echo "Starting unauthenticated Speech Lab endpoint at http://$host:$port/inference"
exec "$build_dir/bin/whisper-server" \
  -m "$model_path" \
  --host "$host" \
  --port "$port" \
  --threads "$threads" \
  --language auto \
  --no-timestamps \
  --no-gpu
