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

-- ---------------------------------------------------------------------------
-- Framing for the FireRed / LeafGreen pictures.
--
-- The stored 112x112 master was fitted to its frame by the size of the whole
-- foreground, so one stray fleck far from the creature (a label, a spark, a
-- stray line left by the image model) shrinks the creature and pushes it off
-- centre -- and the source image that produced it is not kept, so it cannot be
-- converted again.  This works from the master instead: it finds the pieces of
-- ink, drops the specks, and fits what is left to the frame, so the creatures
-- already in a save are framed the same way new ones are.
-- ---------------------------------------------------------------------------

SpriteWriter.FRAMING_VERSION = 1
local SPECK_FRACTION = 0.04    -- of the main body's area
local MERGE_GAP = 3            -- pieces this close are one creature

local function decodeGrid(rows, width, height)
  local R, G, B, A = {}, {}, {}, {}
  for y = 0, height - 1 do
    local row = tostring(rows[y + 1] or "")
    for x = 0, width - 1 do
      local r, g, b, a = decodeColor(row:sub(x * 2 + 1, x * 2 + 2))
      local i = y * width + x + 1
      R[i], G[i], B[i], A[i] = r, g, b, a
    end
  end
  return R, G, B, A
end

-- Drop the pieces of ink that are not the creature: anything small and apart
-- from the main body.  Returns the bounds of what is kept, or nil if nothing is.
local function dropSpecks(A, width, height)
  local label, pieces = {}, {}
  for start = 1, width * height do
    if A[start] > 0 and not label[start] then
      local id = #pieces + 1
      local queue, head, tail = { start }, 1, 1
      label[start] = id
      local piece = { id = id, area = 0, minX = width, minY = height, maxX = -1, maxY = -1 }
      while head <= tail do
        local index = queue[head]
        head = head + 1
        local x, y = (index - 1) % width, math.floor((index - 1) / width)
        piece.area = piece.area + 1
        if x < piece.minX then piece.minX = x end
        if x > piece.maxX then piece.maxX = x end
        if y < piece.minY then piece.minY = y end
        if y > piece.maxY then piece.maxY = y end
        for dy = -MERGE_GAP, MERGE_GAP do
          local ny = y + dy
          if ny >= 0 and ny < height then
            for dx = -MERGE_GAP, MERGE_GAP do
              local nx = x + dx
              if nx >= 0 and nx < width then
                local neighbour = ny * width + nx + 1
                if A[neighbour] > 0 and not label[neighbour] then
                  label[neighbour] = id
                  tail = tail + 1
                  queue[tail] = neighbour
                end
              end
            end
          end
        end
      end
      pieces[id] = piece
    end
  end
  if #pieces == 0 then return nil end
  local main = pieces[1]
  for _, piece in ipairs(pieces) do
    if piece.area > main.area then main = piece end
  end
  local keep = {}
  for _, piece in ipairs(pieces) do
    keep[piece.id] = piece == main
      or piece.area >= main.area * SPECK_FRACTION
      or (piece.minX >= main.minX - 2 and piece.maxX <= main.maxX + 2
        and piece.minY >= main.minY - 2 and piece.maxY <= main.maxY + 2)
  end
  local minX, minY, maxX, maxY = width, height, -1, -1
  for index = 1, width * height do
    local id = label[index]
    if id and not keep[id] then
      A[index] = 0
    elseif id then
      local x, y = (index - 1) % width, math.floor((index - 1) / width)
      if x < minX then minX = x end
      if x > maxX then maxX = x end
      if y < minY then minY = y end
      if y > maxY then maxY = y end
    end
  end
  if maxX < 0 then return nil end
  return minX, minY, maxX, maxY
end

-- Render a master into an outWidth x outHeight picture: specks removed, the
-- creature scaled to fit with `pad` clear pixels all round and centred.
local function drawFramed(rows, sourceWidth, sourceHeight, outWidth, outHeight, pad, outPath)
  if not (love and love.image and love.image.newImageData and love.filesystem) then
    return nil, "sprite rendering needs LOVE image and filesystem modules"
  end
  love.filesystem.createDirectory(SpriteWriter.ROOT)
  local R, G, B, A = decodeGrid(rows, sourceWidth, sourceHeight)
  local minX, minY, maxX, maxY = dropSpecks(A, sourceWidth, sourceHeight)
  if not minX then return nil, "sprite art is empty" end
  local boundWidth, boundHeight = maxX - minX + 1, maxY - minY + 1
  local scale = math.min((outWidth - pad * 2) / boundWidth, (outHeight - pad * 2) / boundHeight)
  local renderedWidth, renderedHeight = boundWidth * scale, boundHeight * scale
  local startX, startY = (outWidth - renderedWidth) / 2, (outHeight - renderedHeight) / 2
  local image = love.image.newImageData(outWidth, outHeight)
  for y = 0, outHeight - 1 do
    for x = 0, outWidth - 1 do
      local dx0, dy0 = math.max(x, startX), math.max(y, startY)
      local dx1 = math.min(x + 1, startX + renderedWidth)
      local dy1 = math.min(y + 1, startY + renderedHeight)
      local red, green, blue, ink, area = 0, 0, 0, 0, 0
      if dx1 > dx0 and dy1 > dy0 then
        local sx0, sy0 = minX + (dx0 - startX) / scale, minY + (dy0 - startY) / scale
        local sx1, sy1 = minX + (dx1 - startX) / scale, minY + (dy1 - startY) / scale
        area = (sx1 - sx0) * (sy1 - sy0)
        for sy = math.floor(sy0), math.ceil(sy1) - 1 do
          if sy >= 0 and sy < sourceHeight then
            local overlapY = math.max(0, math.min(sy1, sy + 1) - math.max(sy0, sy))
            for sx = math.floor(sx0), math.ceil(sx1) - 1 do
              if sx >= 0 and sx < sourceWidth then
                local overlapX = math.max(0, math.min(sx1, sx + 1) - math.max(sx0, sx))
                local weight = overlapX * overlapY
                local i = sy * sourceWidth + sx + 1
                if weight > 0 and A[i] > 0 then
                  ink = ink + weight
                  red, green, blue = red + R[i] * weight, green + G[i] * weight,
                    blue + B[i] * weight
                end
              end
            end
          end
        end
      end
      local coverage = area > 0 and ink / area or 0
      if coverage >= 0.3 then
        image:setPixel(x, y, red / ink, green / ink, blue / ink,
          coverage >= 0.6 and 1 or 0.5)
      else
        image:setPixel(x, y, 1, 1, 1, 0)
      end
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
  -- a new framing must not be served the pictures an older one cached
  mix("framing" .. SpriteWriter.FRAMING_VERSION)
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
      _, err = drawFramed(definition.front, tonumber(definition.frontWidth),
        tonumber(definition.frontHeight), 64, 64, 3, frontPath)
    else
      _, err = draw(definition.front, 28, 28, 2, frontPath)
    end
    if err then return nil, nil, err end
  end
  if force or not fs.getInfo(backPath) then
    local _, err
    if SpriteWriter.isHighResolution(definition) then
      _, err = drawFramed(definition.back, tonumber(definition.backWidth),
        tonumber(definition.backHeight), 64, 64, 3, backPath)
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
