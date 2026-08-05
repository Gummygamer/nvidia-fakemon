package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Json = require("src.link.Json")
local Runtime = require("src.mods.Runtime")
local Client = require("mods.nvidia_fakemon.fakemon_client")
local ImageClient = require("mods.nvidia_fakemon.image_client")
local Pipeline = require("mods.nvidia_fakemon.fakemon_pipeline")
local Learnset = require("mods.nvidia_fakemon.learnset")
local SpriteConverter = require("mods.nvidia_fakemon.sprite_converter")
local SpriteGenerator = require("mods.nvidia_fakemon.sprite_generator")

local realNewCanvas, densityOptions = love.graphics.newCanvas
love.graphics.newCanvas = function(_, _, options)
  densityOptions = options
  return { setFilter = function() end }
end
require("src.render.PixelCanvas").new(16, 12, "nearest", 2)
love.graphics.newCanvas = realNewCanvas
T.eq(densityOptions.dpiscale, 2,
  "high-detail battles request an integer 2x canvas backing density")

local workerChunk, workerSyntax = loadfile("mods/nvidia_fakemon/fakemon_worker.lua")
T.check(workerChunk ~= nil, "network worker compiles (" .. tostring(workerSyntax) .. ")")

local request = Json.decode(Client.buildRequest({
  mapId = "ROUTE_1", tileset = "OVERWORLD",
  forbiddenNames = { "PIKACHU", "FLAREON", "VOLTMITE" },
}))
T.check(type(request) == "table", "generation request is valid JSON")
T.eq(request.model, Client.DEFAULT_MODEL, "default NIM model is selected")
T.eq(request.stream, false, "generation uses a complete non-streamed response")
T.check(request.messages[2].content:find("ROUTE_1", 1, true) ~= nil,
  "map identity grounds the creature design")
local secondRequest = Json.decode(Client.buildRequest({
  mapId = "ROUTE_1", tileset = "OVERWORLD", variant = 2,
}))
T.check(secondRequest.messages[2].content:find("variant 2", 1, true) ~= nil,
  "the second map design is prompted as a distinct variant")
T.check(request.messages[2].content:find("Do not return pixel data", 1, true) ~= nil,
  "the text model is not asked to paint a fragile pixel grid")
T.check(request.messages[2].content:find("level_1_moves", 1, true) ~= nil
    and request.messages[2].content:find("learnset", 1, true) ~= nil,
  "the metadata model is asked for starting moves and a level-up learnset")
T.check(request.messages[2].content:find("THUNDERSHOCK", 1, true) ~= nil
    and request.messages[2].content:find("PSYCHIC_M", 1, true) ~= nil,
  "the metadata prompt constrains move choices to exact Generation I IDs")
T.check(request.messages[2].content:find("never reuse an existing Pokemon species name", 1, true)
    and request.messages[2].content:find("FLAREON", 1, true),
  "the text model receives explicit existing and generated name exclusions")
local function imageClient(config)
  config = config or {}
  config.getenv = config.getenv or function() return nil end
  return ImageClient.clientFor(config)
end

local disabledImageClient = imageClient()
T.eq(disabledImageClient.provider(), "disabled",
  "image generation is honestly disabled without image-provider configuration")
local autoCloudflare = imageClient({
  accountId = "0123456789abcdef0123456789abcdef", cloudflareToken = "cf-test-token",
})
T.eq(autoCloudflare.provider(), "cloudflare",
  "complete Cloudflare credentials select Workers AI when provider is unset")
local nimImageClient = imageClient({
  provider = "nim", baseUrl = "https://images.example.test/v1", model = "visual/model",
})
T.eq(nimImageClient.provider(), "nim", "an explicit NIM image base selects NIM")
T.eq(imageClient({ baseUrl = "https://images.example.test/v1" }).provider(), "nim",
  "an explicit NIM base selects NIM when the provider variable is unset")
T.eq(nimImageClient.endpoint(), "https://images.example.test/v1/images/generations",
  "NIM image generation has a separately configurable endpoint")
T.eq(nimImageClient.model(), "visual/model",
  "NIM image generation has a separately configurable model")

