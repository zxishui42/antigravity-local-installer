import { resolveInstaller } from "../web/installer-resolver.js";

function assert(ok, message) {
  if (!ok) throw new Error(message);
}

const baseInput = {
  os: "windows",
  graphics: "amd",
  hardwareId: "rx-5700-xt-8",
  runtime: "automatic",
};

const packageData = {
  installer_file: "profiles/p1.exe",
  sha256: "abc",
  size_bytes: 123,
  platform: "windows",
  route: "Ollama",
  model: "gemma4:e2b",
  model_label: "Gemma 4 E2B",
};

let manifest = {
  packages: { p1: packageData },
  routes: [{
    os: "windows",
    graphics: "amd",
    hardware_id: "rx-5700-xt-8",
    memory_gb: null,
    runtime: "automatic",
    status: "installer_available",
    profile_id: "p1",
    required_ram_gb: 16,
    required_vram_gb: null,
  }],
};

let r = resolveInstaller(manifest, baseInput);
assert(r.status === "need_system_ram", "RAM must be collected before package delivery.");

r = resolveInstaller(manifest, { ...baseInput, systemRamGb: 8 });
assert(r.status === "not_enough_ram", "Low RAM must not receive the installer.");

r = resolveInstaller(manifest, { ...baseInput, systemRamGb: 16 });
assert(r.status === "installer_available" && r.installerFile === "profiles/p1.exe", "Valid hardware should resolve to the released package.");

for (const status of ["pending_validation", "pending_product_definition", "unsupported_route"]) {
  manifest = {
    packages: {},
    routes: [{
      os: "windows",
      graphics: "amd",
      hardware_id: "rx-5700-xt-8",
      memory_gb: null,
      runtime: "automatic",
      status,
      profile_id: status === "unsupported_route" ? null : "candidate-p1",
      final_check: "example_gate",
      required_ram_gb: 16,
      required_vram_gb: 24,
    }],
  };
  r = resolveInstaller(manifest, { ...baseInput, systemRamGb: 32 });
  assert(r.status === status, status + " must not collapse into a generic missing-installer state.");
  assert(r.finalCheck === "example_gate", status + " must preserve its next validation/action gate.");
}

r = resolveInstaller({ routes: [], packages: {} }, {
  os: "windows",
  graphics: "nvidia",
  hardwareId: "unknown",
  runtime: "automatic",
  systemRamGb: 32,
});
assert(r.status === "no_released_installer", "Unknown configuration must not receive a package.");

console.log("WEBSITE INSTALLER RESOLVER PASSED");
