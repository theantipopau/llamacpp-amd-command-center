# ADR-004: Versioned catalogue as runtime data — `catalog/*.json`

- **Status:** Accepted, 2026-10-08 (Phase A, implemented in the same phase)
- **Checklist:** §3 (typed commands), §4 (catalogue and recommendations),
  §20 (document decisions)

## Context

The model catalogue, AMD ROCm package facts, ROCm support pattern and the
runtime-compatibility rule were hardcoded inside `Install-LlamaCpp-AMD.ps1`.
That makes them hard to review as data, impossible for other tooling to read,
and one edit away from drifting from the evidence records
(`docs/research/upstream-evidence.md`, `tests/fixtures/catalog-evidence.json`).

Checklist priority: a trustworthy AMD hardware intelligence layer needs a
**versioned catalogue system** — `models.json`, `runtimes.json`,
`hardware_profiles.json`, plus compatibility metadata.

## Decision

1. **`catalog/` next to the script is the single source of truth**, loaded at
   runtime by `Get-CatalogJson` (session-cached):
   - `models.json` — the nine models, same property names as before
     (`Id`, `File`, `Rank`, `Tools`, ...), consumed by `Get-ModelCatalog`.
   - `runtimes.json` — AMD ROCm package tag/url/name/size/page, `checked_on`
     and `freshness_days`, consumed by the script-scope `$script:AmdRocm*`
     variables and `Get-PlannedRuntime`.
   - `hardware_profiles.json` — the AMD Windows ROCm compatibility-matrix
     pattern and the three reason texts, consumed by `Get-HardwareProfile`.
   - `compatibility.json` — rules (`backend`, `tag_regex`, `model_flags`,
     `message_template`) consumed by `Get-ModelRuntimeBlocker`.
2. **No embedded fallback copy.** A missing or malformed file throws with its
   exact path at first use (and `runtimes.json` plus siblings are preloaded at
   script start, so every action fails fast instead of half-way through an
   install). Two copies of the same data would drift; CI would only notice
   after users did.
3. **Versioning.** Every file carries `schema_version` (integer, starts at 1)
   and `catalog_version` (the command-centre version that wrote it), plus
   `verified_on`/`verified_against` pointing at the evidence record. Breaking
   shape changes increment `schema_version`; catalogue content edits bump
   `catalog_version`. Consumers must ignore unknown fields.
4. **Packaging.** The release workflow copies `catalog/` into the ZIP next to
   the two scripts; README troubleshooting says to keep the scripts and the
   `catalog` folder together.
5. **Tests read the shipped files.** The harness sets `$script:CatalogDirectory`
   to the repository's `catalog/`, so every existing catalogue/evidence
   assertion now validates the real files. New checks assert schema versions,
   pinned AMD package facts, the ROCm pattern, the compatibility rules, and
   that a missing file raises a clear error rather than silent stale data.

## Consequences

- Catalogue edits are plain data diffs, reviewable against the evidence record.
- External tooling (future GUI, benchmarking, hardware profiles) can read the
  same files the script runs on.
- Distribution now includes a data folder; a lone copy of the `.ps1` outside
  the repository/ZIP is intentionally unsupported (clear error, no silent
  degradation).
- Behaviour is unchanged: the model list, ROCm package facts, blocker messages
  and recommendation logic are byte-for-byte what the inline data produced,
  asserted by the unchanged evidence-fixture and picker tests.