local imageDefinition = {
  name = "VOLTMITE", kind = "SPARKBUG", types = { "ELECTRIC", "BUG" },
  shape = "INSECT", features = { "ANTENNA", "SHELL" },
  bodyColors = { "yellow", "black" }, markings = "white chest spots",
  pose = "alert and balanced", texture = "smooth shell",
  visualDescription = "a compact beetle with a bright segmented shell",
}
local seedA = ImageClient.seed(imageDefinition, { mapId = "ROUTE_1", tileset = "OVERWORLD" })
local seedB = ImageClient.seed(imageDefinition, { mapId = "ROUTE_1", tileset = "OVERWORLD" })
T.eq(seedA, seedB, "image seed is deterministic for identical art direction")
local cloudflareClient = imageClient({
  provider = "cloudflare", accountId = "0123456789abcdef0123456789abcdef",
  cloudflareToken = "cf-test-token", steps = 99,
})
T.eq(cloudflareClient.endpoint(),
  "https://api.cloudflare.com/client/v4/accounts/0123456789abcdef0123456789abcdef/ai/run/@cf/black-forest-labs/flux-1-schnell",
  "Cloudflare endpoint is constructed from a validated account and registered model")
T.eq(cloudflareClient.model(), ImageClient.DEFAULT_MODEL,
  "FLUX.1 Schnell is the default Cloudflare image model")
local imageRequest = Json.decode(cloudflareClient.buildRequest(imageDefinition,
  { mapId = "ROUTE_1", tileset = "OVERWORLD" }, seedA))
T.eq(imageRequest.model, nil, "Cloudflare model lives in the validated endpoint, not the JSON body")
T.eq(imageRequest.steps, 8, "FLUX request steps are clamped to the model maximum")
T.eq(imageRequest.seed, seedA, "image request carries the deterministic seed")
T.check(imageRequest.prompt:find("left half", 1, true) ~= nil
  and imageRequest.prompt:find("right half", 1, true) ~= nil,
  "one source sheet requests consistent front and rear views")
T.check(imageRequest.prompt:find("Generation 1 Pokemon", 1, true) ~= nil
    and imageRequest.prompt:find("exactly four grayscale tones", 1, true) ~= nil
    and imageRequest.prompt:find("no antialiasing", 1, true) ~= nil
    and imageRequest.prompt:find("32%-by%-32 back sprite") ~= nil,
  "Cloudflare is prompted for classic Generation I monochrome pixel art")
T.check(imageRequest.prompt:find("Pokemon Red and Blue", 1, true) ~= nil
    and imageRequest.prompt:find("never as an ordinary real%-world animal") ~= nil
    and imageRequest.prompt:find("oversized expressive head and eyes", 1, true) ~= nil
    and imageRequest.prompt:find("avoid natural animal proportions", 1, true) ~= nil,
  "image art direction favors stylized Generation I monsters over realistic animals")
T.check(imageRequest.prompt:find("not modern full%-color concept art") ~= nil,
  "Cloudflare is explicitly steered away from modern full-color rendering")
local oversizedImageDefinition = {
  shape = string.rep("s", 100),
  features = { string.rep("f", 100), string.rep("g", 100), string.rep("h", 100) },
  bodyColors = { string.rep("c", 100), string.rep("d", 100), string.rep("e", 100) },
  markings = string.rep("m", 500), pose = string.rep("p", 500),
  texture = string.rep("t", 500), visualDescription = string.rep("v", 500),
}
local oversizedImageRequest = Json.decode(cloudflareClient.buildRequest(
  oversizedImageDefinition, { mapId = "ROUTE_1", tileset = "OVERWORLD" }, seedA))
T.check(#oversizedImageRequest.prompt <= ImageClient.MAX_PROMPT_LENGTH,
  "Cloudflare prompts stay within the provider's 2,048-character limit")
T.check(oversizedImageRequest.prompt:find("not modern full%-color concept art") ~= nil,
  "bounded prompts retain the final rendering constraints")

local fakePng = "\137PNG\r\n\26\nfixture"
local encodedPng = love.data.encode("string", "base64", fakePng)
local parsedImage, parsedImageErr, parsedFormat = cloudflareClient.parseResponse(
  Json.encode({ success = true, result = { image = encodedPng } }))
T.eq(parsedImageErr, nil, "base64 image response parses")
T.eq(parsedImage, fakePng, "base64 response is decoded without persistence")
T.eq(parsedFormat, "png", "supported image format is identified")
local parsedNimImage = nimImageClient.parseResponse(
  Json.encode({ data = { { b64_json = encodedPng } } }))
T.eq(parsedNimImage, fakePng, "legacy NIM b64_json responses remain compatible")
local bareImage = cloudflareClient.parseResponse(Json.encode({ image = encodedPng }))
T.eq(bareImage, fakePng, "bare Cloudflare model output remains defensively compatible")
local cloudflareFailure, cloudflareFailureErr = cloudflareClient.parseResponse(Json.encode({
  success = false, errors = { { code = 429, message = "temporary quota reached" } },
}))
T.eq(cloudflareFailure, nil, "Cloudflare failure envelopes are rejected")
T.check(cloudflareFailureErr:find("429", 1, true) ~= nil
    and cloudflareFailureErr:find("temporary quota", 1, true) ~= nil,
  "bounded Cloudflare error details reach fallback classification")
