local SpriteGenerator = require("mods.nvidia_fakemon.sprite_generator")

local Converter = {}

Converter.VERSION = 2
Converter.DEFAULT_BACKGROUND_THRESHOLD = 0.22
Converter.MAX_SOURCE_DIMENSION = 2048
Converter.ART_FORMAT = "rgb216a27-v1"
Converter.FRONT_WIDTH = 112
Converter.FRONT_HEIGHT = 112
Converter.BACK_WIDTH = 112
Converter.BACK_HEIGHT = 112

local HEX = "0123456789abcdef"

local okFfi, ffi = pcall(require, "ffi")

local function buffers(size)
  if okFfi then
    return ffi.new("uint8_t[?]", size), ffi.new("int32_t[?]", size)
  end
  return {}, {}
end

local function valueAt(values, index)
  if okFfi then return values[index] end
  return values[index + 1] or 0
end

local function setValue(values, index, value)
  if okFfi then values[index] = value else values[index + 1] = value end
end

local function dimensions(image)
  if not (image and image.getDimensions and image.getPixel) then
    return nil, nil, "decoded image does not expose pixels"
  end
  local ok, width, height = pcall(image.getDimensions, image)
  if not ok then return nil, nil, "could not inspect decoded image" end
  width, height = tonumber(width), tonumber(height)
  if not width or not height or width < 64 or height < 64
      or width > Converter.MAX_SOURCE_DIMENSION or height > Converter.MAX_SOURCE_DIMENSION then
    return nil, nil, "image dimensions must be between 64 and "
      .. Converter.MAX_SOURCE_DIMENSION .. " pixels"
  end
  return math.floor(width), math.floor(height)
end

local function segment(image, region, threshold)
  local width, height = region.width, region.height
  local total = width * height
  local background, queue = buffers(total)
  local head, tail = 0, 0
  local thresholdSquared = threshold * threshold

  local function qualifies(index)
    local x, y = index % width, math.floor(index / width)
    local ok, r, g, b, a = pcall(image.getPixel, image, region.x + x, region.y + y)
    if not ok then return false end
    r, g, b, a = tonumber(r) or 0, tonumber(g) or 0, tonumber(b) or 0, tonumber(a) or 1
    if a < 0.5 then return true end
    local dr, dg, db = 1 - r, 1 - g, 1 - b
    return dr * dr + dg * dg + db * db <= thresholdSquared
  end

  local function enqueue(index)
    if valueAt(background, index) ~= 0 or not qualifies(index) then return end
    setValue(background, index, 1)
    setValue(queue, tail, index)
    tail = tail + 1
  end

  for x = 0, width - 1 do
    enqueue(x)
    enqueue((height - 1) * width + x)
  end
  for y = 1, height - 2 do
    enqueue(y * width)
    enqueue(y * width + width - 1)
  end

  while head < tail do
    local index = valueAt(queue, head)
    head = head + 1
    local x = index % width
    if x > 0 then enqueue(index - 1) end
    if x + 1 < width then enqueue(index + 1) end
    if index >= width then enqueue(index - width) end
    if index + width < total then enqueue(index + width) end
  end

  local minX, minY, maxX, maxY = width, height, -1, -1
  local foreground = 0
  for index = 0, total - 1 do
    if valueAt(background, index) == 0 then
      local x, y = index % width, math.floor(index / width)
      minX, minY = math.min(minX, x), math.min(minY, y)
      maxX, maxY = math.max(maxX, x), math.max(maxY, y)
      foreground = foreground + 1
    end
  end
  if foreground < total * 0.002 then return nil, "no usable creature silhouette was found" end
  if foreground > total * 0.92 then return nil, "background removal left an unreasonable foreground area" end

  return {
    background = background, region = region,
    minX = minX, minY = minY, maxX = maxX, maxY = maxY,
  }
end

local function sourcePixel(image, segmented, x, y)
  local width = segmented.region.width
  local index = y * width + x
  if valueAt(segmented.background, index) ~= 0 then return nil end
  local r, g, b, a = image:getPixel(segmented.region.x + x, segmented.region.y + y)
  if tonumber(a) and a < 0.5 then return nil end
  return tonumber(r) or 0, tonumber(g) or 0, tonumber(b) or 0
end

