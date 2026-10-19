#!/usr/bin/env python3
import argparse, json
from pathlib import Path

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--catalog",action="append",required=True)
    ap.add_argument("--output",required=True)
    args=ap.parse_args()
    items=[]
    ids=set(); files=set()
    for name in args.catalog:
        data=json.loads(Path(name).read_text())
        for item in data.get("installers",[]):
            pid=item["id"]; fn=item["installer_file"]
            if pid in ids: raise SystemExit(f"Duplicate profile id across platform catalogs: {pid}")
            if fn in files: raise SystemExit(f"Duplicate installer filename across platform catalogs: {fn}")
            ids.add(pid);files.add(fn);items.append(item)
    items.sort(key=lambda x:x["id"])
    out={"schema_version":1,"verified_profile_count":len(items),"installers":items}
    Path(args.output).write_text(json.dumps(out,indent=2)+"\n")
    print(f"Merged {len(items)} release installer(s) -> {args.output}")

if __name__=="__main__":
    main()