local authFailure, authFailureErr = cloudflareClient.parseResponse(Json.encode({
  success = false, errors = { { code = 10000, message = "Authentication error" } },
}))
T.eq(authFailure, nil, "Cloudflare authentication failures are rejected")
T.check(authFailureErr:find("CLOUDFLARE_API_TOKEN", 1, true) ~= nil
    and authFailureErr:find("restart the game", 1, true) ~= nil,
  "Cloudflare authentication failures explain how to replace an expired token")
local malformedImage, malformedErr = cloudflareClient.parseResponse(
  Json.encode({ success = true, result = { image = "not+valid=padding===" } }))
T.eq(malformedImage, nil, "malformed base64 image is rejected")
T.check(type(malformedErr) == "string", "malformed base64 returns a bounded error")
local unsupportedImage, unsupportedErr = cloudflareClient.parseResponse(Json.encode({
  success = true, result = { image = love.data.encode("string", "base64", "GIF89a") },
}))
T.eq(unsupportedImage, nil, "unsupported decoded image magic is rejected")
T.check(unsupportedErr:find("unsupported format", 1, true) ~= nil,
  "unsupported image magic has a safe diagnostic")
local oldImageLimit = ImageClient.MAX_IMAGE_BYTES
ImageClient.MAX_IMAGE_BYTES = 4
local tooLargeImage, tooLargeImageErr = cloudflareClient.parseResponse(Json.encode({
  success = true, result = { image = encodedPng },
}))
ImageClient.MAX_IMAGE_BYTES = oldImageLimit
T.eq(tooLargeImage, nil, "oversized decoded image data is rejected")
T.check(tooLargeImageErr:find("size limit", 1, true) ~= nil,
  "oversized decoded image data reports the configured limit")
local oldResponseLimit = ImageClient.MAX_RESPONSE_BYTES
ImageClient.MAX_RESPONSE_BYTES = 32
local oversizedImage, oversizedErr = cloudflareClient.parseResponse(string.rep("x", 33))
ImageClient.MAX_RESPONSE_BYTES = oldResponseLimit
T.eq(oversizedImage, nil, "oversized image envelope is rejected before JSON parsing")
T.check(oversizedErr:find("size limit", 1, true) ~= nil,
  "oversized response reports the configured limit")

local capturedCloudflare, capturedNim
local transportCloudflare = imageClient({
  provider = "cloudflare", accountId = "0123456789abcdef0123456789abcdef",
  cloudflareToken = "cloudflare-only-token", nvidiaKey = "wrong-nvidia-token",
  transport = function(_, _, headers) capturedCloudflare = headers.Authorization; return "{}" end,
})
transportCloudflare.perform("{}", "test")
local transportNim = imageClient({
  provider = "nim", baseUrl = "https://images.example.test/v1",
  nvidiaKey = "nvidia-only-token", cloudflareToken = "wrong-cloudflare-token",
  transport = function(_, _, headers) capturedNim = headers.Authorization; return "{}" end,
})
transportNim.perform("{}", "test")
T.eq(capturedCloudflare, "Bearer cloudflare-only-token",
  "Cloudflare requests use only the Cloudflare token")
T.eq(capturedNim, "Bearer nvidia-only-token", "NIM image requests use only the NVIDIA token")
local invalidAccountBody, invalidAccountErr = imageClient({
  provider = "cloudflare", accountId = "../bad", cloudflareToken = "test",
}).perform("{}", "test")
T.eq(invalidAccountBody, nil, "malformed Cloudflare account IDs never enter a URL")
T.check(invalidAccountErr:find("32%-character") ~= nil,
  "malformed Cloudflare account IDs return a safe configuration error")
local invalidModelRequest, invalidModelErr = imageClient({
  provider = "cloudflare", accountId = "0123456789abcdef0123456789abcdef",
  cloudflareToken = "test", model = "@cf/unregistered/model",
}).buildRequest(imageDefinition, {}, seedA)
T.eq(invalidModelRequest, nil, "unregistered Cloudflare models cannot reuse the FLUX schema")
T.check(invalidModelErr:find("unsupported Cloudflare image model", 1, true) ~= nil,
  "unregistered Cloudflare models fail with a capability-registry diagnostic")

