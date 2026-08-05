local Learnset = {}

-- The metadata model only gets to choose moves that actually exist in the
-- Generation I data set. Keeping this list beside the mod also lets worker
-- validation reject invented move names before they reach a save file.
local MOVE_IDS = [[
ABSORB ACID ACID_ARMOR AGILITY AMNESIA AURORA_BEAM BARRAGE BARRIER BIDE BIND
BITE BLIZZARD BODY_SLAM BONEMERANG BONE_CLUB BUBBLE BUBBLEBEAM CLAMP
COMET_PUNCH CONFUSE_RAY CONFUSION CONSTRICT CONVERSION COUNTER CRABHAMMER CUT
DEFENSE_CURL DIG DISABLE DIZZY_PUNCH DOUBLESLAP DOUBLE_EDGE DOUBLE_KICK
DOUBLE_TEAM DRAGON_RAGE DREAM_EATER DRILL_PECK EARTHQUAKE EGG_BOMB EMBER
EXPLOSION FIRE_BLAST FIRE_PUNCH FIRE_SPIN FISSURE FLAMETHROWER FLASH FLY
FOCUS_ENERGY FURY_ATTACK FURY_SWIPES GLARE GROWL GROWTH GUILLOTINE GUST
HARDEN HAZE HEADBUTT HI_JUMP_KICK HORN_ATTACK HORN_DRILL HYDRO_PUMP HYPER_BEAM
HYPER_FANG HYPNOSIS ICE_BEAM ICE_PUNCH JUMP_KICK KARATE_CHOP KINESIS
LEECH_LIFE LEECH_SEED LEER LICK LIGHT_SCREEN LOVELY_KISS LOW_KICK MEDITATE
MEGA_DRAIN MEGA_KICK MEGA_PUNCH METRONOME MIMIC MINIMIZE MIRROR_MOVE MIST
NIGHT_SHADE PAY_DAY PECK PETAL_DANCE PIN_MISSILE POISONPOWDER POISON_GAS
POISON_STING POUND PSYBEAM PSYCHIC_M PSYWAVE QUICK_ATTACK RAGE RAZOR_LEAF
RAZOR_WIND RECOVER REFLECT REST ROAR ROCK_SLIDE ROCK_THROW ROLLING_KICK
SAND_ATTACK SCRATCH SCREECH SEISMIC_TOSS SELFDESTRUCT SHARPEN SING SKULL_BASH
SKY_ATTACK SLAM SLASH SLEEP_POWDER SLUDGE SMOG SMOKESCREEN SOFTBOILED
SOLARBEAM SONICBOOM SPIKE_CANNON SPLASH SPORE STOMP STRENGTH STRING_SHOT
STUN_SPORE SUBMISSION SUBSTITUTE SUPERSONIC SUPER_FANG SURF SWIFT SWORDS_DANCE
TACKLE TAIL_WHIP TAKE_DOWN TELEPORT THRASH THUNDER THUNDERBOLT THUNDERPUNCH
THUNDERSHOCK THUNDER_WAVE TOXIC TRANSFORM TRI_ATTACK TWINEEDLE VICEGRIP
VINE_WHIP WATERFALL WATER_GUN WHIRLWIND WING_ATTACK WITHDRAW WRAP
]]

