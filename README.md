# hotschmoe.github.io

Landing page plus browser games, built from their source repos.

## How it works

- `games.json` is the manifest: one entry per hosted game (source repo, build command, output dir, metadata).
- `tool/sync.dart` builds every game whose repo head or manifest entry changed, caches builds in `.cache/`, and assembles the deployable site in `_site/` (static page + `projects/<slug>/` + generated `projects.json`).
- `.github/workflows/deploy.yml` runs that on every push, every 6 hours, on manual dispatch and on `repository_dispatch: game-updated`, then publishes `_site/` to Pages. Builds are not committed.
- Private repos stay private; the page links to source only when the repo is public (detected automatically).

## Add a game

Add an entry to `games.json`:

```json
{
  "slug": "my-game",
  "kind": "game",
  "title": "My Game",
  "tagline": "One line.",
  "description": "A few sentences.",
  "tech": ["Rust", "WebAssembly"],
  "requires": ["webgpu"],
  "repo": "hotschmoe/my-game",
  "build": "trunk build --release --public-url {base}",
  "out": "dist"
}
```

`{base}` expands to `/projects/<slug>/`. `requires: ["webgpu"]` injects a "no WebGPU" error page guard. Optional `ref` pins a branch. `kind` may be `game`, `tool` or `project`; the landing page groups by kind.

## Local use

```sh
dart run tool/sync.dart --check       # which games are stale
dart run tool/sync.dart               # build stale games, assemble _site/
dart run tool/sync.dart --force --only gemtd
python3 -m http.server -d _site 8000
```

Needs `gh` (authenticated), `cargo` + `wasm32-unknown-unknown`, `trunk`, `flutter`, `zig` on the path.
