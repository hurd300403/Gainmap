# Gainmap agent instructions

Before changing, releasing, or answering operational questions about Gainmap app distribution or its download page, read [`docs/gainmap-release-and-download.md`](docs/gainmap-release-and-download.md) completely.

Key invariants:

- The download page is Firebase Hosting (`gainmap-production`), not Vercel. A bare `firebase deploy` is not allowed for a page-only change; use the hosting-only command in the runbook.
- A push or merge does not publish either app. The Mac release script and the App Store Connect/TestFlight distribution steps are separate release actions.
- The Mac and TestFlight buttons use stable URLs. Do not replace them with version-specific URLs during routine releases.
- Release only from a clean local `main` whose `HEAD` exactly matches `origin/main` after fetching.
- Never print, commit, or copy signing, notarization, App Store Connect, Firebase, GitHub, Patreon, Sparkle, or Sentry secrets.
