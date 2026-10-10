import { describe, expect, it } from "vitest";
import {
  describeGpu,
  describeIdleCapability,
  describeIdleVramEffect,
  describeLibraryBadges,
  describeUnlockableModels,
  describeLibraryFit,
  describeLibraryResult,
  describeLibraryState,
  describeMissingBackend,
  describeModel,
  describeOverall,
  describePortOwner,
  describeRuntime,
  describeServer,
  describeSettingsSave,
  describeSupport,
  describeTier,
  describeStatusBadge,
  nextTabIndex,
  describeModelState,
  describeGamePause,
  isGamePauseValid,
  describeUseCase,
  formatElapsed,
  formatStartProgress,
  isMinutesValid,
  isRunning,
  isUseCaseValid,
  libraryConfirmText,
  libraryOperation
} from "./format";
import type { BackendResult, HardwareProfile, LibraryModel, Tier } from "./types";

const hardware: HardwareProfile = {
  CpuName: "AMD Ryzen 7 9800X3D 8-Core Processor",
  CpuCores: 8,
  CpuThreads: 16,
  RamGiB: 31.2,
  RocmGpu: "AMD Radeon RX 9070 XT",
  MaxAmdVramGiB: 15.8,
  Gpus: [
    { Name: "AMD Radeon RX 9070 XT", IsAmd: true, IsIntegrated: false, VramGiB: 15.8 },
    { Name: "AMD Radeon Graphics", IsAmd: true, IsIntegrated: true, VramGiB: 0.5 }
  ],
  support: { level: "supported", confidence: "high", reasons: [] },
  recommendation: { backend: "ROCm", model_id: "qwen3.5-9b", confidence: "high", reason: "matrix" }
};

const tier: Tier = {
  tier: "balanced",
  model_id: "qwen3.5-9b",
  model_name: "Qwen3.5 9B",
  status: "recommended",
  confidence: "high",
  reason: "Stays entirely in VRAM.",
  gpu_resident: true,
  blockers: []
};

describe("server state wording", () => {
  it("names every phase the backend can report", () => {
    expect(describeServer("running")).toContain("Running");
    expect(describeServer("loading")).toContain("Starting");
    expect(describeServer("stopped")).toBe("Stopped");
  });

  it("never invents a phase it was not given", () => {
    expect(describeServer(undefined)).toContain("Unknown");
    expect(isRunning(undefined)).toBe(false);
    expect(isRunning("loading")).toBe(false);
    expect(isRunning("running")).toBe(true);
  });
});

describe("hardware and model wording", () => {
  it("summarises the GPU, its VRAM and system RAM", () => {
    const text = describeGpu(hardware);
    expect(text).toContain("AMD Radeon RX 9070 XT");
    expect(text).toContain("15.8 GiB VRAM");
    expect(text).toContain("31.2 GiB system RAM");
  });

  it("says when the hardware scan is unavailable instead of showing zeros", () => {
    expect(describeGpu(null)).toBe("Hardware scan unavailable");
  });

  it("explains the support verdict", () => {
    expect(describeSupport("supported", "high")).toContain("Supported");
    expect(describeSupport("unsupported", "low")).toContain("Not supported");
    expect(describeSupport(undefined, undefined)).toBe("Hardware support unknown");
  });

  it("describes the runtime and the active model", () => {
    expect(describeRuntime({ tag: "rocm-7.2.1-b8407", backend: "ROCm", installed_at: "2026-09-28T22:26:54Z", exe_present: true })).toBe(
      "ROCm rocm-7.2.1-b8407, installed 2026-09-28"
    );
    expect(describeRuntime(null)).toContain("No runtime installed");
    expect(describeRuntime({ tag: "b8407", backend: "ROCm", installed_at: "", exe_present: false })).toContain("llama-server.exe is missing");
    expect(describeModel(null)).toBe("No model selected yet");
    expect(describeModel({ id: "qwen3.5-9b", alias: "qwen3.5:9b", name: "Qwen3.5 9B", context_size: 65536, port: 8080, model_present: true, runtime_blocker: "" })).toBe(
      "Qwen3.5 9B (qwen3.5:9b), 64k context"
    );
  });
});

