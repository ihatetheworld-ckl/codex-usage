# Validation

## macOS

`bash scripts/test.sh` checks quota selection, remaining percentages, missing fields, reset-time formatting and the actual Swift JSON-RPC subprocess transport using a fake server.

`bash scripts/test-ui.sh` opens native AppKit windows and a native menu, dispatches mouse events to those test windows, and checks menu painting, click-versus-drag behavior, and free-position persistence. It uses synthetic data and a separate preferences domain.

With the Codex desktop app foregrounded, `CODEX_USAGE_UI_WITH_CODEX=1 bash scripts/test-ui.sh` additionally checks immediate docking snap-back against the actual host window bounds. This was checked on the development Apple Silicon Mac. This host-dependent check is not run on GitHub's clean runners, which do not contain a signed-in Codex desktop app.

Release packaging cross-compiles `arm64` and `x86_64`, combines them with `lipo`, and verifies both slices and the ad hoc application signature. CI executes the native UI tests on Apple Silicon; it does not prove Intel hardware behavior.

## Windows

`dotnet run --project windows/CodexUsage.Tests -c Release` checks the quota parser and actual subprocess transport. It runs on macOS or Windows without a real account.

The Windows release job runs the published `CodexUsage.exe --self-test <report.json>` on a Windows runner. This initializes actual WPF/native windows, uses a native test-host window, exercises the same drag controller used by pointer handlers, checks docked snap-back and free-position restoration, opens the detail menu, verifies remaining text, and checks transparent corner pixels.

The Windows smoke test does **not** use a real Codex account or a real Codex desktop host. In particular, CI cannot establish compatibility with every desktop installation path, organization login policy, Windows Store package, antivirus configuration, or mixed-DPI multi-monitor setup. A real-account check on the target Windows device is still needed.

## Release gates

The tag must match `VERSION`. Both platform jobs must pass before the release job receives write permission. It downloads both platform archives, produces `SHA256SUMS.txt`, creates a draft, uploads both packages, then publishes that draft. A failed platform job leaves the public release unpublished.

No authentication files or development usage snapshots are needed by CI. Keep `.build/`, `dist/`, local validation logs, `.env`, signing keys, and account configuration out of the Git index.
