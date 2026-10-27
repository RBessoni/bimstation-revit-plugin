# Working on BIM Station for Revit

BIM Station (released as "BIM Cost" up to 1.0.4) is a rebranded fork of Speckle's Revit
connector. `BIMSTATION.md` documents the
project for people; this file records what an agent needs to avoid re-learning the hard
parts. Read both before changing anything.

## The single most important fact

**The panel UI is not in this repo.** What a user sees inside Revit is a Nuxt 3 app that
lives in a separate repo, cloned as a sibling:

```
<parent>/
├── <this repo>/                  ← C# connector, installer, Revit integration
└── speckle-connectors-dui/       ← the panel UI (repo: RBessoni/costrail-connector-dui)
```

If a request is about how the panel *looks* or *reads* — colours, copy, buttons, layout —
the change belongs in `../speckle-connectors-dui`, not here. Searching this repo for panel
text will find nothing.

The UI folder **must** be named `speckle-connectors-dui`. `Connectors/Revit/Directory.Build.targets`
and `Build/installer/BIMStationForRevit.iss` resolve it by relative path. A plain `git clone`
of the fork produces `costrail-connector-dui` and the build then ships an installer with no
panel, silently and with no error.

## Both repos

| | Repo | Upstream | Branch |
| --- | --- | --- | --- |
| C# | `RBessoni/costrail-revit-plugin` | `specklesystems/speckle-sharp-connectors` | `bimcost/rebrand` |
| UI | `RBessoni/costrail-connector-dui` | `specklesystems/speckle-connectors-dui` | `bimcost/rebrand` |

Both keep `upstream` as a second remote with **push disabled** (`DISABLED_use_origin`).
Never re-enable it. Pull upstream changes with `git fetch upstream && git merge upstream/dev`
(`upstream/main` for the UI).

## Build and verify

One command builds everything, in the only order that works — UI first, because the
installer embeds its output:

```powershell
.\Build\build-installer.ps1              # full build
.\Build\build-installer.ps1 -SkipUi      # C#-only change, much faster
.\Build\build-installer.ps1 -Version 1.1.0
```

Gates that must pass before handing work over:

