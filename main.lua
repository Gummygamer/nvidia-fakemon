local Client = require("mods.nvidia_fakemon.fakemon_client")
local Json = require("src.link.Json")
local SpriteGenerator = require("mods.nvidia_fakemon.sprite_generator")
local SpriteWriter = require("mods.nvidia_fakemon.sprite_writer")
local Learnset = require("mods.nvidia_fakemon.learnset")
local Gen3 = require("mods.nvidia_fakemon.gen3")
local GameVersion = require("src.core.GameVersion")

local MAX_FAKEMON = 256
local DEX_OFFSET = 151
local STATE_VERSION = 1
local FAKEMON_PER_MAP = 2
local REUSED_PER_MAP = 2
local STARTER_MAPS = { OAKS_LAB = true }

local ICONS = {
  FLYING = "BIRD", WATER = "WATER", BUG = "BUG", GRASS = "GRASS",
  GHOST = "FAIRY", DRAGON = "SNAKE", ROCK = "HELIX",
}

local function slotId(index)
  return ("NVIDIA_FAKE_%03d"):format(index)
end

local function placeholder(index, front, back)
  return {
    id = slotId(index), name = "FUTUREMON", dex = DEX_OFFSET + index,
    types = { "NORMAL" },
    baseStats = { hp = 60, attack = 60, defense = 60, speed = 60, special = 60 },
    catchRate = 120, baseExp = 100,
    level1Moves = { "TACKLE", "GROWL" }, growthRate = "MEDIUM_FAST",
    tmhm = {}, learnset = {}, evolutions = {},
    spriteFront = front, spriteBack = back, frontSize = 7,
    dexEntry = { kind = "MYSTERY", heightFt = 3, heightIn = 0,
      weight = 300, text = "_NVIDIA_FAKEMON_EMPTY" },
  }
end

local function freshState()
  return { version = STATE_VERSION, nextIndex = 1, maps = {}, fakemon = {}, order = {} }
end