Learnset.validMoves = {}
Learnset.moveIds = {}
for id in MOVE_IDS:gmatch("[A-Z0-9_]+") do
  Learnset.validMoves[id] = true
  Learnset.moveIds[#Learnset.moveIds + 1] = id
end

local TYPE_STARTERS = {
  NORMAL = "POUND", FIGHTING = "KARATE_CHOP", FLYING = "PECK",
  POISON = "POISON_STING", FIRE = "EMBER", WATER = "BUBBLE",
  GRASS = "ABSORB", ELECTRIC = "THUNDERSHOCK", PSYCHIC = "CONFUSION",
  PSYCHIC_TYPE = "CONFUSION", GROUND = "SAND_ATTACK", ROCK = "ROCK_THROW",
  BUG = "LEECH_LIFE", GHOST = "LICK",
}

local TYPE_PROGRESSIONS = {
  NORMAL = { "QUICK_ATTACK", "HEADBUTT", "BODY_SLAM", "HYPER_BEAM" },
  FIGHTING = { "LOW_KICK", "KARATE_CHOP", "SUBMISSION", "HI_JUMP_KICK" },
  FLYING = { "GUST", "WING_ATTACK", "DRILL_PECK", "SKY_ATTACK" },
  POISON = { "POISON_STING", "ACID", "SLUDGE", "TOXIC" },
  FIRE = { "EMBER", "FIRE_SPIN", "FLAMETHROWER", "FIRE_BLAST" },
  WATER = { "WATER_GUN", "BUBBLEBEAM", "SURF", "HYDRO_PUMP" },
  GRASS = { "ABSORB", "VINE_WHIP", "RAZOR_LEAF", "SOLARBEAM" },
  ELECTRIC = { "THUNDERSHOCK", "THUNDER_WAVE", "THUNDERBOLT", "THUNDER" },
  PSYCHIC = { "CONFUSION", "PSYBEAM", "PSYCHIC_M", "DREAM_EATER" },
  PSYCHIC_TYPE = { "CONFUSION", "PSYBEAM", "PSYCHIC_M", "DREAM_EATER" },
  ICE = { "MIST", "AURORA_BEAM", "ICE_BEAM", "BLIZZARD" },
  GROUND = { "SAND_ATTACK", "DIG", "BONE_CLUB", "EARTHQUAKE" },
  ROCK = { "ROCK_THROW", "DEFENSE_CURL", "ROCK_SLIDE", "HYPER_BEAM" },
  BUG = { "STRING_SHOT", "LEECH_LIFE", "TWINEEDLE", "PIN_MISSILE" },
  GHOST = { "LICK", "CONFUSE_RAY", "NIGHT_SHADE", "DREAM_EATER" },
  DRAGON = { "LEER", "DRAGON_RAGE", "SLAM", "HYPER_BEAM" },
}

local FALLBACK_LEVELS = { 9, 20, 34, 48 }

local function moveId(value)
  return tostring(value or ""):upper():gsub("[^A-Z0-9_]", "")
end

local function available(data, id)
  return Learnset.validMoves[id] and (not data or not data.moves or data.moves[id] ~= nil)
end

function Learnset.normalize(level1, rows, data)
  local starting, learned, seen = {}, {}, {}
  for _, value in ipairs(type(level1) == "table" and level1 or {}) do
    local id = moveId(value)
    if available(data, id) and not seen[id] then
      starting[#starting + 1], seen[id] = id, true
      if #starting == 4 then break end
    end
  end

  for _, row in ipairs(type(rows) == "table" and rows or {}) do
    local level = type(row) == "table" and tonumber(row.level)
    local id = type(row) == "table" and moveId(row.move) or ""
    if level and level >= 2 and level <= 100 and available(data, id) and not seen[id] then
      learned[#learned + 1] = { level = math.floor(level), move = id }
      seen[id] = true
      if #learned == 12 then break end
    end
  end
  table.sort(learned, function(a, b)
    if a.level == b.level then return a.move < b.move end
    return a.level < b.level
  end)
  return starting, learned, seen
end

function Learnset.resolve(definition, data, types)
  definition = type(definition) == "table" and definition or {}
  local starting, learned, seen = Learnset.normalize(
    definition.level1Moves, definition.learnset, data)

  if #starting == 0 then
    for _, id in ipairs({ "TACKLE", "GROWL" }) do
      if available(data, id) and not seen[id] then
        starting[#starting + 1], seen[id] = id, true
      end
    end
    for _, typeId in ipairs(types or definition.types or {}) do
      local id = TYPE_STARTERS[typeId]
      if id and available(data, id) and not seen[id] and #starting < 4 then
        starting[#starting + 1], seen[id] = id, true
      end
    end
  end

  -- Old saves and partially malformed model responses still receive a useful,
  -- type-aware progression. Valid authored rows always win and are preserved.
  if #learned < 4 then
    for _, typeId in ipairs(types or definition.types or {}) do
      for index, id in ipairs(TYPE_PROGRESSIONS[typeId] or {}) do
        if available(data, id) and not seen[id] then
          learned[#learned + 1] = { level = FALLBACK_LEVELS[index], move = id }
          seen[id] = true
        end
      end
    end
    for index, id in ipairs(TYPE_PROGRESSIONS.NORMAL) do
      if #learned >= 4 then break end
      if available(data, id) and not seen[id] then
        learned[#learned + 1] = { level = FALLBACK_LEVELS[index], move = id }
        seen[id] = true
      end
    end
    table.sort(learned, function(a, b)
      if a.level == b.level then return a.move < b.move end
      return a.level < b.level
    end)
  end
  return starting, learned
end

function Learnset.promptIds()
  return table.concat(Learnset.moveIds, ",")
end

return Learnset
