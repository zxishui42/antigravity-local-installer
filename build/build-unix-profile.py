#!/usr/bin/env python3
import argparse, json, os, shlex, shutil, tarfile, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def q(v):
    return shlex.quote("" if v is None else str(v))

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--profile-id", required=True)
    ap.add_argument("--output-dir", default=str(ROOT/"dist"/"unix"))
    ap.add_argument("--branch-test", action="store_true")
    args=ap.parse_args()

    cfg=json.loads((ROOT/"src/_internal/pack.json").read_text())
    profile=next((p for p in cfg["profiles"] if p["id"]==args.profile_id), None)
    if not profile:
        raise SystemExit(f"Unknown profile: {args.profile_id}")
    platform=profile.get("platform")
    arch=profile.get("architecture")
    if platform not in ("macos","linux"):
        raise SystemExit("Only macOS/Linux profiles are supported by this builder")
    shared=cfg["shared"]
    uv_key=f"{platform}-{'arm64' if arch=='arm64' else 'x64'}"
    uv=shared["uv_assets"][uv_key]
    ollama=None
    if profile["route"]=="Ollama":
        ollama_key="macos-universal" if platform=="macos" else f"linux-{arch}"
        ollama=shared["ollama_assets"][ollama_key]

    outdir=Path(args.output_dir); outdir.mkdir(parents=True, exist_ok=True)
    payload=outdir/f"{profile['id']}-payload"
    if payload.exists(): shutil.rmtree(payload)
    payload.mkdir()

    env={
      "PROFILE_ID":profile["id"],"PROFILE_PLATFORM":platform,"PROFILE_ARCH":arch,
      "PROFILE_ROUTE":profile["route"],"INSTALL_FOLDER":profile["install_folder"],
      "MODEL":profile["model"],"MODEL_LABEL":profile["model_label"],
      "MIN_RAM_GB":profile.get("min_ram_gb",8),
      "PYTHON_VERSION":shared["python_version"],"ANTIGRAVITY_VERSION":shared["antigravity_version"],
      "LITERT_LM_VERSION":shared.get("litert_lm_version",""),
      "UV_URL":uv["url"],"UV_SHA256":uv["sha256"],
      "OLLAMA_URL":ollama["url"] if ollama else "","OLLAMA_SHA256":ollama["sha256"] if ollama else "",
      "OLLAMA_ARCHIVE":ollama["archive"] if ollama else "",
      "LITERT_DOWNLOAD_URL":profile.get("litert_download_url",""),
      "MODEL_SHA256":profile.get("model_sha256",""),"LITERT_BACKEND":profile.get("litert_backend","gpu"),
    }
    (payload/"profile.env").write_text("\n".join(f"{k}={q(v)}" for k,v in env.items())+"\n")
    for name in ("local_agent.py","litert_agent.py"):
        shutil.copy2(ROOT/"src/_internal"/name,payload/name)
    shutil.copy2(ROOT/"src/unix/install.sh",payload/"install.sh")
    os.chmod(payload/"install.sh",0o755)

    tar_path=outdir/f"{profile['id']}.tar.gz"
    with tarfile.open(tar_path,"w:gz") as tf:
        for item in payload.iterdir():
            tf.add(item, arcname=item.name)
    print(tar_path)

if __name__=="__main__":
    main()
