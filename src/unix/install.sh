#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/profile.env"

log(){ printf '%s\n' "[Antigravity Local] $*"; }
fail(){ printf '%s\n' "[Antigravity Local] ERROR: $*" >&2; exit 1; }

OS_NAME="$(uname -s)"
ARCH_NAME="$(uname -m)"
case "$OS_NAME" in
  Darwin) PLATFORM="macos" ;;
  Linux) PLATFORM="linux" ;;
  *) fail "Unsupported operating system: $OS_NAME" ;;
esac

case "$ARCH_NAME" in
  arm64|aarch64) ARCH_KEY="arm64" ;;
  x86_64|amd64) ARCH_KEY="x64" ;;
  *) fail "Unsupported architecture: $ARCH_NAME" ;;
esac

[ "$PLATFORM" = "$PROFILE_PLATFORM" ] || fail "This package is for $PROFILE_PLATFORM, not $PLATFORM."
[ "$ARCH_KEY" = "$PROFILE_ARCH" ] || fail "This package is for $PROFILE_ARCH, not $ARCH_KEY."

if [ -n "${ANTIGRAVITY_INSTALL_ROOT:-}" ]; then
  ROOT="$ANTIGRAVITY_INSTALL_ROOT"
elif [ "$PLATFORM" = "macos" ]; then
  ROOT="$HOME/Library/Application Support/AntigravityLocal/$INSTALL_FOLDER"
else
  ROOT="$HOME/.local/share/AntigravityLocal/$INSTALL_FOLDER"
fi

RUNTIME="$ROOT/runtime"
MODEL_ROOT="$ROOT/models"
CACHE_ROOT="$ROOT/cache"
VENV="$RUNTIME/venv"
UV_ROOT="$RUNTIME/uv"
UV="$UV_ROOT/uv"
STATE="$ROOT/install-state.json"
LOG_DIR="$ROOT/logs"
mkdir -p "$ROOT" "$RUNTIME" "$MODEL_ROOT" "$CACHE_ROOT" "$LOG_DIR"

if [ "$PLATFORM" = "macos" ]; then
  RAM_BYTES="$(sysctl -n hw.memsize)"
  RAM_GB=$(( RAM_BYTES / 1024 / 1024 / 1024 ))
else
  RAM_KB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
  RAM_GB=$(( RAM_KB / 1024 / 1024 ))
fi
[ "$RAM_GB" -ge "$MIN_RAM_GB" ] || fail "This setup needs at least $MIN_RAM_GB GB RAM. Detected about $RAM_GB GB."

