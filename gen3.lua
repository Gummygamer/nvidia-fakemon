-- FireRed / LeafGreen arm of NVIDIA Living Fakedex.
--
-- Gen 1 keeps a species as a record in `game.data.pokemon`.  Gen 3 keeps it as
-- numbered rows spread over the live `src.core.game3.pokemon` tables (names,
-- types, stats, species meta, learnsets, evolutions...).  The loader folds mod
-- registrations into those rows once, at boot, and then freezes the registry;
-- a creature that NIM invents later in the run is written into the same rows
-- here with the engine's own record writer (Schemas.gen3View.monWrite), so the
-- numbering, validation and conversions are the ones `mod.content.pokemon`
-- uses.
--
-- Species numbers: FireRed's table ends at 411 and 412 is SPECIES_EGG, so the
-- 256 Fakedex slots take 413..668.

local Gen3 = {}

Gen3.INDEX_BASE = 412
Gen3.AREA_KEYS = { "land", "grass", "water", "rocks", "fishing" }

-- Gen 1 move ids this mod prompts with that Gen 3 spells differently.
local MOVE_ALIASES = { PSYCHIC_M = "PSYCHIC" }

function Gen3.index(slotNumber)
  return Gen3.INDEX_BASE + slotNumber
end

local function pokemonModule()
  local ok, module = pcall(require, "src.core.game3.pokemon")
  return ok and module or nil
end

-- The table the loader wrote registrations into; the module itself otherwise.
local function target(game)
  local root = game and game.data and game.data.gen3Pokemon
  if type(root) == "table" then return root end
  return pokemonModule()
end

local function schemas()
  local ok, module = pcall(require, "src.mods.Schemas")
  return ok and module and module.gen3View or nil
end

-- ------- records

local function baseRecord(slot, index)
  return {
    id = slot, index = index,
    abilities = {},
    catchRate = 120, baseExp = 100, growthRate = "MEDIUM_FAST",
    genderRatio = 127, eggCycles = 20, friendship = 70,
    -- UNDISCOVERED: a generated creature never breeds.
    eggGroups = { 15, 15 },
    tmhm = {}, evolutions = {},
  }
end

local function stats(six)
  return {
    hp = six.hp, attack = six.attack, defense = six.defense, speed = six.speed,
    specialAttack = six.specialAttack, specialDefense = six.specialDefense,
  }
end

function Gen3.placeholder(slot, index, front, back)
  local record = baseRecord(slot, index)
  record.name = "FAKE" .. slot:match("(%d+)$")
  record.types = { "NORMAL" }
  record.baseStats = stats({ hp = 60, attack = 60, defense = 60, speed = 60,
    specialAttack = 60, specialDefense = 60 })
  record.learnset = { { level = 1, move = "TACKLE" }, { level = 1, move = "GROWL" } }
  record.spriteFront, record.spriteBack = front, back
  return record
end

-- A move the running game actually has, spelled the way Gen 3 spells it.
function Gen3.moveChecker(game)
  local view = schemas()
  local movesBase = game and game.data and game.data.gen3Moves
  if not movesBase then
    local ok, moves = pcall(require, "src.core.game3.battle.moves")
    movesBase = ok and moves or nil
  end
  local function exists(id)
    if not (view and movesBase and view.moveNum) then return nil end
    local ok, num = pcall(view.moveNum, movesBase, id)
    return ok and tonumber(num) or nil
  end
  -- When the name index cannot be read at all, accept the mod's own vetted
  -- list rather than giving every creature an empty moveset.
  local indexed = exists("TACKLE") ~= nil
  return function(id)
    id = MOVE_ALIASES[id] or id
    if not indexed then return id end
    return exists(id) and id or nil
  end
end

-- Gen 1 stores one Special stat; Gen 3 splits it.
function Gen3.baseStats(raw)
  local special = raw.special or raw.specialAttack or 60
  return stats({
    hp = raw.hp, attack = raw.attack, defense = raw.defense, speed = raw.speed,
    specialAttack = raw.specialAttack or special,
    specialDefense = raw.specialDefense or special,
  })
end

