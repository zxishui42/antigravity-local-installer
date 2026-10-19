#!/usr/bin/env python3
import argparse, os, shutil, stat, subprocess, tarfile, tempfile
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

def run(cmd):
    subprocess.run(cmd, check=True)

def build_payload(profile_id, outdir):
    run(["python3", str(ROOT/"build/build-unix-profile.py"), "--profile-id", profile_id, "--output-dir", str(outdir)])
    return outdir/f"{profile_id}-payload", outdir/f"{profile_id}.tar.gz"

def build_linux(profile_id, outdir):
    payload, tar_path=build_payload(profile_id,outdir)
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

def build_macos(profile_id, outdir):
    payload, _=build_payload(profile_id,outdir)
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
CONSOLE_USER="$(stat -f %Su /dev/console)"
if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ] || [ "$CONSOLE_USER" = "loginwindow" ]; then
  echo "No signed-in macOS user was found." >&2
  exit 1
fi
USER_HOME="$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory | awk '{{print $2}}')"
[ -n "$USER_HOME" ] || exit 1
/usr/bin/sudo -u "$CONSOLE_USER" /usr/bin/env HOME="$USER_HOME" /bin/bash {install_path!r}
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
    args=ap.parse_args()
    out=Path(args.output_dir); out.mkdir(parents=True,exist_ok=True)
    if args.platform=="linux": build_linux(args.profile_id,out)
    else: build_macos(args.profile_id,out)

if __name__=="__main__":
    main()
