#!/usr/bin/env bash
set -euo pipefail

PROFILE_ID="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT_DIR/dist/unix-e2e"
rm -rf "$OUT"
mkdir -p "$OUT"
python3 "$ROOT_DIR/build/build-unix-profile.py" --profile-id "$PROFILE_ID" --output-dir "$OUT"

PAYLOAD="$OUT/$PROFILE_ID-payload"
TEST_ROOT="${ANTIGRAVITY_E2E_INSTALL_ROOT:-$RUNNER_TEMP/antigravity-unix-e2e-$PROFILE_ID}"
rm -rf "$TEST_ROOT"

# Keep the native runtime path real, but use a small model so this job validates the production engine quickly.
if [ "${ANTIGRAVITY_E2E_MODEL:-}" != "" ]; then
  python3 - "$PAYLOAD/profile.env" "$ANTIGRAVITY_E2E_MODEL" <<'PY'
import pathlib, re, sys
p=pathlib.Path(sys.argv[1])
s=p.read_text()
s=re.sub(r"^MODEL=.*$", "MODEL='"+sys.argv[2].replace("'","'\\''")+"'", s, flags=re.M)
s=re.sub(r"^MIN_RAM_GB=.*$", "MIN_RAM_GB='1'", s, flags=re.M)
p.write_text(s)
PY
fi

ANTIGRAVITY_INSTALL_ROOT="$TEST_ROOT" ANTIGRAVITY_TEST_PORT="${ANTIGRAVITY_TEST_PORT:-11531}" "$PAYLOAD/install.sh"
test -f "$TEST_ROOT/install-state.json"
python3 - "$TEST_ROOT/install-state.json" "$PROFILE_ID" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
assert s["profile"]==sys.argv[2], s
assert s["route"]=="Ollama", s
print("NATIVE OLLAMA E2E PASSED:", s["profile"], s["model"])
PY
