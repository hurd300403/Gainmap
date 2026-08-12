# Claude Code project instructions

For every Gainmap build, release, TestFlight, GitHub DMG, Sparkle, or download-page task, first read [`docs/gainmap-release-and-download.md`](docs/gainmap-release-and-download.md) completely and use it as the authoritative deployment runbook.

Do not assume that merging or pushing publishes an app. Do not call the download page Vercel: it is hosted by the dedicated Firebase project `gainmap-production`. Preserve the permanent TestFlight and GitHub `releases/latest` button URLs unless the distribution channel itself is intentionally being replaced.

Never expose or persist credentials. Confirm remote release state with read-only evidence before saying a build is public.
