#!/usr/bin/env python3
import argparse, json
from pathlib import Path

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--catalog",required=True)
    ap.add_argument("--routing",required=True)
    ap.add_argument("--output",required=True)
    args=ap.parse_args()

    catalog=json.loads(Path(args.catalog).read_text())
    routing=json.loads(Path(args.routing).read_text())
    packages={x["id"]:{
        "installer_file":x["installer_file"],
        "sha256":x["sha256"],
        "size_bytes":x["size_bytes"],
        "platform":x.get("platform","windows"),
        "route":x.get("route"),
        "model":x.get("model"),
        "model_label":x.get("model_label"),
    } for x in catalog.get("installers",[])}

    routes=[]
    for row in routing.get("configurations",[]):
        if row.get("status")!="installer_available":
            continue
        pid=row.get("profile_id")
        if pid not in packages:
            raise SystemExit(f"Released route has no package: {pid}")
        routes.append({
          "os":row.get("os"),
          "graphics":row.get("graphics"),
          "hardware_id":row.get("hardware_id"),
          "memory_gb":row.get("memory_gb"),
          "runtime":row.get("runtime"),
          "profile_id":pid,
          "installer_file":packages[pid]["installer_file"],
          "required_ram_gb":row.get("required_ram_gb"),
          "required_vram_gb":row.get("required_vram_gb"),
        })

    out={
      "schema_version":1,
      "package_count":len(packages),
      "route_count":len(routes),
      "packages":packages,
      "routes":routes,
    }
    Path(args.output).write_text(json.dumps(out,indent=2)+"\n")
    print(f"Website download manifest: {len(packages)} package(s), {len(routes)} released route(s).")

if __name__=="__main__":
    main()
