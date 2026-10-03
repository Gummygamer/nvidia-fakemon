-- Driver test: generated creatures survive the engine's species reload on
-- FireRed / LeafGreen.
--
-- Entering the field runs Pokemon.install, which rebuilds every species table
-- from the ROM and puts the boot-time placeholders back.  A save loaded with
-- generated creatures in it used to come out of that showing FAKE001, FAKE002...
-- instead of their names, stats and icons.  This applies a creature, forces the
-- reload the engine does, and checks the creature is still there.
--
-- It needs an imported FireRed or LeafGreen cache, so it is a driver test, not a
-- ROM-free one:
--
--   POKEPORT_DRIVER=mods/nvidia_fakemon/tests/gen3_reload_driver.lua \
--   POKEPORT_VERSION=leafgreen POKEPORT_TOUCH=0 POKEPORT_IDENTITY=fakemon-reload-test love .
--
-- (POKEPORT_IDENTITY must hold the imported cache; copy the version's folder from
-- your real save directory into a scratch identity so the test never touches your
-- saves.)  Exits 0 on PASS, 1 on FAIL.
local U = require("tests.drivers.util")

local failures = 0
local function check(ok, label)
  print((ok and "PASS " or "FAIL ") .. label)
  if not ok then failures = failures + 1 end
  return ok
end

local function finish()
  if failures == 0 then
    print("PASS gen3_reload_driver")
    love.event.quit(0)
  else
    print("FAIL gen3_reload_driver failures=" .. failures)
    love.event.quit(1)
  end
end

return function(game)
  for _ = 1, 900 do
    if game.phase == "boot" and game.boot then break end
    U.wait(1)
  end
  game:_handleBootAction({ action = "new_game", name = "RED" })
  U.wait(240)

  local Pokemon = require("src.core.game3.pokemon")
  local exports = game.mods and game.mods.exports and game.mods.exports.nvidia_fakemon
  if not check(exports ~= nil, "the Fakemon mod is loaded on this boot") then return finish() end

  local NUMBER = 413     -- NVIDIA_FAKE_001 on FireRed / LeafGreen
  check(Pokemon._names[NUMBER] == "FAKE001", "the slot starts as its placeholder")

  local definition = {
    name = "reloadmon", kind = "TEST", types = { "GRASS", "NORMAL" },
    baseStats = { hp = 45, attack = 52, defense = 40, speed = 85, special = 40 },
    catchRate = 150, baseExp = 62, description = "A creature for the reload test.",
    heightFt = 1, heightIn = 4, weight = 120,
    level1Moves = { "TACKLE", "GROWL" },
    learnset = { { level = 7, move = "VINE_WHIP" } },
  }
  check(exports.applyDefinition(game, "NVIDIA_FAKE_001", definition, true) == true,
    "a generated creature installs into its slot")
  check(Pokemon._names[NUMBER] == "RELOADMON", "its name reaches the species table")
  local statsBefore = Pokemon._stats and Pokemon._stats[NUMBER] and Pokemon._stats[NUMBER].spe

  -- what Runtime.start does every time a game is entered
  Pokemon.install(nil)
  check(Pokemon._names[NUMBER] == "RELOADMON",
    "the name survives the engine's species reload (got " .. tostring(Pokemon._names[NUMBER]) .. ")")
  check(Pokemon._stats and Pokemon._stats[NUMBER] and Pokemon._stats[NUMBER].spe == statsBefore,
    "and so do its stats")
  check(Pokemon._icons and Pokemon._icons[NUMBER] ~= nil, "and its party icon")
  check(Pokemon._names[NUMBER + 1] == "FAKE002", "an empty slot stays a placeholder")

  -- and a reload triggered the other way, by invalidating then reading again
  Pokemon.invalidate()
  Pokemon.install(nil)
  check(Pokemon._names[NUMBER] == "RELOADMON", "and a second reload leaves it in place")

  -- loading a different save must not leave the first one's creature behind
  require("src.mods.Runtime").emit("save.loading", { raw = { modData = {} } })
  check(Pokemon._names[NUMBER] == "FAKE001",
    "loading a save with no creatures clears the previous save's (got "
    .. tostring(Pokemon._names[NUMBER]) .. ")")

  finish()
end
