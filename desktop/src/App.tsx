import { useCallback, useEffect, useRef, useState } from "react";
import * as api from "./api";
import {
  describeDiagnostics,
  describeGpu,
  describeIdleCapability,
  describeIdleVramEffect,
  describeLibraryBadges,
  describeLibraryFit,
  describeUnlockableModels,
  describeLibraryResult,
  describeLibraryState,
  describeMissingBackend,
  describeModel,
  describePortOwner,
  describeRuntime,
  describeServer,
  describeSettingsSave,
  describeSupport,
  describeTier,
  describeUseCase,
  formatStartProgress,
  isMinutesValid,
  isUseCaseValid,
  libraryConfirmText,
  libraryOperation
} from "./format";
import { asDocument as narrow } from "./types";
import type {
  BackendResult,
  DiagnosticDocument,
  LibraryDocument,
  LibraryModel,
  LibraryResultDocument,
  RecommendationDocument,
  RuntimeAdapterResult,
  RuntimeHealthDocument,
  SettingsDocument,
  SettingsSaveDocument,
  StateDocument
} from "./types";

const POLL_INTERVAL_MS = 2000;
const GIVE_UP_AFTER_MS = 25000;
const START_DEADLINE_MS = 240000;

type Busy = null | "refresh" | "start" | "stop" | "updateRuntime" | "diagnose" | "settings" | `library:${string}`;

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => window.setTimeout(resolve, milliseconds));
}

/** Expandable raw detail: nothing is hidden when something fails. */
function RawDetail({ result }: { result: BackendResult | null }) {
  if (!result) {
    return null;
  }
  const document = result.document === null || result.document === undefined ? "(none)" : JSON.stringify(result.document, null, 2);
  return (
    <details className="raw">
      <summary>Technical detail</summary>
      <dl>
        <dt>Action</dt>
        <dd>{result.action}</dd>
        <dt>Command</dt>
        <dd>
          <code>{result.command || "(not run)"}</code>
        </dd>
        <dt>Exit code</dt>
        <dd>{result.exit_code === null ? "(none)" : result.exit_code}</dd>
        <dt>Install root</dt>
        <dd>
          <code>{result.install_root}</code>
        </dd>
        <dt>Backend script</dt>
        <dd>
          <code>{result.script ?? "(not found)"}</code>
        </dd>
      </dl>
      {result.stderr.trim() ? (
        <>
          <p>Standard error</p>
          <pre>{result.stderr}</pre>
        </>
      ) : null}
      <p>Backend document</p>
      <pre>{document}</pre>
    </details>
  );
}

function ErrorBox({ result }: { result: BackendResult | null }) {
  if (!result || result.ok) {
    return null;
  }
  return (
    <div className="error" role="alert">
      <p>{result.error ?? "The backend call failed."}</p>
      <RawDetail result={result} />
    </div>
  );
}

