local Generator = {}

-- Bump this when the local renderer changes. Definitions from older builds
-- are redrawn on load, which repairs the low-quality digit grids returned by
-- the original text-model prompt without discarding the generated creature.
Generator.VERSION = 3

local SHAPES = {
  BIPED = true, QUADRUPED = true, ROUND = true,
  SERPENT = true, WINGED = true, INSECT = true,
}

local FEATURES = {
  HORNS = true, EARS = true, WINGS = true, TAIL = true,
  CLAWS = true, ANTENNA = true, FINS = true, SHELL = true,
  LEAVES = true, FLAMES = true,
}

local function hash(text)
  local value = 5381
  for index = 1, #text do
    value = (value * 33 + text:byte(index)) % 2147483647
  end
  return value
end

local function seedFor(definition)
  local parts = { definition.name or "NEWMON", definition.kind or "MYSTERY" }
  for _, value in ipairs(definition.types or {}) do parts[#parts + 1] = value end
  return hash(table.concat(parts, ":"))
end

local function normalizedShape(definition, seed)
  local shape = tostring(definition.shape or ""):upper()
  if SHAPES[shape] then return shape end
  local choices = { "BIPED", "QUADRUPED", "ROUND", "SERPENT", "WINGED", "INSECT" }
  return choices[(seed % #choices) + 1]
end

local function normalizedFeatures(definition, seed, shape)
  local out, seen = {}, {}
  for _, value in ipairs(type(definition.features) == "table" and definition.features or {}) do
    local feature = tostring(value):upper()
    if FEATURES[feature] and not seen[feature] then
      out[#out + 1], seen[feature] = feature, true
      if #out == 3 then break end
    end
  end
  local implied = {
    WINGED = "WINGS", INSECT = "ANTENNA", SERPENT = "TAIL",
    QUADRUPED = "EARS",
  }
  local first = implied[shape]
  if first and not seen[first] and #out < 3 then
    out[#out + 1], seen[first] = first, true
  end
  if #out == 0 then
    local choices = { "HORNS", "EARS", "TAIL", "FINS", "SHELL", "LEAVES" }
    out[1] = choices[(math.floor(seed / 17) % #choices) + 1]
  end
  return out
end

local function canvas(width, height)
  local value = { width = width, height = height, mask = {}, pixels = {} }
  for y = 1, height do
    value.mask[y], value.pixels[y] = {}, {}
    for x = 1, width do value.pixels[y][x] = 0 end
  end
  return value
end

local function inside(value, x, y)
  return x >= 1 and x <= value.width and y >= 1 and y <= value.height
end

local function dot(value, cx, cy, radius)
  radius = math.max(0.55, radius)
  local x0, x1 = math.floor(cx - radius), math.ceil(cx + radius)
  local y0, y1 = math.floor(cy - radius), math.ceil(cy + radius)
  for y = y0, y1 do
    for x = x0, x1 do
      if inside(value, x, y) then
        local dx, dy = x - cx, y - cy
        if dx * dx + dy * dy <= radius * radius then value.mask[y][x] = true end
      end
    end
  end
end

local function ellipse(value, cx, cy, rx, ry)
  for y = math.floor(cy - ry), math.ceil(cy + ry) do
    for x = math.floor(cx - rx), math.ceil(cx + rx) do
      if inside(value, x, y) then
        local dx, dy = (x - cx) / rx, (y - cy) / ry
        if dx * dx + dy * dy <= 1 then value.mask[y][x] = true end
      end
    end
  end
end

local function line(value, x1, y1, x2, y2, thickness)
  local steps = math.max(math.abs(x2 - x1), math.abs(y2 - y1)) * 2
  steps = math.max(1, math.ceil(steps))
  for step = 0, steps do
    local t = step / steps
    dot(value, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, thickness)
  end
end

local function has(features, wanted)
  for _, value in ipairs(features) do if value == wanted then return true end end
  return false
end

local function buildMask(value, shape, features, seed)
  local width, height = value.width, value.height
  local sx, sy = width / 28, height / 28
  local cx = (width + 1) / 2
  local headY, headRx = 8.5 * sy, 5 * sx
  local flip = seed % 2 == 0 and 1 or -1

  -- Features that sit behind the body are drawn first so their joins become
  -- part of one clean silhouette.
  if shape == "WINGED" or has(features, "WINGS") then
    ellipse(value, cx - 6.5 * sx, 14.5 * sy, 5.5 * sx, 7 * sy)
    ellipse(value, cx + 6.5 * sx, 14.5 * sy, 5.5 * sx, 7 * sy)
    line(value, cx - 2 * sx, 12 * sy, cx - 10 * sx, 9 * sy, 1.1 * sx)
    line(value, cx + 2 * sx, 12 * sy, cx + 10 * sx, 9 * sy, 1.1 * sx)
  end

  if shape == "ROUND" then
    ellipse(value, cx, 15.5 * sy, 8.5 * sx, 9.5 * sy)
    ellipse(value, cx - 5 * sx, 24 * sy, 3 * sx, 2 * sy)
    ellipse(value, cx + 5 * sx, 24 * sy, 3 * sx, 2 * sy)
    headY, headRx = 10.5 * sy, 5 * sx
  elseif shape == "QUADRUPED" then
    ellipse(value, cx, 16.5 * sy, 9 * sx, 6 * sy)
    ellipse(value, cx, 9.5 * sy, 5.5 * sx, 5 * sy)
    for _, offset in ipairs({ -6, -2, 2, 6 }) do
      line(value, cx + offset * sx, 19 * sy, cx + offset * sx, 25 * sy, 1.5 * sx)
    end
    headY, headRx = 9 * sy, 5 * sx
  elseif shape == "SERPENT" then
    ellipse(value, cx, 7.5 * sy, 5.5 * sx, 4.5 * sy)
    for index = 0, 8 do
      local y = (11 + index * 1.8) * sy
      local x = cx + math.sin(index * 0.9 + flip) * 4 * sx
      dot(value, x, y, (3.2 - index * 0.12) * sx)
    end
    headY, headRx = 7.5 * sy, 5 * sx
  elseif shape == "INSECT" then
    ellipse(value, cx, 7.5 * sy, 4.5 * sx, 4 * sy)
    ellipse(value, cx, 14 * sy, 5 * sx, 5 * sy)
    ellipse(value, cx, 21 * sy, 4.5 * sx, 6 * sy)
    for _, y in ipairs({ 12, 16, 20 }) do
      line(value, cx - 3 * sx, y * sy, cx - 9 * sx, (y + flip * 2) * sy, 0.8 * sx)
      line(value, cx + 3 * sx, y * sy, cx + 9 * sx, (y - flip * 2) * sy, 0.8 * sx)
    end
    headY, headRx = 7.5 * sy, 4 * sx
  else
    -- BIPED is also the compact central body used by WINGED.
    ellipse(value, cx, 8.5 * sy, 5.5 * sx, 4.5 * sy)
    ellipse(value, cx, 17 * sy, 7 * sx, 8 * sy)
    line(value, cx - 5 * sx, 14 * sy, cx - 10 * sx, 20 * sy, 1.4 * sx)
    line(value, cx + 5 * sx, 14 * sy, cx + 10 * sx, 20 * sy, 1.4 * sx)
    line(value, cx - 3 * sx, 21 * sy, cx - 5 * sx, 26 * sy, 1.7 * sx)
    line(value, cx + 3 * sx, 21 * sy, cx + 5 * sx, 26 * sy, 1.7 * sx)
  end

  if has(features, "TAIL") and shape ~= "SERPENT" then
    line(value, cx + 6 * sx, 18 * sy, cx + 11 * sx, (13 + flip * 3) * sy, 1.2 * sx)
    dot(value, cx + 11 * sx, (13 + flip * 3) * sy, 1.8 * sx)
  end
  if has(features, "HORNS") then
    line(value, cx - 3 * sx, headY - 2 * sy, cx - 5 * sx, headY - 7 * sy, 1.1 * sx)
    line(value, cx + 3 * sx, headY - 2 * sy, cx + 5 * sx, headY - 7 * sy, 1.1 * sx)
  end
  if has(features, "EARS") then
    ellipse(value, cx - headRx, headY - 3 * sy, 2.2 * sx, 4 * sy)
    ellipse(value, cx + headRx, headY - 3 * sy, 2.2 * sx, 4 * sy)
  end
  if has(features, "ANTENNA") then
    line(value, cx - 2 * sx, headY - 3 * sy, cx - 5 * sx, headY - 8 * sy, 0.65 * sx)
    line(value, cx + 2 * sx, headY - 3 * sy, cx + 5 * sx, headY - 8 * sy, 0.65 * sx)
    dot(value, cx - 5 * sx, headY - 8 * sy, 1.1 * sx)
    dot(value, cx + 5 * sx, headY - 8 * sy, 1.1 * sx)
  end
  if has(features, "FINS") then
    line(value, cx - 5 * sx, 15 * sy, cx - 10 * sx, 11 * sy, 1.5 * sx)
    line(value, cx + 5 * sx, 15 * sy, cx + 10 * sx, 11 * sy, 1.5 * sx)
  end
  if has(features, "LEAVES") then
    ellipse(value, cx, headY - 5 * sy, 1.8 * sx, 4 * sy)
    ellipse(value, cx - 3 * sx, headY - 4 * sy, 3 * sx, 1.8 * sy)
    ellipse(value, cx + 3 * sx, headY - 4 * sy, 3 * sx, 1.8 * sy)
  end
  if has(features, "FLAMES") then
    line(value, cx + 6 * sx, 19 * sy, cx + 10 * sx, 15 * sy, 1.5 * sx)
    line(value, cx + 10 * sx, 15 * sy, cx + 9 * sx, 11 * sy, 1.2 * sx)
  end
  if has(features, "CLAWS") then
    line(value, cx - 5 * sx, 24 * sy, cx - 8 * sx, 26 * sy, 0.65 * sx)
    line(value, cx + 5 * sx, 24 * sy, cx + 8 * sx, 26 * sy, 0.65 * sx)
  end

  return headY
end

local function shade(value, seed)
  local cx = (value.width + 1) / 2
  for y = 1, value.height do
    for x = 1, value.width do
      if value.mask[y][x] then
        local edge = not (value.mask[y - 1] and value.mask[y - 1][x])
          or not (value.mask[y + 1] and value.mask[y + 1][x])
          or not value.mask[y][x - 1] or not value.mask[y][x + 1]
        if edge then
          value.pixels[y][x] = 3
        elseif x > cx + 1 and (x + y + seed) % 3 ~= 0 then
          value.pixels[y][x] = 2
        else
          value.pixels[y][x] = 1
        end
      end
    end
  end
end

local function detail(value, x, y, shadeValue)
  x, y = math.floor(x + 0.5), math.floor(y + 0.5)
  if inside(value, x, y) and value.mask[y][x] then value.pixels[y][x] = shadeValue end
end

local function addDetails(value, shape, features, seed, headY, back)
  local sx, sy = value.width / 28, value.height / 28
  local cx = (value.width + 1) / 2
  if back then
    for offset = -1, 1 do detail(value, cx + offset * sx, 10 * sy, 3) end
    for offset = -2, 2 do detail(value, cx + offset * sx, 17 * sy, 2) end
  else
    local eyeOffset = (shape == "INSECT" and 2.5 or 2) * sx
    detail(value, cx - eyeOffset, headY, 3)
    detail(value, cx + eyeOffset, headY, 3)
    detail(value, cx, headY + 2.5 * sy, 3)
    detail(value, cx - sx, headY + 2.5 * sy, 2)
  end

  -- One deliberate marking gives each seed variety without the visual noise
  -- caused by independently generated pixels.
  if has(features, "SHELL") then
    for offset = -2, 2 do detail(value, cx + offset * sx, 17 * sy, offset == 0 and 3 or 2) end
  elseif seed % 3 == 0 then
    detail(value, cx - 2 * sx, 17 * sy, 3)
    detail(value, cx + 2 * sx, 17 * sy, 3)
  else
    for offset = -2, 2 do detail(value, cx + offset * sx, 16 * sy, 2) end
  end
end

local function rows(value)
  local out = {}
  for y = 1, value.height do
    local row = {}
    for x = 1, value.width do row[x] = tostring(value.pixels[y][x]) end
    out[y] = table.concat(row)
  end
  return out
end

local function render(width, height, back, seed, shape, features)
  local value = canvas(width, height)
  local headY = buildMask(value, shape, features, seed)
  shade(value, seed)
  addDetails(value, shape, features, seed, headY, back)
  return rows(value)
end

local function validRows(value, width, height)
  if type(value) ~= "table" or #value ~= height then return false end
  for y = 1, height do
    if type(value[y]) ~= "string" or #value[y] ~= width
        or value[y]:find("[^0-3]") then return false end
  end
  return true
end

local function validImageRows(value, width, height)
  if type(width) ~= "number" or type(height) ~= "number"
      or width < 1 or height < 1 or width > 256 or height > 256
      or width ~= math.floor(width) or height ~= math.floor(height)
      or type(value) ~= "table" or #value ~= height then return false end
  for y = 1, height do
    if type(value[y]) ~= "string" or #value[y] ~= width * 2
        or value[y]:find("[^0-9a-f]") then return false end
    for x = 1, width do
      if tonumber(value[y]:sub(x * 2 - 1, x * 2), 16) > 0xf3 then return false end
    end
  end
  return true
end

function Generator.generate(definition)
  local seed = seedFor(definition)
  local shape = normalizedShape(definition, seed)
  local features = normalizedFeatures(definition, seed, shape)
  definition.shape, definition.features = shape, features
  definition.front = render(28, 28, false, seed, shape, features)
  definition.back = render(16, 16, true, seed, shape, features)
  definition.artSource = "procedural"
  definition.artVersion = Generator.VERSION
  definition.artFormat = nil
  definition.frontWidth, definition.frontHeight = nil, nil
  definition.backWidth, definition.backHeight = nil, nil
  definition.imagePipelineVersion = nil
  definition.imageProvider = nil
  definition.imageModel = nil
  definition.imageSeed = nil
  definition.imagePrompt = nil
  definition.imageAttemptProvider = nil
  definition.imageAttemptModel = nil
  definition.imageFallbackReason = nil
  definition.imageFallbackTransient = nil
  return definition
end

local function isImageArt(definition)
  return definition.artSource == "nim-image"
    or definition.artSource == "cloudflare-image"
end

function Generator.ensure(definition)
  if type(definition) ~= "table" then return false end
  -- Image-derived rows are already in the stable logical 0..3 format. A
  -- procedural renderer bump must never replace them during an offline load.
  if isImageArt(definition) and definition.artFormat == "rgb216a27-v1"
      and validImageRows(definition.front,
        tonumber(definition.frontWidth) or 0, tonumber(definition.frontHeight) or 0)
      and validImageRows(definition.back,
        tonumber(definition.backWidth) or 0, tonumber(definition.backHeight) or 0) then return false end
  if isImageArt(definition)
      and validRows(definition.front, 28, 28)
      and validRows(definition.back, 16, 16) then return false end
  -- Version-3 definitions predate explicit provenance. Mark them without
  -- redrawing so existing saves keep their exact pixels.
  if definition.artSource == nil and definition.artVersion == Generator.VERSION
      and validRows(definition.front, 28, 28)
      and validRows(definition.back, 16, 16) then
    definition.artSource = "procedural"
    return false
  end
  if definition.artVersion == Generator.VERSION
      and definition.artSource == "procedural"
      and validRows(definition.front, 28, 28)
      and validRows(definition.back, 16, 16) then return false end
  Generator.generate(definition)
  return true
end

Generator.validRows = validRows
Generator.validImageRows = validImageRows
Generator.isImageArt = isImageArt

return Generator
