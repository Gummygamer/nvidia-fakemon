# Changelog

## Unreleased

- FireRed and LeafGreen support (`"games": ["gen1", "frlg"]`). The 256 Fakedex
  slots become species 413..668 (FireRed's table ends at 411 and 412 is the
  egg). Generated creatures are written into the live species rows with the
  engine's own record writer, get 64x64 battle art through `pokemon.sprite`
  and a 32x32 icon, and replace wild encounters (`encounter.species`) and
  about a third of trainer party slots. Gen 3 gifts and scripted wilds stay
  vanilla because story scripts match species by number.

- Recover source art that a stricter converter used to throw away. Image
  models do not always honour "pure white": an off-white or subtly textured
  backdrop sits outside the 0.22 segmentation radius, the border flood fill
  never propagates, and the whole view was rejected as
  `background removal left an unreasonable foreground area`, dropping a
  perfectly good design to procedural art. The backdrop radius now widens in
  steps (1.0x, then 1.6x, then 2.2x of the configured value, capped at 0.6)
  but only after the configured radius has failed, so a clean sheet keeps the
  exact segmentation it always had and no creature edge is eroded by a
  looser default. Rejection diagnostics now report the measured foreground
  share and the widest radius tried.
- Divide the two-view sheet at its widest near-white column band instead of
  always at the exact centre. A sheet that gives one view more room than the
  other put the centred cut through a creature, which still segmented cleanly
  and so no area guard could catch it. Candidate cuts stay within 25% of the
  centre, near-ties resolve toward the centre so a well-formed sheet keeps the
  cut it always had, and a silhouette touching the divider is deprioritized
  rather than trusted. Both paths stay deterministic for identical source
  pixels, and a genuinely full-bleed design is still rejected.
- Bump `sprite_converter` to version 3. The version is persisted per species
  as `imagePipelineVersion`; existing rows are not rewritten, and the pipeline
  contract around it is unchanged.
- Fix Cloudflare FLUX request construction by sending exactly `prompt` and
  `steps`; the current Workers AI REST schema rejects `seed` with error 5006.
  Cloudflare rows still retain the derived seed as intended-seed provenance,
  but Cloudflare generation is no longer described as deterministic across
  requests. Keep sending `seed` to the legacy Visual NIM image endpoint, whose
  documented schema still accepts it.
- Default `NVIDIA_FAKEMON_MODEL` to `minimaxai/minimax-m3` because both
  earlier defaults fail at the hosted NVIDIA NIM API:
  `meta/llama-3.1-8b-instruct` reached end of life and answers `410 Gone`,
  while `mistralai/mistral-7b-instruct-v0.3` answers `404 Function ... Not
  found for account`. Its context still fits the full Generation I move-ID
  list in the creature prompt, that prompt's JSON object comes back directly
  in `content`, and it answers inside the 90-second request budget.
- Keep generated image prompts within Cloudflare Workers AI's 2,048-character
  limit, including definitions whose visual fields reach their maximum sizes.
- Generate and validate species-specific level-1 moves and level-up learnsets,
  with type-aware fallback progressions for legacy or incomplete definitions.
- Prompt source art with explicit Pokemon Red and Blue battle-sprite anatomy,
  silhouette, and pixel constraints so designs read as stylized Generation I
  monsters instead of realistic animals or polished modern creature artwork.
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
  hosted FLUX.1 Schnell with a coherent two-view source sheet.
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
