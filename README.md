# NVIDIA Living Fakedex

This enabled-by-default mod grows a different Fakedex for every save. The first
time a map with a wild encounter table or starter is entered, it asks NVIDIA
NIM for two Generation 1-compatible creatures: their names, types, five base
stats, Pokedex details, level-1 moves, a species-specific level-up learnset,
and concise visual direction. Move IDs and levels are validated before they
reach the save; old or incomplete definitions receive a type-aware fallback
progression. Maps without encounters do not spend generation requests.

Source art is configured independently. Cloudflare Workers AI is explicitly
prompted for classic first-generation monochrome handheld pixel art and can
generate one consistent front/rear reference sheet with hosted FLUX.1 Schnell.
The current Cloudflare FLUX REST schema accepts only the prompt and step count
used here, so Cloudflare generation is not guaranteed to be repeatable across
requests; the locally derived intended seed is retained in provenance but is
not transmitted. The legacy Visual NIM provider continues to send its seed.
The worker removes its edge-connected near-white background, crops and area-reduces both
views into deterministic 112x112 indexed-color masters with coverage alpha.

Segmentation tolerates an image model that does not honour "pure white". The
backdrop radius is tried at the configured value first and only widened (to
1.6x, then 2.2x of it, capped at 0.6) once that fails, so a clean sheet keeps
its exact segmentation; without this, an off-white or textured backdrop left
the border flood fill with nowhere to start and the whole view was rejected as
`background removal left an unreasonable foreground area`. The divider between
the views is the widest near-white column band within 25% of the centre rather
than the centre itself, because a sheet that gives one view more room than the
other otherwise cuts through a creature -- which segments cleanly and so no
area guard can catch it. Near-ties resolve toward the centre, so a well-formed
sheet keeps the cut it always had. Both paths are deterministic for identical
source pixels, and a genuinely full-bleed design is still rejected and still
falls back to procedural art, now with the measured foreground share in the
diagnostic.
Battles render those masters on a 2x backing canvas, while compatibility-size
56x56 front and 32x32 back PNGs serve the remaining classic UI. Remote source
artwork is never installed directly or stored in the save.

If online image generation is disabled, fails, returns malformed data, or
cannot be converted, the local procedural renderer completes the creature.
The saved definition records that fallback and a short sanitized reason; it
does not silently claim remote art succeeded.

Each eligible map draws encounters from its two new creatures and up to two
creatures reused from previously explored maps. Grass, fishing, scripted wilds,
and gifts use that persistent map pool. Trainers have a deterministic chance
per party slot to use any Fakemon generated so far, including on maps without a
local pool. In Oak's Lab, the two lab Fakemon can replace the chosen starter
while `EVENT_GOT_STARTER` is still unset. Vanilla Pokemon remain available
until a map's asynchronous requests complete.

## Setup

Set `NVIDIA_API_KEY` for the metadata request. The default metadata model is
`google/gemma-4-31b-it`; override it with `NVIDIA_FAKEMON_MODEL`. Earlier
defaults are unusable: `meta/llama-3.1-8b-instruct` answers `410 Gone`,
`mistralai/mistral-7b-instruct-v0.3` answers `404 Function ... Not found for
account`, and `minimaxai/minimax-m3` reached end of life on 2026-09-09. `NVIDIA_NIM_BASE_URL` can
point at a compatible hosted or self-hosted NIM and defaults to
`https://integrate.api.nvidia.com/v1`.

For Cloudflare source art, create a Workers AI API token and set:

- `NVIDIA_FAKEMON_IMAGE_PROVIDER=cloudflare`
- `CLOUDFLARE_ACCOUNT_ID` to the account's 32-character hexadecimal ID
- `CLOUDFLARE_API_TOKEN` to a token allowed to run Workers AI
- `NVIDIA_FAKEMON_IMAGE_MODEL` optionally; the initial registry supports only
  `@cf/black-forest-labs/flux-1-schnell`
- `NVIDIA_FAKEMON_IMAGE_STEPS` optionally; FLUX defaults to 8 and is clamped to
  its supported range of 1 through 8

Create the token from **Workers AI > Use REST API > Create a Workers AI API
Token** in the Cloudflare dashboard. Do not copy an OAuth credential returned
by `wrangler auth token` after `wrangler login`: Wrangler can refresh that
credential for its own commands, but the copied value eventually expires while
the running game cannot refresh it. A custom persistent token needs both
`Workers AI - Read` and `Workers AI - Edit` permissions.

PowerShell example:

```powershell
$env:NVIDIA_API_KEY = "nvapi-..." # NVIDIA metadata model
$env:NVIDIA_FAKEMON_IMAGE_PROVIDER = "cloudflare"
$env:CLOUDFLARE_ACCOUNT_ID = "0123456789abcdef0123456789abcdef"
$env:CLOUDFLARE_API_TOKEN = "..."
$env:NVIDIA_FAKEMON_IMAGE_MODEL = "@cf/black-forest-labs/flux-1-schnell"
\.\Play-Windows.bat
```

