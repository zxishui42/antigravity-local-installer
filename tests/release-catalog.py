#!/usr/bin/env python3
import argparse, json
from pathlib import Path

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--catalog",required=True)
    ap.add_argument("--routing",required=True)
    ap.add_argument("--package-root")
    args=ap.parse_args()
    catalog=json.loads(Path(args.catalog).read_text())
    routing=json.loads(Path(args.routing).read_text())
    by_id={x["id"]:x for x in catalog.get("installers",[])}
    if args.package_root:
        import hashlib
        root=Path(args.package_root)
        for item in by_id.values():
            path=root/item["installer_file"]
            if not path.is_file():
                raise SystemExit(f"Released package file is missing: {path}")
            h=hashlib.sha256()
            with path.open("rb") as fh:
                for chunk in iter(lambda:fh.read(1024*1024),b""):
                    h.update(chunk)
            if h.hexdigest().lower()!=str(item["sha256"]).lower():
                raise SystemExit(f"Released package checksum mismatch: {item['id']}")
    available=[x for x in routing.get("configurations",[]) if x.get("status")=="installer_available"]
    if not available:
        raise SystemExit("No installer_available website configurations.")
    for row in available:
        pid=row.get("profile_id")
        if pid not in by_id:
            raise SystemExit(f"Website route points to a package not present in global release catalog: {pid}")
        if row.get("installer_file") != by_id[pid].get("installer_file"):
            raise SystemExit(f"Installer filename mismatch for {pid}: routing={row.get('installer_file')} catalog={by_id[pid].get('installer_file')}")
    used={x.get("profile_id") for x in available}
    unused=set(by_id)-used
    if unused:
        raise SystemExit("Released package(s) unused by website routing: "+", ".join(sorted(unused)))
    print(f"GLOBAL RELEASE CATALOG PASSED: {len(by_id)} package(s), {len(available)} website configurations.")

if __name__=="__main__":
    main()
