# BIM Station for Revit

Fork of Speckle's Revit connector, rebranded as the BIM Station plugin (released as
"BIM Cost" up to 1.0.4).

This file documents what upstream's README does not: the two-repo layout, the build
pipeline, and how to sync with Speckle without losing our changes. Kept separate from
`README.md` so upstream merges never conflict with it.

## Repository layout

The build reads the panel UI from a **sibling directory**. Both repos must be cloned
next to each other, with these exact folder names:

```
<any parent folder>/
├── bimstation-revit-plugin/        ← this repo (C# connector + installer)
└── speckle-connectors-dui/       ← the panel UI (Nuxt 3)
```

This repo's folder can be named anything — nothing points at it by name. The **UI folder
must be called `speckle-connectors-dui`**: `Connectors/Revit/Directory.Build.targets` and
`Build/installer/BIMStationForRevit.iss` both resolve it as `../speckle-connectors-dui`, so
renaming it silently ships an installer with no panel.

| Repo | Upstream | What we changed |
| --- | --- | --- |
| `bimstation-revit-plugin` | `specklesystems/speckle-sharp-connectors` | Addin manifests, ribbon, icons, telemetry removal, bundled-UI hosting, installer |
| `bimstation-connector-dui` | `specklesystems/speckle-connectors-dui` | Whole visual identity, debranding, removed update check and feedback |

Both use the branch `bimcost/rebrand` (named before the rename to BIM Station), and both
keep `upstream` as a second remote so Speckle's changes can be pulled in later.

## Where it installs

Per user, under `%AppData%\Autodesk\Revit\Addins\<ver>\`:

- `BIMStation.Revit<ver>\` holds the assemblies and the `ui\` panel bundle
- `BIMStation.Revit<ver>.addin` is the manifest

The assemblies keep their upstream `Speckle.*` names, but the folder and manifest do not:
upstream installs to `Speckle.Connectors.Revit<ver>`, and sharing that path would overwrite
an installed official Speckle connector. The BIM Cost releases (1.0.x) did use that path;
the installer removes the old folder on upgrade, but only when its manifest carries our
`ClientId`.

## First-time setup on a new machine

```powershell
git clone https://github.com/RBessoni/bimstation-revit-plugin.git
git clone https://github.com/RBessoni/bimstation-connector-dui.git speckle-connectors-dui

winget install --id Microsoft.DotNet.SDK.10
winget install --id OpenJS.NodeJS.LTS
winget install --id JRSoftware.InnoSetup
```

The second clone **must** pass `speckle-connectors-dui` as the target folder. The repo and
the folder are deliberately named differently, and the build resolves the folder, not the
repo — a plain `git clone` of that URL produces the wrong folder name.

Node ships Corepack, which provides the Yarn version the UI pins — no separate Yarn install.

## Building the installer

```powershell
cd bimstation-revit-plugin
.\Build\build-installer.ps1
```

That generates the UI, builds both connectors in Release, and compiles the single-file
installer into `output/`. Use `-SkipUi` when only C# changed, and `-Version 1.2.0` to stamp
a version.

The script checks every prerequisite up front and tells you the exact `winget` command for
whatever is missing.

## Editing the panel UI

The UI is a normal Nuxt app with mocked host bindings, so it runs standalone with hot
reload — no Revit needed:

```powershell
cd ../speckle-connectors-dui
corepack yarn dev:nuxt --port 8082
```

In dev mode the app registers mocked bindings and renders the full panel. To see your live
edits inside Revit instead of the bundled copy, set `SPECKLE_DUI_URL=http://localhost:8082`
and restart Revit.

## How the panel is served in production

There is no web server in the installed plugin. `RevitControlWebView` maps the `ui/` folder
next to the assembly onto `https://bimstation-panel.example` using WebView2's
`SetVirtualHostNameToFolderMapping`, which gives a real https origin instead of `file://`.
The host is deliberately not `bimstation.app`: that is the real web app, and the mapping
would shadow it inside the panel. `.example` is reserved and can never resolve to a real site.

Two consequences worth remembering:

- The virtual host has **no directory index**, so the panel is opened at `/index.html`.
  `pages/index.vue` carries `definePageMeta({ alias: ['/index.html'] })` so the router
  accepts that path. Without it the panel shows Nuxt's 404.
- Anything needing a server at runtime breaks. `<NuxtImg>` in particular routes through the
  IPX provider and 404s silently — use plain `<img>`.

`SPECKLE_DUI_URL` (env var, then HKLM, then HKCU) still overrides the bundled UI, so moving
to a hosted panel later needs no recompile.

## Pulling upstream changes

```powershell
git fetch upstream
git merge upstream/dev        # or upstream/main in the UI repo
```

Pushing to `upstream` is disabled in this repo on purpose. Expect conflicts in the files
listed in the table above.

## Not in version control

`output/` (installers) and the UI's `.output/` (generated bundle) are gitignored — both are
build artifacts, rebuilt by the script above. Never commit the `.exe`.
