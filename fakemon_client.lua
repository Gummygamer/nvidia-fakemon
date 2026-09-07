local Json = require("src.link.Json")
local HostShell = require("src.core.HostShell")
local SpriteGenerator = require("mods.nvidia_fakemon.sprite_generator")
local Learnset = require("mods.nvidia_fakemon.learnset")

local Client = {}

Client.DEFAULT_BASE_URL = "https://integrate.api.nvidia.com/v1"
-- meta/llama-3.1-8b-instruct reached end of life on the hosted NIM API on
-- 2026-08-26 and now answers 410 Gone. Its replacement,
-- mistralai/mistral-7b-instruct-v0.3, is still listed by /v1/models but its
-- backing function is gone, so it answers 404 Function ... Not found for
-- account. minimaxai/minimax-m3 does serve the creature prompt: its context
-- still fits the full Generation I move-ID list, the JSON object comes back
-- directly in content, and it answers inside the 90s request budget.
Client.DEFAULT_MODEL = "minimaxai/minimax-m3"

local VALID_TYPES = {
  NORMAL = true, FIGHTING = true, FLYING = true, POISON = true,
  FIRE = true, WATER = true, GRASS = true, ELECTRIC = true,
  PSYCHIC = true, ICE = true, GROUND = true, ROCK = true,
  BUG = true, GHOST = true, DRAGON = true,
}

local VALID_SHAPES = {
  BIPED = true, QUADRUPED = true, ROUND = true,
  SERPENT = true, WINGED = true, INSECT = true,
}

local VALID_FEATURES = {
  HORNS = true, EARS = true, WINGS = true, TAIL = true,
  CLAWS = true, ANTENNA = true, FINS = true, SHELL = true,
  LEAVES = true, FLAMES = true,
}

local function trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function clamp(value, lo, hi, fallback)
  value = tonumber(value)
  if not value then return fallback end
  return math.max(lo, math.min(hi, math.floor(value + 0.5)))
end

local function ascii(value, max)
  local out = tostring(value or "")
    :gsub("[^%w%s%p]", "?"):gsub("[{}]", "")
    :gsub("[%c]", " "):gsub("%s+", " ")
  out = trim(out)
  if max and #out > max then out = out:sub(1, max) end
  return out
end

local function upperWord(value, max, fallback)
  local out = ascii(value, max):upper():gsub("[^A-Z]", "")
  if out == "" then return fallback end
  return out:sub(1, max)
end

local function forbiddenNameSet(context)
  local out = {}
  for _, value in ipairs(type(context) == "table"
      and type(context.forbiddenNames) == "table" and context.forbiddenNames or {}) do
    local name = upperWord(value, 10, "")
    if name ~= "" then out[name] = true end
  end
  return out
end

