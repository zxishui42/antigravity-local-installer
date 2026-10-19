import { resolveInstaller } from "../web/installer-resolver.js";

const manifest = {
  packages: {
    p1: {
      installer_file: "profiles/p1.exe",
      sha256: "abc",
      size_bytes: 123,
      platform: "windows",
      route: "Ollama",
      model: "gemma4:e2b",
      model_label: "Gemma 4 E2B",
    },
  },
  routes: [
    {
      os: "windows",
      graphics: "amd",
      hardware_id: "rx-5700-xt-8",
      memory_gb: null,
      runtime: "automatic",
      profile_id: "p1",
      required_ram_gb: 16,
    },
  ],
};

function assert(ok, message) {
  if (!ok) throw new Error(message);
}

let r = resolveInstaller(manifest, {
  os: "windows", graphics: "amd", hardwareId: "rx-5700-xt-8", runtime: "automatic"
});
assert(r.status === "need_system_ram", "RAM must be collected before package delivery.");

r = resolveInstaller(manifest, {
  os: "windows", graphics: "amd", hardwareId: "rx-5700-xt-8", runtime: "automatic", systemRamGb: 8
});
assert(r.status === "not_enough_ram", "Low RAM must not receive the installer.");

r = resolveInstaller(manifest, {
  os: "windows", graphics: "amd", hardwareId: "rx-5700-xt-8", runtime: "automatic", systemRamGb: 16
});
assert(r.status === "installer_available" && r.installerFile === "profiles/p1.exe", "Valid hardware should resolve to the package.");

r = resolveInstaller(manifest, {
  os: "windows", graphics: "nvidia", hardwareId: "unknown", runtime: "automatic", systemRamGb: 32
});
assert(r.status === "no_released_installer", "Unknown configuration must not receive a package.");

console.log("WEBSITE INSTALLER RESOLVER PASSED");
