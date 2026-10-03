local SpriteWriter = {}

SpriteWriter.ROOT = "nvidia_fakemon"

local SHADES = {
  -- Zero is empty canvas, not the lightest ink. Keeping its RGB channels
  -- white avoids dark fringes if a renderer samples outside opaque pixels,
  -- while alpha makes the battle scene show through the sprite sheet.
  ["0"] = { 1.00, 1.00, 1.00, 0 },
  ["1"] = { 0.67, 0.67, 0.67, 1 },
  ["2"] = { 0.33, 0.33, 0.33, 1 },
  ["3"] = { 0.00, 0.00, 0.00, 1 },
}

local function decodeColor(code)
  local value = tonumber(code, 16)
  if not value or value == 0 then return 1, 1, 1, 0 end
  if value <= 216 then
    local color = value - 1
    local r = math.floor(color / 36)
    local g = math.floor(color / 6) % 6
    local b = color % 6
    return r / 5, g / 5, b / 5, 1
  end
  local color = value - 217
  local r = math.floor(color / 9)
  local g = math.floor(color / 3) % 3
  local b = color % 3
  return r / 2, g / 2, b / 2, 0.5
end

local function path(slot, side)
  return ("%s/%s_%s.png"):format(SpriteWriter.ROOT, slot:lower(), side)
end


local function highPath(slot, side)
  return ("%s/%s_%s_hd.png"):format(SpriteWriter.ROOT, slot:lower(), side)
end

function SpriteWriter.paths(slot)
  return path(slot, "front"), path(slot, "back")
end


function SpriteWriter.battlePaths(slot)
  return highPath(slot, "front"), highPath(slot, "back")
end

local function draw(rows, logicalWidth, logicalHeight, scale, outPath)
  if not (love and love.image and love.image.newImageData and love.filesystem) then
    return nil, "sprite rendering needs LOVE image and filesystem modules"
  end
  love.filesystem.createDirectory(SpriteWriter.ROOT)
  local image = love.image.newImageData(logicalWidth * scale, logicalHeight * scale)
  for y = 0, logicalHeight - 1 do
    local row = tostring(rows[y + 1] or "")
    for x = 0, logicalWidth - 1 do
      local color = SHADES[row:sub(x + 1, x + 1)] or SHADES["0"]
      for oy = 0, scale - 1 do
        for ox = 0, scale - 1 do
          image:setPixel(x * scale + ox, y * scale + oy,
            color[1], color[2], color[3], color[4])
        end
      end
    end
  end
  local ok, err = pcall(image.encode, image, "png", outPath)
  if not ok then return nil, tostring(err) end
  return outPath
end

local function drawColor(rows, sourceWidth, sourceHeight, outWidth, outHeight, outPath)
  if not (love and love.image and love.image.newImageData and love.filesystem) then
    return nil, "sprite rendering needs LOVE image and filesystem modules"
  end
  love.filesystem.createDirectory(SpriteWriter.ROOT)
  local image = love.image.newImageData(outWidth, outHeight)
  for y = 0, outHeight - 1 do
    local sy = math.min(sourceHeight - 1,
      math.floor((y + 0.5) * sourceHeight / outHeight))
    local row = tostring(rows[sy + 1] or "")
    for x = 0, outWidth - 1 do
      local sx = math.min(sourceWidth - 1,
        math.floor((x + 0.5) * sourceWidth / outWidth))
      local code = row:sub(sx * 2 + 1, sx * 2 + 2)
      image:setPixel(x, y, decodeColor(code))
    end
  end
  local ok, err = pcall(image.encode, image, "png", outPath)
  if not ok then return nil, tostring(err) end
  return outPath
end

function SpriteWriter.isHighResolution(definition)
  return type(definition) == "table" and definition.artFormat == "rgb216a27-v1"
    and tonumber(definition.frontWidth) and tonumber(definition.frontHeight)
    and tonumber(definition.backWidth) and tonumber(definition.backHeight)
end