When `NVIDIA_FAKEMON_IMAGE_PROVIDER` is unset, the mod selects Cloudflare only
if both Cloudflare values are present. It selects legacy Visual NIM only when
`NVIDIA_FAKEMON_IMAGE_BASE_URL` is explicitly set. Otherwise image generation
is `disabled`, a clear configuration warning is logged once, and procedural art
is used. The old implicit hosted Stable Diffusion 3.5 endpoint is intentionally
not used.

Legacy/self-hosted Visual NIM remains available with:

```powershell
$env:NVIDIA_FAKEMON_IMAGE_PROVIDER = "nim"
$env:NVIDIA_FAKEMON_IMAGE_BASE_URL = "https://your-nim.example/v1"
$env:NVIDIA_FAKEMON_IMAGE_MODEL = "stabilityai/stable-diffusion-3.5-large"
```

That provider uses `NVIDIA_API_KEY`; it never receives the Cloudflare token.
Set `NVIDIA_FAKEMON_IMAGE_PROVIDER=disabled` to force local procedural art.

Cloudflare currently documents 10,000 free Workers AI neurons per account per
day, reset at 00:00 UTC. FLUX.1 Schnell pricing and limits can change, so check
the official [Workers AI pricing](https://developers.cloudflare.com/workers-ai/platform/pricing/)
and [FLUX.1 Schnell model](https://developers.cloudflare.com/workers-ai/models/flux-1-schnell/)
pages before relying on a quota estimate.

## Persistence and fallback

Final logical pixel rows, gameplay data, bounded image provider/model/intended
seed/prompt metadata, and art provenance live in
`save.modData.nvidia_fakemon`. For Cloudflare rows, `imageSeed` records the
deterministic seed the client derived for provenance and future compatibility;
the current Cloudflare request does not transmit it.
Rendered PNGs live in the LOVE save directory under `nvidia_fakemon/`.
Choosing **NEW GAME** replaces the mod-data bucket and deletes those PNGs
before the new Fakedex begins.

Successful Cloudflare definitions use `artSource = "cloudflare-image"` and can
be restored offline with the credentials removed. Older `nim-image` rows remain
compatible, including the earlier 28x28/16x16 monochrome image format.
Procedural sprites from older renderer versions can be redrawn from
their saved identity, but valid remote-derived rows are never replaced merely
because the procedural renderer changes.

Pipeline-version-1 saves cannot recover the discarded Cloudflare source image
offline, so their reduced rows remain unchanged. Newly generated Fakemon use
the color-master format; regenerating an old design requires a new image-model
request rather than an upscaler pretending the lost detail is still present.

A failed image attempt stores `imageAttemptProvider`, `imageAttemptModel`, and
a bounded `imageFallbackReason`. Obvious temporary quota, rate-limit, timeout,
network, and server failures are also marked transient. The initial policy does
not automatically retry saved fallback art: this prevents tight loops and
preserves the assigned species slot, stats, name, party identity, and map
assignment. A future explicit re-art action can use the diagnostic marker.

Cloudflare error `10000: Authentication error` means the configured token is
invalid or expired, not that the daily neuron allocation was exhausted. Replace
`CLOUDFLARE_API_TOKEN` with an active Workers AI API token and restart the game.
Cloudflare reports exhausted free allocation separately as error `3036` with
HTTP status 429.

## Privacy and security

Bearer headers are staged in a short-lived curl header file, so neither token
appears on the child process command line. Request, header, and response staging
files are removed on success and failure paths. Responses and decoded images
are size-bounded, and PNG/JPEG magic bytes are verified before LOVE decodes the
source.

Tokens, response bodies, base64 image data, and full request headers are never
written to generated definitions. Errors are bounded and redact bearer values,
NVIDIA-style keys, and suspicious encoded runs. Creature metadata and the
two-view art prompt are sent to the configured services.

The mod reserves 256 slots (`NVIDIA_FAKE_001` through `NVIDIA_FAKE_256`) so the
engine can validate a saved generated Pokemon before runtime data is restored.
That covers every map in the supported Generation 1 datasets.

## Verification

The normal focused suite is offline:

```powershell
\.\tools\love-luajit.cmd mods/nvidia_fakemon/tests/nvidia_fakemon_test.lua
```

An opt-in live smoke test uses the configured Cloudflare account, verifies the
Cloudflare envelope/provenance and converted row dimensions, rewrites the rows
without a network call, and prints two disposable PNG paths for visual review:

```powershell
$env:NVIDIA_FAKEMON_LIVE_IMAGE_TEST = "1"
\.\tools\love-luajit.cmd mods/nvidia_fakemon/tests/cloudflare_image_smoke_test.lua
```

The normal automated suite never makes an image request.


## FireRed and LeafGreen

The mod runs on Gen1Recomp Deluxe's FireRed and LeafGreen as well. Generation
is identical (same NIM metadata, same art pipeline); only the engine wiring
differs. Notes:

- Slots use species numbers 413-668. Stats map Gen 1's single Special to both
  Special Attack and Special Defense; creatures have no ability and cannot breed.
- Wild encounters (grass, surf, rock smash) and trainer parties use the map pool;
  gifts, fossils and scripted wild battles are left alone.
- Generated creatures have no National Dex page.
- Fakemon icons and 64x64 battle art are drawn from the same generated artwork.