local fixtureImage = {}
function fixtureImage:getDimensions() return 160, 96 end
function fixtureImage:getPixel(x, y)
  local panelX = x < 80 and x or x - 80
  local centerX = x < 80 and 40 or 40
  local rx = x < 80 and 14 or 12
  local ry = x < 80 and 37 or 34
  local dx, dy = (panelX - centerX) / rx, (y - 48) / ry
  if dx * dx + dy * dy <= 1 then
    -- A large enclosed white marking is deliberately the same color as the
    -- backdrop. Edge-connected filling must preserve it as light creature ink.
    if math.abs(panelX - centerX) <= 5 and math.abs(y - 48) <= 8 then
      return 1, 1, 1, 1
    end
    return x < 80 and 0.15 or 0.28, 0.45, 0.72, 1
  end
  return 0.98, 0.98, 0.98, 1
end

local converted, convertErr = SpriteConverter.convertImage(fixtureImage)
T.eq(convertErr, nil, "two-view source converts to persistent color masters")
T.eq(converted.artFormat, SpriteConverter.ART_FORMAT,
  "converted art declares its indexed true-color format")
T.check(SpriteGenerator.validImageRows(converted.front, 112, 112),
  "converted front retains a 112x112 color master")
T.check(SpriteGenerator.validImageRows(converted.back, 112, 112),
  "converted back retains a 112x112 color master")
T.check(table.concat(converted.front):find("00", 1, true) ~= nil,
  "edge-connected backdrop remains transparent")
T.check(table.concat(converted.front):find("d8", 1, true) ~= nil,
  "enclosed white creature marking survives background removal")
T.same(SpriteConverter.convertImage(fixtureImage), converted,
  "conversion is deterministic for identical source pixels")

local encodedFixture = love.image.newImageData(160, 96)
for y = 0, 95 do
  for x = 0, 159 do
    encodedFixture:setPixel(x, y, fixtureImage:getPixel(x, y))
  end
end
local fixtureFileData = encodedFixture:encode("png")
local decodedConversion, decodedConversionErr = SpriteConverter.convertBytes(
  fixtureFileData:getString(), "png")
T.eq(decodedConversionErr, nil, "PNG source bytes decode inside the local converter")
T.same(decodedConversion, converted, "byte decoding reaches the deterministic conversion path")
local oversizedHeader = "\137PNG\r\n\26\n" .. string.char(0, 0, 0, 13) .. "IHDR"
  .. string.char(0, 0, 16, 0, 0, 0, 0, 64)
local oversizedSource, oversizedSourceErr = SpriteConverter.decodeImage(oversizedHeader, "png")
T.eq(oversizedSource, nil, "unreasonable source dimensions are rejected before image decoding")
T.check(oversizedSourceErr:find("dimensions", 1, true) ~= nil,
  "dimension preflight returns a bounded validation error")

local function rowBounds(rows)
  local minX, minY, maxX, maxY = 999, 999, 0, 0
  for y, row in ipairs(rows) do
    for x = 1, #row / 2 do
      if row:sub(x * 2 - 1, x * 2) ~= "00" then
        minX, minY, maxX, maxY = math.min(minX, x), math.min(minY, y),
          math.max(maxX, x), math.max(maxY, y)
      end
    end
  end
  return minX, minY, maxX, maxY
end
local minX, _, maxX = rowBounds(converted.front)
T.check(math.abs((minX - 1) - (112 - maxX)) <= 3,
  "aspect-preserved front reduction is centered on its logical canvas")

