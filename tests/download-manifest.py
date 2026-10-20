#!/usr/bin/env python3
import argparse, json
from pathlib import Path

KEYS=("os","graphics","hardware_id","memory_gb","runtime")

def key(row):
    return tuple(row.get(k) for k in KEYS)

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--manifest",required=True)
    ap.add_argument("--routing",required=True)
    args=ap.parse_args()

    manifest=json.loads(Path(args.manifest).read_text())
    routing=json.loads(Path(args.routing).read_text())

    if int(manifest.get("schema_version",0)) < 2:
        raise SystemExit("Download manifest schema must include all route states.")

    routes=list(routing.get("configurations",[]))
    published=list(manifest.get("routes",[]))

    if len(published)!=len(routes):
        raise SystemExit(f"Download manifest lost website configurations: routing={len(routes)} manifest={len(published)}")
    if int(manifest.get("route_count",-1))!=len(routes):
        raise SystemExit("Download manifest route_count is wrong.")

    route_map={key(x):x for x in routes}
    if len(route_map)!=len(routes):
        raise SystemExit("Routing contains duplicate website configuration keys.")

    manifest_map={key(x):x for x in published}
    if len(manifest_map)!=len(published):
        raise SystemExit("Download manifest contains duplicate website configuration keys.")
    if set(route_map)!=set(manifest_map):
        missing=set(route_map)-set(manifest_map)
        extra=set(manifest_map)-set(route_map)
        raise SystemExit(f"Download manifest key mismatch. missing={len(missing)} extra={len(extra)}")

    released=0
    packages=manifest.get("packages",{})
    for k,source in route_map.items():
        item=manifest_map[k]
        if item.get("status")!=source.get("status"):
            raise SystemExit(f"Status mismatch for {k}: {source.get('status')} != {item.get('status')}")
        if item.get("profile_id")!=source.get("profile_id"):
            raise SystemExit(f"Profile mismatch for {k}")
        if item.get("final_check")!=source.get("final_check"):
            raise SystemExit(f"Final-check mismatch for {k}")

        if source.get("status")=="installer_available":
            released += 1
            pid=source.get("profile_id")
            if pid not in packages:
                raise SystemExit(f"Released route has no package in download manifest: {pid}")
            if item.get("installer_file")!=packages[pid].get("installer_file"):
                raise SystemExit(f"Released route installer mismatch: {pid}")
        elif item.get("installer_file") is not None:
            raise SystemExit(f"Non-released route exposes a download: {k} / {source.get('status')}")

    if int(manifest.get("released_route_count",-1))!=released:
        raise SystemExit("Download manifest released_route_count is wrong.")

    print(f"WEBSITE DOWNLOAD MANIFEST PASSED: {len(routes)} classified routes, {released} released routes.")

if __name__=="__main__":
    main()
