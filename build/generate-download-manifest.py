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
    released_count=0
    for row in routing.get("configurations",[]):
        status=row.get("status")
        pid=row.get("profile_id")
        item={
          "os":row.get("os"),
          "graphics":row.get("graphics"),
          "hardware_id":row.get("hardware_id"),
          "memory_gb":row.get("memory_gb"),
          "runtime":row.get("runtime"),
          "status":status,
          "profile_id":pid,
          "preferred_profile_id":row.get("preferred_profile_id"),
          "fallback_profile_id":row.get("fallback_profile_id"),
          "fallback_used":bool(row.get("fallback_used",False)),
          "final_check":row.get("final_check"),
          "required_ram_gb":row.get("required_ram_gb"),
          "required_vram_gb":row.get("required_vram_gb"),
        }
        if status=="installer_available":
            if pid not in packages:
                raise SystemExit(f"Released route has no package: {pid}")
            item["installer_file"]=packages[pid]["installer_file"]
            released_count += 1
        else:
            item["installer_file"]=None
        routes.append(item)

    out={
      "schema_version":2,
      "package_count":len(packages),
      "route_count":len(routes),
      "released_route_count":released_count,
      "packages":packages,
      "routes":routes,
    }
    Path(args.output).write_text(json.dumps(out,indent=2)+"\n")
    print(f"Website download manifest: {len(packages)} package(s), {released_count} released route(s), {len(routes)} total classified route(s).")

if __name__=="__main__":
    main()