function SpriteWriter.ensure(slot, definition, force)
  local frontPath, backPath = SpriteWriter.paths(slot)
  local fs = love and love.filesystem
  if not fs then return nil, nil, "sprite persistence needs LOVE filesystem" end
  if SpriteWriter.isHighResolution(definition) then
    local fw, fh = tonumber(definition.frontWidth), tonumber(definition.frontHeight)
    local bw, bh = tonumber(definition.backWidth), tonumber(definition.backHeight)
    local hdFront, hdBack = SpriteWriter.battlePaths(slot)
    if force or not fs.getInfo(frontPath) then
      local _, err = drawColor(definition.front, fw, fh, 56, 56, frontPath)
      if err then return nil, nil, err end
    end
    if force or not fs.getInfo(backPath) then
      local _, err = drawColor(definition.back, bw, bh, 32, 32, backPath)
      if err then return nil, nil, err end
    end
    if force or not fs.getInfo(hdFront) then
      local _, err = drawColor(definition.front, fw, fh, fw, fh, hdFront)
      if err then return nil, nil, err end
    end
    if force or not fs.getInfo(hdBack) then
      local _, err = drawColor(definition.back, bw, bh, bw, bh, hdBack)
      if err then return nil, nil, err end
    end
  else
    if force or not fs.getInfo(frontPath) then
      local _, err = draw(definition.front, 28, 28, 2, frontPath)
      if err then return nil, nil, err end
    end
    if force or not fs.getInfo(backPath) then
      local _, err = draw(definition.back, 16, 16, 2, backPath)
      if err then return nil, nil, err end
    end
  end
  return frontPath, backPath
end

-- FireRed / LeafGreen battle pictures are 64x64 and the engine centres, never
-- scales, any other size, so this renders both views at exactly that size.
-- The file name carries a hash of the art: the engine caches decoded images by
-- path, and a slot that is regenerated (a new game) must not be served the
-- previous creature's picture.
local function artTag(definition)
  local hash = 0
  local function mix(value)
    value = tostring(value or "")
    for index = 1, #value do
      hash = (hash * 131 + value:byte(index)) % 2147483647
    end
  end
  mix(definition.name)
  for _, row in ipairs(definition.front or {}) do mix(row) end
  for _, row in ipairs(definition.back or {}) do mix(row) end
  return ("%08x"):format(hash)
end

function SpriteWriter.gen3Paths(slot, definition)
  local tag = artTag(definition)
  return ("%s/%s_g3_%s_front.png"):format(SpriteWriter.ROOT, slot:lower(), tag),
    ("%s/%s_g3_%s_back.png"):format(SpriteWriter.ROOT, slot:lower(), tag)
end

function SpriteWriter.ensureGen3(slot, definition, force)
  local fs = love and love.filesystem
  if not fs then return nil, nil, "sprite persistence needs LOVE filesystem" end
  local frontPath, backPath = SpriteWriter.gen3Paths(slot, definition)
  if force or not fs.getInfo(frontPath) then
    local _, err
    if SpriteWriter.isHighResolution(definition) then
      _, err = drawColor(definition.front, tonumber(definition.frontWidth),
        tonumber(definition.frontHeight), 64, 64, frontPath)
    else
      _, err = draw(definition.front, 28, 28, 2, frontPath)
    end
    if err then return nil, nil, err end
  end
  if force or not fs.getInfo(backPath) then
    local _, err
    if SpriteWriter.isHighResolution(definition) then
      _, err = drawColor(definition.back, tonumber(definition.backWidth),
        tonumber(definition.backHeight), 64, 64, backPath)
    else
      _, err = draw(definition.back, 16, 16, 4, backPath)
    end
    if err then return nil, nil, err end
  end
  return frontPath, backPath
end

-- A 32x32 party/box icon sampled from the front picture. Returns ImageData.
function SpriteWriter.iconImageData(frontPath)
  if not (love and love.image and love.image.newImageData) then return nil end
  local ok, source = pcall(love.image.newImageData, frontPath)
  if not ok or not source then return nil end
  local sw, sh = source:getDimensions()
  local icon = love.image.newImageData(32, 32)
  for y = 0, 31 do
    for x = 0, 31 do
      icon:setPixel(x, y, source:getPixel(
        math.min(sw - 1, math.floor((x + 0.5) * sw / 32)),
        math.min(sh - 1, math.floor((y + 0.5) * sh / 32))))
    end
  end
  return icon
end

function SpriteWriter.clear()
  local fs = love and love.filesystem
  if not (fs and fs.getDirectoryItems and fs.remove) then return end
  local ok, items = pcall(fs.getDirectoryItems, SpriteWriter.ROOT)
  if ok and type(items) == "table" then
    for _, name in ipairs(items) do
      if name:match("^nvidia_fake_%d%d%d_[%w_]+%.png$") then
        pcall(fs.remove, SpriteWriter.ROOT .. "/" .. name)
      end
    end
  end
  pcall(fs.remove, SpriteWriter.ROOT)
end

return SpriteWriter