describe("recommendation wording", () => {
  it("states status, confidence and residency", () => {
    const text = describeTier(tier);
    expect(text).toContain("Recommended");
    expect(text).toContain("Stays entirely in VRAM.");
  });

  it("does not repeat residency words the backend reason already states", () => {
    const text = describeTier(tier);
    expect(text.match(/VRAM/g)?.length).toBe(1);
  });

  it("moves the tab selection with arrows, wrapping at the ends, and Home/End", () => {
    expect(nextTabIndex("ArrowRight", 0, 4)).toBe(1);
    expect(nextTabIndex("ArrowRight", 3, 4)).toBe(0);
    expect(nextTabIndex("ArrowLeft", 0, 4)).toBe(3);
    expect(nextTabIndex("Home", 2, 4)).toBe(0);
    expect(nextTabIndex("End", 1, 4)).toBe(3);
    expect(nextTabIndex("Enter", 1, 4)).toBeNull();
  });

  it("shows Asleep in the badge when the server is up but its model is out of memory", () => {
    expect(describeStatusBadge("running", "asleep")).toEqual({ label: "Asleep", tone: "off" });
    expect(describeStatusBadge("running", "unloaded")).toEqual({ label: "Asleep", tone: "off" });
    expect(describeStatusBadge("running", "loaded")).toEqual({ label: "Running", tone: "ok" });
    expect(describeStatusBadge("running", undefined)).toEqual({ label: "Running", tone: "ok" });
  });

  it("words the model state and stays silent when the backend did not say", () => {
    expect(describeModelState("asleep")).toContain("loads again on your next message");
    expect(describeModelState("unknown")).toBe("");
    expect(describeModelState(undefined)).toBe("");
  });

  it("explains game pause, its off state, and the router requirement", () => {
    expect(describeGamePause(0, true)).toContain("Off");
    expect(describeGamePause(10, true)).toContain("10 GiB or more");
    expect(describeGamePause(10, false)).toContain("Update llama.cpp first");
  });

  it("accepts off or 4 to 40 whole GiB and nothing else", () => {
    expect(isGamePauseValid("0")).toBe(true);
    expect(isGamePauseValid(" 8 ")).toBe(true);
    expect(isGamePauseValid("40")).toBe(true);
    expect(isGamePauseValid("3")).toBe(false);
    expect(isGamePauseValid("41")).toBe(false);
    expect(isGamePauseValid("")).toBe(false);
    expect(isGamePauseValid("8.5")).toBe(false);
  });

  it("maps every server phase to one badge", () => {
    expect(describeStatusBadge("running")).toEqual({ label: "Running", tone: "ok" });
    expect(describeStatusBadge("loading")).toEqual({ label: "Starting…", tone: "busy" });
    expect(describeStatusBadge("stopped")).toEqual({ label: "Stopped", tone: "off" });
    expect(describeStatusBadge(undefined)).toEqual({ label: "Unknown", tone: "unknown" });
  });

  it("surfaces blockers", () => {
    expect(describeTier({ ...tier, gpu_resident: false, blockers: ["Port 8080 is busy."] })).toContain("Port 8080 is busy.");
  });

  it("says so when a tier is missing", () => {
    expect(describeTier(undefined)).toBe("No recommendation for this tier");
  });
});

describe("port ownership wording", () => {
  it("describes a foreign owner with its PID", () => {
    const text = describePortOwner({ status: "conflict", process_id: 4242, process_name: "chrome", message: "Port 8080 is already in use." });
    expect(text).toContain("already in use");
  });

  it("describes an owned listener and a free port", () => {
    expect(describePortOwner({ status: "owned", process_id: 7, process_name: "llama-server", message: "" })).toContain("already runs this server");
    expect(describePortOwner({ status: "free", process_id: 0, process_name: "", message: "" })).toBe("The port is free");
  });
});