-- Compact, JSON-safe true-color storage. 00 is transparent; 01..d8 encode
-- a 6x6x6 opaque cube and d9..f3 encode a 3x3x3 half-alpha edge cube. This
-- preserves 216 body colors plus smooth silhouettes without embedding the
-- remote bytes in a save or expanding every pixel to an RGB string.
local function encodePixel(r, g, b, coverage)
  local function channel(value, levels)
    return math.max(0, math.min(levels - 1,
      math.floor(value * (levels - 1) + 0.5)))
  end
  local value
  if coverage >= 0.67 then
    value = 1 + channel(r, 6) * 36 + channel(g, 6) * 6 + channel(b, 6)
  else
    value = 217 + channel(r, 3) * 9 + channel(g, 3) * 3 + channel(b, 3)
  end
  return HEX:sub(math.floor(value / 16) + 1, math.floor(value / 16) + 1)
    .. HEX:sub(value % 16 + 1, value % 16 + 1)
end

local function quantize(image, segmented, outWidth, outHeight, opts)
  local boundWidth = segmented.maxX - segmented.minX + 1
  local boundHeight = segmented.maxY - segmented.minY + 1
  local margin = math.max(1, math.ceil(math.max(boundWidth, boundHeight) * (opts.margin or 0.04)))
  local cropMinX = math.max(0, segmented.minX - margin)
  local cropMinY = math.max(0, segmented.minY - margin)
  local cropMaxX = math.min(segmented.region.width - 1, segmented.maxX + margin)
  local cropMaxY = math.min(segmented.region.height - 1, segmented.maxY + margin)
  local cropWidth, cropHeight = cropMaxX - cropMinX + 1, cropMaxY - cropMinY + 1
  local padding = tonumber(opts.padding) or (outWidth >= 96 and 4 or 2)
  local availableWidth, availableHeight = outWidth - padding * 2, outHeight - padding * 2
  local scale = math.min(availableWidth / cropWidth, availableHeight / cropHeight)
  local renderedWidth, renderedHeight = cropWidth * scale, cropHeight * scale
  local startX, startY = (outWidth - renderedWidth) / 2, (outHeight - renderedHeight) / 2
  local pixels = {}
  for y = 0, outHeight - 1 do
    pixels[y + 1] = {}
    for x = 0, outWidth - 1 do
      local dx0, dy0 = math.max(x, startX), math.max(y, startY)
      local dx1, dy1 = math.min(x + 1, startX + renderedWidth), math.min(y + 1, startY + renderedHeight)
      local encoded = "00"
      if dx1 > dx0 and dy1 > dy0 then
        local sx0 = cropMinX + (dx0 - startX) / scale
        local sy0 = cropMinY + (dy0 - startY) / scale
        local sx1 = cropMinX + (dx1 - startX) / scale
        local sy1 = cropMinY + (dy1 - startY) / scale
        local covered, red, green, blue = 0, 0, 0, 0
        local area = (sx1 - sx0) * (sy1 - sy0)
        for sy = math.floor(sy0), math.ceil(sy1) - 1 do
          if sy >= 0 and sy < segmented.region.height then
            local overlapY = math.max(0, math.min(sy1, sy + 1) - math.max(sy0, sy))
            for sx = math.floor(sx0), math.ceil(sx1) - 1 do
              if sx >= 0 and sx < segmented.region.width then
                local overlapX = math.max(0, math.min(sx1, sx + 1) - math.max(sx0, sx))
                local weight = overlapX * overlapY
                if weight > 0 then
                  local r, g, b = sourcePixel(image, segmented, sx, sy)
                  if r then
                    covered = covered + weight
                    red, green, blue = red + r * weight, green + g * weight, blue + b * weight
                  end
                end
              end
            end
          end
        end
        if area > 0 and covered / area >= (opts.coverageThreshold or 0.16) then
          encoded = encodePixel(red / covered, green / covered, blue / covered,
            covered / area)
        end
      end
      pixels[y + 1][x + 1] = encoded
    end
  end

  local rows = {}
  local opaque = 0
  for y = 1, outHeight do
    rows[y] = {}
    for x = 1, outWidth do
      local value = pixels[y][x]
      if value ~= "00" then opaque = opaque + 1 end
      rows[y][x] = value
    end
    rows[y] = table.concat(rows[y])
  end
  if opaque == 0 then return nil, "source art disappeared during sprite reduction" end
  return rows
end

