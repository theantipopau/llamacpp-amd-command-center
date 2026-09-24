# Security Policy

## Scope

This project is a local Windows command center for llama.cpp. It downloads and launches local software and models, then exposes the local llama.cpp server on `127.0.0.1`.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's private vulnerability reporting feature for this repository when available. Include:

- affected file and version or commit;
- Windows version and GPU/driver;
- reproduction steps;
- impact and whether the issue exposes data or allows unintended network access.

## Security assumptions

- The local server is intentionally bound to loopback.
- Users are responsible for reviewing third-party model and editor downloads.
- Model files are checked against published Git LFS SHA-256 values when the upstream repository publishes them.
- The AMD ROCm Windows ZIP currently has no publisher-provided SHA-256 sidecar; the project records the local hash instead.
- No cloud API key is required for the local server.

## Scope notes

Third-party projects and services referenced by the documentation, including AMD, ggml-org, VS Code, Continue, Cline, and Anthropic, maintain their own security processes.
