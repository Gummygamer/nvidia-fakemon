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

function SpriteWriter.clear()
  local fs = love and love.filesystem
  if not (fs and fs.getDirectoryItems and fs.remove) then return end
  local ok, items = pcall(fs.getDirectoryItems, SpriteWriter.ROOT)
  if ok and type(items) == "table" then
    for _, name in ipairs(items) do
      if name:match("^nvidia_fake_%d%d%d_[a-z_]+%.png$") then
        pcall(fs.remove, SpriteWriter.ROOT .. "/" .. name)
      end
    end
  end
  pcall(fs.remove, SpriteWriter.ROOT)
end

return SpriteWriter
