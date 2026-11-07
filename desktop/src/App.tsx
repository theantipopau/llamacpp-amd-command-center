import { useCallback, useEffect, useRef, useState, type KeyboardEvent } from "react";
import * as api from "./api";
import logo from "./assets/logo.png";
import {
  BACKEND_CHOICES,
  describeRollback,
  describeRuntimeUpdate,
  redactPaths,
  type BackendChoice,
  backendChoiceOf,
  describeBackendChoice,
  describeReceipts,
  describeDiagnostics,
  describeGpu,
  describeIdleCapability,
  describeIdleVramEffect,
  describeLibraryBadges,
  describeLibraryFit,
  describeGamePause,
  describeHomeVerdict,
  describeModelState,
  describeStatusBadge,
  isGamePauseValid,
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
  describeVram,
  formatStartProgress,
  isMinutesValid,
  nextTabIndex,
  isUseCaseValid,
  libraryConfirmText,
  libraryOperation
} from "./format";
import { asDocument as narrow, asSettingsDocument, asSettingsSaveDocument } from "./types";
import type {
  BackendResult,
  RuntimeRollbackDocument,
  RuntimeUpdatesDocument,
  DesktopSettings,
  DiagnosticDocument,
  LibraryDocument,
  LibraryModel,
  LibraryResultDocument,
  RecommendationDocument,
  RuntimeAdapterResult,
  RuntimeHealthDocument,
  SettingsDocument,
  StateDocument
} from "./types";

const POLL_INTERVAL_MS = 2000;
const GIVE_UP_AFTER_MS = 25000;
const START_DEADLINE_MS = 240000;
// A download runs hidden in the background: check the read-only library list every
// 15 s for up to an hour, then stop and leave the Refresh button to the user.
const LIBRARY_POLL_MS = 15000;
const LIBRARY_POLL_LIMIT = 240;

type Busy = null | "updates" | "rollback" | "refresh" | "start" | "stop" | "chat" | "updateRuntime" | "diagnose" | "settings" | `backend:${string}` | `library:${string}`;
type Tab = "home" | "models" | "settings" | "health";

const TABS: Array<[Tab, string]> = [
  ["home", "Home"],
  ["models", "Models"],
  ["settings", "Settings"],
  ["health", "Health"]
];

type Theme = "system" | "light" | "dark";
const THEME_KEY = "llamacpp-command-center-theme";