describe("progress and availability wording", () => {
  it("formats elapsed time as seconds then minutes", () => {
    expect(formatElapsed(1200)).toBe("1s");
    expect(formatElapsed(65000)).toBe("1m 5s");
  });

  it("shows real progress text rather than a spinner", () => {
    expect(formatStartProgress("loading", 12000)).toContain("12s so far");
    expect(formatStartProgress("stopped", 9000)).toContain("server window shows the live log");
    expect(formatStartProgress("running", 40000)).toContain("ready after 40s");
  });

  it("explains a missing backend with the locations that were checked", () => {
    const result: BackendResult = {
      ok: false,
      action: "info",
      document: null,
      error: "The PowerShell backend (Install-LlamaCpp-AMD.ps1) was not found.",
      command: "",
      exit_code: null,
      stderr: "",
      install_root: "C:\\Users\\me\\AppData\\Local\\Programs\\llama.cpp",
      script: null,
      candidates: ["C:\\repo\\Install-LlamaCpp-AMD.ps1"]
    };
    const text = describeMissingBackend(result);
    expect(text).toContain("was not found");
    expect(text).toContain("Checked:");
    expect(text).toContain("C:\\repo\\Install-LlamaCpp-AMD.ps1");
  });

  it("words the overall verdict", () => {
    expect(describeOverall("ok", "high")).toContain("Everything checks out");
    expect(describeOverall("broken", "low")).toContain("broken");
    expect(describeOverall(undefined, undefined)).toBe("No verdict from the backend");
  });
});

describe("settings wording and validation", () => {
  it("labels the five catalogued use cases", () => {
    expect(describeUseCase("chat")).toContain("chat");
    expect(describeUseCase("coding")).toContain("Coding");
    expect(describeUseCase("images")).toContain("Pictures");
    expect(describeUseCase("fast")).toContain("Quick");
    expect(describeUseCase("quality")).toContain("Best");
  });

  it("never relabels an unknown use case to a different meaning", () => {
    expect(describeUseCase("future-case")).toBe("future-case");
  });

  it("words idle capability as a runtime fact, not a broken control", () => {
    expect(describeIdleCapability(true, 3)).toContain("leaves graphics memory");
    expect(describeIdleCapability(false, 0)).toContain("Set up the AI first");
    expect(describeIdleCapability(false, 2)).toContain("too old");
  });

  it("validates idle minutes exactly as the backend does", () => {
    expect(isMinutesValid(0)).toBe(true);
    expect(isMinutesValid(15)).toBe(true);
    expect(isMinutesValid(1440)).toBe(true);
    expect(isMinutesValid(-1)).toBe(false);
    expect(isMinutesValid(1441)).toBe(false);
    expect(isMinutesValid(15.5)).toBe(false);
    expect(isMinutesValid(null)).toBe(false);
    expect(isMinutesValid(undefined)).toBe(false);
  });

  it("turns the idle choice into GiB free on the Radeon, with the engine's own arithmetic", () => {
    // 0.9 × VRAM − model size, the same headroom rule Get-VramHeadroom applies.
    const text = describeIdleVramEffect(15.8, 6.2);
    expect(text).toContain("8.0 GiB");
    expect(text).toContain("15.8 GiB");
    expect(text).toContain("free for games");
  });

  it("says nothing about VRAM when the hardware or model is unknown", () => {
    expect(describeIdleVramEffect(null, 6.2)).toBeNull();
    expect(describeIdleVramEffect(15.8, null)).toBeNull();
    expect(describeIdleVramEffect(null, null)).toBeNull();
  });

  it("never claims a negative amount free when the model is bigger than VRAM", () => {
    expect(describeIdleVramEffect(4, 6.2)).toContain("0.0 GiB");
  });

  it("accepts only listed use cases", () => {
    const allowed = ["chat", "coding", "images", "fast", "quality"];
    expect(isUseCaseValid("coding", allowed)).toBe(true);
    expect(isUseCaseValid("nonsense", allowed)).toBe(false);
    expect(isUseCaseValid("chat", [])).toBe(false);
  });

  it("reports saves honestly: applied count, every rejection, or nothing to change", () => {
    expect(describeSettingsSave(2, [])).toContain("Saved (2 settings)");
    expect(describeSettingsSave(1, [])).toContain("Saved (1 setting)");
    expect(describeSettingsSave(0, [])).toContain("Nothing to change");
    const message = describeSettingsSave(0, [
      { field: "idle_unload.minutes", reason: "Minutes must be a whole number from 0 to 1440." },
      { field: "use_case", reason: "Unknown use case 'x'." }
    ]);
    expect(message).toContain("Not saved");
    expect(message).toContain("whole number");
    expect(message).toContain("Unknown use case");
  });
});

