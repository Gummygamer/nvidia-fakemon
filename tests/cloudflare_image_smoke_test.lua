package.path = "./?.lua;./?/init.lua;" .. package.path

if os.getenv("NVIDIA_FAKEMON_LIVE_IMAGE_TEST") ~= "1" then
  print("SKIP cloudflare image smoke test (set NVIDIA_FAKEMON_LIVE_IMAGE_TEST=1)")
  return
end

local Json = require("src.link.Json")
local Pipeline = require("mods.nvidia_fakemon.fakemon_pipeline")
local SpriteGenerator = require("mods.nvidia_fakemon.sprite_generator")
local SpriteWriter = require("mods.nvidia_fakemon.sprite_writer")

local generated = {
  name = "CLOUDBUG", kind = "STORM BUG", types = { "ELECTRIC", "BUG" },
  stats = { hp = 55, attack = 68, defense = 62, speed = 91, special = 76 },
  catch_rate = 145, base_exp = 112, height_ft = 1, height_in = 8,
  weight_tenths_lb = 96,
  description = "It gathers static in the bright plates along its back.",
  shape = "INSECT", features = { "ANTENNA", "SHELL", "WINGS" },
  body_colors = { "yellow", "charcoal", "white" },
  markings = "two pale lightning marks on its shell",
  pose = "alert, balanced, and fully visible",
  texture = "smooth segmented shell",
  visual_description = "a compact beetle-like storm creature with a broad shell and short legs",
}
local completion = Json.encode({ choices = { { message = {
  role = "assistant", content = Json.encode(generated),
} } } })

local result, err = Pipeline.fromCompletion(completion,
  { mapId = "CLOUDFLARE_SMOKE", tileset = "OVERWORLD" }, "cloudflare_smoke")
assert(result, err)
assert(not result.warning, result.warning)
assert(result.definition.artSource == "cloudflare-image",
  "live request did not produce Cloudflare image art")
assert(result.definition.imageProvider == "cloudflare", "provider provenance missing")
assert(SpriteGenerator.validImageRows(result.definition.front, 112, 112),
  "invalid live front master")
assert(SpriteGenerator.validImageRows(result.definition.back, 112, 112),
  "invalid live back master")

local front, back, writeErr = SpriteWriter.ensure("CLOUDFLARE_SMOKE", result.definition, true)
assert(front and back, writeErr)
local battleFront, battleBack = SpriteWriter.battlePaths("CLOUDFLARE_SMOKE")
assert(love.filesystem.getInfo(battleFront) and love.filesystem.getInfo(battleBack),
  "high-resolution battle masters were not written")
local beforeFront = result.definition.front[1]
assert(not SpriteGenerator.ensure(result.definition),
  "offline restoration unexpectedly replaced Cloudflare rows")
assert(result.definition.front[1] == beforeFront, "offline restoration changed Cloudflare pixels")

print("PASS Cloudflare live source art and offline row restoration")
print("Inspect " .. love.filesystem.getSaveDirectory() .. "/" .. battleFront)
print("Inspect " .. love.filesystem.getSaveDirectory() .. "/" .. battleBack)
