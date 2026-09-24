# Contributing

Thanks for helping improve the AMD Windows llama.cpp command center.

## Development principles

- Target Windows PowerShell 5.1 compatibility.
- Keep the batch front end readable, colorful, and safe for non-technical users.
- Never make a download or install silent; show the action in the menu first.
- Keep the server localhost-only unless the project explicitly designs a secure opt-in flow.
- Prefer official upstream sources and verify published hashes where available.
- Do not commit models, generated launchers, local API keys, or user-specific paths.

## Validation

Before opening a pull request:

1. Parse `Install-LlamaCpp-AMD.ps1` with the PowerShell AST parser.
2. Run the batch menu with a clean exit and with invalid input recovery.
3. Exercise the documentation, links, and Continue-template screens.
4. Confirm that no model, extension, or server installation occurs during documentation tests.
5. Check that the README and documentation match the actual menu and configuration values.
6. Validate the release workflow package contains `Start-LlamaCpp.cmd`, `Install-LlamaCpp-AMD.ps1`, `README.md`, `LICENSE`, and `logo.png`.
7. Run `tests/Test-CommandCenter.ps1` and confirm every check passes.

Do not run large model downloads or server launches as part of a basic smoke test unless the change specifically requires it and the user has approved the resource use.
