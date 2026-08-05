local Json = require("src.link.Json")
local HostShell = require("src.core.HostShell")

local ImageClient = {}

ImageClient.DEFAULT_MODEL = "@cf/black-forest-labs/flux-1-schnell"
ImageClient.NIM_DEFAULT_MODEL = "stabilityai/stable-diffusion-3.5-large"
ImageClient.MAX_RESPONSE_BYTES = 20 * 1024 * 1024
ImageClient.MAX_IMAGE_BYTES = 15 * 1024 * 1024
ImageClient.MAX_PROMPT_LENGTH = 2048

local CLOUDFLARE_MODELS = {
  ["@cf/black-forest-labs/flux-1-schnell"] = {
    path = "@cf/black-forest-labs/flux-1-schnell",
    defaultSteps = 8,
    minSteps = 1,
    maxSteps = 8,
  },
}

local function trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function safeText(value, max)
  local out = tostring(value or ""):gsub("[%c]", " "):gsub("%s+", " ")
  out = trim(out):gsub("[{}]", "")
  if #out > (max or 160) then out = out:sub(1, max or 160) end
  return out
end

local function safeError(value)
  local out = safeText(value, 240)
  out = out:gsub("[Bb]earer%s+%S+", "Bearer [redacted]")
    :gsub("nvapi%-%S+", "[redacted credential]")
    :gsub("sk%-%S+", "[redacted credential]")
  out = out:gsub("[%w%+/%=_%-]+", function(run)
    return #run > 32 and "[encoded data omitted]" or run
  end)
  return out ~= "" and out or "image request failed"
end

local function hash(text)
  local value = 5381
  for index = 1, #text do
    value = (value * 33 + text:byte(index)) % 2147483647
  end
  return value
end

function ImageClient.seed(definition, context)
  definition, context = definition or {}, context or {}
  local parts = {
    definition.name or "NEWMON", definition.kind or "MYSTERY",
    table.concat(definition.types or {}, ":"), definition.visualDescription or "",
    context.mapId or "UNKNOWN", context.tileset or "UNKNOWN",
  }
  return hash(table.concat(parts, "|"))
end