return function(mod)
  Client.cleanupStagedFiles()
  local GEN3 = GameVersion.generation() == 3
  local vanillaFront = mod.path .. "/assets/fallback_front.png"
  local vanillaBack = mod.path .. "/assets/fallback_back.png"
  for index = 1, MAX_FAKEMON do
    local id = slotId(index)
    if GEN3 then
      -- FireRed / LeafGreen: numbered species rows, no icon or constants
      -- registries (see gen3.lua).
      mod.content.pokemon:register(id,
        Gen3.placeholder(id, Gen3.index(index), vanillaFront, vanillaBack))
    else
      mod.content.pokemon:register(id, placeholder(index, vanillaFront, vanillaBack))
      mod.content.icons:register(id, "MON")
    end
  end
  if not GEN3 then
    mod.content.constants:patch("dexSize", DEX_OFFSET + MAX_FAKEMON)
    mod.content.constants:patch("dexDigits", 3)
  end

  mod.options:define({
    { key = "enabled", label = "AI FAKEMON", type = "toggle", default = true },
  })

  local game
  local active
  local queue, queued = {}, {}
  local serial = 0
  local warnedThreads, warnedFull, warnedImageConfig = false, false, false

  local function state()
    local value = mod.save:get("state")
    if type(value) ~= "table" or value.version ~= STATE_VERSION then
      value = freshState()
      mod.save:set("state", value)
    end
    value.maps = value.maps or {}
    value.fakemon = value.fakemon or {}
    value.order = value.order or {}
    value.nextIndex = tonumber(value.nextIndex) or 1
    return value
  end

  local function stableHash(value)
    local hash = 0
    value = tostring(value or "")
    for index = 1, #value do
      hash = (hash * 131 + value:byte(index)) % 2147483647
    end
    return hash
  end

  local function encounterTableHasSlots(entry)
    if type(entry) ~= "table" then return false end
    for _, kind in ipairs({ "grass", "water" }) do
      local group = entry[kind]
      if type(group) == "table" and type(group.slots) == "table"
          and #group.slots > 0 and (tonumber(group.rate) or 0) > 0 then
        return true
      end
    end
    return false
  end

  local function eligibleMap(mapId)
    if GEN3 then return Gen3.eligible(mapId) end
    if not mapId or not (game and game.data) then return false end
    if STARTER_MAPS[mapId] then return true end
    if encounterTableHasSlots(game.data.encounters and game.data.encounters[mapId]) then
      return true
    end
    local superRod = game.data.field and game.data.field.superRod
    return type(superRod) == "table" and type(superRod[mapId]) == "table"
      and #superRod[mapId] > 0
  end

  -- Version-1 saves used a single slot string per map. Convert that shape in
  -- place so an existing Fakedex keeps its assignments and can add slot two.
  local function mapRecord(saved, mapId, create)
    local record = saved.maps[mapId]
    if type(record) == "string" then
      record = { own = { record }, reused = {} }
      saved.maps[mapId] = record
    elseif type(record) == "table" and record.own == nil then
      local own = {}
      for _, slot in ipairs(record) do own[#own + 1] = slot end
      record = { own = own, reused = {} }
      saved.maps[mapId] = record
    end
    if type(record) ~= "table" and create then
      record = { own = {}, reused = {} }
      saved.maps[mapId] = record
    end
    if type(record) == "table" then
      record.own = record.own or {}
      record.reused = record.reused or {}
    end
    return record
  end

  local function generatedRoster(saved)
    local out, seen = {}, {}
    for _, row in ipairs(saved.order or {}) do
      local slot = type(row) == "table" and row.species
      if slot and saved.fakemon[slot] and not seen[slot] then
        out[#out + 1], seen[slot] = slot, true
      end
    end
    local remainder = {}
    for slot in pairs(saved.fakemon or {}) do
      if not seen[slot] then remainder[#remainder + 1] = slot end
    end
    table.sort(remainder)
    for _, slot in ipairs(remainder) do out[#out + 1] = slot end
    return out
  end

  local function forbiddenNames(saved)
    local names = {}
    if GEN3 then
      for _, name in ipairs(Gen3.vanillaNames(game)) do
        names[name:upper():gsub("[^A-Z]", "")] = true
      end
    end
    for id, definition in pairs(not GEN3 and game and game.data and game.data.pokemon or {}) do
      if not tostring(id):match("^NVIDIA_FAKE_") and type(definition) == "table"
          and type(definition.name) == "string" and definition.name ~= "" then
        names[definition.name:upper():gsub("[^A-Z]", "")] = true
      end
    end
    for _, definition in pairs(saved.fakemon or {}) do
      if type(definition) == "table" and type(definition.name) == "string"
          and definition.name ~= "" then
        names[definition.name:upper():gsub("[^A-Z]", "")] = true
      end
    end
    local out = {}
    for name in pairs(names) do
      if name ~= "" then out[#out + 1] = name end
    end
    table.sort(out)
    return out
  end

  local function assignReused(saved, mapId, record)
    if record.reuseAssigned then return end
    record.reuseAssigned = true
    local own = {}
    for _, slot in ipairs(record.own) do own[slot] = true end
    local candidates = {}
    for _, slot in ipairs(generatedRoster(saved)) do
      if not own[slot] then candidates[#candidates + 1] = slot end
    end
    if #candidates == 0 then return end
    local start = stableHash(mapId) % #candidates + 1
    local seen = {}
    for offset = 0, #candidates - 1 do
      local slot = candidates[(start + offset - 1) % #candidates + 1]
      if not seen[slot] then
        record.reused[#record.reused + 1], seen[slot] = slot, true
        if #record.reused >= REUSED_PER_MAP then break end
      end
    end
  end

  local function mapPool(mapId)
    local saved = state()
    local record = mapRecord(saved, mapId, false)
    if not record then return {} end
    local out, seen = {}, {}
    for _, list in ipairs({ record.own, record.reused }) do
      for _, slot in ipairs(list) do
        if saved.fakemon[slot] and not seen[slot] then
          out[#out + 1], seen[slot] = slot, true
        end
      end
    end
    return out
  end

  local function chooseFrom(pool, seed)
    if #pool == 0 then return nil end
    return pool[stableHash(seed) % #pool + 1]
  end

  local function replacementFor(mapId, seed)
    return chooseFrom(mapPool(mapId), tostring(mapId) .. "|" .. tostring(seed))
  end

  local function generationsNeeded(mapId)
    if not eligibleMap(mapId) then return 0 end
    local record = mapRecord(state(), mapId, false)
    return math.max(0, FAKEMON_PER_MAP - (record and #record.own or 0))
  end

  local function engineTypes(types)
    local out = {}
    for _, id in ipairs(types or {}) do
      if id == "PSYCHIC" then id = "PSYCHIC_TYPE" end
      out[#out + 1] = id
    end
    if #out == 0 then out[1] = "NORMAL" end
    return out
  end

  -- FireRed / LeafGreen: write the generated creature into the live species
  -- rows and give it art at the 64x64 size Gen 3 pictures use.
  local gen3Fronts = {}
  -- The last record written for each slot.  The engine rebuilds every species
  -- table from the ROM each time a game is entered (Pokemon.install), which
  -- puts the placeholder rows back; these are what is written again afterwards.
  local gen3Records = {}
  local function applyDefinitionGen3(targetGame, slot, definition, forceArt)
    if type(definition) ~= "table" then return nil end
    local repairedArt = SpriteGenerator.ensure(definition)
    local front, back, artErr = SpriteWriter.ensureGen3(slot, definition,
      forceArt or repairedArt)
    if not front then
      mod.log:warn("could not restore " .. slot .. " sprites: " .. tostring(artErr)
        .. " -- verify the save directory is writable")
      return nil
    end
    local index = tonumber(slot:match("(%d+)$")) or 1
    local types = engineTypes(definition.types)
    for i, id in ipairs(types) do
      if id == "PSYCHIC_TYPE" then types[i] = "PSYCHIC" end
    end
    local startMoves, learnedMoves = Learnset.resolve(definition,
      { moves = setmetatable({}, { __index = function() return true end }) }, types)
    local record = Gen3.placeholder(slot, Gen3.index(index), front, back)
    record.name = (definition.name or record.name):upper()
    record.types = types
    record.baseStats = Gen3.baseStats(definition.baseStats or {})
    record.catchRate, record.baseExp = definition.catchRate, definition.baseExp
    record.learnset = Gen3.learnset(startMoves, learnedMoves,
      Gen3.moveChecker(targetGame))
    local ok, err = Gen3.write(targetGame, record)
    if not ok then
      mod.log:warn("could not write " .. slot .. " into the species table: "
        .. tostring(err))
      return nil
    end
    gen3Fronts[slot] = { front = front, back = back }
    gen3Records[slot] = record
    Gen3.setIcon(record.index, front)
    return true
  end

  -- Put every generated creature back into the species rows.  Runs after the
  -- engine reloads them: names, types, stats, learnsets and icons all go back
  -- to the ROM's (and the boot-time placeholders) on entering the field, which
  -- is why a loaded save showed FAKE001, FAKE002... instead of its creatures.
  local function reapplyGen3()
    for slot, record in pairs(gen3Records) do
      Gen3.write(game, record)
      local art = gen3Fronts[slot]
      if art then Gen3.setIcon(record.index, art.front) end
    end
  end

  local function applyDefinition(targetGame, slot, definition, forceArt)
    if GEN3 then return applyDefinitionGen3(targetGame, slot, definition, forceArt) end
    if not (targetGame and targetGame.data and targetGame.data.pokemon) then return nil end
    local def = targetGame.data.pokemon[slot]
    if not def or type(definition) ~= "table" then return nil end
    local repairedArt = SpriteGenerator.ensure(definition)
    local front, back, artErr = SpriteWriter.ensure(slot, definition, forceArt or repairedArt)
    if not front then
      mod.log:warn("could not restore " .. slot .. " sprites: " .. tostring(artErr)
        .. " -- verify the save directory is writable")
      return nil
    end
    local types = engineTypes(definition.types)
    local index = tonumber(slot:match("(%d+)$")) or 1
    def.id, def.name, def.dex = slot, definition.name, DEX_OFFSET + index
    def.types, def.baseStats = types, definition.baseStats
    def.catchRate, def.baseExp = definition.catchRate, definition.baseExp
    def.level1Moves, def.learnset = Learnset.resolve(definition, targetGame.data, types)
    def.growthRate, def.tmhm = "MEDIUM_FAST", {}
    def.evolutions = {}
    def.spriteFront, def.spriteBack, def.frontSize = front, back, 7
    local highResolution = SpriteWriter.isHighResolution(definition)
    def.trueColor = highResolution and true or nil
    def.battleScaleFront = highResolution
      and 56 / tonumber(definition.frontWidth) or nil
    -- Vanilla back pics are 32px images drawn at 2x, for a 64px footprint.
    def.battleScaleBack = highResolution
      and 64 / tonumber(definition.backWidth) or nil
    def.icon = ICONS[types[1]] or "MON"
    local textId = "_NVIDIA_FAKEMON_" .. slot
    targetGame.data.text[textId] = definition.description
    def.dexEntry = {
      kind = definition.kind, heightFt = definition.heightFt,
      heightIn = definition.heightIn, weight = definition.weight, text = textId,
    }
    targetGame.data.constants.dexSize = math.max(
      DEX_OFFSET, targetGame.data.constants.dexSize or DEX_OFFSET, DEX_OFFSET + index)
    return true
  end

  local function restoreBucket(targetGame, bucket)
    local saved = bucket and bucket.state
    if type(saved) ~= "table" then return end
    if not GEN3 then targetGame.data.constants.dexSize = DEX_OFFSET end
    for slot, definition in pairs(saved.fakemon or {}) do
      applyDefinition(targetGame, slot, definition, false)
    end
  end

  local function resetRuntimeSlots()
    if GEN3 then
      for index = 1, MAX_FAKEMON do
        local id = slotId(index)
        Gen3.clearIcon(Gen3.index(index))
        Gen3.write(game, Gen3.placeholder(id, Gen3.index(index),
          vanillaFront, vanillaBack))
      end
      gen3Fronts = {}
      gen3Records = {}
      return
    end
    if not (game and game.data) then return end
    for index = 1, MAX_FAKEMON do
      local id = slotId(index)
      local clean = placeholder(index, vanillaFront, vanillaBack)
      local def = game.data.pokemon[id]
      if def then
        for key in pairs(def) do def[key] = nil end
        for key, value in pairs(clean) do def[key] = value end
      end
      game.data.text["_NVIDIA_FAKEMON_" .. id] = nil
    end
    game.data.constants.dexSize = DEX_OFFSET
    game.data.text._NVIDIA_FAKEMON_EMPTY = "Data not generated."
    require("src.render.Assets").invalidate()
  end

  local function beginNext()
    if active or #queue == 0 or not mod.options:get("enabled") then return end
    if not (love and love.thread and love.thread.newThread and love.thread.getChannel) then
      if not warnedThreads then
        warnedThreads = true
        mod.log:warn("Fakemon generation needs a LOVE build with thread support")
      end
      queue, queued = {}, {}
      return
    end
    local job = table.remove(queue, 1)
    queued[job.key] = nil
    local record = mapRecord(state(), job.mapId, false)
    if record and #record.own >= FAKEMON_PER_MAP then return beginNext() end
    serial = serial + 1
    local tag = "nvidia_fakemon_" .. tostring(serial)
    local channelName = tag .. "_result"
    local okChannel, channel = pcall(love.thread.getChannel, channelName)
    local okThread, thread = pcall(love.thread.newThread, mod.path .. "/fakemon_worker.lua")
    if not okChannel or not channel or not okThread or not thread then
      mod.log:warn("could not create the Fakemon worker -- verify LOVE thread support")
      return beginNext()
    end
    -- Refresh the list when the job starts. The previous queued variant may
    -- have completed since this job was enqueued, so its generated name must
    -- also be excluded from the next NIM response.
    job.forbiddenNames = forbiddenNames(state())
    local request = Client.buildRequest(job)
    local started, startErr = pcall(thread.start, thread,
      channelName, request, Json.encode(job), tag)
    if not started then
      mod.log:warn("Fakemon worker did not start: " .. tostring(startErr)
        .. " -- verify LOVE thread support")
      return beginNext()
    end
    active = { job = job, channel = channel, thread = thread }
    mod.log:info(("generating Fakemon %d of %d for %s")
      :format(job.variant, FAKEMON_PER_MAP, job.mapId))
  end

  local function enqueue(mapId, map)
    local missing = generationsNeeded(mapId)
    if missing == 0 then return end
    local record = mapRecord(state(), mapId, false)
    local completed = record and #record.own or 0
    for variant = completed + 1, completed + missing do
      local key = mapId .. ":" .. tostring(variant)
      if not queued[key] and not (active and active.job.key == key) then
        queued[key] = true
        queue[#queue + 1] = {
          key = key, mapId = mapId, variant = variant,
          tileset = map and map.def and map.def.tileset or "UNKNOWN",
        }
      end
    end
    beginNext()
  end

  local function acceptResult(result)
    local definition = type(result) == "table" and result.definition
    if type(definition) ~= "table" then
      mod.log:warn("NIM Fakemon worker returned no usable definition"
        .. " -- the map will retry on a later visit")
      return
    end
    if result.warning then
      local configurationFallback = definition.imageAttemptProvider == "disabled"
      if not configurationFallback or not warnedImageConfig then
        mod.log:warn(tostring(result.warning))
        if configurationFallback then warnedImageConfig = true end
      end
    end
    local saved = state()
    local index = saved.nextIndex
    if index > MAX_FAKEMON then
      if not warnedFull then
        warnedFull = true
        mod.log:warn("Fakedex slot limit reached -- later maps remain vanilla")
      end
      return
    end
    local slot = slotId(index)
    if not applyDefinition(game, slot, definition, true) then return end
    local record = mapRecord(saved, active.job.mapId, true)
    assignReused(saved, active.job.mapId, record)
    saved.nextIndex = index + 1
    record.own[#record.own + 1] = slot
    saved.fakemon[slot] = definition
    saved.order[#saved.order + 1] = { mapId = active.job.mapId, species = slot }
    mod.save:set("state", saved)
    pcall(function() require("src.render.Assets").invalidate() end)
    mod.log:info(("added %s as Fakedex No.%03d for %s (art: %s)")
      :format(definition.name, DEX_OFFSET + index, active.job.mapId,
        tostring(definition.artSource or "unknown")))
    local saveFn = game and (game.writeSave or game.saveGame)
    if saveFn then
      local ok, wrote = pcall(saveFn, game)
      if not ok or wrote == false then
        mod.log:warn("generated Fakemon is in memory but autosave failed -- save manually before quitting")
      end
    end
  end

  local function poll()
    if not active then beginNext(); return end
    local envelope = active.channel and active.channel:pop()
    if not envelope then return end
    local result, workerErr = Client.decodeEnvelope(envelope)
    if result then
      acceptResult(result)
    else
      mod.log:warn("NIM Fakemon request failed: " .. tostring(workerErr)
        .. " -- check NVIDIA_API_KEY, model access, curl, and network connectivity")
    end
    active = nil
    beginNext()
  end

  mod.events:on("game.ready", function(ev)
    game = ev.game
    if GEN3 then
      -- Registered here, not while the mod loads: the engine's own hook that
      -- puts the registered placeholders back is added after the mods have
      -- run, and hooks run in the order they were added, so this has to come
      -- later to have the last word.
      local ok, P = pcall(require, "src.core.game3.pokemon")
      if ok and type(P) == "table" and type(P.onReload) == "function" then
        P.onReload(reapplyGen3, "nvidia_fakemon")
      end
      return
    end
    game.data.constants.dexSize = DEX_OFFSET
    game.data.text._NVIDIA_FAKEMON_EMPTY = "Data not generated."
  end)

  -- save.loading fires before validation; install the exact generated base
  -- stats first so saved generated party members validate against their slot.
  mod.events:on("save.loading", function(ev)
    local bucket = ev.raw and ev.raw.modData and ev.raw.modData[mod.id]
    -- Another save may have been loaded before this one, and a creature it
    -- generated must not outlive it in a slot this save never filled.
    if GEN3 and game then resetRuntimeSlots() end
    restoreBucket(game, bucket)
  end)

  -- The boot skeleton also fires save.created, before game.ready. Only the
  -- later event from the title screen's NEW GAME is a player-created slot.
  mod.events:on("save.created", function()
    if not game then return end
    active, queue, queued = nil, {}, {}
    SpriteWriter.clear()
    resetRuntimeSlots()
    mod.save:set("state", freshState())
  end)

  mod.events:on("map.entered", function(ev)
    if GEN3 then Gen3.reseedIcons() end
    enqueue(ev.mapId, ev.map)
  end)

  mod.hooks:wrap("input.step", function(next, targetGame, dt)
    next(targetGame, dt)
    poll()
  end)

  -- Normal UI consumers keep the compatibility-size 56x56/32x32 PNGs.
  -- Battles run on a 2x backing canvas and resolve the high-resolution PNGs
  -- here, so source detail survives the classic logical coordinate system.
  -- FireRed / LeafGreen resolve every picture through this hook too, with the
  -- species number in ctx.gen3Species, and take 64x64 art from a path.
  local function slotOfGen3(number)
    number = tonumber(number)
    if not number then return nil end
    local index = number - Gen3.INDEX_BASE
    if index < 1 or index > MAX_FAKEMON then return nil end
    return slotId(index)
  end

  mod.hooks:wrap("pokemon.sprite", function(next, path, ctx)
    local out = next(path, ctx)
    if GEN3 then
      local slot = out == path and ctx and slotOfGen3(ctx.gen3Species) or nil
      local art = slot and gen3Fronts[slot]
      if art then return ctx.side == "back" and art.back or art.front end
      return out
    end
    if out ~= path or not (ctx and ctx.kind == "battle" and ctx.species) then
      return out
    end
    local definition = state().fakemon[ctx.species]
    if not SpriteWriter.isHighResolution(definition) then return out end
    local front, back = SpriteWriter.battlePaths(ctx.species)
    return ctx.side == "back" and back or front
  end)

  mod.hooks:wrap("encounter.species", function(next, encounter, ctx)
    local out = next(encounter, ctx)
    local replacement = out and replacementFor(ctx and ctx.mapId,
      tostring(out.species) .. "|" .. tostring(out.level))
    if replacement then
      if GEN3 then
        -- the engine reads a number here; a name would resolve through the
        -- ROM's own name table, which a generated creature is not in
        local number = Gen3.index(tonumber(replacement:match("(%d+)$")) or 1)
        out.species, out.speciesId, out.moves = number, number, nil
      else
        out.species = replacement
      end
    end
    return out
  end)

  mod.hooks:wrap("encounter.fishing", function(next, rod, mapId, candidates)
    local out = next(rod, mapId, candidates)
    local replacement = out and replacementFor(mapId,
      tostring(rod) .. "|" .. tostring(out.species) .. "|" .. tostring(out.level))
    if replacement then out.species = replacement end
    return out
  end)

  mod.hooks:wrap("trainer.party", function(next, trainerClass, partyIndex, party)
    local out = next(trainerClass, partyIndex, party)
    if type(out) ~= "table" then return out end
    local roster = generatedRoster(state())
    if #roster == 0 then return out end
    local mapped = {}
    for i, row in ipairs(out) do
      local copy = {}
      for key, value in pairs(row) do copy[key] = value end
      local seed = table.concat({ trainerClass, partyIndex, i, row.species, row.level }, "|")
      -- Roughly one party slot in three becomes a Fakemon. This leaves each
      -- trainer's authored team recognizable while letting generated species
      -- appear even on maps that do not generate a local pair.
      if stableHash(seed) % 3 == 0 then
        local chosen = chooseFrom(roster, seed)
        if GEN3 then
          -- a number, and no ROM moveset: the engine derives one from the
          -- generated learnset
          local number = Gen3.index(tonumber(chosen:match("(%d+)$")) or 1)
          copy.species, copy.speciesId = number, number
          copy.moves, copy.moveIds = nil, nil
        else
          copy.species = chosen
        end
      end
      mapped[i] = copy
    end
    return mapped
  end)

  -- Scripted wilds do not pass through the step-encounter hook. Decorate
  -- both public script commands while the command registry is still open;
  -- static_battle calls the engine function directly, so it needs its own
  -- wrapper in addition to start_battle.
  local vanillaStartBattle = not GEN3 and mod.content.commands:get("start_battle")
  if vanillaStartBattle then
    mod.content.commands:override("start_battle", function(ctx, kind, a, b)
      if kind == "wild" then
        local map = ctx.overworld and ctx.overworld.map
        a = (map and replacementFor(map.id,
          tostring(a) .. "|" .. tostring(b))) or a
      end
      return vanillaStartBattle(ctx, kind, a, b)
    end)
  end
  local vanillaStaticBattle = not GEN3 and mod.content.commands:get("static_battle")
  if vanillaStaticBattle then
    mod.content.commands:override("static_battle", function(ctx, species, level, beatFlag)
      local map = ctx.overworld and ctx.overworld.map
      species = (map and replacementFor(map.id,
        tostring(species) .. "|" .. tostring(level))) or species
      return vanillaStaticBattle(ctx, species, level, beatFlag)
    end)
  end

  -- Gen 3 gifts (starters, fossils, Lapras, Eevee) are matched by species in
  -- the story scripts, so they stay vanilla there.
  mod.events:on("pokemon.before_give", function(gift)
    if GEN3 then return end
    local ctx = gift.ctx
    local map = ctx and ctx.overworld and ctx.overworld.map
    if not map then return end
    if map.id == "OAKS_LAB" and ctx.save
        and ctx.save.flags.EVENT_GOT_STARTER then return end
    local replacement = replacementFor(map.id, gift.species)
    if replacement then gift.species = replacement end
  end)

  mod.exports.slotId = slotId
  mod.exports.state = state
  mod.exports.applyDefinition = applyDefinition
  mod.exports.eligibleMap = eligibleMap
  mod.exports.mapPool = mapPool
  mod.exports.replacementFor = replacementFor
  mod.exports.generationsNeeded = generationsNeeded
  mod.exports.fakemonPerMap = FAKEMON_PER_MAP
  mod.exports.reusedPerMap = REUSED_PER_MAP
end
