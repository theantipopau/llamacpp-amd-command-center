# Contributing

Thanks for helping improve the AMD Windows llama.cpp command center.

## Development principles

- Target Windows PowerShell 5.1 compatibility.
- Keep the batch front end readable, colorful, and safe for non-technical users.
- Never make a download or install silent: show what will be downloaded and ask for `YES` first.
- Keep the server localhost-only unless the project explicitly designs a secure opt-in flow.
- Prefer official upstream sources and verify published hashes where available.
- Do not commit models, generated launchers, local API keys, or user-specific paths.
- Batch screen text must not contain an exclamation mark: the menu uses delayed expansion.
- Give any `powershell.exe` call inside a batch `for /f` loop `<nul`, or it can swallow the user's menu input.
- Keep `.cmd` and `.ps1` files in CRLF (`.gitattributes` enforces this in git). Editing them with Git Bash `sed -i` can silently convert them to LF.

## Validation

Before opening a pull request:

1. Parse `Install-LlamaCpp-AMD.ps1` with the PowerShell AST parser.
2. Run the batch menu with a clean exit and with invalid input recovery. To script several choices, redirect a file (`Start-LlamaCpp.cmd < choices.txt`); piped input only delivers the first line to `set /p`.
3. Exercise the guide, links, health check, and Continue-template screens.
4. Confirm that no model, extension, or server installation occurs during documentation tests.
5. Check that the README and documentation match the actual menu and configuration values.
6. Validate the release workflow package contains `Start-LlamaCpp.cmd`, `Install-LlamaCpp-AMD.ps1`, `README.md`, `LICENSE`, and `logo.png`.
7. Run `tests/Test-CommandCenter.ps1` and confirm every check passes. The same checks run in CI on `windows-latest`.
8. If the menu or setup screens change, refresh the screenshots in `docs/` (`menu.png`, `healthcheck.png`, `advisor.png`).

Do not run large model downloads or server launches as part of a basic smoke test unless the change specifically requires it and the user has approved the resource use.