local function forbiddenNamePrompt(context)
  local names = {}
  for name in pairs(forbiddenNameSet(context)) do names[#names + 1] = name end
  table.sort(names)
  if #names == 0 then return "" end
  return " Forbidden names for this save are: " .. table.concat(names, ",") .. "."
end

local function wrap(text, width, lines)
  local words, out, line = {}, {}, ""
  for word in ascii(text, width * lines * 2):gmatch("%S+") do words[#words + 1] = word end
  for _, word in ipairs(words) do
    if #word > width then word = word:sub(1, width) end
    if line == "" then
      line = word
    elseif #line + 1 + #word <= width then
      line = line .. " " .. word
    else
      out[#out + 1], line = line, word
      if #out >= lines then break end
    end
  end
  if #out < lines and line ~= "" then out[#out + 1] = line end
  if #out == 0 then out[1] = "A newly found"; out[2] = "KANTO creature." end
  return table.concat(out, "\n")
end

local function normalizeStats(raw)
  raw = type(raw) == "table" and raw or {}
  local stats = {
    hp = clamp(raw.hp, 25, 160, 60),
    attack = clamp(raw.attack, 15, 155, 65),
    defense = clamp(raw.defense, 15, 180, 65),
    speed = clamp(raw.speed, 15, 150, 65),
    special = clamp(raw.special, 20, 155, 65),
  }
  local total = stats.hp + stats.attack + stats.defense + stats.speed + stats.special
  if total > 600 then
    local scale = 600 / total
    for key, value in pairs(stats) do stats[key] = math.max(15, math.floor(value * scale)) end
  elseif total < 250 then
    local add = math.ceil((250 - total) / 5)
    for key, value in pairs(stats) do stats[key] = math.min(155, value + add) end
  end
  return stats
end

function Client.model()
  local configured = trim(os.getenv("NVIDIA_FAKEMON_MODEL"))
  return configured ~= "" and configured or Client.DEFAULT_MODEL
end

function Client.endpoint()
  local base = trim(os.getenv("NVIDIA_NIM_BASE_URL"))
  if base == "" then base = Client.DEFAULT_BASE_URL end
  base = base:gsub("/+$", "")
  if not base:match("/chat/completions$") then base = base .. "/chat/completions" end
  if not base:match("^https?://") then return nil, "NVIDIA_NIM_BASE_URL must use http or https" end
  return base
end

-- A normal request removes its temporary body and bearer-token header. If
-- the process is killed while curl is running, clear those staged files on
-- the next boot before another generation can begin.
function Client.cleanupStagedFiles()
  local fs = love and love.filesystem
  if not (fs and fs.getDirectoryItems and fs.remove) then return end
  local ok, items = pcall(fs.getDirectoryItems, "")
  if not ok or type(items) ~= "table" then return end
  for _, name in ipairs(items) do
    if name:match("^http_post_nvidia_fakemon_[%w_%-]*%.headers$")
        or name:match("^http_post_nvidia_fakemon_[%w_%-]*%.json$")
        or name:match("^http_post_nvidia_fakemon_[%w_%-]*%.response$") then
      pcall(fs.remove, name)
    end
  end
end

function Client.buildRequest(context)
  context = context or {}
  local prompt = table.concat({
    "Invent exactly one original monster for a Generation 1-style creature RPG.",
    "It will be discovered on map " .. ascii(context.mapId, 48) ..
      ", whose tileset is " .. ascii(context.tileset, 32) .. ".",
    "This is design variant " .. tostring(tonumber(context.variant) or 1) ..
      " for that map; make it distinct from the other local variant.",
    "Return ONLY a JSON object with keys name, kind, types, stats, catch_rate, base_exp,",
    "height_ft, height_in, weight_tenths_lb, description, shape, features, body_colors,",
    "markings, pose, texture, visual_description, level_1_moves, and learnset.",
    "name and kind use uppercase ASCII and at most 10 letters.",
    "The name must be wholly original: never reuse an existing Pokemon species name,"
      .. " a previously generated name, or a trivial respelling of either."
      .. forbiddenNamePrompt(context),
    "types is one or two values from NORMAL,FIGHTING,FLYING,POISON,FIRE,WATER,GRASS,",
    "ELECTRIC,PSYCHIC,ICE,GROUND,ROCK,BUG,GHOST,DRAGON.",
    "stats is an object with integer hp,attack,defense,speed,special in the classic Gen 1 range 15..155.",
    "catch_rate is 3..255, base_exp is 30..255, height_in is 0..11, and weight_tenths_lb is an integer.",
    "description is plain ASCII, one or two short sentences, no franchise names.",
    "shape is one of BIPED,QUADRUPED,ROUND,SERPENT,WINGED,INSECT.",
    "features is one to three values from HORNS,EARS,WINGS,TAIL,CLAWS,ANTENNA,FINS,SHELL,LEAVES,FLAMES.",
    "body_colors is one to three simple color names. markings, pose, texture, and visual_description are short plain ASCII strings.",
    "level_1_moves is an array of two to four low-powered moves known at level 1.",
    "learnset is an array of seven to ten objects shaped exactly as {\"level\":integer,\"move\":\"MOVE_ID\"}.",
    "Use increasing levels from 2 through 60, avoid duplicate moves, introduce stronger moves later, and make every choice fit the creature's types, anatomy, and battle role.",
    "Every move must use one of these exact Generation 1 IDs: " .. Learnset.promptIds() .. ".",
    "Choose a shape and features that fit the creature. Do not return pixel data, markdown, or code fences.",
  }, " ")
  return Json.encode({
    model = Client.model(),
    messages = {
      { role = "system", content =
        "You design concise, technically valid game creatures and visual directions." },
      { role = "user", content = prompt },
    },
    max_tokens = 1200,
    temperature = 0.8,
    top_p = 0.95,
    stream = false,
  })
end

local function apiError(decoded)
  if type(decoded) ~= "table" then return nil end
  if type(decoded.error) == "table" then
    return decoded.error.message or decoded.error.detail or decoded.error.type
  end
  return decoded.detail or decoded.title or decoded.message
end

function Client.normalize(raw, generateArt, context)
  if type(raw) ~= "table" then return nil, "generated definition is not an object" end
  local types, seen = {}, {}
  for _, value in ipairs(type(raw.types) == "table" and raw.types or {}) do
    local id = upperWord(value, 12, "NORMAL")
    if VALID_TYPES[id] and not seen[id] then
      types[#types + 1], seen[id] = id, true
      if #types == 2 then break end
    end
  end
  if #types == 0 then types[1] = "NORMAL" end
  local shape = upperWord(raw.shape, 12, "BIPED")
  if not VALID_SHAPES[shape] then shape = "BIPED" end
  local features, seenFeatures = {}, {}
  for _, value in ipairs(type(raw.features) == "table" and raw.features or {}) do
    local feature = upperWord(value, 12, "")
    if VALID_FEATURES[feature] and not seenFeatures[feature] then
      features[#features + 1], seenFeatures[feature] = feature, true
      if #features == 3 then break end
    end
  end
  local generatedName = upperWord(raw.name, 10, "NEWMON")
  if forbiddenNameSet(context)[generatedName] then
    return nil, "generated name conflicts with an existing Pokemon: " .. generatedName
  end
  local definition = {
    name = generatedName,
    kind = upperWord(raw.kind, 10, "MYSTERY"),
    types = types,
    baseStats = normalizeStats(raw.stats),
    catchRate = clamp(raw.catch_rate, 3, 255, 120),
    baseExp = clamp(raw.base_exp, 30, 255, 100),
    heightFt = clamp(raw.height_ft, 0, 99, 3),
    heightIn = clamp(raw.height_in, 0, 11, 0),
    weight = clamp(raw.weight_tenths_lb, 1, 9999, 300),
    description = wrap(raw.description, 18, 3),
    shape = shape,
    features = features,
    bodyColors = {},
    markings = ascii(raw.markings, 100),
    pose = ascii(raw.pose, 80),
    texture = ascii(raw.texture, 80),
    visualDescription = ascii(raw.visual_description, 220),
  }
  definition.level1Moves, definition.learnset = Learnset.normalize(
    raw.level_1_moves, raw.learnset)
  for _, value in ipairs(type(raw.body_colors) == "table" and raw.body_colors or {}) do
    local color = ascii(value, 24)
    if color ~= "" then definition.bodyColors[#definition.bodyColors + 1] = color end
    if #definition.bodyColors == 3 then break end
  end
  if definition.visualDescription == "" then
    definition.visualDescription = table.concat({
      definition.kind, definition.shape, table.concat(definition.features, " ")
    }, " ")
  end
  if generateArt == false then return definition end
  return SpriteGenerator.generate(definition)
end

function Client.parseCompletion(body, generateArt, context)
  local decoded, decodeErr = Json.decode(body or "")
  if not decoded then return nil, "NIM returned invalid JSON: " .. tostring(decodeErr) end
  local choice = decoded.choices and decoded.choices[1]
  local content = choice and choice.message and choice.message.content
  if type(content) ~= "string" or trim(content) == "" then
    return nil, ascii(apiError(decoded) or "NIM response contained no assistant message", 240)
  end
  local object = content:match("(%b{})")
  if not object then return nil, "assistant message contained no JSON object" end
  local raw, err = Json.decode(object)
  if not raw then return nil, "assistant JSON was invalid: " .. tostring(err) end
  return Client.normalize(raw, generateArt, context)
end

function Client.perform(requestBody, tag)
  local key = os.getenv("NVIDIA_API_KEY")
  if type(key) ~= "string" or key == "" then return nil, "NVIDIA_API_KEY is not set" end
  if key:find("[\r\n]") then return nil, "NVIDIA_API_KEY contains an invalid newline" end
  local endpoint, endpointErr = Client.endpoint()
  if not endpoint then return nil, endpointErr end
  return HostShell.httpPostJson(endpoint, requestBody, {
    Authorization = "Bearer " .. key,
  }, { tag = tag or "nvidia_fakemon", timeout = 90 })
end

function Client.encodeEnvelope(ok, value)
  return Json.encode(ok and { ok = true, body = value }
    or { ok = false, error = tostring(value or "unknown request error") })
end

function Client.decodeEnvelope(value)
  local decoded, err = Json.decode(value or "")
  if not decoded then return nil, "worker returned invalid JSON: " .. tostring(err) end
  if decoded.ok then return decoded.body end
  return nil, tostring(decoded.error or "NIM request failed")
end

return Client