describe("model library display rules", () => {
  it("names exactly what the catalogue says an update unlocks, in the backend's words", () => {
    const two = describeUnlockableModels([
      { id: "ornith-1.5-9b", name: "Ornith 1.5 9B" },
      { id: "gemma4-12b", name: "Gemma 4 12B" }
    ]);
    expect(two).toBe("Updating unlocks 2 models: Ornith 1.5 9B, Gemma 4 12B.");
    const one = describeUnlockableModels([{ id: "ornith-1.5-9b", name: "Ornith 1.5 9B" }]);
    expect(one).toBe("Updating unlocks: Ornith 1.5 9B.");
  });

  it("stays silent when nothing is unlockable or the field is missing", () => {
    expect(describeUnlockableModels([])).toBeNull();
    expect(describeUnlockableModels(null)).toBeNull();
    expect(describeUnlockableModels(undefined)).toBeNull();
  });

  const base: LibraryModel = {
    id: "qwen3-4b",
    name: "Qwen3 4B",
    alias: "qwen3:4b",
    approx_gib: 2.6,
    tools: true,
    vision: false,
    experimental: false,
    downloaded: false,
    active: false,
    runtime_blocker: "",
    fit_status: "EXCELLENT",
    gpu_resident: true
  };

  it("badges only the flags the catalogue actually carries", () => {
    expect(describeLibraryBadges(base)).toBe("2.6 GB · tools");
    expect(describeLibraryBadges({ ...base, vision: true, experimental: true })).toBe("2.6 GB · tools · vision · experimental");
    expect(describeLibraryBadges({ ...base, tools: false })).toBe("2.6 GB");
  });

  it("words every fit status the backend can emit, and no others", () => {
    expect(describeLibraryFit({ ...base, fit_status: "EXCELLENT", gpu_resident: true })).toContain("fully in VRAM");
    expect(describeLibraryFit({ ...base, fit_status: "EXCELLENT", gpu_resident: false })).toContain("memory budget");
    expect(describeLibraryFit({ ...base, fit_status: "SLOWER" })).toContain("slower");
    expect(describeLibraryFit({ ...base, fit_status: "TIGHT" })).toContain("Marginal");
    expect(describeLibraryFit({ ...base, fit_status: "NOT RECOMMENDED" })).toContain("Does not fit");
    expect(describeLibraryFit({ ...base, fit_status: "" })).toBe("");
  });

  it("derives per-model state from the backend fields, never from guesses", () => {
    expect(describeLibraryState({ ...base, active: true })).toBe("Active now");
    expect(describeLibraryState({ ...base, runtime_blocker: "needs a newer llama.cpp" })).toContain("Blocked");
    expect(describeLibraryState({ ...base, downloaded: true })).toContain("activate");
    expect(describeLibraryState(base)).toBe("Not downloaded");
  });

  it("offers exactly one operation per model, blocked models get none", () => {
    expect(libraryOperation({ ...base, active: true })).toBe("active");
    expect(libraryOperation({ ...base, runtime_blocker: "x" })).toBe("blocked");
    expect(libraryOperation({ ...base, downloaded: true })).toBe("remove");
    expect(libraryOperation({ ...base, experimental: true })).toBe("blocked");
    expect(libraryOperation(base)).toBe("download");
  });

  it("confirms destructive and large operations in plain language", () => {
    const removeText = libraryConfirmText({ ...base, downloaded: true }, "remove");
    expect(removeText).toContain("Delete");
    expect(removeText).toContain("Qwen3 4B");
    const downloadText = libraryConfirmText(base, "download");
    expect(downloadText).toContain("Download");
    expect(downloadText).toContain("SHA-256");
    expect(libraryConfirmText(base, "activate")).toBeNull();
    expect(libraryConfirmText(base, "active")).toBeNull();
  });

  it("reports change results with the backend's own verdict", () => {
    expect(describeLibraryResult("activated", "Qwen3.5 9B is now the active model.")).toEqual({ message: "Qwen3.5 9B is now the active model.", ok: true });
    expect(describeLibraryResult("validated", "passed preflight").ok).toBe(true);
    expect(describeLibraryResult("failed", "is not downloaded yet").ok).toBe(false);
    expect(describeLibraryResult("failed", "")).toEqual({ message: "failed", ok: false });
  });
});
