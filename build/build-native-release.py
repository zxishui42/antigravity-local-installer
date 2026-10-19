#!/usr/bin/env python3
import argparse, hashlib, json, subprocess
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

def sha256(path):
    h=hashlib.sha256()
    with open(path,"rb") as f:
        for chunk in iter(lambda:f.read(1024*1024),b""):
            h.update(chunk)
    return h.hexdigest()

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--platform",choices=["macos","linux"],required=True)
    ap.add_argument("--output-dir",default=str(ROOT/"dist"))
    args=ap.parse_args()
    cfg=json.loads((ROOT/"src/_internal/pack.json").read_text())
    profiles=[
      p for p in cfg["profiles"]
      if p.get("platform")==args.platform and p.get("verified") is True and p.get("release",True) is True
    ]
    out=Path(args.output_dir); (out/"profiles").mkdir(parents=True,exist_ok=True)
    items=[]
    for p in profiles:
        subprocess.run([
          "python3",str(ROOT/"build/build-native-package.py"),
          "--profile-id",p["id"],"--platform",args.platform,
          "--output-dir",str(out/"profiles")
        ],check=True)
        ext="pkg" if args.platform=="macos" else "run"
        file=out/"profiles"/f"{p['id']}.{ext}"
        if not file.exists():
            raise SystemExit(f"Missing built package: {file}")
        items.append({
          "id":p["id"],"title":p["title"],"platform":args.platform,"route":p["route"],
          "model":p["model"],"model_label":p["model_label"],
          "installer_file":f"profiles/{file.name}",
          "sha256":sha256(file),"size_bytes":file.stat().st_size,"verified":True
        })
    manifest={
      "schema_version":1,"platform":args.platform,
      "verified_profile_count":len(items),"installers":items
    }
    target=out/f"platform-catalog-{args.platform}.json"
    target.write_text(json.dumps(manifest,indent=2)+"\n")
    print(target)

if __name__=="__main__":
    main()