-- level1: ordered start moves; learned: { level, move } rows.
function Gen3.learnset(level1, learned, resolveMove)
  local rows, seen = {}, {}
  for _, id in ipairs(level1 or {}) do
    local move = resolveMove(id)
    if move and not seen[move] then
      rows[#rows + 1], seen[move] = { level = 1, move = move }, true
    end
  end
  for _, row in ipairs(learned or {}) do
    local move = resolveMove(row.move)
    if move and not seen[move] then
      rows[#rows + 1], seen[move] = { level = row.level, move = move }, true
    end
  end
  if #rows == 0 then rows[1] = { level = 1, move = "TACKLE" } end
  return rows
end

-- Writes one record into the live species rows.
function Gen3.write(game, record)
  local view = schemas()
  local live = target(game)
  if not (view and view.monWrite and live) then
    return nil, "this build has no Gen 3 species writer"
  end
  local ok, err = pcall(view.monWrite, live, {
    ops = { [record.id] = true },
    get = function(_, id) return id == record.id and record or nil end,
  })
  if not ok then return nil, tostring(err) end
  return true
end

-- ------- icons

local iconEntries = {}

local function iconEntry(frontPath)
  local SpriteWriter = require("mods.nvidia_fakemon.sprite_writer")
  local data = SpriteWriter.iconImageData(frontPath)
  if not (data and love.graphics and love.graphics.newImage) then return nil end
  local image = love.graphics.newImage(data)
  if image.setFilter then image:setFilter("nearest", "nearest") end
  return {
    image = image, w = 32, h = 32, sheetH = 32, frames = 1,
    quads = { [0] = love.graphics.newQuad(0, 0, 32, 32, 32, 32) },
  }
end

-- Party and box icons come from the ROM's per-species icon sheets, which a
-- generated creature has none of; hand the module a sheet of the same shape.
function Gen3.setIcon(index, frontPath)
  local P = pokemonModule()
  if not (P and P._icons) then return end
  local entry = iconEntries[index]
  if not entry or entry.path ~= frontPath then
    local built = iconEntry(frontPath)
    entry = built and { icon = built, path = frontPath } or nil
    iconEntries[index] = entry
  end
  if entry then P._icons[index] = entry.icon end
end

function Gen3.clearIcon(index)
  iconEntries[index] = nil
  local P = pokemonModule()
  if P and P._icons then P._icons[index] = nil end
end

-- Icons live in a cache the engine may rebuild; put back any that went missing.
function Gen3.reseedIcons()
  local P = pokemonModule()
  if not (P and P._icons) then return end
  for index, entry in pairs(iconEntries) do
    if P._icons[index] == nil then P._icons[index] = entry.icon end
  end
end

-- ------- names and maps

-- Every ROM species name, for "do not reuse an existing name".
function Gen3.vanillaNames(game)
  local live = target(game)
  local names = {}
  local table_ = live and (rawget(live, "_names") or rawget(live, "names"))
  for number, name in pairs(type(table_) == "table" and table_ or {}) do
    if type(number) == "number" and number <= Gen3.INDEX_BASE
        and type(name) == "string" and name ~= "" then
      names[#names + 1] = name
    end
  end
  return names
end

function Gen3.mapId()
  local Collision = package.loaded["src.core.game3.collision"]
  return Collision and Collision._mapId or nil
end

local function areaHasSlots(area)
  if type(area) ~= "table" then return false end
  local slots = area.slots or area.mons or (#area > 0 and area) or nil
  return type(slots) == "table" and #slots > 0
end

-- A map is worth generating for when it has any wild table.
function Gen3.eligible(mapId)
  if not mapId then return false end
  local ok, Encounters = pcall(require, "src.core.game3.encounters")
  if not (ok and Encounters) then return false end
  if Encounters.ensureLoaded then pcall(Encounters.ensureLoaded) end
  local tables = rawget(Encounters, "_tables")
  local entry = type(tables) == "table" and tables[mapId] or nil
  if type(entry) ~= "table" then return false end
  for _, key in ipairs(Gen3.AREA_KEYS) do
    if areaHasSlots(entry[key]) then return true end
  end
  return false
end

return Gen3
