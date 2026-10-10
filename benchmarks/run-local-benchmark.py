#!/usr/bin/env python3
"""Capture real benchmark numbers from a running local llama.cpp server.

This is the only supported way to fill `benchmarks/results/`: every measurement is taken
from a live server, nothing is estimated, and nothing is rounded to look better. The
tool reads the typed state document (`-Action State`) for the runtime, model and context
that are actually running, so the label on a number can never drift from the setup that
produced it (ADR-003, ADR-005).

Usage:
    python benchmarks/run-local-benchmark.py                     # 3 runs, median reported
    python benchmarks/run-local-benchmark.py --runs 5 --max-tokens 256
    python benchmarks/run-local-benchmark.py --dry-run           # no file written

The script never starts or stops the server: starting is an explicit, confirmed action in
the command center (or `-Action Runtime -RuntimeAction start`).
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import platform
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

PROMPT = (
    "In two sentences, explain what a local large language model is and one reason to run "
    "one on your own computer."
)

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "Install-LlamaCpp-AMD.ps1"
RESULTS = REPO / "benchmarks" / "results"
CATALOG = REPO / "catalog" / "models.json"


def model_quantisation(model_id: str) -> str | None:
    """The quantisation token from the catalogue file name (the single source of truth).

    Read from `catalog/models.json` rather than guessed, so the label on a benchmark
    result can never disagree with the model the catalogue actually ships.
    """
    try:
        catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    entries = catalog["models"] if isinstance(catalog, dict) and "models" in catalog else catalog
    for entry in entries:
        if str(entry.get("Id")) == model_id:
            file_name = str(entry.get("File") or "")
            stem = file_name[:-5] if file_name.lower().endswith(".gguf") else file_name
            for part in reversed(stem.split("-")):
                if part[:1].upper() == "Q" and any(ch.isdigit() for ch in part):
                    return part
    return None


def powershell(script: str) -> str:
    """Run a small PowerShell expression and return its standard output."""
    completed = subprocess.run(
        [
            "powershell.exe",
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            script,
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    return completed.stdout.strip()


def backend_state() -> dict:
    """The typed state document from the backend (never inferred from anything else)."""
    completed = subprocess.run(
        [
            "powershell.exe",
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(SCRIPT),
            "-Action",
            "State",
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if completed.returncode != 0:
        raise SystemExit(f"-Action State failed ({completed.returncode}): {completed.stderr.strip()}")
    return json.loads(completed.stdout)


def server_props(base_url: str, timeout: float = 10.0) -> dict:
    """The server's own view of its context and slots, so the setup label is not guessed."""
    try:
        with urllib.request.urlopen(f"{base_url.rstrip('/')}/props", timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8", "replace"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        return {}


def peak_memory_mb() -> float | None:
    """Peak working set of the server process, in MiB (includes loading the model)."""
    raw = powershell(
        "$p = Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue | "
        "Sort-Object PeakWorkingSet64 -Descending | Select-Object -First 1; "
        "if ($p) { [math]::Round($p.PeakWorkingSet64 / 1MB, 1) } else { '' }"
    )
    try:
        return float(raw)
    except ValueError:
        return None


def desktop_activity() -> list[str]:
    """What else was running on the desktop: a benchmark is not a clean room."""
    raw = powershell(
        "Get-Process | Where-Object { $_.MainWindowTitle -ne '' } | "
        "Select-Object -ExpandProperty MainWindowTitle -Unique"
    )
    return [line.strip() for line in raw.splitlines() if line.strip()]


def one_run(base_url: str, model: str, max_tokens: int, timeout: float) -> dict:
    """One streaming completion; time to first token and generation throughput."""
    body = json.dumps(
        {
            "model": model,
            "messages": [{"role": "user", "content": PROMPT}],
            "max_tokens": max_tokens,
            "temperature": 0,
            "stream": True,
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/v1/chat/completions",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    started = time.perf_counter()
    first_token_at: float | None = None
    tokens = 0
    finished_at = started
    with urllib.request.urlopen(request, timeout=timeout) as response:
        for raw_line in response:
            line = raw_line.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if payload == "[DONE]":
                break
            try:
                chunk = json.loads(payload)
            except json.JSONDecodeError:
                continue
            choices = chunk.get("choices") or []
            if not choices:
                continue
            delta = choices[0].get("delta") or {}
            content = delta.get("content") or ""
            if content:
                tokens += 1
                if first_token_at is None:
                    first_token_at = time.perf_counter()
            finished_at = time.perf_counter()
    if first_token_at is None or tokens == 0:
        raise SystemExit("the server streamed no content: is the model loaded?")
    return {
        "ttft_ms": round((first_token_at - started) * 1000, 1),
        "generation_ms": round((finished_at - first_token_at) * 1000, 1),
        "tokens": tokens,
        "tokens_per_second": round(tokens / (finished_at - first_token_at), 2),
        "total_ms": round((finished_at - started) * 1000, 1),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--runs", type=int, default=3, help="how many completions to run (median is reported)")
    parser.add_argument("--max-tokens", type=int, default=192, help="tokens generated per run")
    parser.add_argument("--base-url", default="http://127.0.0.1:8080")
    parser.add_argument("--model", default="", help="alias to call; defaults to the active model alias")
    parser.add_argument("--timeout", type=float, default=180.0)
    parser.add_argument("--out", default="", help="result file; defaults to benchmarks/results/<date>-<model>.json")
    parser.add_argument("--dry-run", action="store_true", help="print the document but do not write it")
    args = parser.parse_args()

    state = backend_state()
    server = state.get("server") or {}
    if server.get("state") != "running":
        raise SystemExit("the server is not running: start it first (the command center will only benchmark a live server)")
    model_state = state.get("model") or {}
    runtime_state = state.get("runtime") or {}
    hardware = state.get("hardware") or {}
    model_alias = args.model or str(model_state.get("alias") or "local")
    model_id = str(model_state.get("id") or "")

    activity = desktop_activity()
    props = server_props(args.base_url)
    generation = props.get("default_generation_settings") or {}
    slots = props.get("total_slots") or 1
    per_slot_context = generation.get("n_ctx") or model_state.get("context_size")
    runs = []
    for index in range(1, args.runs + 1):
        run = one_run(args.base_url, model_alias, args.max_tokens, args.timeout)
        runs.append(run)
        print(
            f"run {index}/{args.runs}: ttft {run['ttft_ms']} ms, "
            f"{run['tokens_per_second']} tok/s over {run['tokens']} tokens ({run['total_ms']} ms total)",
            flush=True,
        )

    memory = peak_memory_mb()
    timestamp = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    document = {
        "schema_version": 1,
        "ttft_ms": round(statistics.median(run["ttft_ms"] for run in runs), 1),
        "tokens_per_second": round(statistics.median(run["tokens_per_second"] for run in runs), 2),
        "memory_peak_mb": memory,
        "runtime": f"{runtime_state.get('backend', 'unknown')} {runtime_state.get('tag', 'unknown')}",
        "model": model_id or model_alias,
        "timestamp": timestamp,
        "measurements": {
            "ttft_ms": {
                "median": round(statistics.median(run["ttft_ms"] for run in runs), 1),
                "min": min(run["ttft_ms"] for run in runs),
                "max": max(run["ttft_ms"] for run in runs),
            },
            "tokens_per_second": {
                "median": round(statistics.median(run["tokens_per_second"] for run in runs), 2),
                "min": min(run["tokens_per_second"] for run in runs),
                "max": max(run["tokens_per_second"] for run in runs),
            },
            "memory_peak_mb": {
                "value": memory,
                "kind": "peak working set of llama-server since it started, so it includes loading the model",
            },
        },
        "runs": runs,
        "setup": {
            "model_alias": model_alias,
            "quantisation": model_quantisation(model_id),
            "context_size_tokens": model_state.get("context_size"),
            "per_slot_context_tokens_reported_by_server": per_slot_context,
            "parallel_slots": slots,
            "context_window_total_tokens": (per_slot_context * slots) if per_slot_context else None,
            "reported_by": "the server's /props endpoint (setup) and -Action State (runtime, model, hardware)",
            "max_tokens_per_run": args.max_tokens,
            "temperature": 0,
            "prompt": PROMPT,
            "server_port": server.get("port"),
            "install_root": state.get("install_root"),
            "command_center_version": state.get("command_center_version"),
        },
        "hardware": {
            "gpu": hardware.get("RocmGpu") or "",
            "cpu": hardware.get("CpuName") or "",
            "ram_gib": hardware.get("RamGiB"),
            "vram_gib_max_dedicated": hardware.get("MaxAmdVramGiB"),
            "support_level": (hardware.get("support") or {}).get("level"),
            "detection_confidence": (hardware.get("detection") or {}).get("confidence"),
        },
        "environment": {
            "desktop_activity": activity,
            "os": f"{platform.system()} {platform.release()} ({platform.version()})",
            "python": platform.python_version(),
            "note": "Measured on a working desktop, not a clean room; the windows above were open or idle.",
        },
    }

    out_path = Path(args.out) if args.out else RESULTS / f"{timestamp[:10]}-{model_id or model_alias}.json"
    text = json.dumps(document, indent=2) + "\n"
    if args.dry_run:
        print(text)
        return 0
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(text, encoding="utf-8", newline="\n")
    print(f"wrote {out_path}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except urllib.error.URLError as error:
        sys.exit(f"could not reach the server: {error}")