function Converter.convertImage(image, opts)
  opts = opts or {}
  local width, height, dimErr = dimensions(image)
  if not width then return nil, dimErr end
  local split = math.floor(width / 2)
  if split < 32 or width - split < 32 then return nil, "two-view image is too narrow" end
  local threshold = tonumber(opts.backgroundThreshold) or Converter.DEFAULT_BACKGROUND_THRESHOLD
  threshold = math.max(0.03, math.min(0.6, threshold))
  local frontMask, frontErr = segment(image, { x = 0, y = 0, width = split, height = height }, threshold)
  if not frontMask then return nil, "front view: " .. frontErr end
  local backMask, backErr = segment(image,
    { x = split, y = 0, width = width - split, height = height }, threshold)
  if not backMask then return nil, "back view: " .. backErr end
  local front, frontQuantizeErr = quantize(image, frontMask,
    Converter.FRONT_WIDTH, Converter.FRONT_HEIGHT, opts)
  if not front then return nil, "front view: " .. frontQuantizeErr end
  local back, backQuantizeErr = quantize(image, backMask,
    Converter.BACK_WIDTH, Converter.BACK_HEIGHT, opts)
  if not back then return nil, "back view: " .. backQuantizeErr end
  if not SpriteGenerator.validImageRows(front, Converter.FRONT_WIDTH, Converter.FRONT_HEIGHT)
      or not SpriteGenerator.validImageRows(back, Converter.BACK_WIDTH, Converter.BACK_HEIGHT) then
    return nil, "converted sprite rows failed validation"
  end
  return {
    front = front, back = back, artFormat = Converter.ART_FORMAT,
    frontWidth = Converter.FRONT_WIDTH, frontHeight = Converter.FRONT_HEIGHT,
    backWidth = Converter.BACK_WIDTH, backHeight = Converter.BACK_HEIGHT,
  }
end

function Converter.decodeImage(bytes, extension)
  if type(bytes) ~= "string" or bytes == "" then return nil, "source image bytes are empty" end
  if not (love and love.filesystem and love.filesystem.newFileData
      and love.image and love.image.newImageData) then
    return nil, "image conversion needs LOVE filesystem and image support"
  end
  local function be16(offset)
    local a, b = bytes:byte(offset, offset + 1)
    return a and b and a * 256 + b or nil
  end
  local function be32(offset)
    local a, b, c, d = bytes:byte(offset, offset + 3)
    return a and d and ((a * 256 + b) * 256 + c) * 256 + d or nil
  end
  local sourceWidth, sourceHeight
  if extension == "png" then
    sourceWidth, sourceHeight = be32(17), be32(21)
  elseif extension == "jpg" then
    local index, limit = 3, math.min(#bytes - 8, 1024 * 1024)
    local sof = {
      [0xc0] = true, [0xc1] = true, [0xc2] = true, [0xc3] = true,
      [0xc5] = true, [0xc6] = true, [0xc7] = true,
      [0xc9] = true, [0xca] = true, [0xcb] = true,
      [0xcd] = true, [0xce] = true, [0xcf] = true,
    }
    while index <= limit do
      if bytes:byte(index) ~= 0xff then index = index + 1 else
        while bytes:byte(index + 1) == 0xff do index = index + 1 end
        local marker = bytes:byte(index + 1)
        if sof[marker] then
          sourceHeight, sourceWidth = be16(index + 5), be16(index + 7)
          break
        end
        if marker == 0xd9 or marker == 0xda then break end
        if marker == 0x01 or marker and marker >= 0xd0 and marker <= 0xd8 then
          index = index + 2
        else
          local length = be16(index + 2)
          if not length or length < 2 then break end
          index = index + 2 + length
        end
      end
    end
  end
  if not sourceWidth or not sourceHeight or sourceWidth < 64 or sourceHeight < 64
      or sourceWidth > Converter.MAX_SOURCE_DIMENSION
      or sourceHeight > Converter.MAX_SOURCE_DIMENSION then
    return nil, "source image header has unreasonable dimensions"
  end
  local okFile, fileData = pcall(love.filesystem.newFileData, bytes,
    "nvidia_fakemon_source." .. tostring(extension or "png"))
  if not okFile or not fileData then return nil, "could not stage source image in memory" end
  local okImage, image = pcall(love.image.newImageData, fileData)
  if not okImage or not image then return nil, "generated source image could not be decoded" end
  return image
end

function Converter.convertBytes(bytes, extension, opts)
  local image, err = Converter.decodeImage(bytes, extension)
  if not image then return nil, err end
  return Converter.convertImage(image, opts)
end

return Converter