function readTheme(): Theme {
  try {
    const saved = window.localStorage.getItem(THEME_KEY);
    if (saved === "light" || saved === "dark" || saved === "system") {
      return saved;
    }
  } catch {
    // A locked-down webview can deny storage; the system preference still works.
  }
  return "system";
}

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
  const [desktopSettings, setDesktopSettings] = useState<DesktopSettings | null>(null);
  // Kept as text so a cleared box stays empty while the user types a new number.
  const [settingsDraftMinutes, setSettingsDraftMinutes] = useState<string>("");
  const [settingsDraftUseCase, setSettingsDraftUseCase] = useState<string | null>(null);
  const [settingsDraftGamePause, setSettingsDraftGamePause] = useState<string>("");
  const [settingsSave, setSettingsSave] = useState<{ message: string; ok: boolean } | null>(null);
  const [library, setLibrary] = useState<LibraryDocument | null>(null);
  const [libraryNote, setLibraryNote] = useState<{ message: string; ok: boolean } | null>(null);
  const [pendingDownload, setPendingDownload] = useState<string | null>(null);
  const [notice, setNotice] = useState<string>("");
  const [busy, setBusy] = useState<Busy>("refresh");
  const [progress, setProgress] = useState<string>("");
  const [loading, setLoading] = useState(true);
  const [tab, setTab] = useState<Tab>("home");
  const [theme, setTheme] = useState<Theme>(readTheme);
  const busyRef = useRef<Busy>(null);
  const tabRefs = useRef<Partial<Record<Tab, HTMLButtonElement | null>>>({});

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

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    try {
      window.localStorage.setItem(THEME_KEY, theme);
    } catch {
      // The visual choice still applies for this session.
    }
  }, [theme]);

  async function onStart() {
    if (busyRef.current !== null) {
      return;
    }
    busyRef.current = "start";
    setBusy("start");
    setNotice("");
    const begin = Date.now();
    setProgress(formatStartProgress("loading", 0));
    const startResult = await api.startServer();
    if (!startResult.ok) {
      setFailure(startResult);
      setNotice("The server was not started.");
    } else {
      // One loop drives the progress text: it ticks every second and probes the health
      // endpoint every POLL_INTERVAL_MS. The text always uses the phase from the last probe.
      let phase = "loading";
      let nextProbe = begin;
      while (Date.now() - begin < START_DEADLINE_MS) {
        await sleep(1000);
        if (Date.now() >= nextProbe) {
          nextProbe = Date.now() + POLL_INTERVAL_MS;
          const health = await api.runtimeHealth();
          if (!health.ok) {
            setFailure(health);
            break;
          }
          phase = narrow<RuntimeHealthDocument>(health.document)?.state ?? "";
          if (phase === "running") {
            break;
          }
          if (phase === "stopped" && Date.now() - begin > GIVE_UP_AFTER_MS) {
            break;
          }
        }
        setProgress(formatStartProgress(phase, Date.now() - begin));
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
        setTab("health");
        setNotice("The server did not come up. The reasons are under Health, from the backend's own diagnostics.");
      }
    }
    setProgress("");
    await refresh();
    busyRef.current = null;
    setBusy(null);
  }

  /** Open the chat window through the install's own Chat.cmd, which starts the AI first when it is off. */
  async function onOpenChat() {
    if (busyRef.current !== null) {
      return;
    }
    busyRef.current = "chat";
    setBusy("chat");
    setNotice("");
    const result = await api.openChat();
    if (result.ok) {
      setNotice("The chat window is opening. If the AI is off, it starts first; the first load can take a minute or two.");
    } else {
      setFailure(result);
      setNotice("The chat window did not open.");
    }
    // Give the helper a moment to begin before reading the server state again.
    await sleep(2000);
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
        "Download the newest llama.cpp build?\n\nDownloaded models are kept and launchers are rebuilt for the new build.\nThe download runs in the background with size and SHA-256 checks."
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

  const [updatesDoc, setUpdatesDoc] = useState<RuntimeUpdatesDocument | null>(null);
  const [buildNote, setBuildNote] = useState<{ message: string; ok: boolean } | null>(null);
  const [copyNote, setCopyNote] = useState<string | null>(null);

  /** User-started: asks the backend whether newer llama.cpp builds exist. Downloads nothing. */
  async function onCheckUpdates() {
    if (busyRef.current !== null) {
      return;
    }
    busyRef.current = "updates";
    setBusy("updates");
    setBuildNote(null);
    const result = await api.getRuntimeUpdates();
    const document = narrow<RuntimeUpdatesDocument>(result.document);
    if (!result.ok || !document) {
      setFailure(result);
      setBuildNote({ message: "The update check did not return a document.", ok: false });
    } else {
      setUpdatesDoc(document);
    }
    busyRef.current = null;
    setBusy(null);
  }

  /** Go back to the previous llama.cpp build. Confirmed first; refused while the AI runs. */
  async function onRollback() {
    if (busyRef.current !== null) {
      return;
    }
    if (!window.confirm("Go back to the previous llama.cpp build?\n\nYour models and settings are kept. The launchers are rebuilt for the older build.")) {
      return;
    }
    busyRef.current = "rollback";
    setBusy("rollback");
    setBuildNote(null);
    const result = await api.rollbackRuntime();
    const document = narrow<RuntimeRollbackDocument>(result.document);
    if (!result.ok || !document) {
      setBuildNote({ message: result.error ?? "The rollback did not run. Nothing was changed.", ok: false });
    } else {
      setBuildNote(describeRollback(document));
    }
    busyRef.current = null;
    setBusy(null);
    await refresh();
  }

  async function onCopyDiagnostics() {
    if (!diagnostics) {
      return;
    }
    const text = JSON.stringify(redactPaths(diagnostics), null, 2);
    try {
      await api.copyToClipboard(text);
      setCopyNote("Copied. Your Windows user name is replaced with %USERPROFILE%.");
    } catch {
      setCopyNote("The clipboard was not available. Open “Diagnostics document” below and copy the text by hand.");
    }
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

  /** Normalize the backend's settings document before it reaches React. */
  const applySettingsDocument = useCallback((raw: unknown) => {
    const document = asSettingsDocument(raw);
    setSettings(document);
    if (document) {
      setSettingsDraftMinutes(document.idle_unload.capable ? String(document.idle_unload.minutes ?? 0) : "");
      setSettingsDraftUseCase(document.use_case.saved ?? document.use_case.allowed[0] ?? null);
      setSettingsDraftGamePause(String(document.game_pause?.gib ?? 0));
    } else {
      setSettingsDraftMinutes("");
      setSettingsDraftUseCase(null);
      setSettingsDraftGamePause("");
    }
  }, []);

  const loadSettings = useCallback(async () => {
    const result = await api.getSettings();
    if (result.ok) {
      applySettingsDocument(result.document);
    } else {
      setFailure(result);
    }
  }, [applySettingsDocument]);

  useEffect(() => {
    void loadSettings();
  }, [loadSettings]);

  useEffect(() => {
    void api.getDesktopSettings().then(setDesktopSettings).catch(() => setDesktopSettings({ start_minimised_to_tray: false }));
  }, []);

  async function onToggleStartMinimised(checked: boolean) {
    setDesktopSettings({ start_minimised_to_tray: checked });
    try {
      const saved = await api.saveDesktopSettings(checked);
      setDesktopSettings(saved);
      setSettingsSave({ message: "Tray start setting saved.", ok: true });
    } catch {
      setDesktopSettings({ start_minimised_to_tray: !checked });
      setSettingsSave({ message: "The tray start setting could not be saved.", ok: false });
    }
  }

  /** Save one model's backend choice through the backend's settings patch, then re-read the library. */
  async function onBackendChoice(model: LibraryModel, choice: BackendChoice) {
    if (busyRef.current !== null) {
      return;
    }
    busyRef.current = `backend:${model.id}`;
    setBusy(`backend:${model.id}`);
    const result = await api.saveSettings(JSON.stringify({ model_backends: { [model.id]: choice } }));
    const document = asSettingsSaveDocument(result.document);
    if (!result.ok || !document) {
      setFailure(result);
      setLibraryNote({ message: "The backend choice did not reach the backend. Nothing was saved.", ok: false });
    } else {
      const message = describeSettingsSave(document.applied.length, document.rejected);
      const running = phase === "running" || phase === "loading";
      setLibraryNote({
        message: document.rejected.length === 0
          ? `${model.name}: backend set to ${choice}. ${running && model.active ? "It applies the next time the AI starts." : "It applies when this model next starts."}`
          : message,
        ok: document.rejected.length === 0
      });
    }
    busyRef.current = null;
    setBusy(null);
    await loadLibrary();
  }

  async function onSaveSettings() {
    if (busyRef.current !== null || !settings) {
      return;
    }
    // Validate in the UI first, but the backend is still the authority: its result
    // document answers, and the drafts re-sync to whatever it actually saved.
    const minutesText = settingsDraftMinutes.trim();
    const minutesPrefilled = /^\d+$/.test(minutesText) ? Number(minutesText) : null;
    const useCase = settingsDraftUseCase;
    if (settings.idle_unload.capable && !isMinutesValid(minutesPrefilled)) {
      setSettingsSave({ message: "Idle unload needs a whole number of minutes from 0 to 1440.", ok: false });
      return;
    }
    if (useCase === null || !isUseCaseValid(useCase, settings.use_case.allowed)) {
      setSettingsSave({ message: "Pick one of the listed use cases.", ok: false });
      return;
    }
    const pauseCapable = settings.game_pause?.capable === true;
    if (pauseCapable && !isGamePauseValid(settingsDraftGamePause)) {
      setSettingsSave({ message: "Game pause needs 0 (off) or a whole number from 4 to 40 GiB.", ok: false });
      return;
    }
    busyRef.current = "settings";
    setBusy("settings");
    setSettingsSave(null);
    const patch = JSON.stringify({
      idle_unload: { minutes: settings.idle_unload.capable ? minutesPrefilled : (settings.idle_unload.minutes ?? 0) },
      use_case: useCase,
      // Only sent when the installed llama.cpp can do it; otherwise the backend leaves it alone.
      ...(pauseCapable ? { game_pause: { gib: Number(settingsDraftGamePause.trim()) } } : {})
    });
    const result = await api.saveSettings(patch);
    const document = asSettingsSaveDocument(result.document);
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

  // While a download runs hidden in the background, re-read the library so the list
  // shows the model as downloaded when the file lands. Stops on success or after the
  // poll limit.
  useEffect(() => {
    if (pendingDownload === null) {
      return;
    }
    let polls = 0;
    const timer = window.setInterval(() => {
      polls += 1;
      if (polls > LIBRARY_POLL_LIMIT) {
        setPendingDownload(null);
        return;
      }
      void loadLibrary();
    }, LIBRARY_POLL_MS);
    return () => window.clearInterval(timer);
  }, [pendingDownload, loadLibrary]);

  useEffect(() => {
    if (pendingDownload !== null && library?.models.some((model) => model.id === pendingDownload && model.downloaded)) {
      setPendingDownload(null);
    }
  }, [library, pendingDownload]);

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
      if (operation === "download" && document.status === "validated") {
        setPendingDownload(model.id);
      }
    }
    await refresh();
    busyRef.current = null;
    setBusy(null);
  }

  /** ARIA tabs: arrows, Home and End move the selection and focus together. */
  function onTabKeyDown(event: KeyboardEvent<HTMLButtonElement>, index: number) {
    const next = nextTabIndex(event.key, index, TABS.length);
    if (next === null) {
      return;
    }
    event.preventDefault();
    const [id] = TABS[next];
    setTab(id);
    tabRefs.current[id]?.focus();
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
  const badge = describeStatusBadge(phase, state.server?.model_state);
  const modelLine = describeModelState(state.server?.model_state);
  const hardware = state.hardware;
  // What the idle choice means in VRAM terms; the backend's settings document already
  // carries the two facts, the rule only words them (null when either is unknown).
  const idleVramEffect = settings ? describeIdleVramEffect(settings.gpu_vram_gib, settings.active_model_footprint_gib) : null;
  // What 'Update llama.cpp' would unlock, straight from the library document's
  // catalogue-driven list; absent or empty means the line simply does not render.
  const unlockLine = describeUnlockableModels(library?.unlocked_models);
  const homeVerdict = describeHomeVerdict(phase, state.model?.name, state.model?.model_present, state.server?.port);
  const vram = state?.model ? describeVram(state.vram_estimate) : null;

  return (
    <main className="window" id="main-content">
      <a className="skip-link" href="#main-content">Skip to content</a>
      <header className="app-header">
        <img src={logo} alt="" className="logo" />
        <div className="titles">
          <h1>llama.cpp Command Center</h1>
          <p className="subtitle">Runs entirely on this PC</p>
        </div>
        <span className={`badge ${badge.tone}`} role="status" aria-live="polite">
          {badge.label}
        </span>
        <div className="theme-switch" role="group" aria-label="Color theme">
          {(["system", "light", "dark"] as const).map((choice) => (
            <button
              key={choice}
              type="button"
              aria-pressed={theme === choice}
              onClick={() => setTheme(choice)}
              title={choice === "system" ? "Follow the Windows theme" : `Use the ${choice} theme`}
            >
              {choice === "system" ? "Auto" : choice === "light" ? "Light" : "Dark"}
            </button>
          ))}
        </div>
      </header>

      <div className="action-bar" role="toolbar" aria-label="Server actions">
        <button type="button" className="primary" onClick={onStart} disabled={busy !== null || phase === "running"} autoFocus>
          {busy === "start" ? "Starting…" : "Start the AI"}
        </button>
        <button type="button" onClick={onStop} disabled={busy !== null || phase === "stopped"}>
          {busy === "stop" ? "Stopping…" : "Stop the AI"}
        </button>
        <button type="button" onClick={onOpenChat} disabled={busy !== null}>
          {busy === "chat" ? "Opening…" : "Open chat"}
        </button>
        <button
          type="button"
          onClick={onUpdateRuntime}
          disabled={busy !== null}
          title={describeUnlockableModels(library?.unlocked_models) ?? "Checks for a newer llama.cpp build; models are kept"}
        >
          {busy === "updateRuntime" ? "Updating llama.cpp…" : "Update llama.cpp"}
        </button>
        <button type="button" onClick={() => void refresh()} disabled={busy !== null}>
          {busy === "refresh" ? "Refreshing…" : "Refresh"}
        </button>
      </div>

      <div className="status-line">
        {notice ? (
          <p role="status" aria-live="polite">
            {notice}
          </p>
        ) : null}
        {progress ? (
          <p className="progress" role="status" aria-live="polite">
            {progress}
          </p>
        ) : null}
      </div>

      <ErrorBox result={failure} />

      <nav className="tabs" role="tablist" aria-label="Sections">
        {TABS.map(([id, label], index) => (
          <button
            key={id}
            ref={(element) => {
              tabRefs.current[id] = element;
            }}
            type="button"
            role="tab"
            id={`tab-${id}`}
            aria-selected={tab === id}
            aria-controls={`panel-${id}`}
            tabIndex={tab === id ? 0 : -1}
            onClick={() => setTab(id)}
            onKeyDown={(event) => onTabKeyDown(event, index)}
          >
            {label}
          </button>
        ))}
      </nav>

      <div role="tabpanel" id={`panel-${tab}`} aria-labelledby={`tab-${tab}`} className="tab-panel" aria-busy={busy !== null}>
        {tab === "home" ? (
          <>
            <section className={`card home-verdict ${homeVerdict.tone}`} aria-live="polite">
              <h2>{homeVerdict.headline}</h2>
              <p className="verdict-detail">{homeVerdict.detail}</p>
              {vram ? (
                <div className="vram">
                  <div className="vram-labels">
                    <span>Graphics memory estimate</span>
                    <span>{vram.available ? `${vram.verdict} · ${vram.percent}%` : vram.verdict}</span>
                  </div>
                  {vram.available ? (
                    <div className={`vram-track${vram.fits ? "" : " over"}`} role="img" aria-label={vram.spoken}>
                      {vram.segments.map((segment) => (
                        <span
                          key={segment.key}
                          className={`vram-fill vram-${segment.key}`}
                          style={{ width: `${segment.percent}%` }}
                        />
                      ))}
                    </div>
                  ) : null}
                  <p className="muted">{vram.label}</p>
                  {vram.available ? (
                    <ul className="vram-legend">
                      {vram.segments.map((segment) => (
                        <li key={segment.key}>
                          <span className={`vram-swatch vram-${segment.key}`} aria-hidden="true" />
                          {segment.label} {segment.gib.toFixed(1)} GiB
                        </li>
                      ))}
                    </ul>
                  ) : null}
                </div>
              ) : null}
            </section>
            <section className="card">
              <h2>Your AI</h2>
              <dl className="facts">
                <dt>Active model</dt>
                <dd>{describeModel(state.model)}</dd>
                <dt>Server</dt>
                <dd>
                  {describeServer(phase)} on port {state.server?.port ?? 0}
                  {modelLine && phase === "running" ? ` · ${modelLine}` : ""}
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
          </>
        ) : null}

        {tab === "models" ? (
          <section className="card">
            <h2>Model library</h2>
            {unlockLine ? (
              <p className="muted" role="status">
                {unlockLine}
              </p>
            ) : null}
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
                        {model.downloaded && model.preferred_backend ? (
                          <div className="backend-choice">
                            <label>
                              Backend{" "}
                              <select
                                value={backendChoiceOf(model)}
                                onChange={(event) => void onBackendChoice(model, event.target.value as BackendChoice)}
                                disabled={busy !== null}
                                aria-label={`Backend for ${model.name}`}
                              >
                                {BACKEND_CHOICES.map((choice) => (
                                  <option key={choice} value={choice}>
                                    {choice === "Auto" ? "Auto (recommended)" : choice}
                                  </option>
                                ))}
                              </select>
                            </label>
                            <span className="muted">{describeBackendChoice(model)}</span>
                          </div>
                        ) : null}
                        {describeReceipts(model).length > 0 ? (
                          <div className="receipts">
                            <p className="muted receipts-title">Tested on this PC</p>
                            <ul>
                              {describeReceipts(model).map((line) => (
                                <li key={line}>{line}</li>
                              ))}
                            </ul>
                          </div>
                        ) : (
                          <p className="muted">Not benchmarked on this PC yet.</p>
                        )}
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
                {library.receipts_caveat ? <p className="muted">Reading the speeds: {library.receipts_caveat}</p> : null}
                {library.hardware_error ? <p className="warning">Hardware scan problem: {library.hardware_error}</p> : null}
                {libraryNote ? (
                  <p className={libraryNote.ok ? "verdict" : "warning"} role="status" aria-live="polite">
                    {libraryNote.message}
                  </p>
                ) : null}
                {pendingDownload !== null ? (
                  <p className="progress" role="status" aria-live="polite">
                    Download running in the background. This list updates when the file is in place.
                  </p>
                ) : null}
                {busy?.startsWith("library:") ? (
                  <p className="progress" role="status" aria-live="polite">
                    Working…
                  </p>
                ) : null}
              </>
            ) : (
              <p>The model library document was not returned by the backend.</p>
            )}
          </section>
        ) : null}

        {tab === "settings" ? (
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
                          inputMode="numeric"
                          min={0}
                          max={1440}
                          value={settingsDraftMinutes}
                          onChange={(event) => setSettingsDraftMinutes(event.target.value)}
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
                  <dt>{" "}</dt>
                  <dd className="muted">{describeIdleCapability(settings.idle_unload.capable, settings.idle_unload.installed_models)}</dd>
                  {idleVramEffect ? (
                    <>
                      <dt>Graphics memory</dt>
                      <dd className="muted">{idleVramEffect}</dd>
                    </>
                  ) : null}
                  <dt>Game pause</dt>
                  <dd>
                    {settings.game_pause?.capable !== true ? (
                      "Not available with the installed runtime"
                    ) : (
                      <label>
                        Unload the model when other programs use
                        {" "}
                        <input
                          type="number"
                          inputMode="numeric"
                          min={0}
                          max={40}
                          value={settingsDraftGamePause}
                          onChange={(event) => setSettingsDraftGamePause(event.target.value)}
                          style={{ width: "5em" }}
                          aria-label="Graphics memory in GiB at which other programs pause the model (0 is off)"
                        />
                        {" "}
                        GiB or more (0 is off)
                      </label>
                    )}
                  </dd>
                  <dt>{" "}</dt>
                  <dd className="muted">{describeGamePause(Number(settingsDraftGamePause) || 0, settings.game_pause?.capable)}</dd>
                  <dt>Use case</dt>
                  <dd>
                    {settings.use_case.allowed.length > 0 ? (
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
                    ) : (
                      <span className="muted">The backend did not report any use cases.</span>
                    )}
                  </dd>
                  <dt>{" "}</dt>
                  <dd className="muted">The suggestion engine uses this when you ask for a model.</dd>
                  <dt>Window</dt>
                  <dd>
                    <label>
                      <input
                        type="checkbox"
                        checked={desktopSettings?.start_minimised_to_tray ?? false}
                        onChange={(event) => void onToggleStartMinimised(event.target.checked)}
                      />{" "}
                      Start minimised to the system tray
                    </label>
                    <p className="muted">Closing the window keeps the app in the tray; Open restores it.</p>
                  </dd>
                </dl>
                {settingsSave ? (
                  <p className={settingsSave.ok ? "verdict" : "warning"} role="status" aria-live="polite">
                    {settingsSave.message}
                  </p>
                ) : null}
                <div className="actions">
                  <button type="button" className="primary" onClick={onSaveSettings} disabled={busy !== null}>
                    {busy === "settings" ? "Saving…" : "Save settings"}
                  </button>
                </div>
              </>
            ) : (
              <p>The settings document was not returned by the backend.</p>
            )}
          </section>
        ) : null}

        {tab === "health" ? (
          <section className="card">
            <h2>Health</h2>
            <div className="actions">
              <button type="button" onClick={onDiagnose} disabled={busy !== null}>
                {busy === "diagnose" ? "Checking…" : "Run diagnostics"}
              </button>
            </div>
            <h3>llama.cpp builds</h3>
            <div className="actions">
              <button type="button" onClick={() => void onCheckUpdates()} disabled={busy !== null}>
                {busy === "updates" ? "Checking…" : "Check for newer builds"}
              </button>
              <button
                type="button"
                onClick={() => void onRollback()}
                disabled={busy !== null || phase !== "stopped"}
                title={phase !== "stopped" ? "Stop the AI first" : "Go back to the previous build"}
              >
                {busy === "rollback" ? "Rolling back…" : "Roll back to the previous build"}
              </button>
            </div>
            {updatesDoc ? (
              <ul className="builds">
                {updatesDoc.updates.map((entry) => (
                  <li key={`${entry.backend}-${entry.installed_tag}`}>{describeRuntimeUpdate(entry)}</li>
                ))}
              </ul>
            ) : null}
            {buildNote ? (
              <p className={buildNote.ok ? "verdict" : "warning"} role="status">
                {buildNote.message}
              </p>
            ) : null}
            {diagnostics ? (
              <>
                <p className="verdict" role="status">{describeDiagnostics(diagnostics)}</p>
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
                <div className="actions">
                  <button type="button" onClick={() => void onCopyDiagnostics()}>
                    Copy diagnostics
                  </button>
                </div>
                {copyNote ? (
                  <p className="muted" role="status">
                    {copyNote}
                  </p>
                ) : null}
                <details className="raw">
                  <summary>Diagnostics document (user folder hidden)</summary>
                  <pre>{JSON.stringify(redactPaths(diagnostics), null, 2)}</pre>
                </details>
                <RawDetail result={diagnosticResult} />
              </>
            ) : (
              <p>Press “Run diagnostics” to ask the backend for its four health sections.</p>
            )}
          </section>
        ) : null}
      </div>
    </main>
  );
}