export default function App() {
  const [state, setState] = useState<StateDocument | null>(null);
  const [recommendations, setRecommendations] = useState<RecommendationDocument | null>(null);
  const [diagnostics, setDiagnostics] = useState<DiagnosticDocument | null>(null);
  const [diagnosticResult, setDiagnosticResult] = useState<BackendResult | null>(null);
  const [failure, setFailure] = useState<BackendResult | null>(null);
  const [settings, setSettings] = useState<SettingsDocument | null>(null);
  const [settingsDraftMinutes, setSettingsDraftMinutes] = useState<number | null>(null);
  const [settingsDraftUseCase, setSettingsDraftUseCase] = useState<string | null>(null);
  const [settingsSave, setSettingsSave] = useState<{ message: string; ok: boolean } | null>(null);
  const [library, setLibrary] = useState<LibraryDocument | null>(null);
  const [libraryNote, setLibraryNote] = useState<{ message: string; ok: boolean } | null>(null);
  const [notice, setNotice] = useState<string>("");
  const [busy, setBusy] = useState<Busy>("refresh");
  const [progress, setProgress] = useState<string>("");
  const [loading, setLoading] = useState(true);
  const [startedAt, setStartedAt] = useState<number | null>(null);
  const busyRef = useRef<Busy>(null);

  const applyStateResult = useCallback((result: BackendResult): boolean => {
    const document = narrow<StateDocument>(result.document);
    if (result.ok && document) {
      setState(document);
      setFailure(null);
      return true;
    }
    setFailure(result);
    return false;
  }, []);

  /** Refresh every displayed value from the backend documents. */
  const refresh = useCallback(async () => {
    setBusy("refresh");
    const [stateResult, recommendationResult] = await Promise.all([api.getState(), api.getRecommendations()]);
    const stateOk = applyStateResult(stateResult);
    const recommendationDocument = narrow<RecommendationDocument>(recommendationResult.document);
    if (recommendationResult.ok && recommendationDocument) {
      setRecommendations(recommendationDocument);
    } else if (!stateOk) {
      setFailure(stateResult);
    }
    setLoading(false);
    setBusy(null);
  }, [applyStateResult]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  // Elapsed time is part of the progress message, so it is real information, not a spinner.
  useEffect(() => {
    if (startedAt === null) {
      return;
    }
    const timer = window.setInterval(() => {
      setProgress((current) => (current === "" ? current : formatStartProgress(state?.server?.state, Date.now() - startedAt)));
    }, 1000);
    return () => window.clearInterval(timer);
  }, [startedAt, state?.server?.state]);

  async function onStart() {
    if (busyRef.current !== null) {
      return;
    }
    busyRef.current = "start";
    setBusy("start");
    setNotice("");
    const begin = Date.now();
    setStartedAt(begin);
    setProgress(formatStartProgress("stopped", 0));
    const startResult = await api.startServer();
    if (!startResult.ok) {
      setFailure(startResult);
      setNotice("The server was not started.");
    } else {
      setProgress(formatStartProgress("loading", 0));
      let phase: string = "stopped";
      while (Date.now() - begin < START_DEADLINE_MS) {
        await sleep(POLL_INTERVAL_MS);
        const health = await api.runtimeHealth();
        const document = narrow<RuntimeHealthDocument>(health.document);
        phase = document?.state ?? "";
        if (!health.ok) {
          setFailure(health);
          break;
        }
        setProgress(formatStartProgress(phase, Date.now() - begin));
        if (phase === "running") {
          break;
        }
        if (phase === "stopped" && Date.now() - begin > GIVE_UP_AFTER_MS) {
          break;
        }
      }
      if (phase === "running") {
        setNotice(`The AI is running at ${state?.server?.base_url ?? ""}.`);
        setDiagnostics(null);
      } else {
        // The backend's own verdict, not a generic message: ask for diagnostics.
        const result = await api.getDiagnostics();
        setDiagnosticResult(result);
        setDiagnostics(narrow<DiagnosticDocument>(result.document));
        if (!result.ok) {
          setFailure(result);
        }
        setNotice("The server did not come up. The reasons below come from the backend's own diagnostics.");
      }
    }
    setStartedAt(null);
    setProgress("");
    await refresh();
    busyRef.current = null;
    setBusy(null);
  }

  /** Ask the backend for the newest llama.cpp; two-step like stop: the backend answers
   * requires_confirmation first, and only a confirmed second call downloads. */
  async function onUpdateRuntime() {
    if (busyRef.current !== null) {
      return;
    }
    busyRef.current = "updateRuntime";
    setBusy("updateRuntime");
    setNotice("");
    const first = await api.updateRuntime(false);
    const firstDoc = narrow<RuntimeAdapterResult>(first.document);
    if (!first.ok) {
      setFailure(first);
    } else if (firstDoc?.status === "requires_confirmation") {
      const confirmed = window.confirm(
        "Download the newest llama.cpp build?\n\nDownloaded models are kept and launchers are rebuilt for the new build.\nThe download runs in its own window with size and SHA-256 checks."
      );
      if (!confirmed) {
        setNotice("Nothing was downloaded.");
        busyRef.current = null;
        setBusy(null);
        return;
      }
      const result = await api.updateRuntime(true);
      const doc = narrow<RuntimeAdapterResult>(result.document);
      if (result.ok && doc) {
        setNotice(doc.detail);
        if (doc.status === "failed" || doc.status === "declined") {
          setFailure(result);
        }
      } else {
        setFailure(result);
      }
    } else if (firstDoc?.status === "server_running") {
      setNotice(firstDoc.detail);
    }
    await refresh();
    busyRef.current = null;
    setBusy(null);
  }

  async function onStop() {
    if (busyRef.current !== null) {
      return;
    }
    busyRef.current = "stop";
    setBusy("stop");
    setNotice("");
    let result = await api.stopServer(false);
    const document = narrow<RuntimeAdapterResult>(result.document);
    if (result.ok && document?.status === "requires_confirmation") {
      const confirmed = window.confirm(
        "Turn the AI off?\n\nAnything using it right now — a chat in VS Code, for example — stops getting replies."
      );
      if (!confirmed) {
        setNotice("Nothing was stopped.");
        await refresh();
        busyRef.current = null;
        setBusy(null);
        return;
      }
      result = await api.stopServer(true);
    }
    const stopped = narrow<RuntimeAdapterResult>(result.document);
    if (result.ok) {
      // Stopping a process is asynchronous: keep refreshing until the backend reports the
      // server gone, so the window never shows a stale "loading" after a stop.
      const begin = Date.now();
      setProgress("Waiting for the server to stop…");
      let phase: string = "loading";
      while (Date.now() - begin < 20000) {
        await sleep(1000);
        const probe = await api.runtimeHealth();
        phase = narrow<RuntimeHealthDocument>(probe.document)?.state ?? "";
        setProgress(`Waiting for the server to stop — ${Math.round((Date.now() - begin) / 1000)}s`);
        if (phase === "stopped") {
          break;
        }
      }
      setProgress("");
      setNotice(`The AI is ${stopped?.status === "not_running" ? "already off" : "off"}. ${stopped?.detail ?? ""}`.trim());
    } else {
      setFailure(result);
      setProgress("");
    }
    await refresh();
    busyRef.current = null;
    setBusy(null);
  }

  async function onDiagnose() {
    if (busyRef.current !== null) {
      return;
    }
    busyRef.current = "diagnose";
    setBusy("diagnose");
    setNotice("");
    const result = await api.getDiagnostics();
    setDiagnosticResult(result);
    setDiagnostics(narrow<DiagnosticDocument>(result.document));
    if (!result.ok) {
      setFailure(result);
    }
    await refresh();
    busyRef.current = null;
    setBusy(null);
  }

  /** Show the backend's settings document as the draft, the save result re-syncs it. */
  const applySettingsDocument = useCallback((document: SettingsDocument | null) => {
    setSettings(document);
    if (document) {
      setSettingsDraftMinutes(document.idle_unload.capable ? document.idle_unload.minutes ?? 0 : null);
      setSettingsDraftUseCase(document.use_case.saved ?? document.use_case.allowed[0] ?? null);
    } else {
      setSettingsDraftMinutes(null);
      setSettingsDraftUseCase(null);
    }
  }, []);

  const loadSettings = useCallback(async () => {
    const result = await api.getSettings();
    const document = narrow<SettingsDocument>(result.document);
    if (result.ok && document) {
      applySettingsDocument(document);
    } else if (!result.ok) {
      setFailure(result);
    }
  }, [applySettingsDocument]);

  useEffect(() => {
    void loadSettings();
  }, [loadSettings]);

  async function onSaveSettings() {
    if (busyRef.current !== null || !settings) {
      return;
    }
    // Validate in the UI first, but the backend is still the authority: its result
    // document answers, and the drafts re-sync to whatever it actually saved.
    const minutesPrefilled = settingsDraftMinutes;
    const useCase = settingsDraftUseCase;
    if (settings.idle_unload.capable && !isMinutesValid(minutesPrefilled)) {
      setSettingsSave({ message: "Idle unload needs a whole number of minutes from 0 to 1440.", ok: false });
      return;
    }
    if (useCase === null || !isUseCaseValid(useCase, settings.use_case.allowed)) {
      setSettingsSave({ message: "Pick one of the listed use cases.", ok: false });
      return;
    }
    busyRef.current = "settings";
    setBusy("settings");
    setSettingsSave(null);
    const patch = JSON.stringify({
      idle_unload: { minutes: settings.idle_unload.capable ? minutesPrefilled : (settings.idle_unload.minutes ?? 0) },
      use_case: useCase
    });
    const result = await api.saveSettings(patch);
    const document = narrow<SettingsSaveDocument>(result.document);
    if (!result.ok || !document) {
      setFailure(result);
      setSettingsSave({ message: "The change did not reach the backend. Nothing was saved.", ok: false });
    } else {
      const message = describeSettingsSave(document.applied.length, document.rejected);
      setSettingsSave({ message, ok: document.rejected.length === 0 });
      if (document.settings) {
        applySettingsDocument(document.settings);
      }
    }
    busyRef.current = null;
    setBusy(null);
  }

  const applyLibraryDocument = useCallback((document: LibraryDocument | null) => {
    setLibrary(document);
  }, []);

  const loadLibrary = useCallback(async () => {
    const result = await api.getLibrary();
    const document = narrow<LibraryDocument>(result.document);
    if (result.ok && document) {
      applyLibraryDocument(document);
    } else if (!result.ok) {
      setFailure(result);
    }
  }, [applyLibraryDocument]);

  useEffect(() => {
    void loadLibrary();
  }, [loadLibrary]);

  async function onLibraryOperation(model: LibraryModel) {
    if (busyRef.current !== null) {
      return;
    }
    const operation = libraryOperation(model);
    const confirmText = libraryConfirmText(model, operation);
    if (confirmText !== null && !window.confirm(confirmText)) {
      setLibraryNote({ message: `Nothing was ${operation === "remove" ? "deleted" : "downloaded"}.`, ok: true });
      return;
    }
    const key = `library:${operation}` as const;
    busyRef.current = key;
    setBusy(key);
    setLibraryNote(null);
    let result: BackendResult;
    if (operation === "download") {
      result = await api.downloadModel(model.id);
    } else {
      result = await api.libraryChange(operation === "remove" ? "remove" : "activate", model.id);
    }
    const document = narrow<LibraryResultDocument>(result.document);
    if (!result.ok || !document) {
      setFailure(result);
      setLibraryNote({ message: "The change did not reach the backend.", ok: false });
    } else {
      const described = describeLibraryResult(document.status, document.detail);
      setLibraryNote(described);
      if (document.library) {
        applyLibraryDocument(document.library);
      }
    }
    // A download opened its own console window; a refresh a little later shows the
    // progress, so refresh the whole window view now as well.
    await refresh();
    busyRef.current = null;
    setBusy(null);
  }

  if (loading) {
    return (
      <main className="window">
        <h1>llama.cpp Command Center</h1>
        <p role="status">Asking the backend for the current state…</p>
      </main>
    );
  }

  if (!state) {
    return (
      <main className="window">
        <h1>llama.cpp Command Center</h1>
        <section className="card">
          <h2>The backend is not available</h2>
          <p>{failure ? describeMissingBackend(failure) : "No state document was returned."}</p>
          <ErrorBox result={failure} />
        </section>
      </main>
    );
  }

  const phase = state.server?.state;
  const hardware = state.hardware;
  // What the idle choice means in VRAM terms; the backend's settings document already
  // carries the two facts, the rule only words them (null when either is unknown).
  const idleVramEffect = settings ? describeIdleVramEffect(settings.gpu_vram_gib, settings.active_model_gib) : null;
  // What 'Update llama.cpp' would unlock, straight from the library document's
  // catalogue-driven list; absent or empty means the line simply does not render.
  const unlockLine = describeUnlockableModels(library?.unlocked_models);

  return (
    <main className="window">
      <header>
        <h1>llama.cpp Command Center</h1>
        <p className="subtitle" role="status" aria-live="polite">
          {describeServer(phase)}
          {notice ? ` — ${notice}` : ""}
        </p>
      </header>

      {progress ? (
        <p className="progress" role="status" aria-live="polite">
          {progress}
        </p>
      ) : null}

      <ErrorBox result={failure} />

      <section className="card">
        <h2>Your AI</h2>
        <dl className="facts">
          <dt>Active model</dt>
          <dd>{describeModel(state.model)}</dd>
          <dt>Server</dt>
          <dd>
            {describeServer(phase)} on port {state.server?.port ?? 0}
          </dd>
          <dt>Runtime</dt>
          <dd>{describeRuntime(state.runtime)}</dd>
          <dt>GPU</dt>
          <dd>{describeGpu(hardware)}</dd>
          <dt>Support</dt>
          <dd>{describeSupport(hardware?.support?.level, hardware?.support?.confidence)}</dd>
          <dt>Install root</dt>
          <dd>
            <code>{state.install_root}</code>
          </dd>
        </dl>
        {state.hardware_error ? <p className="warning">Hardware scan problem: {state.hardware_error}</p> : null}
        {state.model?.runtime_blocker ? <p className="warning">{state.model.runtime_blocker}</p> : null}
      </section>

      <section className="actions">
        <button type="button" onClick={onStart} disabled={busy !== null || phase === "running"} autoFocus>
          {busy === "start" ? "Starting…" : "Start the AI"}
        </button>
        <button type="button" onClick={onStop} disabled={busy !== null || phase === "stopped"}>
          {busy === "stop" ? "Stopping…" : "Stop the AI"}
        </button>
        <button
          type="button"
          onClick={onUpdateRuntime}
          disabled={busy !== null}
          title={describeUnlockableModels(library?.unlocked_models) ?? "Checks for a newer llama.cpp build; models are kept"}
        >
          {busy === "updateRuntime" ? "Updating llama.cpp…" : "Update llama.cpp"}
        </button>
        <button type="button" onClick={onDiagnose} disabled={busy !== null}>
          {busy === "diagnose" ? "Checking…" : "Run diagnostics"}
        </button>
        <button type="button" onClick={() => void refresh()} disabled={busy !== null}>
          {busy === "refresh" ? "Refreshing…" : "Refresh"}
        </button>
        {unlockLine ? (
          <p className="muted" role="status">
            {unlockLine}
          </p>
        ) : null}
      </section>

      <section className="card">
        <h2>Recommended models</h2>
        {recommendations ? (
          <ul className="tiers">
            {(["fast", "balanced", "maximum"] as const).map((key) => (
              <li key={key} className={state.model?.id === recommendations.recommended[key]?.model_id ? "current" : undefined}>
                <h3>{key}</h3>
                <p>{describeTier(recommendations.recommended[key])}</p>
              </li>
            ))}
          </ul>
        ) : (
          <p>The recommendation engine did not return a document.</p>
        )}
        {recommendations?.hardware_error ? <p className="warning">Hardware scan problem: {recommendations.hardware_error}</p> : null}
      </section>

      <section className="card">
        <h2>Model library</h2>
        {library ? (
          <>
            <ul className="models">
              {library.models.map((model) => {
                const operation = libraryOperation(model);
                return (
                  <li key={model.id} className={model.active ? "current" : undefined}>
                    <div className="model-line">
                      <span className="model-name">{model.name}</span>
                      <span className="muted model-badges">{describeLibraryBadges(model)}</span>
                    </div>
                    <p className="model-state">{describeLibraryState(model)}{describeLibraryFit(model) ? ` — ${describeLibraryFit(model)}` : ""}</p>
                    {model.runtime_blocker ? <p className="warning">{model.runtime_blocker}</p> : null}
                    {operation === "active" ? null : (
                      <div className="actions">
                        {operation === "download" ? (
                          <button type="button" onClick={() => void onLibraryOperation(model)} disabled={busy !== null}>
                            Download
                          </button>
                        ) : null}
                        {operation === "remove" ? (
                          <>
                            <button type="button" onClick={() => void onLibraryOperation(model)} disabled={busy !== null}>
                              Switch to this model
                            </button>
                            <button type="button" onClick={() => void onLibraryOperation(model)} disabled={busy !== null}>
                              Remove from disk
                            </button>
                          </>
                        ) : null}
                        {operation === "blocked" ? (
                          <button type="button" disabled title={model.runtime_blocker || "Blocked by the installed runtime"}>
                            Not available on this runtime
                          </button>
                        ) : null}
                      </div>
                    )}
                  </li>
                );
              })}
            </ul>
            {library.hardware_error ? <p className="warning">Hardware scan problem: {library.hardware_error}</p> : null}
            {libraryNote ? (
              <p className={libraryNote.ok ? "verdict" : "warning"} role="status" aria-live="polite">
                {libraryNote.message}
              </p>
            ) : null}
            {busy?.startsWith("library:") ? (
              <p className="progress" role="status" aria-live="polite">
                {busy === "library:download" ? "Download started in its own window — this screen refreshes when it is done." : "Working…"}
              </p>
            ) : null}
          </>
        ) : (
          <p>The model library document was not returned by the backend.</p>
        )}
      </section>

      <section className="card">
        <h2>Settings</h2>
        {settings ? (
          <>
            <dl className="facts">
              <dt>Idle unload</dt>
              <dd>
                {settings.idle_unload.capable ? (
                  <label>
                    Unload the model after
                    {" "}
                    <input
                      type="number"
                      min={0}
                      max={1440}
                      value={settingsDraftMinutes ?? 0}
                      onChange={(event) => {
                        const parsed = Number.parseInt(event.target.value, 10);
                        setSettingsDraftMinutes(Number.isNaN(parsed) ? null : parsed);
                      }}
                      style={{ width: "5em" }}
                      aria-label="Minutes of idle time before the model unloads"
                    />
                    {" "}
                    idle minutes (0 turns it off)
                  </label>
                ) : (
                  "Not available with the installed runtime"
                )}
              </dd>
              <dt>{"\u00a0"}</dt>
              <dd className="muted">{describeIdleCapability(settings.idle_unload.capable, settings.idle_unload.installed_models)}</dd>
              {idleVramEffect ? (
                <>
                  <dt>Graphics memory</dt>
                  <dd className="muted">{idleVramEffect}</dd>
                </>
              ) : null}
              <dt>Use case</dt>
              <dd>
                <select
                  value={settingsDraftUseCase ?? ""}
                  onChange={(event) => setSettingsDraftUseCase(event.target.value)}
                  aria-label="What you use the AI for"
                >
                  {settings.use_case.allowed.map((id) => (
                    <option key={id} value={id}>
                      {describeUseCase(id)}
                    </option>
                  ))}
                </select>
              </dd>
              <dt>{"\u00a0"}</dt>
              <dd className="muted">The suggestion engine uses this when you ask for a model.</dd>
            </dl>
            {settingsSave ? (
              <p className={settingsSave.ok ? "verdict" : "warning"} role="status" aria-live="polite">
                {settingsSave.message}
              </p>
            ) : null}
            <div className="actions">
              <button type="button" onClick={onSaveSettings} disabled={busy !== null}>
                {busy === "settings" ? "Saving…" : "Save settings"}
              </button>
            </div>
          </>
        ) : (
          <p>The settings document was not returned by the backend.</p>
        )}
      </section>

      <section className="card">
        <h2>Diagnostics</h2>
        {diagnostics ? (
          <>
            <p className="verdict">{describeDiagnostics(diagnostics)}</p>
            <dl className="facts">
              <dt>Runtime</dt>
              <dd>
                {describeServer(diagnostics.runtime_health?.state)} · validation {diagnostics.runtime_health?.validation_status ?? "unknown"} ·{" "}
                {describePortOwner(diagnostics.runtime_health?.port_owner)}
              </dd>
              <dt>Hardware</dt>
              <dd>{describeSupport(diagnostics.hardware_health?.level ?? undefined, diagnostics.hardware_health?.confidence)}</dd>
              <dt>Model</dt>
              <dd>
                {diagnostics.model_health?.id || "no active model"} · fit {diagnostics.model_health?.fit || "unknown"} ·{" "}
                {diagnostics.model_health?.present ? "file present" : "file missing"}
              </dd>
              <dt>Editors</dt>
              <dd>
                VS Code {diagnostics.editor_health?.vscode?.state ?? "unknown"} · Continue{" "}
                {diagnostics.editor_health?.ll_continue?.configured ? "configured" : "not configured"} · llama-vscode{" "}
                {diagnostics.editor_health?.llama_vscode?.endpoint_set ? "endpoint set" : "no endpoint"}
              </dd>
            </dl>
            {[...diagnostics.blockers, ...(diagnostics.runtime_health?.blockers ?? []), ...diagnostics.warnings].map((line) => (
              <p className="warning" key={line}>
                {line}
              </p>
            ))}
            <details className="raw">
              <summary>Raw diagnostics document</summary>
              <pre>{JSON.stringify(diagnostics, null, 2)}</pre>
            </details>
            <RawDetail result={diagnosticResult} />
          </>
        ) : (
          <p>Press “Run diagnostics” to ask the backend for its four health sections.</p>
        )}
      </section>
    </main>
  );
}