TMP="$(mktemp -d)"
SERVER_PID=""
cleanup(){
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then kill "$SERVER_PID" >/dev/null 2>&1 || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

download(){
  local url="$1" out="$2"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 "$url" -o "$out"
}
sha256_file(){
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}
verify(){
  local file="$1" expected="$2" actual
  actual="$(sha256_file "$file")"
  [ "$actual" = "$expected" ] || fail "Integrity check failed for $(basename "$file")."
}

install_uv(){
  if [ -x "$UV" ]; then return; fi
  log "Preparing private runtime..."
  local archive="$TMP/uv.tar.gz"
  download "$UV_URL" "$archive"
  verify "$archive" "$UV_SHA256"
  mkdir -p "$UV_ROOT" "$TMP/uv-extract"
  tar -xzf "$archive" -C "$TMP/uv-extract"
  local found
  found="$(find "$TMP/uv-extract" -type f -name uv | head -n 1)"
  [ -n "$found" ] || fail "uv executable was not found in the runtime archive."
  cp "$found" "$UV"
  chmod +x "$UV"
}

install_python(){
  export UV_PYTHON_INSTALL_DIR="$RUNTIME/python-builds"
  export UV_CACHE_DIR="$CACHE_ROOT/uv"
  "$UV" python install "$PYTHON_VERSION" >/dev/null
  if [ ! -x "$VENV/bin/python" ]; then
    "$UV" venv --python "$PYTHON_VERSION" "$VENV" >/dev/null
  fi
  local packages=("google-antigravity==$ANTIGRAVITY_VERSION")
  if [ "$PROFILE_ROUTE" = "LiteRT" ]; then
    packages+=("litert-lm==$LITERT_LM_VERSION")
  elif [ "$PLATFORM" = "linux" ]; then
    packages+=("zstandard")
  fi
  "$UV" pip install --python "$VENV/bin/python" "${packages[@]}" >/dev/null
}

install_ollama(){
  OLLAMA_HOME="$RUNTIME/ollama"
  OLLAMA_BIN=""
  if [ -d "$OLLAMA_HOME" ]; then
    OLLAMA_BIN="$(find "$OLLAMA_HOME" -type f -name ollama | head -n 1 || true)"
  fi
  if [ -n "$OLLAMA_BIN" ]; then return; fi
  log "Downloading private Ollama runtime..."
  local archive="$TMP/ollama.archive"
  download "$OLLAMA_URL" "$archive"
  verify "$archive" "$OLLAMA_SHA256"
  rm -rf "$OLLAMA_HOME"
  mkdir -p "$OLLAMA_HOME"
  if [ "$OLLAMA_ARCHIVE" = "tgz" ]; then
    tar -xzf "$archive" -C "$OLLAMA_HOME"
  elif [ "$OLLAMA_ARCHIVE" = "tar.zst" ]; then
    "$VENV/bin/python" - "$archive" "$OLLAMA_HOME" <<'PY'
import os, sys, tarfile, tempfile
import zstandard as zstd
src, dest = sys.argv[1], sys.argv[2]
with tempfile.NamedTemporaryFile(suffix=".tar", delete=False) as tmp:
    tar_path = tmp.name
try:
    with open(src, "rb") as inp, open(tar_path, "wb") as out:
        zstd.ZstdDecompressor().copy_stream(inp, out)
    with tarfile.open(tar_path, "r:") as tf:
        tf.extractall(dest)
finally:
    try: os.unlink(tar_path)
    except OSError: pass
PY
  else
    fail "Unsupported Ollama archive type: $OLLAMA_ARCHIVE"
  fi
  OLLAMA_BIN="$(find "$OLLAMA_HOME" -type f -name ollama -perm -u+x | head -n 1 || true)"
  [ -n "$OLLAMA_BIN" ] || fail "Private Ollama executable was not found after extraction."
}

start_ollama(){
  local port="${ANTIGRAVITY_TEST_PORT:-11435}"
  export OLLAMA_HOST="127.0.0.1:$port"
  export OLLAMA_MODELS="$MODEL_ROOT"
  if [ "$PLATFORM" = "linux" ]; then
    local libdir
    libdir="$(find "$RUNTIME/ollama" -type d -path '*/lib/ollama' | head -n 1 || true)"
    if [ -n "$libdir" ]; then export LD_LIBRARY_PATH="$libdir:${LD_LIBRARY_PATH:-}"; fi
  fi
  "$OLLAMA_BIN" serve >"$LOG_DIR/ollama.log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 120); do
    if curl -fsS "http://127.0.0.1:$port/api/version" >/dev/null 2>&1; then return; fi
    if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then fail "Ollama stopped during startup."; fi
    sleep 1
  done
  fail "Ollama did not become ready."
}

install_ollama_route(){
  install_ollama
  start_ollama
  log "Downloading model $MODEL..."
  "$OLLAMA_BIN" pull "$MODEL"
  cp "$SCRIPT_DIR/local_agent.py" "$ROOT/local_agent.py"
  export ANTIGRAVITY_LOCAL_MODEL="$MODEL"
  export ANTIGRAVITY_LOCAL_BASE_URL="http://$OLLAMA_HOST/v1"
  export ANTIGRAVITY_LOCAL_PROMPT="Reply with only: OK"
  log "Testing Antigravity -> Ollama -> model..."
  local output
  output="$("$VENV/bin/python" "$ROOT/local_agent.py")"
  [ -n "$output" ] || fail "Antigravity returned no output."
  log "Installation test returned: $output"
}

install_litert_route(){
  mkdir -p "$MODEL_ROOT"
  local model_file="$MODEL_ROOT/model.litertlm"
  if [ ! -f "$model_file" ] || [ "$(sha256_file "$model_file")" != "$MODEL_SHA256" ]; then
    log "Downloading LiteRT model..."
    download "$LITERT_DOWNLOAD_URL" "$model_file.part"
    verify "$model_file.part" "$MODEL_SHA256"
    mv "$model_file.part" "$model_file"
  fi
  cp "$SCRIPT_DIR/litert_agent.py" "$ROOT/litert_agent.py"
  export ANTIGRAVITY_LOCAL_PROMPT="Reply with only: OK"
  export ANTIGRAVITY_LITERT_MODEL_PATH="$model_file"
  export ANTIGRAVITY_LITERT_BACKEND="$LITERT_BACKEND"
  export ANTIGRAVITY_LITERT_CACHE_DIR="$CACHE_ROOT/litert"
  mkdir -p "$ANTIGRAVITY_LITERT_CACHE_DIR"
  log "Testing Antigravity -> LiteRT -> model..."
  local output
  output="$("$VENV/bin/python" "$ROOT/litert_agent.py")"
  [ -n "$output" ] || fail "LiteRT returned no output."
  log "Installation test returned: $output"
}

write_state(){
  export AG_ROOT="$ROOT" AG_MODEL="$MODEL" AG_ROUTE="$PROFILE_ROUTE" AG_PROFILE="$PROFILE_ID" AG_MODEL_LABEL="$MODEL_LABEL"
  "$VENV/bin/python" - "$STATE" <<'PY'
import json, os, sys
state = {
  "profile": os.environ["AG_PROFILE"],
  "route": os.environ["AG_ROUTE"],
  "model": os.environ["AG_MODEL"],
  "model_label": os.environ["AG_MODEL_LABEL"],
  "install_root": os.environ["AG_ROOT"],
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2)
PY
}

install_uv
install_python
case "$PROFILE_ROUTE" in
  Ollama) install_ollama_route ;;
  LiteRT) install_litert_route ;;
  *) fail "Unsupported route: $PROFILE_ROUTE" ;;
esac
write_state
log "Installation complete: $MODEL_LABEL via $PROFILE_ROUTE."
