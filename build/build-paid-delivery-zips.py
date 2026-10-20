#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import zipfile
from pathlib import Path

WINDOWS_README = """ANTIGRAVITY LOCAL SETUP PACK
================================

WHAT THIS PACKAGE DOES

This package installs the tested Antigravity Local setup selected for your computer before payment.
It prepares the required local runtime, downloads the matching local model, connects Antigravity to it,
and runs an installation test.

HOW TO INSTALL

1. Keep this ZIP as your purchase copy.
2. Double-click AntigravityLocalSetup.exe.
3. Choose the local drive where you want the model files stored.
4. Click Install.
5. Leave the installer open while the runtime and model are downloaded.
6. When installation finishes, click Test installation.

The model download can take time depending on its size and your network connection.
Re-running the installer is safe if the first attempt is interrupted.

YOU DO NOT NEED

- PowerShell or Command Prompt
- Python or pip
- Manual Ollama commands
- API keys
- Manual model configuration

AFTER INSTALLATION

Windows creates an Antigravity Installation Test shortcut on your desktop.
Run it once after installation. A pass means Antigravity successfully started the local model
and received a response.

If installation stops, use Copy details in the installer and send that log to support.
Do not try to repair the private runtime manually.
"""

MAC_README = """ANTIGRAVITY LOCAL SETUP PACK
================================

WHAT THIS PACKAGE DOES

This package installs the tested Antigravity Local setup selected for your Mac before payment.
It prepares a private runtime, downloads the matching local model, connects Antigravity to it,
and runs a real response test during setup.

HOW TO INSTALL

1. Keep this ZIP as your purchase copy.
2. Double-click AntigravityLocalSetup.pkg.
3. Follow the normal macOS Installer prompts.
4. After the package window finishes, the model setup can continue in the background.
5. Keep your Mac awake and connected to the internet while the runtime and model are downloaded.

The first setup can take time because the model files are downloaded after the package is installed.
If the setup was interrupted, running the .pkg again is safe.

YOU DO NOT NEED

- Terminal commands
- Python or pip
- Manual Ollama commands
- API keys
- Manual model configuration

INSTALLATION LOGS

If support asks for installation details, the package writes logs under:

~/Library/Logs/AntigravityLocal/

Do not edit the private runtime files unless support specifically asks you to.
"""

WINDOWS_INTEGRATION = """LOCAL INTEGRATION NOTES
=======================

The current Windows package configures Antigravity Local automatically.

WHAT IS INSTALLED

- A private Antigravity Python runtime inside the AntigravityLocal installation folder.
- The tested local model for the configuration you selected before payment.
- For Ollama-based packages, the installer uses a loopback-only local Ollama service.
- A local Antigravity agent script is configured to talk to that private local model.
- An Antigravity Installation Test shortcut is created on the desktop.

HOW ANTIGRAVITY CONNECTS

For the current Ollama packages, the installer selects an available loopback port on 127.0.0.1,
starts the local model service only when needed, and points Antigravity's LocalOpenAIAgentConfig
at that local OpenAI-compatible endpoint.

The chosen port and installation state are managed by the installed package. You do not need to
enter the port or model name manually.

MANUAL INTEGRATION

The current paid package is designed to configure Antigravity Local automatically. It does not
promise a separate stable public API for third-party applications.

If you are building your own local workflow, do not hard-code an installer-managed port. The
Installation Test app may choose an available local port when it starts. Use the installed
Antigravity setup as provided, or contact support if you need a separately supported API workflow.

SECURITY

The local model service binds to 127.0.0.1 only. It is not intended to be exposed to the public internet.
"""

