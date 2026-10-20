export function resolveInstaller(manifest, input) {
  if (!manifest || !Array.isArray(manifest.routes)) {
    return { status: "manifest_error" };
  }

  const runtime = input.runtime || "automatic";
  const memoryGb = input.memoryGb == null ? null : Number(input.memoryGb);
  const systemRamGb = input.systemRamGb == null ? null : Number(input.systemRamGb);

  const route = manifest.routes.find((r) =>
    r.os === input.os &&
    r.graphics === input.graphics &&
    r.hardware_id === input.hardwareId &&
    r.runtime === runtime &&
    (r.memory_gb == null || Number(r.memory_gb) === memoryGb)
  );

  if (!route) {
    return { status: "no_released_installer" };
  }

  if (route.status && route.status !== "installer_available") {
    return {
      status: route.status,
      profileId: route.profile_id || null,
      finalCheck: route.final_check || null,
      requiredRamGb: route.required_ram_gb == null ? null : Number(route.required_ram_gb),
      requiredVramGb: route.required_vram_gb == null ? null : Number(route.required_vram_gb),
    };
  }

  if (route.required_ram_gb != null) {
    if (systemRamGb == null) {
      return {
        status: "need_system_ram",
        requiredRamGb: Number(route.required_ram_gb),
        profileId: route.profile_id,
      };
    }
    if (systemRamGb < Number(route.required_ram_gb)) {
      return {
        status: "not_enough_ram",
        requiredRamGb: Number(route.required_ram_gb),
        detectedRamGb: systemRamGb,
        profileId: route.profile_id,
      };
    }
  }

  const pkg = manifest.packages && manifest.packages[route.profile_id];
  if (!pkg) {
    return { status: "manifest_error", profileId: route.profile_id };
  }

  return {
    status: "installer_available",
    profileId: route.profile_id,
    installerFile: pkg.installer_file,
    sha256: pkg.sha256,
    sizeBytes: pkg.size_bytes,
    platform: pkg.platform,
    route: pkg.route,
    model: pkg.model,
    modelLabel: pkg.model_label,
  };
}