local function list(values, fallback, itemMax)
  local out = {}
  for _, value in ipairs(type(values) == "table" and values or {}) do
    value = safeText(value, itemMax or 32)
    if value ~= "" then out[#out + 1] = value end
    if #out == 3 then break end
  end
  return #out > 0 and table.concat(out, ", ") or fallback
end

function ImageClient.prompt(definition)
  definition = definition or {}
  local prompt = table.concat({
    "Create one original Pokemon-like fantasy monster as a clean two-view"
      .. " battle-sprite sheet; do not copy an existing Pokemon.",
    "The left half must show its full body in a lively three-quarter front battle pose;"
      .. " the right half must show the exact same creature from the rear.",
    "Keep anatomy, proportions, colors, and markings consistent between views.",
    "Creature: " .. safeText(definition.visualDescription, 220) .. ".",
    "Body plan: " .. safeText(definition.shape, 24) .. "; distinctive features: "
      .. list(definition.features, "simple readable features", 24) .. ".",
    "Colors: " .. list(definition.bodyColors, "a restrained natural palette", 24)
      .. "; markings: " .. safeText(definition.markings, 72) .. ".",
    "Pose: " .. safeText(definition.pose, 64) .. "; surface texture: "
      .. safeText(definition.texture, 64) .. ".",
    "Make it a designed elemental monster, never as an ordinary real-world animal.",
    "Use Generation 1 Pokemon caricature: compact body, oversized expressive head and eyes,"
      .. " chunky simplified limbs, and one or two bold fantasy features.",
    "Simplify fur, feathers, scales, muscles, and joints into graphic clusters; avoid natural"
      .. " animal proportions, fine hair, realistic anatomy, and wildlife poses.",
    "Render both views as Pokemon Red and Blue battle sprites on the original Game Boy,"
      .. " not later-generation or promotional art.",
    "Use chunky pixel clusters, a dark outline, exactly four grayscale tones, sparse one-bit"
      .. " dithering, and no antialiasing or smooth vector edges.",
    "Match a 56-by-56 front sprite; make the 32-by-32 back sprite simpler and coarser but readable.",
    "Center one strong silhouette on pure white. No scenery, ground, shadow, text, labels,"
      .. " border, frame, props, logo, or other creatures.",
    "It must look like monochrome handheld pixel art, not modern full-color concept art,"
      .. " a 3D render, or pixelated digital painting.",
  }, " ")
  -- Workers AI rejects FLUX prompts longer than 2,048 characters. Keep this
  -- final guard even though each model-supplied field is independently bounded.
  return safeText(prompt, ImageClient.MAX_PROMPT_LENGTH)
end

local function decodeBase64(encoded)
  encoded = tostring(encoded or ""):gsub("%s", "")
  if encoded == "" then return nil, "image response contained no base64 data" end
  if #encoded > math.ceil(ImageClient.MAX_IMAGE_BYTES * 4 / 3) + 8 then
    return nil, "image response exceeded the decoded size limit"
  end
  local padding = encoded:match("(=*)$") or ""
  local content = encoded:sub(1, #encoded - #padding)
  if #encoded % 4 ~= 0 or #padding > 2 or content == ""
      or content:find("[^A-Za-z0-9%+/]") or encoded:sub(1, #content) ~= content then
    return nil, "image response contained malformed base64"
  end
  if not (love and love.data and love.data.decode) then
    return nil, "image decoding needs LOVE data support"
  end
  local ok, bytes = pcall(love.data.decode, "string", "base64", encoded)
  if not ok or type(bytes) ~= "string" or bytes == "" then
    return nil, "image response contained malformed base64"
  end
  if #bytes > ImageClient.MAX_IMAGE_BYTES then
    return nil, "decoded image exceeded the size limit"
  end
  return bytes
end

local function decodeImage(encoded)
  local bytes, err = decodeBase64(encoded)
  if not bytes then return nil, err end
  if bytes:sub(1, 8) == "\137PNG\r\n\26\n" then return bytes, nil, "png" end
  local a, b = bytes:byte(1, 2)
  if a == 0xff and b == 0xd8 then return bytes, nil, "jpg" end
  return nil, "image response used an unsupported format"
end

local function decodeEnvelope(body)
  if type(body) ~= "string" or body == "" then return nil, "image response was empty" end
  if #body > ImageClient.MAX_RESPONSE_BYTES then
    return nil, "image response exceeded the size limit"
  end
  local decoded = Json.decode(body)
  if type(decoded) ~= "table" then return nil, "image service returned invalid JSON" end
  return decoded
end

local function readConfig(overrides, name, alias)
  if type(overrides) == "table" then
    if overrides[name] ~= nil then return trim(overrides[name]) end
    if alias and overrides[alias] ~= nil then return trim(overrides[alias]) end
    if type(overrides.getenv) == "function" then return trim(overrides.getenv(name)) end
  end
  return trim(os.getenv(name))
end

local function nimEndpoint(base)
  base = trim(base):gsub("/+$", "")
  if base == "" then return nil, "NVIDIA_FAKEMON_IMAGE_BASE_URL is not set" end
  if not base:match("^https?://") then
    return nil, "NVIDIA_FAKEMON_IMAGE_BASE_URL must use http or https"
  end
  if not base:match("/images/generations$") then base = base .. "/images/generations" end
  return base
end

local function cloudflareEndpoint(accountId, model)
  if not accountId:match("^[%x]+$") or #accountId ~= 32 then
    return nil, "CLOUDFLARE_ACCOUNT_ID must be a 32-character hexadecimal ID"
  end
  local capability = CLOUDFLARE_MODELS[model]
  if not capability then return nil, "unsupported Cloudflare image model" end
  return "https://api.cloudflare.com/client/v4/accounts/" .. accountId
    .. "/ai/run/" .. capability.path
end

local function cloudflareError(decoded)
  local parts = {}
  for _, row in ipairs(type(decoded.errors) == "table" and decoded.errors or {}) do
    if type(row) == "table" then
      local code = safeText(row.code, 24)
      local message = safeText(row.message or row.detail, 150)
      local part = code ~= "" and ("Cloudflare " .. code) or "Cloudflare image error"
      if message ~= "" then part = part .. ": " .. message end
      if code == "10000" and message:lower():find("authentication", 1, true) then
        part = part .. "; CLOUDFLARE_API_TOKEN is invalid or expired."
          .. " Create a Workers AI API token and restart the game"
      end
      parts[#parts + 1] = part
    elseif #parts == 0 then
      parts[1] = safeText(row, 180)
    end
    if #parts == 2 then break end
  end
  return safeError(#parts > 0 and table.concat(parts, "; ")
    or decoded.message or "Cloudflare image request failed")
end

local PROVIDERS = {}

PROVIDERS.cloudflare = {
  model = function(config)
    local value = readConfig(config, "NVIDIA_FAKEMON_IMAGE_MODEL", "model")
    return value ~= "" and value or ImageClient.DEFAULT_MODEL
  end,
  endpoint = function(config)
    return cloudflareEndpoint(readConfig(config, "CLOUDFLARE_ACCOUNT_ID", "accountId"),
      PROVIDERS.cloudflare.model(config))
  end,
  buildRequest = function(config, definition, context, seed)
    local model = PROVIDERS.cloudflare.model(config)
    local capability = CLOUDFLARE_MODELS[model]
    if not capability then return nil, "unsupported Cloudflare image model" end
    local configuredSteps = tonumber(readConfig(config, "NVIDIA_FAKEMON_IMAGE_STEPS", "steps"))
    local steps = math.floor(configuredSteps or capability.defaultSteps)
    steps = math.max(capability.minSteps, math.min(capability.maxSteps, steps))
    seed = tonumber(seed) or ImageClient.seed(definition, context)
    seed = math.max(0, math.min(2147483647, math.floor(seed)))
    return Json.encode({ prompt = ImageClient.prompt(definition), steps = steps, seed = seed })
  end,
  perform = function(config, requestBody, tag)
    local token = readConfig(config, "CLOUDFLARE_API_TOKEN", "cloudflareToken")
    if token == "" then return nil, "CLOUDFLARE_API_TOKEN is not set" end
    if token:find("[\r\n]") then return nil, "CLOUDFLARE_API_TOKEN contains an invalid newline" end
    local endpoint, endpointErr = PROVIDERS.cloudflare.endpoint(config)
    if not endpoint then return nil, endpointErr end
    local transport = type(config) == "table" and config.transport or HostShell.httpPostJson
    local body, err = transport(endpoint, requestBody, { Authorization = "Bearer " .. token }, {
      tag = (tag or "nvidia_fakemon") .. "_cloudflare_image",
      timeout = 180,
      maxResponseBytes = ImageClient.MAX_RESPONSE_BYTES,
    })
    if not body then return nil, safeError(err) end
    return body
  end,
  parseResponse = function(body)
    local decoded, err = decodeEnvelope(body)
    if not decoded then return nil, err end
    if decoded.success == false then return nil, cloudflareError(decoded) end
    local encoded = type(decoded.result) == "table" and decoded.result.image or decoded.image
    if type(encoded) ~= "string" then
      if type(decoded.errors) == "table" and #decoded.errors > 0 then
        return nil, cloudflareError(decoded)
      end
      return nil, "Cloudflare image response contained no image"
    end
    return decodeImage(encoded)
  end,
}

PROVIDERS.nim = {
  model = function(config)
    local value = readConfig(config, "NVIDIA_FAKEMON_IMAGE_MODEL", "model")
    return value ~= "" and value or ImageClient.NIM_DEFAULT_MODEL
  end,
  endpoint = function(config)
    return nimEndpoint(readConfig(config, "NVIDIA_FAKEMON_IMAGE_BASE_URL", "baseUrl"))
  end,
  buildRequest = function(config, definition, context, seed)
    seed = tonumber(seed) or ImageClient.seed(definition, context)
    seed = math.max(0, math.min(2147483647, math.floor(seed)))
    return Json.encode({
      model = PROVIDERS.nim.model(config), prompt = ImageClient.prompt(definition),
      n = 1, size = "1024x1024", response_format = "b64_json", seed = seed,
    })
  end,
  perform = function(config, requestBody, tag)
    local key = readConfig(config, "NVIDIA_API_KEY", "nvidiaKey")
    if key == "" then return nil, "NVIDIA_API_KEY is not set" end
    if key:find("[\r\n]") then return nil, "NVIDIA_API_KEY contains an invalid newline" end
    local endpoint, endpointErr = PROVIDERS.nim.endpoint(config)
    if not endpoint then return nil, endpointErr end
    local transport = type(config) == "table" and config.transport or HostShell.httpPostJson
    local body, err = transport(endpoint, requestBody, { Authorization = "Bearer " .. key }, {
      tag = (tag or "nvidia_fakemon") .. "_nim_image", timeout = 180,
      maxResponseBytes = ImageClient.MAX_RESPONSE_BYTES,
    })
    if not body then return nil, safeError(err) end
    return body
  end,
  parseResponse = function(body)
    local decoded, err = decodeEnvelope(body)
    if not decoded then return nil, err end
    if type(decoded.error) == "table" or decoded.detail or decoded.message then
      local value = type(decoded.error) == "table" and
        (decoded.error.message or decoded.error.detail or decoded.error.type) or
        (decoded.detail or decoded.message)
      return nil, safeError(value)
    end
    local encoded = decoded.data and decoded.data[1] and decoded.data[1].b64_json
    if type(encoded) ~= "string" then return nil, "image response contained no b64_json image" end
    return decodeImage(encoded)
  end,
}

PROVIDERS.disabled = {
  model = function() return "disabled" end,
  endpoint = function() return nil, "online image generation is disabled" end,
  buildRequest = function() return "{}" end,
  perform = function(config)
    local reason = type(config) == "table" and config.selectionError
    return nil, reason or "online image generation is disabled; configure Cloudflare credentials or an explicit NIM image base URL"
  end,
  parseResponse = function() return nil, "online image generation is disabled" end,
}

local function selectedName(config)
  local explicit = readConfig(config, "NVIDIA_FAKEMON_IMAGE_PROVIDER", "provider"):lower()
  if explicit ~= "" then
    if PROVIDERS[explicit] then return explicit end
    return "disabled", "unsupported NVIDIA_FAKEMON_IMAGE_PROVIDER value"
  end
  local account = readConfig(config, "CLOUDFLARE_ACCOUNT_ID", "accountId")
  local token = readConfig(config, "CLOUDFLARE_API_TOKEN", "cloudflareToken")
  if account ~= "" and token ~= "" then return "cloudflare" end
  if readConfig(config, "NVIDIA_FAKEMON_IMAGE_BASE_URL", "baseUrl") ~= "" then return "nim" end
  return "disabled"
end

function ImageClient.clientFor(config)
  config = config or {}
  local name, selectionError = selectedName(config)
  if selectionError then config.selectionError = selectionError end
  local implementation = PROVIDERS[name]
  return {
    seed = ImageClient.seed,
    prompt = ImageClient.prompt,
    provider = function() return name end,
    model = function() return implementation.model(config) end,
    endpoint = function() return implementation.endpoint(config) end,
    buildRequest = function(definition, context, seed)
      return implementation.buildRequest(config, definition, context, seed)
    end,
    perform = function(requestBody, tag) return implementation.perform(config, requestBody, tag) end,
    parseResponse = implementation.parseResponse,
  }
end

local function active() return ImageClient.clientFor() end

function ImageClient.provider() return active().provider() end
function ImageClient.model() return active().model() end
function ImageClient.endpoint() return active().endpoint() end
function ImageClient.buildRequest(definition, context, seed)
  return active().buildRequest(definition, context, seed)
end
function ImageClient.perform(requestBody, tag) return active().perform(requestBody, tag) end
function ImageClient.parseResponse(body) return active().parseResponse(body) end

ImageClient.safeError = safeError
ImageClient.safeText = safeText
ImageClient.providers = PROVIDERS
ImageClient.cloudflareModels = CLOUDFLARE_MODELS

return ImageClient
