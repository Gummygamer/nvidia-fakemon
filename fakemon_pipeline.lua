local Client = require("mods.nvidia_fakemon.fakemon_client")
local ImageClient = require("mods.nvidia_fakemon.image_client")
local SpriteConverter = require("mods.nvidia_fakemon.sprite_converter")
local SpriteGenerator = require("mods.nvidia_fakemon.sprite_generator")

local Pipeline = {}

local function callString(object, method, fallbackValue)
  if type(object) ~= "table" or type(object[method]) ~= "function" then return fallbackValue end
  local ok, value = pcall(object[method])
  if not ok or type(value) ~= "string" or value == "" then return fallbackValue end
  return ImageClient.safeText(value, 160)
end

local function isTransient(reason)
  reason = tostring(reason or ""):lower()
  return reason:find("timeout", 1, true) ~= nil
    or reason:find("timed out", 1, true) ~= nil
    or reason:find("network", 1, true) ~= nil
    or reason:find("temporary", 1, true) ~= nil
    or reason:find("rate limit", 1, true) ~= nil
    or reason:find("quota", 1, true) ~= nil
    or reason:find("429", 1, true) ~= nil
    or reason:find("%f[%D]5%d%d%f[%D]") ~= nil
end

local function fallback(definition, reason, imageClient)
  local safeReason = ImageClient.safeError(reason)
  local provider = callString(imageClient, "provider", "unknown")
  local model = callString(imageClient, "model", "unknown")
  SpriteGenerator.generate(definition)
  definition.imageAttemptProvider = provider
  definition.imageAttemptModel = model
  definition.imageFallbackReason = safeReason
  definition.imageFallbackTransient = isTransient(safeReason) or nil
  return {
    definition = definition,
    warning = "image art unavailable; used procedural fallback ("
      .. safeReason .. "; provider: " .. provider .. ")",
  }
end

function Pipeline.fromCompletion(completionBody, context, tag, dependencies)
  dependencies = dependencies or {}
  local imageClient = dependencies.imageClient or ImageClient
  local converter = dependencies.converter or SpriteConverter
  local definition, metadataErr = Client.parseCompletion(completionBody, false, context)
  if not definition then return nil, metadataErr end

  local ran, imageResult, imageErr = pcall(function()
    local seed = imageClient.seed(definition, context)
    local prompt = imageClient.prompt(definition)
    local request, buildErr = imageClient.buildRequest(definition, context, seed)
    if not request then return nil, buildErr end
    local imageBody, requestErr = imageClient.perform(request, tag)
    if not imageBody then return nil, requestErr end
    local bytes, parseErr, extension = imageClient.parseResponse(imageBody)
    if not bytes then return nil, parseErr end
    local rows, conversionErr = converter.convertBytes(bytes, extension)
    if not rows then return nil, conversionErr end
    return { rows = rows, seed = seed, prompt = prompt }
  end)
  if not ran then return fallback(definition, imageResult, imageClient) end
  if not imageResult then return fallback(definition, imageErr, imageClient) end

  definition.front, definition.back = imageResult.rows.front, imageResult.rows.back
  definition.artFormat = imageResult.rows.artFormat
  definition.frontWidth, definition.frontHeight =
    imageResult.rows.frontWidth, imageResult.rows.frontHeight
  definition.backWidth, definition.backHeight =
    imageResult.rows.backWidth, imageResult.rows.backHeight
  local provider = callString(imageClient, "provider", "nim")
  definition.artSource = provider == "cloudflare" and "cloudflare-image" or "nim-image"
  definition.artVersion = nil
  definition.imagePipelineVersion = converter.VERSION or SpriteConverter.VERSION
  definition.imageProvider = provider
  definition.imageModel = imageClient.model()
  definition.imageSeed = imageResult.seed
  definition.imagePrompt = ImageClient.safeText(imageResult.prompt, 2048)
  definition.imageAttemptProvider = nil
  definition.imageAttemptModel = nil
  definition.imageFallbackReason = nil
  definition.imageFallbackTransient = nil
  return { definition = definition }
end

return Pipeline