MAC_INTEGRATION = """LOCAL INTEGRATION NOTES
=======================

The current macOS package configures Antigravity Local automatically.

WHAT IS INSTALLED

- A private Antigravity runtime under your user Library.
- The tested local model for the configuration selected before payment.
- A local Antigravity agent script used by the installation test.
- For the current released macOS packages, the route uses a private Ollama runtime and local model files.

HOW ANTIGRAVITY CONNECTS

During setup the package starts its private local model service on the Mac, points Antigravity's
LocalOpenAIAgentConfig at the local OpenAI-compatible endpoint, and verifies that a response comes back.

MANUAL INTEGRATION

The current package configures Antigravity Local automatically and does not expose a separate stable
public API for manual third-party integration. Do not rely on an internal port, model path, or private
runtime file as a permanent external interface.

If you need a separately supported API workflow for another local application, treat that as a
different integration from this one-click package.

FILES

The installed runtime is stored under:

~/Library/Application Support/AntigravityLocal/

Installation logs are stored under:

~/Library/Logs/AntigravityLocal/

Do not edit these files unless support specifically asks you to.
"""


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--artifact-root", required=True)
    ap.add_argument("--output-dir", required=True)
    args = ap.parse_args()

    manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8-sig"))
    packages = manifest.get("packages") or {}
    if len(packages) != 5:
        raise SystemExit(f"Expected exactly 5 released packages, found {len(packages)}")

    root = Path(args.artifact_root)
    out = Path(args.output_dir)
    out.mkdir(parents=True, exist_ok=True)

    delivery = {}
    for profile_id, meta in sorted(packages.items()):
        source = root / meta["installer_file"]
        if not source.is_file():
            raise SystemExit(f"Missing installer: {source}")
        actual = sha256_file(source)
        if actual.lower() != str(meta["sha256"]).lower():
            raise SystemExit(f"SHA mismatch for {profile_id}")
        if source.stat().st_size != int(meta["size_bytes"]):
            raise SystemExit(f"Size mismatch for {profile_id}")

        platform = meta["platform"]
        ext = ".exe" if platform == "windows" else ".pkg"
        installer_name = "AntigravityLocalSetup" + ext
        readme = WINDOWS_README if platform == "windows" else MAC_README
        integration = WINDOWS_INTEGRATION if platform == "windows" else MAC_INTEGRATION
        zip_name = f"{profile_id}.zip"
        zip_path = out / zip_name

        with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
            zf.write(source, installer_name)
            zf.writestr("READ_ME_FIRST.txt", readme)
            zf.writestr("LOCAL_INTEGRATION.txt", integration)

        with zipfile.ZipFile(zip_path) as zf:
            names = sorted(zf.namelist())
            expected_names = sorted([installer_name, "READ_ME_FIRST.txt", "LOCAL_INTEGRATION.txt"])
            if names != expected_names:
                raise SystemExit(f"Unexpected delivery ZIP contents for {profile_id}: {names}")
            installer_bytes = zf.read(installer_name)
            inside_hash = hashlib.sha256(installer_bytes).hexdigest()
            if inside_hash.lower() != actual.lower():
                raise SystemExit(f"Installer changed inside ZIP for {profile_id}")

        delivery[profile_id] = {
            "object_key": f"delivery/{zip_name}",
            "delivery_file": zip_name,
            "customer_filename": "AntigravityLocalSetupPack.zip",
            "installer_filename": installer_name,
            "installer_sha256": actual,
            "installer_size_bytes": source.stat().st_size,
            "delivery_sha256": sha256_file(zip_path),
            "delivery_size_bytes": zip_path.stat().st_size,
            "platform": platform,
        }

    manifest_out = out / "delivery-manifest.json"
    manifest_out.write_text(json.dumps({
        "schema_version": 1,
        "package_count": len(delivery),
        "released_route_count": int(manifest.get("released_route_count") or 0),
        "packages": delivery,
    }, indent=2), encoding="utf-8")

    print(f"PAID DELIVERY BUNDLE PASSED: {len(delivery)} package(s), {manifest.get('released_route_count')} released route(s).")
    for profile_id, item in delivery.items():
        print(f"{profile_id}: {item['delivery_file']} {item['delivery_sha256']} {item['delivery_size_bytes']} bytes")


if __name__ == "__main__":
    main()
