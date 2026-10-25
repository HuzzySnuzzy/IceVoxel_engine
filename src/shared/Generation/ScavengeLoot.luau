--!strict
--[[
	The zombie apocalypse's loot: what the ruins' and bunkers' containers hold (Generation/Cities,
	Generation/Bunkers fill their Chests, Supply Crates and Medicine Cabinets from them), rolled
	from the content packs' loot tables (Shared/Content: the Apocalypse pack's `loot` has the tables
	and what is in them). Pure, deterministic: a container's items come from its position and the
	world's salt alone, as Generation/Mineshafts' chests do, so every machine agrees and nothing is
	saved until a player opens one (server Players/Containers keeps it from then on). Loot ignores
	the Ages: scavenging is how a survivor gets ahead.

	  Tables   a name -> pools of { rolls = { min, max }, entries = { { item | false, weight, min,
	           max, wear? } } } (the packs' `loot`): each pool rolls rolls[1]..rolls[2] times, each
	           roll an entry by weight (false: nothing), `min`..`max` of its item into a random free
	           slot of 27. An entry with `wear` = { lo, hi } comes worn (an item with a durability):
	           `damage` = floor(durability x (lo + r x (hi - lo))), one more number from the
	           container's generator for such entries only (so a table's rolls changed only where
	           its pools did). `roll` rolls any of the packs' tables; NAMES are the ruins' and
	           bunkers' (their generators name them), and TABLES those tables:
	             house, grocery, pharmacy, medicine_cabinet, hardware, police, fire_station,
	             office, car (the ruins); bunker_storage, bunker_medical, bunker_armory,
	             bunker_generator (the bunkers).
	  Rolls    `roll(name, salt, x, y, z)`: Hash.rng of Hash.hash3(salt, x, y, z). The callers'
	           salts: Hash.hash2(seed, Hash.string("cities.loot"), 0x0C17) and
	           Hash.hash2(seed, Hash.string("bunkers.loot"), 0xB0B5).
]]

local Content = require(script.Parent.Parent.Content)
local Hash = require(script.Parent.Parent.Util.Hash)

-- The durability of item `name` (0: none, or no such item).
local function durabilityOf(name: string): number
	-- (Shared/Items is required here, when a worn entry first rolls, not as this loads: the
	-- terrain generators' actors that load this table never need it otherwise.)
	local Items = require(script.Parent.Parent.Items)
	local id = Items.find(name)
	local def = if id then Items.get(id) else nil
	return if def and def.durability then def.durability else 0
end

-- `wear`'s share of `name`'s durability worn: a whole damage below the durability.
local function worn(name: string, wear: { number }, r: number): number
	local durability = durabilityOf(name)
	if durability <= 0 then
		return 0
	end
	local share = math.clamp(wear[1] + r * (wear[2] - wear[1]), 0, 1)
	return math.min(math.floor(durability * share), durability - 1)
end

-- One item of a container (StructureGen's / Mineshafts' ContainerItem).
export type ContainerItem = { slot: number, item: string, count: number, damage: number }
export type Pool = { rolls: { number }, entries: { { any } } }

local ScavengeLoot = {}

-- Slots of a chest (and a supply crate or medicine cabinet).
ScavengeLoot.SLOTS = 27

-- Every loot table of the packs, by name.
local LOOT: { [string]: { Pool } } = Content.default.loot

-- The ruins' and the bunkers' tables (see the header): their names, frozen, and the tables.
ScavengeLoot.NAMES = table.freeze({
	"house",
	"grocery",
	"pharmacy",
	"medicine_cabinet",
	"hardware",
	"police",
	"fire_station",
	"office",
	"car",
	"bunker_storage",
	"bunker_medical",
	"bunker_armory",
	"bunker_generator",
})
local TABLES: { [string]: { Pool } } = {}
for _, name in ScavengeLoot.NAMES do
	TABLES[name] = assert(LOOT[name], `ScavengeLoot: no pack has the loot table {name}`)
end
ScavengeLoot.TABLES = TABLES

-- The items of a container of table `name` (any of the packs' loot tables) at (x, y, z) (`salt`:
-- the world's loot salt; see the header): a fresh table. An unknown table holds nothing.
function ScavengeLoot.roll(name: string, salt: number, x: number, y: number, z: number): { ContainerItem }
	local pools = LOOT[name]
	local items: { ContainerItem } = {}
	if pools == nil then
		return items
	end
	local rng = Hash.rng(Hash.hash3(salt, x, y, z))
	local free: { number } = table.create(ScavengeLoot.SLOTS)
	for slot = 1, ScavengeLoot.SLOTS do
		free[slot] = slot
	end
	for _, pool in pools do
		local total = 0
		for _, entry in pool.entries do
			total += entry[2]
		end
		for _ = 1, rng:int(pool.rolls[1], pool.rolls[2]) do
			local pick = rng:int(0, total - 1)
			for _, entry in pool.entries do
				pick -= entry[2]
				if pick < 0 then
					if entry[1] and #free > 0 then
						local k = rng:int(1, #free)
						local slot = table.remove(free, k) :: number
						local count = rng:int(entry[3], entry[4])
						local wear = entry[5]
						local damage = if wear then worn(entry[1], wear, rng:float()) else 0
						table.insert(items, { slot = slot, item = entry[1], count = count, damage = damage })
					end
					break
				end
			end
		end
	end
	return items
end

return ScavengeLoot
