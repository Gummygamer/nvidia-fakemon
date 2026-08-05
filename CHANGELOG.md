# Changelog

## Unreleased

- Generate and validate species-specific level-1 moves and level-up learnsets,
  with type-aware fallback progressions for legacy or incomplete definitions.
- Prompt Cloudflare source art as four-tone, hand-pixeled classic Generation I
  battle sprites instead of polished modern full-color creature artwork.
- Exclude every built-in and previously generated species name from metadata
  prompts, and reject a response that still returns an exact collision.
- Give Cloudflare authentication fallback an actionable expired-token
  diagnostic and document why copied Wrangler OAuth credentials are unsuitable
  for a long-running game process.
- Generate two Fakemon only for maps with wild encounter tables or starters,
  avoiding network and image work for empty maps.
- Give newer maps persistent encounter pools that mix their two local designs
  with up to two previously discovered Fakemon.
- Let deterministic trainer party slots draw from the generated roster while
  preserving the rest of each authored party and its slot metadata.
- Preserve generated source art as 112x112 indexed color with coverage alpha,
  write separate battle masters and compatibility-size UI sprites, and render
  battles on a 2x backing canvas so the extra detail reaches the display.
- Keep legacy monochrome image rows and procedural saves loadable without
  rewriting their art.
- Add Cloudflare Workers AI as the preferred online source-art provider, using
  hosted FLUX.1 Schnell with a deterministic two-view source sheet.
- Separate Cloudflare account/token configuration from the NVIDIA key used for
  creature metadata, and validate Cloudflare account/model endpoint inputs.
- Select Cloudflare automatically only when both credentials exist; require an
  explicit base URL for legacy Visual NIM image generation; otherwise report
  that online image art is disabled instead of silently targeting an
  unsupported NVIDIA hosted endpoint.
- Convert source art locally with edge-connected background removal,
  aspect-preserving area reduction, three-tone quantization, and hard
  transparency.
- Persist bounded provider/model/seed/prompt provenance while excluding source
  image bytes, and preserve both Cloudflare- and NIM-derived rows across
  procedural renderer migrations.
- Persist sanitized provider/model/failure diagnostics for procedural fallback
  and classify obvious temporary quota, rate-limit, timeout, and network
  failures without automatically retrying in a loop.
- Fall back to procedural art after any image request, decode, validation, or
  conversion failure without losing valid gameplay metadata.
- Bound large HTTP image responses and clean temporary response files.
- Encode empty sprite pixels with transparent alpha and automatically rewrite
  existing generated sprite PNGs.
- Generate battle sprites locally from NIM-selected anatomy traits, avoiding
  truncated or noisy pixel grids from chat-model responses.
- Automatically redraw legacy generated sprites without resetting Fakédex data.

## 1.0.0

### Added

- NVIDIA NIM generation of save-specific Fakemon definitions and monochrome battle sprites.
- One-time generation queue driven by first visits to maps.
- Persistent Fakédex slots, map assignments, art source, and immediate autosaves.
- Wild, fishing, scripted-wild, trainer-party, gift, and Oak's Lab starter replacement hooks.
- New Game cleanup for both save state and rendered sprite files.