- UI repo: `corepack yarn lint:ci` (TypeScript + CSS). Non-negotiable.
- C#: the Release build inside the script. ILRepack emits three `Method reference is used
  with definition return type` warnings — those are pre-existing upstream noise, not
  regressions.

`ISCC.exe` lives at `%LOCALAPPDATA%\Programs\Inno Setup 6\` — winget installs it per-user,
so it is not on PATH and not under Program Files.

## Verifying UI changes

The dev server is flaky in this environment and has died mid-session more than once. The
reliable loop is to build the static bundle and serve it, which also tests closer to
production than dev mode does:

```powershell
cd ../speckle-connectors-dui; corepack yarn generate
# then serve .output/public over plain http and inspect the DOM
```

Two habits that repeatedly caught real bugs:

- **Assert against the built bundle, not the source.** `grep -rl "<string>" .output/public`
  is how you prove a removal actually shipped. Source greps have been misleading.
- **Read computed styles and DOM text via JS, not screenshots.** Screenshots return black
  frames whenever the browser pane is not displayed, and the page often renders a beat
  after navigation — query once, then query again before concluding anything is broken.

Production mode legitimately shows `BIM Station plugin is not connected.` outside Revit: there
are no host bindings. That is correct, not a failure. Dev mode registers mocked bindings and
renders the full panel.

## Traps that have already cost time

**Theme tokens.** The upstream Tailwind theme defines every colour on `html`, `html.dark`
*and* `html[class*="dark"]`. Our overrides live at the end of `assets/css/tailwind.css`.
A `:root` override (0,1,0) beats `html` (0,0,1) so light mode works — but a plain `.dark`
(0,1,0) **loses** to `html.dark` (0,1,1) and dark mode silently reverts to Speckle blue.
The dark selector must be `:root.dark`. To diagnose, enumerate the CSSOM in the browser;
reading the compiled `plugin.js` is far slower.

**`<NuxtImg>` is forbidden.** It routes through the IPX provider, which needs a server. The
panel is static files behind a WebView2 virtual host, so it 404s silently. Use plain `<img>`;
Vite inlines small SVGs as data URIs anyway.

**The `/index.html` route.** The virtual host has no directory index, so the host opens
`/index.html` directly. `pages/index.vue` carries `definePageMeta({ alias: ['/index.html'] })`.
Remove it and the panel shows Nuxt's 404 on launch.

**WebView2 initialisation order.** `RevitControlWebView` must not set `Source` in the
constructor: `SetVirtualHostNameToFolderMapping` can only be called once `CoreWebView2`
exists. Initialisation is explicit (`EnsureCoreWebView2Async`) and navigation happens in
`OnInitialized`, after bindings are registered so host objects exist before the page loads.

**Building while Revit is open.** `AfterBuildRevit` copies the addin into the Revit Addins
folder and fails on locked DLLs. Always pass `-p:ContinuousIntegrationBuild=true` for
Release/packaging builds; the installer handles deployment. Installing also requires Revit
to be closed — the installer refuses to start otherwise.

## Editing conventions

**GUIDs are load-bearing.** The addin `ClientId` (`8ae12a74-…`) and `DockablePaneId`
(`8b926740-…`) were changed precisely because every upstream manifest shares one of each.
If they ever match upstream again, Revit conflicts when both connectors are installed and
one fails to load. Never take upstream's values in a merge.

**The install location is ours too.** Since 1.1.0 the plugin installs to
`Addins\<ver>\BIMStation.Revit<ver>\` with manifest `BIMStation.Revit<ver>.addin`, set in
`Directory.Build.targets` and the `.iss`; the source manifests keep upstream's file names.
Upstream's `Speckle.Connectors.Revit<ver>` is the official connector's path, so a merge
that restores it makes our installer overwrite Speckle. The `.addin` `<Assembly>` path must
match the folder. Assembly names, namespaces and the embedded icon resource names
(`Speckle.Connectors.Revit<ver>.Assets.logo16.png`) stay `Speckle.*` — renaming them breaks
the ribbon icons silently and every upstream merge.

**Shared parameters stay in the "Speckle" group.** `RevitParameterCreator` writes to
`%AppData%\Speckle\SpeckleSharedParameters.txt`, group `Speckle`. Renaming either creates
definitions with new GUIDs, which then clash with parameters already bound in users' projects.

**Telemetry must stay out.** Upstream's Release path exports logs and traces to
`seq.speckle.systems` with a hardcoded API key. `Sdk/Speckle.Connectors.Common/Connector.cs`
has it removed. Check this after every upstream merge.

**The debranding boundary.** Remove *visual* Speckle references — names, logos, docs links,
promo blocks, the update checker. Keep *functional* ones: adding an account still downloads
Speckle's Desktop Service. Do not "fix" that.

**Sign-in always targets `https://bimstation.app`.** Since 2026-10-27 `GetDefaultSpeckleServerUrl()`
falls back to it (not `app.speckle.systems`), and the panel has no server field: users only pick
their account. The browser sign-in opens `{server}/authn/verify/connectrV3/{challenge}` (the
SDK's `AuthApp.ConnectorsV3`; callback `http://localhost:29355`), which bimstation.app serves
(`sdui` 404s there, so the panel's own non-binding flow would not work).

**The sign-in success page is ours.** The SDK's `AuthFlow` hardcodes a page saying "Your Speckle
Connector is now authorized". `Sdk/Speckle.Connectors.Common/Credentials/BimStationAuthFlow.cs`
reimplements the flow with a BIM Station page and is registered over the SDK's `IAuthFlow` in
`Connector.Initialize` (the SDK registers with `TryAdd`, so ours must come after). Token refresh
still goes to the SDK. When bumping `Speckle.Sdk`, diff its `Credentials/AuthFlow.cs` (tag =
package version on github.com/specklesystems/speckle-sharp-sdk) against our copy.
`SPECKLE_DEFAULT_SPECKLE_SERVER_URL` (env, then HKLM, then HKCU under
`Software\Speckle\Connector Config\Global`) still overrides it, which is how you point a dev
machine at a local server. Never take upstream's `app.speckle.systems` fallback in a merge.

## Which server the plugin actually talks to

**Production publishes go to Blackbird's own server**, not Speckle's:
`https://bimcost.blackbirdindustries.com.au` — "BIM Station — Model Hub". Since 2026-10 that
domain 301-redirects pages and unknown routes to the canonical `https://bimstation.app`, but
the routes the connector uses (`/graphql`, `/api/diff`, `/objects`, `/api/getobjects`) still
answer directly on the old domain. If it is ever retired, publishing stops. It reports
version `2.31.14` but speaks the **v3 API** (`project` resolves, `stream` does not), so the
connector is API-compatible with it. The same API answers on `https://bimstation.app` (its
`serverInfo.canonicalUrl`), which is where new accounts are created; accounts made earlier on
the old domain keep working against it.

That server is a separate codebase in a separate environment, and it is where publish
failures usually live. Before blaming the connector, probe it:

```bash
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"query":"{ serverInfo { version name } }"}' \
  https://bimcost.blackbirdindustries.com.au/graphql
curl -s https://bimcost.blackbirdindustries.com.au/api/v1/data-module-enabled   # 301 to bimstation.app, then 404 = expected
```

It does **not** implement the model-ingestion API (`canCreateModelIngestion` is absent) nor
`/api/v1/data-module-enabled`, so `SendOperation` correctly degrades to
`SendViaVersionCreate`. Both of those are working fallbacks, not faults.

Which objects get uploaded is decided by the server's `POST /api/diff/{projectId}` response,
not by a local cache — so a retry after a partial publish re-offers exactly what the server
is missing. `SendConversionCache` is an in-memory `Dictionary` that dies with the Revit
process; the per-project SQLite file under `%AppData%\Speckle\Projects\` is the SDK's object
store, not an upload ledger.

Upload concurrency (measured at 4 in-flight batches) lives in the `Speckle.Sdk` NuGet
package, not in this repo. There is no connector-side knob to serialise uploads without
forking the SDK — so server-side write paths must tolerate concurrent idempotent inserts.

**Multi-line edits.** Escaping through `bash -c "node -e ..."` has failed repeatedly on
backslashes and quotes; write the script to a file and run it. Several source files are
CRLF, so anchors containing `\n` silently fail to match — use `\r?\n`, and confirm a
replacement actually applied instead of trusting that the command exited zero.

**Do not count XML or Vue tags with grep.** `grep -c '<MenuItem'` also counts `<MenuItems>`,
which once hid an unbalanced tag and produced a 500 that looked like an unrelated bug. When
a structural edit goes wrong, restore the file from git and redo it with verified line
ranges rather than patching the damage.

## Not in version control

`output/` (installers) and the UI's `.output/` (generated bundle) are gitignored build
artifacts. Never commit the `.exe`. `.claude/` is also ignored, so any launch config there
is local-only.