local front, back = {}, {}
for _ = 1, 28 do front[#front + 1] = string.rep("03", 14) end
for _ = 1, 16 do back[#back + 1] = string.rep("12", 8) end
local generated = {
  name = "Volt Mite!", kind = "Spark Bug", types = { "ELECTRIC", "BUG" },
  stats = { hp = 999, attack = 80, defense = 70, speed = 120, special = 85 },
  catch_rate = 150, base_exp = 110, height_ft = 1, height_in = 7,
  weight_tenths_lb = 84, description = "It stores static in its bright shell.",
  shape = "INSECT", features = { "ANTENNA", "SHELL" },
  level_1_moves = { "TACKLE", "THUNDERSHOCK", "INVENTED_BEAM", "TACKLE" },
  learnset = {
    { level = 28, move = "THUNDERBOLT" }, { level = 8, move = "STRING_SHOT" },
    { level = 15, move = "THUNDER_WAVE" }, { level = 46, move = "THUNDER" },
    { level = 150, move = "FLASH" }, { level = 30, move = "INVENTED_BEAM" },
    { level = 35, move = "THUNDERBOLT" },
  },
  front = { "not usable model pixels" }, back = {},
}
local completion = Json.encode({ choices = { { message = {
  role = "assistant", content = "```json\n" .. Json.encode(generated) .. "\n```",
} } } })
local def, parseErr = Client.parseCompletion(completion)
T.eq(parseErr, nil, "valid generated JSON parses")
T.eq(def.name, "VOLTMITE", "name is normalized to Gen 1 text")
T.same(def.types, { "ELECTRIC", "BUG" }, "two legal types survive")
T.check(def.baseStats.hp <= 160, "base stats are clamped to Gen 1 limits")
T.eq(#def.front, 28, "front art has 28 logical rows")
T.eq(#def.back, 16, "back art has 16 logical rows")
T.eq(def.artVersion, SpriteGenerator.VERSION, "sprite uses the current local renderer")
T.eq(def.shape, "INSECT", "model-selected anatomy reaches the renderer")
T.same(def.level1Moves, { "TACKLE", "THUNDERSHOCK" },
  "starting moves are de-duplicated and invented move IDs are rejected")
T.same(def.learnset, {
  { level = 8, move = "STRING_SHOT" }, { level = 15, move = "THUNDER_WAVE" },
  { level = 28, move = "THUNDERBOLT" }, { level = 46, move = "THUNDER" },
}, "valid generated level-up moves are sorted and persisted")
T.eq(def.artSource, "procedural", "legacy completion parsing retains procedural art")
T.check(def.front[1] ~= generated.front[1], "unreliable model-provided pixels are ignored")
T.check(SpriteGenerator.validRows(def.front, 28, 28), "local front sprite is structurally valid")
T.check(SpriteGenerator.validRows(def.back, 16, 16), "local back sprite is structurally valid")
local conflictingDef, conflictingErr = Client.parseCompletion(completion, false, {
  forbiddenNames = { "VOLTMITE" },
})
T.eq(conflictingDef, nil, "an existing Pokemon or generated name is never accepted")
T.check(conflictingErr:find("VOLTMITE", 1, true) ~= nil,
  "name-collision validation identifies the rejected response")

local legacy = {
  name = "OLDMON", kind = "GLITCH", types = { "NORMAL" },
  front = front, back = back,
}
T.check(SpriteGenerator.ensure(legacy), "legacy generated art is repaired on load")
T.eq(legacy.artVersion, SpriteGenerator.VERSION, "repaired art is versioned")
T.check(not SpriteGenerator.ensure(legacy), "current valid art is not redrawn repeatedly")
T.eq(legacy.artSource, "procedural", "legacy version-3 saves gain procedural provenance")

local legacyImage = {
  name = "OLDART", artSource = "cloudflare-image",
  front = front, back = back,
}
T.check(not SpriteGenerator.ensure(legacyImage),
  "legacy 28x28/16x16 Cloudflare rows remain loadable without redraw")
T.eq(legacyImage.front[1], front[1], "legacy image pixels remain unchanged")

local imageRows = converted
local fakeImageClient = {
  seed = function() return 4242 end,
  prompt = function() return "safe two-view prompt" end,
  buildRequest = function() return "image request" end,
  perform = function() return "image envelope" end,
  parseResponse = function() return "image bytes", nil, "png" end,
  provider = function() return "cloudflare" end,
  model = function() return "visual/test-model" end,
}
local fakeConverter = {
  VERSION = 7,
  convertBytes = function(bytes, format)
    T.eq(bytes, "image bytes", "pipeline passes decoded image bytes only to converter")
    T.eq(format, "png", "pipeline preserves validated source format")
    return imageRows
  end,
}
local hybrid = assert(Pipeline.fromCompletion(completion,
  { mapId = "ROUTE_1", tileset = "OVERWORLD" }, "test",
  { imageClient = fakeImageClient, converter = fakeConverter }))
T.eq(hybrid.definition.artSource, "cloudflare-image",
  "successful Workers AI art records Cloudflare provenance")
T.eq(hybrid.definition.imageProvider, "cloudflare", "image provider is persisted")
T.eq(hybrid.definition.imagePipelineVersion, 7, "image converter version is persisted")
T.eq(hybrid.definition.artFormat, SpriteConverter.ART_FORMAT,
  "high-resolution color format is persisted")
T.eq(hybrid.definition.frontWidth, 112, "front master dimensions are persisted")
T.eq(hybrid.definition.imageModel, "visual/test-model", "visual model metadata is persisted")
T.eq(hybrid.definition.imageSeed, 4242, "visual seed metadata is persisted")
T.eq(hybrid.definition.imagePrompt, "safe two-view prompt", "sanitized visual prompt is persisted")
T.eq(hybrid.definition.artVersion, nil, "procedural renderer version is not attached to image art")
T.check(not Json.encode(hybrid.definition):find("image bytes", 1, true),
  "source image bytes are never stored in the save definition")
hybrid.definition.artVersion = -999
local preservedFront = hybrid.definition.front[1]
T.check(not SpriteGenerator.ensure(hybrid.definition),
  "procedural renderer bumps do not replace valid Cloudflare-derived rows")
T.eq(hybrid.definition.front[1], preservedFront, "Cloudflare-derived pixels survive offline migration")
local savedNimArt = {}
for key, value in pairs(hybrid.definition) do savedNimArt[key] = value end
savedNimArt.artSource, savedNimArt.imageProvider = "nim-image", "nim"
T.check(not SpriteGenerator.ensure(savedNimArt),
  "legacy NIM-derived rows also survive procedural renderer migrations")

local fallbackClient = {}
for key, value in pairs(fakeImageClient) do fallbackClient[key] = value end
fallbackClient.perform = function() return nil,
  "temporary outage sk-secret-secret " .. string.rep("A", 120) end
local fallback = assert(Pipeline.fromCompletion(completion,
  { mapId = "ROUTE_1", tileset = "OVERWORLD" }, "test",
  { imageClient = fallbackClient, converter = fakeConverter }))
T.eq(fallback.definition.name, "VOLTMITE", "image failure does not discard valid metadata")
T.eq(fallback.definition.artSource, "procedural", "image failure completes with procedural art")
T.eq(fallback.definition.imageAttemptProvider, "cloudflare",
  "fallback provenance records the attempted provider")
T.eq(fallback.definition.imageAttemptModel, "visual/test-model",
  "fallback provenance records the attempted model")
T.check(type(fallback.definition.imageFallbackReason) == "string"
    and #fallback.definition.imageFallbackReason < 300,
  "fallback provenance persists a bounded diagnostic")
T.check(SpriteGenerator.validRows(fallback.definition.front, 28, 28),
  "fallback art remains installable")
T.check(#fallback.warning < 400 and not fallback.warning:find(string.rep("A", 100), 1, true)
    and not fallback.warning:find("sk-secret", 1, true),
  "fallback errors do not leak large response or credential-like bodies")
local rateLimitClient = {}
for key, value in pairs(fakeImageClient) do rateLimitClient[key] = value end
rateLimitClient.perform = function() return nil, "Cloudflare 429: temporary quota reached" end
local rateLimited = assert(Pipeline.fromCompletion(completion,
  { mapId = "ROUTE_1", tileset = "OVERWORLD" }, "test",
  { imageClient = rateLimitClient, converter = fakeConverter }))
T.eq(rateLimited.definition.imageFallbackTransient, true,
  "rate-limit and temporary-quota fallback is classified as transient")
local timeoutClient = {}
for key, value in pairs(fakeImageClient) do timeoutClient[key] = value end
timeoutClient.perform = function() return nil, "network request timed out" end
local timedOut = assert(Pipeline.fromCompletion(completion,
  { mapId = "ROUTE_1", tileset = "OVERWORLD" }, "test",
  { imageClient = timeoutClient, converter = fakeConverter }))
T.eq(timedOut.definition.imageFallbackTransient, true,
  "network timeouts reach persisted transient fallback metadata")
local configurationFallback = assert(Pipeline.fromCompletion(completion,
  { mapId = "ROUTE_1", tileset = "OVERWORLD" }, "test",
  { imageClient = disabledImageClient, converter = fakeConverter }))
T.eq(configurationFallback.definition.imageAttemptProvider, "disabled",
  "missing image configuration is explicit in fallback metadata")
T.check(configurationFallback.definition.imageFallbackReason:find("disabled", 1, true) ~= nil,
  "missing image configuration retains a bounded actionable reason")
local secretClient = {}
for key, value in pairs(fakeImageClient) do secretClient[key] = value end
secretClient.perform = function()
  return nil, "Bearer " .. string.rep("C", 60) .. " " .. string.rep("B", 200)
end
local secretFallback = assert(Pipeline.fromCompletion(completion,
  { mapId = "ROUTE_1", tileset = "OVERWORLD" }, "test",
  { imageClient = secretClient, converter = fakeConverter }))
local savedSecretFallback = Json.encode(secretFallback.definition)
T.check(not savedSecretFallback:find(string.rep("C", 40), 1, true)
    and not savedSecretFallback:find(string.rep("B", 100), 1, true),
  "Cloudflare-like tokens and large encoded bodies never leak into saved diagnostics")
local thrownFallback = assert(Pipeline.fromCompletion(completion,
  { mapId = "ROUTE_1", tileset = "OVERWORLD" }, "test", {
    imageClient = fakeImageClient,
    converter = { convertBytes = function() error("decoder crashed") end },
  }))
T.eq(thrownFallback.definition.artSource, "procedural",
  "unexpected image-converter errors also complete through fallback")
T.check(thrownFallback.warning:find("decoder crashed", 1, true) ~= nil,
  "unexpected conversion failure is reduced to a short diagnostic")

local Data = require("src.core.Data")
Data:load()
for id in pairs(Learnset.validMoves) do
  T.check(Data.moves[id] ~= nil, "learnset allowlist move exists in Generation I data: " .. id)
end
for id in pairs(Data.moves) do
  if id ~= "STRUGGLE" then
    T.check(Learnset.validMoves[id], "every naturally learnable Generation I move is allowed: " .. id)
  end
end
T.check(not Learnset.validMoves.STRUGGLE,
  "STRUGGLE cannot be generated as a naturally learned move")
local run = T.sdk.loadMod("mods/nvidia_fakemon", { data = Data })
T.eq(#run.errors, 0, "mod loads cleanly")
T.check(Data.pokemon.NVIDIA_FAKE_001 ~= nil, "reserved Fakemon slots are registered")
T.eq(Data.constants.dexSize, 407, "the frozen registry reserves all save-safe dex slots")

local exports = run.loader.exports.nvidia_fakemon
local game = {
  data = Data,
  save = { flags = {} },
  overworld = { map = { id = "ROUTE_1" } },
  writeSave = function() return true end,
}
Runtime.emit("game.ready", { game = game })
T.eq(Data.constants.dexSize, 151, "the visible Fakédex starts at the vanilla size")
local realNewImageData = love.image.newImageData
local transparentPixels, opaquePixels = 0, 0
love.image.newImageData = function()
  return {
    setPixel = function(_, _, _, _, _, _, alpha)
      if alpha == 0 then transparentPixels = transparentPixels + 1 end
      if alpha == 1 then opaquePixels = opaquePixels + 1 end
    end,
    encode = function() return true end,
  }
end
Runtime.emit("save.loading", { raw = { modData = { nvidia_fakemon = { state = {
  fakemon = { NVIDIA_FAKE_001 = hybrid.definition },
} } } } })
T.eq(Data.pokemon.NVIDIA_FAKE_001.name, "VOLTMITE",
  "saved hybrid rows restore offline without starting a network worker")
T.check(exports.applyDefinition(game, "NVIDIA_FAKE_001", hybrid.definition, true),
  "a generated definition installs into its reserved slot")
T.check(transparentPixels > 0, "empty sprite pixels are written with transparent alpha")
T.check(opaquePixels > 0, "creature pixels remain opaque")
T.eq(Data.pokemon.NVIDIA_FAKE_001.name, "VOLTMITE", "generated name reaches live data")
T.eq(Data.constants.dexSize, 152, "installing a definition grows the visible Fakédex")
T.eq(Data.pokemon.NVIDIA_FAKE_001.spriteFront,
  "nvidia_fakemon/nvidia_fake_001_front.png", "front art uses the persistent save path")
T.eq(Data.pokemon.NVIDIA_FAKE_001.trueColor, true,
  "image-derived sprites bypass Game Boy palette quantization")
T.eq(Data.pokemon.NVIDIA_FAKE_001.battleScaleFront, 0.5,
  "112px front master fits the classic 56px battle footprint")
T.same(Data.pokemon.NVIDIA_FAKE_001.level1Moves, { "TACKLE", "THUNDERSHOCK" },
  "generated starting moves reach the live species definition")
T.same(Data.pokemon.NVIDIA_FAKE_001.learnset, def.learnset,
  "the generated species-specific level-up learnset reaches gameplay")

local legacyMoveDefinition = {}
for key, value in pairs(hybrid.definition) do legacyMoveDefinition[key] = value end
legacyMoveDefinition.level1Moves, legacyMoveDefinition.learnset = nil, nil
T.check(exports.applyDefinition(game, "NVIDIA_FAKE_002", legacyMoveDefinition, true),
  "a legacy definition without generated moves remains installable")
T.check(#Data.pokemon.NVIDIA_FAKE_002.level1Moves >= 2
    and #Data.pokemon.NVIDIA_FAKE_002.learnset >= 4,
  "legacy definitions receive starting moves and a type-aware level-up progression")
love.image.newImageData = realNewImageData

local saved = exports.state()
saved.fakemon.NVIDIA_FAKE_001 = hybrid.definition
saved.maps.ROUTE_1 = "NVIDIA_FAKE_001"
T.eq(exports.fakemonPerMap, 2, "eligible maps plan two newly generated Fakemon")
T.eq(exports.reusedPerMap, 2, "newer maps can retain two prior discoveries")
T.check(exports.eligibleMap("ROUTE_1"), "grass encounter maps are generation-eligible")
T.check(exports.eligibleMap("OAKS_LAB"), "the starter lab is generation-eligible")
T.check(exports.eligibleMap("CELADON_CITY"),
  "maps with map-specific fishing encounters are generation-eligible")
T.check(not exports.eligibleMap("REDS_HOUSE_1F"),
  "maps without encounters or starters do not generate Fakemon")
T.same(exports.mapPool("ROUTE_1"), { "NVIDIA_FAKE_001" },
  "legacy single-slot map saves migrate into the map pool")
T.eq(exports.generationsNeeded("ROUTE_1"), 1,
  "a legacy one-Fakemon map schedules only its missing second design")
T.eq(exports.generationsNeeded("ROUTE_2"), 2,
  "a new eligible map schedules exactly two designs")
T.eq(exports.generationsNeeded("REDS_HOUSE_1F"), 0,
  "an ineligible map schedules no generation work")
for index = 2, 4 do saved.fakemon[("NVIDIA_FAKE_%03d"):format(index)] = hybrid.definition end
saved.maps.ROUTE_2 = {
  own = { "NVIDIA_FAKE_002", "NVIDIA_FAKE_003" },
  reused = { "NVIDIA_FAKE_001", "NVIDIA_FAKE_004" }, reuseAssigned = true,
}
T.same(exports.mapPool("ROUTE_2"), {
  "NVIDIA_FAKE_002", "NVIDIA_FAKE_003", "NVIDIA_FAKE_001", "NVIDIA_FAKE_004",
}, "newer encounter pools combine two local and two prior Fakemon")
local battlePath = Runtime.call("pokemon.sprite", function(value) return value end,
  Data.pokemon.NVIDIA_FAKE_001.spriteFront,
  { species = "NVIDIA_FAKE_001", side = "front", kind = "battle" })
T.eq(battlePath, "nvidia_fakemon/nvidia_fake_001_front_hd.png",
  "battle resolution selects the high-resolution master")
local encounter = Runtime.call("encounter.species", function(value) return value end,
  { species = "RATTATA", level = 3 }, { mapId = "ROUTE_1" })
T.eq(encounter.species, "NVIDIA_FAKE_001", "grass encounter uses the map Fakemon")

local fish = Runtime.call("encounter.fishing", function()
  return { species = "MAGIKARP", level = 5 }
end, "OLD_ROD", "ROUTE_1", {})
T.eq(fish.species, "NVIDIA_FAKE_001", "fishing encounter uses the map Fakemon")

local party = Runtime.call("trainer.party", function(_, _, value) return value end,
  "OPP_BUG_CATCHER", 1, { { species = "WEEDLE", level = 6, moves = { "STRING_SHOT" } } })
T.check(saved.fakemon[party[1].species] ~= nil,
  "trainer party can use a Fakemon generated on an earlier map")
T.eq(party[1].level, 6, "trainer level is preserved")
T.same(party[1].moves, { "STRING_SHOT" }, "trainer slot metadata is preserved")
local vanillaParty = Runtime.call("trainer.party", function(_, _, value) return value end,
  "OPP_YOUNGSTER", 1, { { species = "RATTATA", level = 7 } })
T.eq(vanillaParty[1].species, "RATTATA",
  "trainer Fakemon are possible rather than replacing every authored slot")

local routeGift = {
  species = "EEVEE",
  ctx = { save = { flags = {} }, overworld = { map = { id = "ROUTE_1" } } },
}
Runtime.emit("pokemon.before_give", routeGift)
T.eq(routeGift.species, "NVIDIA_FAKE_001", "map gifts use the generated species")

saved.maps.OAKS_LAB = "NVIDIA_FAKE_002"
saved.fakemon.NVIDIA_FAKE_002 = hybrid.definition
local gift = {
  species = "CHARMANDER",
  ctx = { save = { flags = {} }, overworld = { map = { id = "OAKS_LAB" } } },
}
Runtime.emit("pokemon.before_give", gift)
T.eq(gift.species, "NVIDIA_FAKE_002", "unclaimed Oak starter uses the lab Fakemon")
gift.species = "CHARMANDER"
gift.ctx.save.flags.EVENT_GOT_STARTER = true
Runtime.emit("pokemon.before_give", gift)
T.eq(gift.species, "CHARMANDER", "claimed starter is never rewritten")

run.release()
T.finish("nvidia_fakemon")
