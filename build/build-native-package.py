#!/usr/bin/env python3
import argparse, os, re, shutil, stat, subprocess, tarfile, tempfile
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

def run(cmd):
    subprocess.run(cmd, check=True)

def build_payload(profile_id, outdir, ci_min_ram_gb=None):
    run(["python3", str(ROOT/"build/build-unix-profile.py"), "--profile-id", profile_id, "--output-dir", str(outdir)])
    payload=outdir/f"{profile_id}-payload"
    if ci_min_ram_gb is not None:
        if os.environ.get("CI","").lower()!="true":
            raise SystemExit("--ci-min-ram-gb is only allowed inside CI.")
        env_path=payload/"profile.env"
        text=env_path.read_text()
        replacement="MIN_RAM_GB='"+str(ci_min_ram_gb)+"'"
        text,count=re.subn(r"^MIN_RAM_GB=.*$",replacement,text,flags=re.M)
        if count!=1:
            raise SystemExit("Could not apply CI RAM override to profile.env.")
        env_path.write_text(text)
        print(f"CI only: package RAM preflight overridden to {ci_min_ram_gb} GB.")
    return payload, outdir/f"{profile_id}.tar.gz"

def build_linux(profile_id, outdir, ci_min_ram_gb=None):
    payload, tar_path=build_payload(profile_id,outdir,ci_min_ram_gb)
    target=outdir/f"{profile_id}.run"
    stub='''#!/usr/bin/env bash
set -euo pipefail
SELF="$0"
TMP="$(mktemp -d)"
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT
LINE="$(awk '/^__ANTIGRAVITY_PAYLOAD_BELOW__$/ {print NR + 1; exit}' "$SELF")"
[ -n "$LINE" ] || { echo "Installer payload marker is missing." >&2; exit 1; }
tail -n +"$LINE" "$SELF" | tar -xzf - -C "$TMP"
exec "$TMP/install.sh"
exit 0
__ANTIGRAVITY_PAYLOAD_BELOW__
'''
    with target.open("wb") as f:
        f.write(stub.encode())
        f.write(tar_path.read_bytes())
    target.chmod(target.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    print(target)

def build_macos(profile_id, outdir, ci_min_ram_gb=None):
    payload, _=build_payload(profile_id,outdir,ci_min_ram_gb)
    if shutil.which("pkgbuild") is None:
        raise SystemExit("pkgbuild is required on macOS.")
    stage=Path(tempfile.mkdtemp(prefix="ag-pkg-"))
    try:
        dest=stage/"root"/"Library"/"Application Support"/"AntigravityLocal"/"Installer"/profile_id
        dest.mkdir(parents=True)
        for item in payload.iterdir():
            if item.is_dir(): shutil.copytree(item,dest/item.name)
            else: shutil.copy2(item,dest/item.name)
        os.chmod(dest/"install.sh",0o755)

        scripts=stage/"scripts"; scripts.mkdir()
        post=scripts/"postinstall"
        install_path=f"/Library/Application Support/AntigravityLocal/Installer/{profile_id}/install.sh"
        post.write_text(f'''#!/bin/bash
set -e
LOG_FILE="/var/tmp/antigravity-local-postinstall.log"
exec >>"$LOG_FILE" 2>&1

echo "[Antigravity Local] macOS package postinstall started."

valid_user() {{
  [ -n "$1" ] &&
  [ "$1" != "root" ] &&
  [ "$1" != "loginwindow" ] &&
  /usr/bin/id "$1" >/dev/null 2>&1
}}

CONSOLE_USER="$(/usr/bin/stat -f %Su /dev/console 2>/dev/null || true)"

if ! valid_user "$CONSOLE_USER"; then
  for candidate in "${{SUDO_USER:-}}" "${{USER:-}}"; do
    if valid_user "$candidate"; then
      CONSOLE_USER="$candidate"
      break
    fi
  done
fi

if ! valid_user "$CONSOLE_USER"; then
  CONSOLE_USER="$(/usr/bin/dscl . -list /Users UniqueID 2>/dev/null | /usr/bin/awk '$2 >= 501 && $1 !~ /^_/ {{print $1, $2}}' | /usr/bin/sort -nk2 | /usr/bin/awk 'NR==1 {{print $1}}')"
fi

if ! valid_user "$CONSOLE_USER"; then
  echo "[Antigravity Local] No usable macOS user account was found." >&2
  exit 1
fi

USER_HOME="$(/usr/bin/dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{{print $2}}')"
if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
  echo "[Antigravity Local] Home folder could not be resolved for $CONSOLE_USER." >&2
  exit 1
fi

echo "[Antigravity Local] Installing for user: $CONSOLE_USER"
echo "[Antigravity Local] User home: $USER_HOME"

/usr/bin/sudo -H -u "$CONSOLE_USER" /usr/bin/env HOME="$USER_HOME" USER="$CONSOLE_USER" LOGNAME="$CONSOLE_USER" /bin/bash {install_path!r}
echo "[Antigravity Local] macOS package postinstall completed."
''')
        os.chmod(post,0o755)

        target=outdir/f"{profile_id}.pkg"
        safe="".join(ch if ch.isalnum() else "." for ch in profile_id)
        run(["pkgbuild","--root",str(stage/"root"),"--scripts",str(scripts),
             "--identifier","com.antigravitylocal."+safe,"--version","1.0",
             "--install-location","/",str(target)])
        print(target)
    finally:
        shutil.rmtree(stage,ignore_errors=True)

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--profile-id",required=True)
    ap.add_argument("--platform",choices=["linux","macos"],required=True)
    ap.add_argument("--output-dir",default=str(ROOT/"dist"/"native"))
    ap.add_argument("--ci-min-ram-gb",type=float,default=None,help="CI-only package preflight override; never used for production releases")
    args=ap.parse_args()
    out=Path(args.output_dir); out.mkdir(parents=True,exist_ok=True)
    if args.platform=="linux": build_linux(args.profile_id,out,args.ci_min_ram_gb)
    else: build_macos(args.profile_id,out,args.ci_min_ram_gb)

if __name__=="__main__":
    main()
