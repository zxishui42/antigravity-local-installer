#!/usr/bin/env bash
set -euo pipefail

PROFILE_ID="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT_DIR/dist/unix-litert-e2e"
rm -rf "$OUT"
mkdir -p "$OUT"
python3 "$ROOT_DIR/build/build-unix-profile.py" --profile-id "$PROFILE_ID" --output-dir "$OUT"

PAYLOAD="$OUT/$PROFILE_ID-payload"
TEST_ROOT="$RUNNER_TEMP/antigravity-unix-litert-e2e-$PROFILE_ID"
rm -rf "$TEST_ROOT"

# Validate the production LiteRT route with the much smaller official E2B checkpoint.
# The production 26B package remains unreleased until it also passes on target 24 GB+ accelerated hardware.
python3 - "$PAYLOAD/profile.env" <<'PY'
import pathlib, re, sys
p=pathlib.Path(sys.argv[1])
s=p.read_text()
values={
  "MODEL":"gemma4-e2b-ci",
  "MODEL_LABEL":"Gemma 4 E2B LiteRT CI",
  "LITERT_DOWNLOAD_URL":"https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm?download=true",
  "MODEL_SHA256":"181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c",
  "LITERT_BACKEND":"cpu",
  "MIN_RAM_GB":"1",
}
for k,v in values.items():
    s=re.sub(rf"^{re.escape(k)}=.*$", k+"='"+v.replace("'","'\\''")+"'", s, flags=re.M)
p.write_text(s)
PY

ANTIGRAVITY_INSTALL_ROOT="$TEST_ROOT" "$PAYLOAD/install.sh"
test -f "$TEST_ROOT/install-state.json"
python3 - "$TEST_ROOT/install-state.json" "$PROFILE_ID" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
assert s["profile"]==sys.argv[2], s
assert s["route"]=="LiteRT", s
print("NATIVE LITERT ENGINE E2E PASSED:", s["profile"], s["model"])
PY
