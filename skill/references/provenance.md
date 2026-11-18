# Provenance and reuse boundary

AutoSkin Codex is an independent authoring and installation workflow inspired by
[Finderchangchang/codex-autoskin](https://github.com/Finderchangchang/codex-autoskin).
The upstream project established the safe renderer-injection approach: keep the official Codex
application untouched, use a loopback Chromium DevTools connection, scan theme folders, and keep
installation reversible.

The upstream engine is MIT-licensed. Retain its copyright and license whenever engine files are
copied or modified. This skill includes the adapted runtime under `scripts/`,
`assets/renderer-inject.js`, and `styles/dream/`; its retained license is
`references/upstream-runtime-LICENSE.txt`.

The public package does not redistribute the upstream demo themes. Its runtime `themes/` directory
is intentionally empty, and user-selected themes are installed under durable `themes-private/`
storage. The editable themes are `examples/chiikawa-summer/` and `examples/hachiware-five/`.
Each has a separate asset notice.

This skill replaces the upstream authoring contract with:

- semantic schema v2 rather than requiring users to write dozens of CSS tokens;
- file-based assets rather than Base64 pasted into authored CSS;
- deterministic build and validation;
- multi-surface previewing;
- snapshot-first installation with explicit apply, pause/resume, failure recovery, and uninstall states.
- a self-contained runtime distribution so users do not need the older skill installed beside it.

Artwork supplied by a user remains user material. Do not add private or third-party-IP-based theme
artwork to this general-purpose skill unless the user explicitly authorizes its inclusion and its
reuse terms are recorded beside the assets.

The bundled `examples/chiikawa-summer/` package is included at the user's explicit request as the
default worked example. It contains independently created, unofficial, non-commercial fan art
based on the Chiikawa IP. The original character names, designs, and related intellectual property
belong to Nagano and their respective official rights holders. Keep these assets isolated from the
generic template and do not represent them as official assets or as covered by the project code
license or upstream runtime MIT license. Preserve the accompanying `ASSET-NOTICE.md` whenever the
example is packaged or shared.
