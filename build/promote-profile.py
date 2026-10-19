#!/usr/bin/env python3
import argparse, json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

def main():
    ap=argparse.ArgumentParser(description="Promote a validated installer profile without hand-editing routing files.")
    ap.add_argument("--profile-id",required=True)
    ap.add_argument("--gate",required=True,help="Validation gate that has actually been satisfied")
    ap.add_argument("--evidence-json",required=True,help="JSON object with the completed validation evidence")
    ap.add_argument("--dry-run",action="store_true")
    args=ap.parse_args()

    pack_path=ROOT/"src/_internal/pack.json"
    routing_path=ROOT/"catalog/package-routing.json"
    pack=json.loads(pack_path.read_text())
    routing=json.loads(routing_path.read_text())

    profile=next((p for p in pack["profiles"] if p["id"]==args.profile_id),None)
    if not profile:
        raise SystemExit(f"Unknown profile: {args.profile_id}")

    required=profile.get("release_gate")
    if not required:
        raise SystemExit(f"Profile {args.profile_id} has no release_gate and cannot be promoted automatically.")
    if required != args.gate:
        raise SystemExit(f"Wrong gate for {args.profile_id}. Required: {required}; supplied: {args.gate}")

    evidence=json.loads(args.evidence_json)
    if not isinstance(evidence,dict) or not evidence:
        raise SystemExit("Evidence must be a non-empty JSON object.")

    profile["verified"]=True
    profile["release"]=True
    profile["verification_status"]="released_after_"+args.gate
    profile["validation_evidence"]=evidence

    touched=0
    for rule in routing["rules"]:
        if rule.get("profile_id")==args.profile_id and rule.get("status")=="pending_validation":
            rule["status"]="installer_available"
            rule["final_check"]="installer"
            touched+=1
    if touched==0:
        raise SystemExit(f"No pending_validation routing rule points to {args.profile_id}; refusing release.")

    if args.dry_run:
        print(json.dumps({"profile":profile,"updated_rules":touched},indent=2))
        return

    pack_path.write_text(json.dumps(pack,indent=2,ensure_ascii=False)+"\n")
    routing_path.write_text(json.dumps(routing,indent=2,ensure_ascii=False)+"\n")
    print(json.dumps({"released_profile":args.profile_id,"updated_rules":touched},indent=2))

if __name__=="__main__":
    main()
