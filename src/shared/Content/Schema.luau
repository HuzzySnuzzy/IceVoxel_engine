--!strict
--[[
	What content may say (Shared/Content): the kinds of data a pack holds, the fields of each kind's
	entries with their types, and the check every entry passes as packs load. An unknown field, or
	one of the wrong type, is an error naming the pack and the entry (`harndess = 2` fails loudly
	instead of being ignored, with a "did you mean hardness?"); the registries check what only they
	know as they load (a machine's kind, a sound event, a skill).

	The kinds (a pack's modules, each optional; Content's header says how they load and merge):
	  blocks    { BlockSpec }: block entries (BLOCK_FIELDS below)
	  items     { ItemSpec }: items that are no blocks (every placeable block is an item too)
	  recipes   { Recipe }: { type = "shaped" | "shapeless" | "smelting", ... } (RECIPE_FIELDS)
	  tags      { [tag]: { name } }: item tags, "#planks" in a recipe (Minecraft's item tags)
	  textures  { [texture name]: Texture }: the texture pack's textures (Shared/TexturePack)
	  loot      { [table name]: { Pool } }: loot tables (ScavengeLoot's format: the ruins', the
	            bunkers', the mineshafts')
	  ores      { OreFeature }: ore features (Generation/Ores' format, the block by name)
	  ages      { AgeRecord }: the Ages, in order (Core's; Progression/Ages)
	  lore      { [name]: line }: tooltip lore of items no entry carries its own of
	A pack's `pack` module is its manifest (MANIFEST_FIELDS): { order, description, requires? }.

	Per-entry fields that feed other registries (each replaces a side table that registry kept by
	name; those tables still work while content moves into packs, but giving a value both ways is
	an error):
	  lore             block, item  the tooltip's lore line (Items/LoreList)
	  texture          block        its faces' textures: { All, Sides, Top, Bottom, Front, Sprite }
	                                (TexturePack.Blocks' Faces)
	  icon             item         its inventory picture, "rbxassetid://<n>", or "" for not made
	                                yet (TexturePack.Icons). (A block's `icon` is still its item's
	                                model boxes.)
	  age              block, item  the Age that opens its recipes, by id ("iron"; Progression/Ages'
	                                recipe lists)
	  skill            block, item  the skill node its recipes also need, by id ("demolition";
	                                Progression/Skills' `recipes`)
	  knowledge        block, item  { mine = points }: mining it again (Knowledge.ORES), { smelt =
	                                points }: each one smelted (Knowledge.SMELTED)
	  miner            block        { ticks, joules, floor? }: the Metal Miner copies this ore at
	                                these numbers (Machines/MinerRules' list, Config.Miner.Ores)
	  radiation        block, item  Sv/h it gives a block away or carried (Config.Radiation.Sources)
	  radiationShield  block        the share of radiation it lets through (Config.Radiation
	                                .Shielding)
	  shielding        item         armor: the share of radiation it keeps out (Config.Radiation
	                                .Hazmat)
	  fuel             block, item  burn ticks as furnace fuel (Crafting/Recipes' fuel)
	  tags             block, item  the tags it is in, { "planks" } (the packs' tags)
	  heats, cools     block        true: it warms / cools a player near it, Tough As Nails (Config
	                                .ToughAsNails.HeatingBlocks / CoolingBlocks)
	  sounds           block        { [action] = event }: its own action sounds (SoundList
	                                .BLOCK_SOUNDS)
	  equipSound       item         armor: the event putting it on plays (SoundList.ARMOR)
	  loot             block        a loot table's name, or its pools: now and then what it gives
	                                in place of its usual drop (Items.lootDrop; Items' leafDrop,
	                                randomDrop and strawDrop)
	  override         block, item, texture  patches the entry of that name an earlier pack made
	The fields blocks always had (blastResistance, zombieBreak, flammable) say on the entry what the
	Base pack's tables (BLAST_RESISTANCE, ZOMBIE_BREAK, the fire odds) set by name.

	A type check (`Schema.check`, a Check) answers nil for a good value, or what is wrong with it
	(" must be a number, not a string"), and the path into it (".shape[2].size").
]]

--[[ Types ]]

-- One box of a shaped block (`shape`, `icon`).
export type ShapeBox = {
	size: { number },
	offset: { number },
	rotation: { number }?,
	color: { number }?,
	material: string?,
	glow: boolean?,
	transparency: number?,
}

export type Bounds = { min: { number }, max: { number } }

-- A transmitter (`transmitter`) and a fluid tank (`tank`); see Shared/Transmitters.
export type TransmitterSpec = { kind: string, tier: number, restrictive: boolean? }
export type TankSpec = { tier: number, capacity: number }
-- A machine (`machine`) and the energy it holds and moves (`energy`); see Shared/Machines.
export type MachineSpec = { kind: string }
export type EnergySpec = { capacity: number, input: number?, output: number? }
-- A plant (`plant`): its soil set, and the names of its other half.
export type PlantSpec = { soil: string?, top: string?, bottom: string? }
-- A door half (`door`): the way it faces, its hinge side ("Left" / "Right"), open or not, and
-- which half (Shared/Blocks/Doors).
export type DoorSpec = { facing: string, hinge: string, open: boolean, upper: boolean }
-- A jigsaw block's orientation (`jigsaw`): the direction its front faces and its top.
export type JigsawSpec = { front: string, top: string }
-- How a block burns (`flammable`): Minecraft's ignite and burn odds.
export type FlammableSpec = { ignite: number, burn: number }
-- What using a toggling block turns it into (`toggle`), and the sound it makes.
export type ToggleSpec = { to: string, sound: string? }

-- A block's textures per face (`texture`; Shared/TexturePack's Faces).
export type Faces = {
	All: string?,
	Sides: string?,
	Top: string?,
	Bottom: string?,
	-- Glow lichen, ladders, rails, vines: the face looking away from its support.
	Front: string?,
	-- Plants, rope, cobwebs, hanging roots: drawn as two crossed images.
	Sprite: string?,
}

-- A texture (the `textures` kind; Shared/TexturePack's header says what each field does).
export type Texture = {
	-- The colour map, "rbxassetid://<number>"; "" = not made yet.
	Color: string,
	-- Normal, roughness and metalness maps ("" or nil: none).
	Normal: string?,
	Roughness: string?,
	Metalness: string?,
	-- The Roblox material (Enum.Material name) the MaterialVariant is based on; parts using the
	-- texture take it.
	Material: string,
	-- true (default): the drawn block's voxel colour; false: the texture's own colours; a block
	-- name: that block's voxel colour.
	Tint: (boolean | string)?,
	-- { r, g, b } 0-255: the colour map's average (linear-light mean, as sRGB).
	Average: { number }?,
	-- false: never needs Config.Textures.OddBoxes (noisy textures: leaves).
	Align: boolean?,
	override: boolean?,
}

-- One entry of a loot pool: { item | false (nothing), weight, min, max, wear = { lo, hi }? }.
export type LootEntry = { any }
-- A loot pool: rolled `rolls[1]`..`rolls[2]` times, each roll an entry by weight.
export type Pool = { rolls: { number }, entries: { LootEntry } }

-- What Knowledge gives for an entry (`knowledge`).
export type KnowledgeSpec = { mine: number?, smelt: number? }
-- The Metal Miner's numbers for an ore (`miner`): ticks an item, J a tick, the least J an item.
export type MinerSpec = { ticks: number, joules: number, floor: number? }

export type BlockSpec = {
	name: string,
	render: string?,
	color: { number }?,
	material: string?,
	transparency: number?,
	reflectance: number?,
	solid: boolean?,
	sturdy: boolean?,
	replaceable: boolean?,
	breakable: boolean?,
	placeable: boolean?,
	behaviour: string?,
	friction: number?,
	fluid: { group: string, level: number, tickDelay: number }?,
	displayName: string?,
	hardness: number?,
	tool: string?,
	toolLevel: number?,
	blastResistance: number?,
	drops: (string | false)?,
	dropCount: number?,
	maxStack: number?,
	container: number?,
	menu: string?,
	decor: string?,
	sound: string?,
	light: number?,
	lightColor: { number }?,
	shape: { ShapeBox }?,
	bounds: Bounds?,
	obstructs: boolean?,
	collides: boolean?,
	collision: { Bounds }?,
	fence: number?,
	support: string?,
	item: string?,
	brokenByFluid: boolean?,
	transmitter: TransmitterSpec?,
	tank: TankSpec?,
	icon: { ShapeBox }?,
	machine: MachineSpec?,
	energy: EnergySpec?,
	plant: PlantSpec?,
	door: DoorSpec?,
	tinted: boolean?,
	foliageColor: { number }?,
	scatter: boolean?,
	shearDrops: (string | boolean)?,
	shearCount: number?,
	shearSpeed: number?,
	creativeOnly: boolean?,
	structureMode: string?,
	jigsaw: JigsawSpec?,
	caveTwin: string?,
	seasonless: boolean?,
	flammable: FlammableSpec?,
	climbable: boolean?,
	chain: boolean?,
	axis: string?,
	stuck: { number }?,
	zombieBreak: number?,
	toggle: ToggleSpec?,
	layer: number?,
	insulation: number?,
	speedFactor: number?,
	-- Fields that feed other registries (the header).
	lore: string?,
	texture: Faces?,
	age: string?,
	skill: string?,
	knowledge: KnowledgeSpec?,
	miner: MinerSpec?,
	radiation: number?,
	radiationShield: number?,
	fuel: number?,
	tags: { string }?,
	heats: boolean?,
	cools: boolean?,
	sounds: { [string]: string }?,
	loot: (string | { Pool })?,
	override: boolean?,
}

-- One box of an item's model (`model`).
export type ModelBox = {
	size: { number },
	offset: { number },
	color: { number }?,
	material: string?,
	rotation: number?,
	shape: string?,
}

-- What an accessory does (the `accessory` field).
export type AccessorySpec = {
	speed: number?,
	runBoost: number?,
	airJumps: number?,
	jump: number?,
	noFallDamage: boolean?,
	regen: number?,
	mana: number?,
	defense: number?,
	fireWalk: boolean?,
	knockback: number?,
	swim: number?,
	attackSpeed: number?,
	worn: string?,
}

-- A magic weapon (the `magic` field).
export type MagicSpec = {
	mana: number,
	damage: number,
	useTicks: number,
	projectile: string,
	fire: number?,
	knockback: number?,
}

export type ItemSpec = {
	name: string,
	displayName: string?,
	maxStack: number?,
	armor: { slot: string, defense: number, toughness: number }?,
	tan: { warmth: number?, cooling: number?, freezeImmune: boolean? }?,
	tool: { kind: string, speed: number, level: number }?,
	durability: number?,
	attack: { damage: number, speed: number }?,
	color: { number }?,
	material: string?,
	model: { ModelBox },
	tilt: number?,
	places: string?,
	accessory: AccessorySpec?,
	vanity: string?,
	magic: MagicSpec?,
	-- Fields that feed other registries (the header).
	lore: string?,
	icon: string?,
	age: string?,
	skill: string?,
	knowledge: KnowledgeSpec?,
	radiation: number?,
	shielding: number?,
	fuel: number?,
	tags: { string }?,
	equipSound: string?,
	override: boolean?,
}

-- A block's or an item's entry, where either will do (Content `entry`).
export type Entry = BlockSpec | ItemSpec

--[[
	A recipe (the `recipes` kind). An ingredient is an item name or "#tag".
	  shaped     `pattern` rows of single characters (" " = empty), `key` maps each character to an
	             ingredient; it may sit anywhere in a big enough grid, and mirrored (Minecraft's
	             ShapedRecipe). `keep`, a key character used once in the pattern: the result takes
	             that ingredient's item data, and its wear when the result wears too.
	  shapeless  `ingredients` in any slots; `keep`, an ingredient listed once, the same way.
	  smelting   one `input` cooks into `result` in a furnace.
	`count` of `result` (default 1).
]]
export type Recipe = {
	type: string,
	pattern: { string }?,
	key: { [string]: string }?,
	ingredients: { string }?,
	input: string?,
	result: string,
	count: number?,
	keep: string?,
}

-- An ore feature (the `ores` kind; Generation/Ores' header says what each field does).
export type OreFeature = {
	name: string,
	block: string,
	veins: number,
	size: number,
	minY: number,
	maxY: number,
	shape: string?,
	plateau: number?,
	depth: boolean?,
	dry: boolean?,
	buried: number?,
}

-- One of an Age's milestones (Progression/Ages).
export type Milestone = {
	category: string,
	key: string?,
	count: number?,
	text: string,
}

-- An Age (the `ages` kind; Progression/Ages): its id (what saves keep), name, the knowledge level
-- it needs, its milestones, the points reaching it gives and its banner's colour.
export type AgeRecord = {
	id: string,
	name: string,
	level: number,
	milestones: { Milestone },
	reward: number,
	color: { number },
}

-- A pack's manifest (its `pack` module).
export type Manifest = { order: number, description: string?, requires: { string }? }

--[[ Checks ]]

-- nil for a good value, else what is wrong (" must be ...") after the path into it.
export type Check = (value: any) -> string?

local Schema = {}

-- What a value is, for messages: "a number", "a string \"x\"", "a table".
local function describe(value: any): string
	local kind = type(value)
	if kind == "string" then
		return `the string "{value}"`
	elseif kind == "number" or kind == "boolean" then
		return tostring(value)
	elseif kind == "nil" then
		return "nothing"
	end
	return `a {kind}`
end

local function primitive(text: string, kind: string): Check
	return function(value: any): string?
		if type(value) ~= kind then
			return ` must be {text}, not {describe(value)}`
		end
		return nil
	end
end

local STRING = primitive("a string", "string")
local BOOLEAN = primitive("true or false", "boolean")
local function NUMBER(value: any): string?
	if type(value) ~= "number" or value ~= value then
		return ` must be a number, not {describe(value)}`
	end
	return nil
end
local function TRUE_ONLY(value: any): string?
	if value ~= true then
		return ` must be true, not {describe(value)}`
	end
	return nil
end
local function FALSE_ONLY(value: any): string?
	if value ~= false then
		return ` must be false, not {describe(value)}`
	end
	return nil
end

-- One of `values` (strings).
local function enum(values: { string }): Check
	local set: { [string]: boolean } = {}
	for _, value in values do
		set[value] = true
	end
	local text = table.concat(values, ", ")
	return function(value: any): string?
		if type(value) ~= "string" or not set[value] then
			return ` must be one of {text}, not {describe(value)}`
		end
		return nil
	end
end

-- Any of `checks`; the message lists what each wants.
local function oneOf(text: string, checks: { Check }): Check
	return function(value: any): string?
		for _, check in checks do
			if check(value) == nil then
				return nil
			end
		end
		return ` must be {text}, not {describe(value)}`
	end
end

-- Is `value` a list (keys 1..n, nothing else)?
local function isList(value: any): boolean
	if type(value) ~= "table" then
		return false
	end
	local n = #value
	for key in value do
		if type(key) ~= "number" or key < 1 or key > n or key ~= math.floor(key) then
			return false
		end
	end
	return true
end

-- A list of `item`s (`length`: exactly that many).
local function listOf(item: Check, length: number?): Check
	return function(value: any): string?
		if not isList(value) then
			return ` must be a list, not {describe(value)}`
		end
		if length and #value ~= length then
			return ` must be a list of {length}, not {#value}`
		end
		for index, element in value do
			local problem = item(element)
			if problem then
				return `[{index}]{problem}`
			end
		end
		return nil
	end
end

-- A table of string keys to `item`s.
local function mapOf(item: Check): Check
	return function(value: any): string?
		if type(value) ~= "table" then
			return ` must be a table, not {describe(value)}`
		end
		for key, element in value do
			if type(key) ~= "string" then
				return ` must have names as keys, not {describe(key)}`
			end
			local problem = item(element)
			if problem then
				return `["{key}"]{problem}`
			end
		end
		return nil
	end
end

--[[
	Edit distance between two names (Levenshtein's, ignoring case), for "did you mean" hints.
]]
local function distance(a: string, b: string): number
	a, b = string.lower(a), string.lower(b)
	-- (previous[j + 1]: the distance from a's first i - 1 letters to b's first j.)
	local previous: { number } = {}
	for j = 1, #b + 1 do
		previous[j] = j - 1
	end
	for i = 1, #a do
		local current: { number } = { i }
		for j = 1, #b do
			local cost = if string.byte(a, i) == string.byte(b, j) then 0 else 1
			current[j + 1] = math.min(previous[j + 1] + 1, current[j] + 1, previous[j] + cost)
		end
		previous = current
	end
	return previous[#b + 1]
end

-- The field of `fields` nearest `name` when it is near enough to be a typo of it, else nil.
function Schema.suggest(name: string, fields: { [string]: any }): string?
	local best, bestDistance = nil, math.max(2, math.floor(#name / 3))
	for field in fields do
		local d = distance(name, field)
		if d <= bestDistance and (best == nil or d < bestDistance or field < best) then
			best, bestDistance = field, d
		end
	end
	return best
end

-- " is no field it may have (did you mean x?)" for an unknown `name`.
local function unknownField(name: string, fields: { [string]: any }): string
	local hint = Schema.suggest(name, fields)
	return `{name} is no field it may have{if hint then ` (did you mean {hint}?)` else ""}`
end

--[[
	A table with only `fields` (name -> Check), `required` of them always there. Problems read
	".field must be ..." or ".field is no field it may have (did you mean ...?)".
]]
local function record(fields: { [string]: Check }, required: { string }?): Check
	return function(value: any): string?
		if type(value) ~= "table" then
			return ` must be a table, not {describe(value)}`
		end
		for key, element in value do
			if type(key) ~= "string" then
				return ` must have names as keys, not {describe(key)}`
			end
			local check = fields[key]
			if check == nil then
				return `.{unknownField(key, fields)}`
			end
			local problem = check(element)
			if problem then
				return `.{key}{problem}`
			end
		end
		for _, key in (required or {}) :: { string } do
			if value[key] == nil then
				return `.{key} is missing`
			end
		end
		return nil
	end
end

Schema.STRING = STRING
Schema.NUMBER = NUMBER
Schema.BOOLEAN = BOOLEAN
Schema.enum = enum
Schema.oneOf = oneOf
Schema.listOf = listOf
Schema.mapOf = mapOf
Schema.record = record

-- { r, g, b }, each 0..255.
local function RGB(value: any): string?
	if not isList(value) or #value ~= 3 then
		return ` must be a colour (r, g, b), not {describe(value)}`
	end
	for index, channel in value do
		if type(channel) ~= "number" or channel < 0 or channel > 255 then
			return `[{index}] must be a number 0..255, not {describe(channel)}`
		end
	end
	return nil
end
local VEC3 = listOf(NUMBER, 3)
local PAIR = listOf(NUMBER, 2)
local STRINGS = listOf(STRING)
local NAMES_MAP = mapOf(STRING)

local SHAPE_BOX = record({
	size = VEC3,
	offset = VEC3,
	rotation = VEC3,
	color = RGB,
	material = STRING,
	glow = BOOLEAN,
	transparency = NUMBER,
}, { "size", "offset" })
local BOUNDS = record({ min = VEC3, max = VEC3 }, { "min", "max" })
local FACES = record({
	All = STRING,
	Sides = STRING,
	Top = STRING,
	Bottom = STRING,
	Front = STRING,
	Sprite = STRING,
})
Schema.FACES = FACES

-- { item | false, weight, min, max, wear = { lo, hi }? }.
local function LOOT_ENTRY(value: any): string?
	if not isList(value) or #value < 4 or #value > 5 then
		return ` must be (item or false, weight, min, max, wear?), not {describe(value)}`
	end
	local item = value[1]
	if item ~= false and type(item) ~= "string" then
		return `[1] must be an item name or false, not {describe(item)}`
	end
	if type(value[2]) ~= "number" or value[2] <= 0 then
		return `[2] must be a weight above 0, not {describe(value[2])}`
	end
	for index = 3, 4 do
		local problem = NUMBER(value[index])
		if problem then
			return `[{index}]{problem}`
		end
	end
	if value[4] < value[3] then
		return ` has its most ({value[4]}) under its fewest ({value[3]})`
	end
	if value[5] ~= nil then
		local problem = PAIR(value[5])
		if problem then
			return `[5]{problem}`
		end
	end
	return nil
end
local POOL = record({ rolls = PAIR, entries = listOf(LOOT_ENTRY) }, { "rolls", "entries" })
local LOOT_TABLE = listOf(POOL)
Schema.LOOT_TABLE = LOOT_TABLE

--[[
	Block fields (everything except `name` is optional; the per-entry fields that feed other
	registries are in the header):
	  name          Unique name, used as `Blocks.id.Name`.
	  render        "Opaque" (default), "Transparent" (glass-like), "Fluid" (only the surface is drawn)
	                or "None" (never drawn).
	  color         { r, g, b } in 0-255.
	  material      Name of an Enum.Material, e.g. "Slate".
	  transparency  Part transparency for Transparent / Fluid blocks.
	  reflectance   Part reflectance.
	  solid         Collides with characters. Default true for drawn blocks.
	  sturdy        false: torches and lanterns can't hang on it, though it is a solid cube
	                (Minecraft's support shape: leaves have none, and a chest's and a cactus's
	                faces stop short of the cell's). Default true for solid, drawn blocks without a
	                `shape` (Blocks.isSturdy); `true` makes a solid shaped block sturdy (a fluid
	                tank).
	  replaceable   Placing a block may overwrite it (air, fluids). Default false.
	  breakable     Players can break it. Default true.
	  placeable     Is an item players can hold and place (creative inventory, drops). Default true
	                for drawn, solid blocks.
	  behaviour     Name of a server block behaviour (see ServerScriptService.IceVoxel.Behaviours).
	  friction      How slippery the block is to walk on (Minecraft's block friction): 0.6 by
	                default, 0.98 for ice. Higher keeps more of the speed from tick to tick.
	  fluid         { group, level, tickDelay } for fluids (filled in by `fluid()` below; every
	                group is a fluid of Shared/Fluids).
	  displayName   Shown in the inventory (default: the name with spaces, "OakLog" -> "Oak Log").
	  hardness      Minecraft's destroy time (0 = breaks at once). Default 1. See Shared/Mining.
	  tool          The tool that mines it fast: "pickaxe", "axe", "shovel" or "hoe" (Minecraft's
	                mineable tags).
	  toolLevel     Set when the block only drops with that tool, of at least this tier (0 wood /
	                gold, 1 stone, 2 iron, 3 diamond): Minecraft's requiresCorrectToolForDrops. It
	                also mines 3.3 times slower without it. nil: drops by hand.
	  blastResistance  Minecraft's explosion resistance (Shared/World/Explosion: each step of an
	                explosion's ray through the block costs (resistance + 0.3) x 0.3). Default
	                its hardness (Minecraft's Properties.strength(f) sets both), 3 600 000 for
	                unbreakable and creative only blocks (bedrock, structure blocks), none at all
	                for air and cave air; fluids 100 (their hardness), so an explosion in water
	                breaks nothing, but fuel 0 (it is the explosive). Minecraft's values that
	                differ from the hardness are in BLAST_RESISTANCE at the end of the list.
	  drops         Name of the item a survival player gets for breaking it (default: the block
	                itself), or false for nothing (e.g. glass, leaves).
	  dropCount     How many of `drops` (default 1).
	  maxStack      Most of its item in one slot (1..64, default 64): Mekanism's Energy Cubes
	                (Batteries) stack to 1, as their charge is in each item.
	  container     Number of item slots the block keeps (a chest's 27, a furnace's 3); breaking it
	                drops what is inside.
	  menu          What right clicking opens: "Chest", "Crafting" (a crafting table's 3 x 3 grid),
	                "Furnace", "StructureBlock" or "Jigsaw" (their settings screens).
	  decor         Faces drawn on the block's parts ("Chest", "CraftingTable", "Furnace",
	                "CreativeEnergyCube", "HeatGenerator", "ElectricFurnace", "BasicBattery",
	                "AdvancedBattery", "EliteBattery", "UltimateBattery", "OilRefinery",
	                "CombustionGenerator", the seasons' machines by name ("WoodStove" ...), the
	                turrets' "<Tier><Type>Turret" ("BasicSmgTurret" ...), "MetalMiner",
	                "AmmoPress", "Tnt", "Nuke", "StructureBlockSave", "StructureBlockLoad",
	                "StructureBlockCorner", "StructureBlockData" and
	                "Jigsaw<Front><Top>", e.g. "JigsawNorthUp"; client Rendering/BlockDecor). Such
	                blocks are drawn one part per block.
	  sound         What breaking, placing, hitting, walking and falling on it sounds like
	                (Minecraft's SoundType; the events are `block.<sound>.break` and so on, see
	                Shared/Sounds): "stone", "wood", "gravel", "grass", "sand", "glass", "snow",
	                "metal", "wool" or "water". Default: from the material (Wood / WoodPlanks wood;
	                Grass / LeafyGrass grass; Ground / Mud / Pebble gravel, as Minecraft's dirt
	                sounds; Sand sand; Snow snow; Glass / Ice / Glacier / Neon glass; Metal /
	                DiamondPlate / CorrodedMetal / Foil metal; Fabric wool; anything else stone),
	                "water" for fluids and none for blocks that are never drawn (air).

	Light and shapes (torches, lanterns, the glow block):
	  light         Light the block gives off, 0..15 (Minecraft's luminance: torches 14, glowstone
	                (here the Glow Block) and lanterns 15). The renderer gives each such block one PointLight (on its
	                `glow` box), and lit blocks are drawn one part per block, so lights never merge or
	                pile up.
	  lightColor    { r, g, b } of that light. Default a warm white.
	  shape         Boxes the block is drawn with instead of a full cube, in pixels (1/16 block):
	                { size = { x, y, z }, offset = { x, y, z }, rotation = { rx, ry, rz }?,
	                  color = { r, g, b }?, material = "Metal"?, glow = true? }. `offset` is the
	                box's centre from the cell's centre (the cell spans -8..8 on every axis) and
	                `rotation` turns the box about its own centre (degrees, CFrame.Angles order).
	                Boxes without a colour / material take the block's; `glow` boxes are Neon and
	                carry the block's light. A shaped block is drawn one part per box, never hides
	                its neighbours and renders like glass ("Transparent") unless `render` says
	                otherwise. At most 15 boxes.
	  bounds        { min = { x, y, z }, max = { x, y, z } } in pixels 0..16: the outline players
	                aim at and see highlighted (Minecraft's VoxelShape). Default: the box around
	                the shape, or the whole cell. Bounds that cover the whole cell are aimed at as
	                a full block (no outline: transmitters, fluid tanks).
	  obstructs     Has a collision box in Minecraft though it is not `solid` (lanterns): its
	                `bounds` keep it from being placed inside a player (Minecraft's
	                BlockItem.canPlace) and falling sand lands on it (Blocks.obstruction). Players
	                and items still pass through it, unlike Minecraft's, where they bump into and
	                stand on lanterns. Torches have no collision box in either game.
	  collides      The movement hull (Shared/Movement/Hull: players, mobs, items) bumps into its
	                `bounds`, though it is not `solid` (Minecraft's collision shape: a door's 3 pixel
	                panel, Blocks.collision). Implies `obstructs`. Lanterns keep none, so players
	                walk through them as before.
	  collision     { Bounds }: the boxes the movement hull bumps into instead (pixels; they may
	                reach up to 24, half a block over the cell: a fence's post and arms, Minecraft's
	                1.5 block fence collision), also for a `solid` block, whose cell then collides
	                only there; placing into a player and line of sight go by them too.
	  fence         0..15: the sides a fence post reaches an arm to (bits: 1 North, 2 South, 4 West,
	                8 East; Minecraft's FenceBlock connections). A fence and its variants (one per
	                set of sides) form a fence group: placing and neighbours changing pick the
	                variant joining the fences and sturdy blocks beside it (Blocks.fenceConnections,
	                server Behaviours/Fence); turning a structure turns its arms.
	  support       The side the block hangs on: "Down" stands on the block below, "Up" hangs from
	                the one above, "North" / "South" / "West" / "East" are fixed to that side. That
	                block must be sturdy (`sturdy` above); when it goes, this one breaks and drops
	                if it also has `behaviour = "Attached"` (server Behaviours/Attached).
	  item          Name of the item that places and drops this block, for variants that are no
	                item of their own (wall torches are placed by, and drop, a Torch); Items.ofBlock
	                answers it. A block and every block naming it as `item` are its variants:
	                placing picks the one whose support holds (Blocks.placementFor).
	  brokenByFluid Flowing water washes it away and it drops (torches: Minecraft's canHoldFluid).
	                Players still can't place blocks into it.
	  flammable     { ignite, burn }: Minecraft's FireBlock odds (FireBlock.setFlammable). `ignite`:
	                how readily fire spreads into air next to it (0..100; > 0 also means fire
	                clings to it and lava sets it alight); `burn`: how readily a fire next to it
	                destroys it (0..100). Set by the fire bootstrap at the end of this list
	                (Minecraft's FireBlock.bootStrap: planks 5 / 20, logs 5 / 5, leaves 30 / 60,
	                plants 60 / 100...) or on the block itself. See server Behaviours/Fire.

	Climbing, hanging and lying along (ladders, rope, vines, rails, cobwebs):
	  climbable     Players and mobs climb it from inside its cell (Minecraft's #climbable tag:
	                ladders, vines; the rope too, Supplementaries'). Blocks.isClimbable;
	                Shared/Movement/PlayerPhysics.
	  chain         It also holds on under a block of its own kind (or that block's cave twin)
	                right above it, not only on its `support`: a rope hangs from the rope above
	                (Supplementaries' RopeBlock.canSurvive), a vine from the same vine above
	                (VineBlock). Blocks.canSurvive. Needs a `support`.
	  axis          "X" or "Z": the horizontal axis it runs along (rails: "Z" North-South, "X"
	                East-West). A block and its variants with an `axis` form an axis group, one
	                per axis: placing picks the one along the player's facing
	                (BaseRailBlock.getStateForPlacement), turning a structure a quarter turn
	                swaps it (Blocks.placementFor, Blocks.rotate, Blocks.axisVariant).
	  stuck         { x, y, z }: moving inside it multiplies a move by these and stops the mover
	                (Minecraft's makeStuckInBlock: a cobweb's 0.25, 0.05, 0.25), and resets the
	                fall distance. Blocks.stuckIn.

	The zombie apocalypse (server Mobs/, Apocalypse/; Shared/Blocks/Toggles):
	  zombieBreak   Ticks one ordinary zombie (MobList `breakPower` 1) hitting it needs to break it
	                (Minecraft's BreakDoorGoal takes 240 for a door); nil: zombies never break it
	                (ores, metal, obsidian, containers, machines, the bunker hatch...). Most blocks
	                get it by name from ZOMBIE_BREAK at the end of the list, before the last cave
	                twins (which copy it); doors and fences set it themselves. Blocks.zombieBreak.
	  toggle        { to = "<Name>", sound = "<event>"? }: using it (`menu` "Toggle", server
	                Players/ToggleUse) swaps it for block `to` and plays `sound` (the bunker
	                hatch opening and shutting); `to` must toggle back. Blocks.toggleOf.

	Plants (grass, ferns, flowers, mushrooms; Minecraft's BushBlock family, see "Plants" below):
	  plant         { soil = "dirt" | "deadbush" | "mushroom"?, top = "<Name>"?, bottom = "<Name>"? }.
	                A single plant or the lower half of a tall one stands on a block of its `soil`
	                set (Blocks.mayPlaceOn, Blocks.canSurvive):
	                  "dirt"      Minecraft's DIRT tag here: Grass, DryGrass, Dirt, CoarseDirt,
	                              Podzol and Mycelium;
	                  "deadbush"  Sand and the dirt set (DeadBushBlock: sand, terracotta, dirt);
	                  "mushroom"  Mycelium or Podzol, or any sturdy opaque full block (Minecraft
	                              also needs a raw light level below 13 on the other blocks; this
	                              game has no block light levels, so that part is left out).
	                `top` names a lower half's upper half, `bottom` an upper half's lower half
	                (DoublePlantBlock). An upper half stands on its own lower half, hangs on
	                nothing (no `support`), is no item of its own (`item` names the lower half,
	                `placeable` is false) and drops nothing; the server places and removes both
	                halves together.
	  tinted        true: the plant's boxes take the foliage colour of the soil it grows on
	                (Minecraft's biome grass tint, `tintindex`): their authored green times the
	                soil's Blocks.FOLIAGE_TINTS entry (Blocks.tintLut; the mesher finds the soil).
	                Short grass, ferns and their tall forms only, whose boxes are all green.
	  foliageColor  { r, g, b } on a soil block: what tinted plants on it look like instead of their
	                authored green (which is the Grass block's). Only DryGrass has one, so savanna
	                grass matches its ground.
	  scatter       true: drawn with a per-position offset (up to 3 pixels each way) and turn about
	                the vertical axis (Minecraft's OffsetType; client rendering). The outline does
	                not move.
	  shearDrops    What Shears harvest from it: true for the block itself, or an item's name
	                (Minecraft's loot tables' `match_tool shears`: leaves, grass, ferns, dead
	                bushes). Anything else held gets the usual drops (Items.drops).
	  shearCount    How many of `shearDrops` (default 1): tall grass gives 2 short grass.
	  shearSpeed    How fast Shears mine it (default the Shears' 15, Minecraft's on leaves): 2 on
	                glow lichen (ShearsItem.getDestroySpeed).
	A plant's `shape` has at most 4 boxes: each is a Part per plant in the world.

	Structures (structure blocks, jigsaw blocks, glow lichen in caves; Shared/Structures):
	  creativeOnly  Minecraft's operator blocks (structure blocks, structure voids, jigsaws): only
	                creative players place, use and break them (at once, like every block in
	                creative); survival players can't mine them (Mining.progressPerTick is 0,
	                Minecraft's hardness -1) and they never drop (Items.drops, Items.blockDrops).
	                They are in the creative inventory and JEI.
	  structureMode The structure block mode this block shows: "save", "load", "corner" or "data"
	                (one block per mode, so everyone sees the mode; Blocks.structureMode).
	  jigsaw        { front, top }: a jigsaw block's orientation (Minecraft's FrontAndTop: front
	                Up or Down with a horizontal top, or a horizontal front with top Up; one block
	                per orientation, Blocks.jigsawOrientation / Blocks.jigsawBlock).
	  caveTwin      Name of the block this one is the cave twin of (CaveGlowLichen* of GlowLichen*,
	                CaveLava of Lava, CaveOil of Oil, and the mineshafts' rails, fence posts,
	                cobwebs, wall torches, moss carpets, vines and hanging roots, at the end of the
	                list): it looks, drops and behaves exactly like it
	                (a fluid twin is a source of the same group), but generation places it in caves
	                and the mesher treats it like cave air while caves are hidden
	                (Blocks.cullLutHiddenCaves, Blocks.caveTwinLut), as CaveAir is to Air. Players
	                never place twins; their `item` is the twin's.
	  seasonless    true: its colour never follows the seasons (Shared/Seasons/Foliage), so it
	                takes an appearance of its own even where it looks exactly like another block
	                (the mineshafts' cave vines keep their green underground).

	Mekanism pipes (Shared/Transmitters):
	  transmitter   { kind = "item" | "fluid" | "energy", tier = 1..4, restrictive = true? }: a
	                Logistical Transporter ("item"), the Restrictive Transporter (`restrictive`), a
	                Mechanical Pipe ("fluid") or a Universal Cable ("energy") of that tier (1 Basic
	                .. 4 Ultimate; the numbers are in Transmitters/Tiers). Its `shape` is the core;
	                the client draws the arms towards what it connects to.
	  tank          { tier = 1..4, capacity = mB }: a Fluid Tank (Transmitters.isTank).
	  icon          Boxes the item's model shows instead of `shape` (same format), starting with
	                the shape's own boxes in the same order: a transmitter's core plus two arms.
	  Shape boxes may also have `transparency` (0..1, default the block's): a transmitter's glass
	  is see-through, its frame is not.

	Mekanism machines (Shared/Machines; the server runs them in server/Machines):
	  machine       { kind = "<kind>" }: a machine of a kind Shared/Machines defines (its slots,
	                data, panel and tick). Its contents live in a container of kind "machine"
	                (server Players/Containers); right clicking opens its panel (`menu` defaults
	                to "Machine"). Don't set `container`: the slots are the kind's.
	  energy        { capacity = J, input = J/t?, output = J/t? }: the energy it holds and the
	                most it takes from / gives to an energy network per tick (Universal Cables
	                and directly adjacent energy blocks). Output only: a producer (generators);
	                input only: a consumer (machines); both: storage (batteries, the backup).
	                `math.huge` is Mekanism's creative infinity. `capacity = 0` (no input or
	                output) for a fuel-only kind (Machines `fuelOnly`: the Wood Stove, the Oil
	                Heater): it holds no energy, and cables never connect to it.

	Seasons (Shared/Seasons; server Seasons/RoomWorld, Seasons/SnowWorld):
	  layer         1..8: a snow layer of that many layers (Minecraft's SnowLayerBlock: 2 pixels
	                each). Its appearance is its own (Blocks.layerLut), and the renderer lowers its
	                box's top to the layers' height (client Rendering/ChunkRenderer).
	  insulation    U, the heat a room loses through one face of the block per degree (Shared/
	                Seasons/Rooms: a wall face). Default by kind and material (Blocks.insulation):
	                fluids, machines and transmitters (cables, pipes, transporters: a wall they
	                run through stays shut) 0.05; solid blocks without their own collision boxes by
	                material (glass 0.12, ice and metal 0.06, wool 0.008, snow 0.015, planks
	                0.025, leaves 0.3, anything else: logs, stone, brick, concrete, ground 0.02);
	                everything else (air, plants, torches, open doors, fences, snow layers 1-7)
	                none: a room's air flows through it. Closed doors, barricades and the closed
	                bunker hatch set theirs (0.1, 0.15, 0.06).
	  speedFactor   what walking on (or in) it multiplies the ground speed by (Minecraft's
	                getBlockSpeedFactor: snow layers 0.75..1). Default 1. Blocks.speedFactor.

	Directions are Minecraft's: North = -Z, South = +Z, West = -X, East = +X.

	Textures: an entry's `texture` (or TexturePack's side table LEGACY_BLOCKS) per face; Blocks
	resolves it (Shared/TexturePack). `color` and `material` stay the block's plain look (drawn
	while its texture is blank or textures are off, and on the map) and the colour a tinted
	texture takes.
]]
Schema.BLOCK_FIELDS = {
	name = STRING,
	render = enum({ "Opaque", "Transparent", "Fluid", "None" }),
	color = RGB,
	material = STRING,
	transparency = NUMBER,
	reflectance = NUMBER,
	solid = BOOLEAN,
	sturdy = BOOLEAN,
	replaceable = BOOLEAN,
	breakable = BOOLEAN,
	placeable = BOOLEAN,
	behaviour = STRING,
	friction = NUMBER,
	fluid = record({ group = STRING, level = NUMBER, tickDelay = NUMBER }, { "group", "level", "tickDelay" }),
	displayName = STRING,
	hardness = NUMBER,
	tool = STRING,
	toolLevel = NUMBER,
	blastResistance = NUMBER,
	drops = oneOf("an item name or false", { STRING, FALSE_ONLY }),
	dropCount = NUMBER,
	maxStack = NUMBER,
	container = NUMBER,
	menu = STRING,
	decor = STRING,
	sound = STRING,
	light = NUMBER,
	lightColor = RGB,
	shape = listOf(SHAPE_BOX),
	bounds = BOUNDS,
	obstructs = BOOLEAN,
	collides = BOOLEAN,
	collision = listOf(BOUNDS),
	fence = NUMBER,
	support = enum({ "Down", "Up", "North", "South", "West", "East" }),
	item = STRING,
	brokenByFluid = BOOLEAN,
	transmitter = record(
		{ kind = enum({ "item", "fluid", "energy" }), tier = NUMBER, restrictive = BOOLEAN },
		{ "kind", "tier" }
	),
	tank = record({ tier = NUMBER, capacity = NUMBER }, { "tier", "capacity" }),
	icon = listOf(SHAPE_BOX),
	machine = record({ kind = STRING }, { "kind" }),
	energy = record({ capacity = NUMBER, input = NUMBER, output = NUMBER }, { "capacity" }),
	plant = record({ soil = enum({ "dirt", "deadbush", "mushroom" }), top = STRING, bottom = STRING }),
	door = record(
		{ facing = STRING, hinge = STRING, open = BOOLEAN, upper = BOOLEAN },
		{ "facing", "hinge", "open", "upper" }
	),
	tinted = BOOLEAN,
	foliageColor = RGB,
	scatter = BOOLEAN,
	shearDrops = oneOf("an item name or true", { STRING, TRUE_ONLY }),
	shearCount = NUMBER,
	shearSpeed = NUMBER,
	creativeOnly = BOOLEAN,
	structureMode = STRING,
	jigsaw = record({ front = STRING, top = STRING }, { "front", "top" }),
	caveTwin = STRING,
	seasonless = BOOLEAN,
	flammable = record({ ignite = NUMBER, burn = NUMBER }, { "ignite", "burn" }),
	climbable = BOOLEAN,
	chain = BOOLEAN,
	axis = enum({ "X", "Z" }),
	stuck = VEC3,
	zombieBreak = NUMBER,
	toggle = record({ to = STRING, sound = STRING }, { "to" }),
	layer = NUMBER,
	insulation = NUMBER,
	speedFactor = NUMBER,
	-- (The header's.)
	lore = STRING,
	texture = FACES,
	age = STRING,
	skill = STRING,
	knowledge = record({ mine = NUMBER, smelt = NUMBER }),
	miner = record({ ticks = NUMBER, joules = NUMBER, floor = NUMBER }, { "ticks", "joules" }),
	radiation = NUMBER,
	radiationShield = NUMBER,
	fuel = NUMBER,
	tags = STRINGS,
	heats = BOOLEAN,
	cools = BOOLEAN,
	sounds = NAMES_MAP,
	loot = oneOf("a loot table's name or its pools", { STRING, LOOT_TABLE }),
	override = BOOLEAN,
} :: { [string]: Check }

--[[
	Item fields (everything except `name` and `model` is optional; an override needs no model; the
	per-entry fields that feed other registries are in the header):
	  name         Unique name, used as `Items.id.Name` (must not be a block name).
	  displayName  Shown in the inventory. Default: the name with spaces ("IronHelmet" -> "Iron Helmet").
	  maxStack     Most items of this kind in one slot. Default 64.
	  armor        { slot = "Head" | "Chest" | "Legs" | "Feet", defense, toughness }: worn in that armor
	               slot; Minecraft's armor points and toughness.
	  tan          { warmth = n?, cooling = n?, freezeImmune = true? } (armor only): Tough As Nails
	               insulation while worn (Shared/ToughAsNails/Temperature, server Players/Climate
	               sums the pieces): `warmth` steps pull a body temperature target below 0 up
	               towards 0, `cooling` steps pull one above 0 down towards 0, never past it (the
	               scale is -10..10, a zone 5 steps wide); `freezeImmune` stops hypothermia
	               (Minecraft's freeze_immune_wearables: leather). 1 or 2 a piece is about right:
	               a full set at 2 keeps a tundra's -10 at -2, neutral. Warm armor (straw, wool)
	               gives warmth, cool armor (leaves) cooling.
	  tool         { kind = "pickaxe" | "axe" | "shovel" | "hoe" | "sword" | "shears", speed, level }:
	               Minecraft's tool tiers (mining speed on blocks of its kind, harvest level; see
	               Shared/Mining). Shears are no tier (level 0): fast on blocks with `shearDrops`
	               (BlockList), which they harvest (Items.drops), and worn by every block.
	  durability   Uses before it breaks (Minecraft's max damage); such items stack to 1.
	  attack       { damage, speed }: Minecraft 1.20.1's attack damage (half hearts, the hand's 1
	               included) and attack speed (full strength attacks a second) of a weapon or tool
	               hitting a mob (Shared/Entities/Combat; anything else hits like the hand: 1, 4 a
	               second). Swords 4-7, axes 7-9, pickaxes 2-5, shovels 2.5-5.5, hoes 1.
	  color        { r, g, b } in 0-255, a representative colour.
	  model        Boxes the item is drawn with, in pixels (1/16 of a block) around the item's centre:
	               { size = { x, y, z }, offset = { x, y, z }, color = { r, g, b }?, material = "Metal"?,
	                 rotation = degrees about the view axis (Z)?, shape = "Ball" | "Cylinder"? }.
	               Coordinates are as the inventory icon shows the item: x to the right, y up, z towards
	               the viewer (the front of armor is +z); angles are anticlockwise. A ball takes the
	               smallest of its sizes; a cylinder's axis is z (its round face looks at the viewer).
	               Boxes without a colour / material take the item's.
	  tilt         Degrees the whole model is turned (anticlockwise) about the view axis. Tools and
	               sticks are modelled upright (handle down, head up) and tilted -45 so they lie
	               diagonally, head at the top right, as in Minecraft's inventory; held in a hand they
	               are drawn upright again (client Rendering/ItemModels).
	  places       Name of a block the item places (Minecraft's ItemNameBlockItem: sweet berries
	               plant their bush): a block that is no item of its own (BlockList `placeable`
	               false, no `item`), which then drops it, is picked as it and is placed by it
	               (Items.ofBlock). Mint Leaves plant Mint, Ginger Root Wild Ginger. The item keeps
	               its own `model`.
	  accessory    Terraria's accessory (Items/Accessories, Config.Accessories): worn in an accessory
	               slot, one of a kind at a time, it works while there. Its effects (all optional):
	                 speed         share of movement speed added (Aglet 0.05, Anklet of the Wind
	                               0.1)
	                 runBoost      sprinting on the ground builds up to 1 + runBoost times the
	                               speed (Hermes Boots 0.4; Config.Accessories.RunDelay, RunRamp)
	                 airJumps      jumps in the air (Cloud in a Bottle 1; Config.Accessories
	                               .AirJumpPower)
	                 jump          jump velocity added, blocks a tick (Shiny Red Balloon 0.1: Jump
	                               Boost I's)
	                 noFallDamage  no fall damage (Lucky Horseshoe)
	                 regen         ticks per half heart healed while hurt (Band of Regeneration
	                               200)
	                 mana          max mana added (Band of Starpower 20)
	                 defense       armor points added (Obsidian Skull, Cobalt Shield 1)
	                 fireWalk      no hurt from hot blocks: campfires (Obsidian Skull)
	                 knockback     knockback resistance, 0..1 (Cobalt Shield 1)
	                 swim          share of swimming acceleration added (Flipper 1)
	                 attackSpeed   share of melee attack speed added (Feral Claws 0.12)
	                 worn          where the character shows it: "Feet", "Hand", "Back", "Waist",
	                               "Face", "Head" or "Neck" (nil: not drawn)
	               Accessories stack to 1 and are no armor.
	  vanity       "Head" | "Chest" | "Legs" | "Feet": a vanity item (Terraria's social items: no
	               stats), worn only in that vanity armor slot, where it changes the character's
	               look. Stacks to 1; no armor.
	  magic        { mana, damage, useTicks, projectile, fire?, knockback? }: a magic weapon (server
	               Players/Magic): using it casts a `projectile` (Shared/Magic's kinds: "spark",
	               "bolt", "water") for `mana` mana every `useTicks` ticks, hitting a mob for
	               `damage` half hearts; `fire` the chance it sets the mob burning, `knockback` its
	               push (blocks a tick). Stacks to 1.

	Icons: an item's `icon` (or TexturePack's side table LEGACY_ICONS) is its picture (blank until
	one is made); inventories draw a filled one instead of the item's model (client Ui/ItemIcon).
	New items get a blank one (""), so swapping their look in later is one id.
]]
local MODEL_BOX = record({
	size = VEC3,
	offset = VEC3,
	color = RGB,
	material = STRING,
	rotation = NUMBER,
	shape = enum({ "Ball", "Cylinder" }),
}, { "size", "offset" })
local ARMOR_SLOT = enum({ "Head", "Chest", "Legs", "Feet" })
Schema.ITEM_FIELDS = {
	name = STRING,
	displayName = STRING,
	maxStack = NUMBER,
	armor = record({ slot = ARMOR_SLOT, defense = NUMBER, toughness = NUMBER }, { "slot", "defense", "toughness" }),
	tan = record({ warmth = NUMBER, cooling = NUMBER, freezeImmune = BOOLEAN }),
	tool = record({ kind = STRING, speed = NUMBER, level = NUMBER }, { "kind", "speed", "level" }),
	durability = NUMBER,
	attack = record({ damage = NUMBER, speed = NUMBER }, { "damage", "speed" }),
	color = RGB,
	material = STRING,
	model = listOf(MODEL_BOX),
	tilt = NUMBER,
	places = STRING,
	accessory = record({
		speed = NUMBER,
		runBoost = NUMBER,
		airJumps = NUMBER,
		jump = NUMBER,
		noFallDamage = BOOLEAN,
		regen = NUMBER,
		mana = NUMBER,
		defense = NUMBER,
		fireWalk = BOOLEAN,
		knockback = NUMBER,
		swim = NUMBER,
		attackSpeed = NUMBER,
		worn = STRING,
	}),
	vanity = ARMOR_SLOT,
	magic = record({
		mana = NUMBER,
		damage = NUMBER,
		useTicks = NUMBER,
		projectile = STRING,
		fire = NUMBER,
		knockback = NUMBER,
	}, { "mana", "damage", "useTicks", "projectile" }),
	-- (The header's.)
	lore = STRING,
	icon = STRING,
	age = STRING,
	skill = STRING,
	knowledge = record({ smelt = NUMBER }),
	radiation = NUMBER,
	shielding = NUMBER,
	fuel = NUMBER,
	tags = STRINGS,
	equipSound = STRING,
	override = BOOLEAN,
} :: { [string]: Check }

-- Recipes (Recipe above), and the fields each type needs and may have.
Schema.RECIPE_FIELDS = {
	type = enum({ "shaped", "shapeless", "smelting" }),
	pattern = STRINGS,
	key = NAMES_MAP,
	ingredients = STRINGS,
	input = STRING,
	result = STRING,
	count = NUMBER,
	keep = STRING,
} :: { [string]: Check }
Schema.RECIPE_TYPES = table.freeze({
	shaped = { needs = { "pattern", "key", "result" }, may = { "count", "keep" } },
	shapeless = { needs = { "ingredients", "result" }, may = { "count", "keep" } },
	smelting = { needs = { "input", "result" }, may = { "count" } },
})

Schema.TEXTURE_FIELDS = {
	Color = STRING,
	Normal = STRING,
	Roughness = STRING,
	Metalness = STRING,
	Material = STRING,
	Tint = oneOf("true, false or a block name", { BOOLEAN, STRING }),
	Average = RGB,
	Align = BOOLEAN,
	override = BOOLEAN,
} :: { [string]: Check }

Schema.ORE_FIELDS = {
	name = STRING,
	block = STRING,
	veins = NUMBER,
	size = NUMBER,
	minY = NUMBER,
	maxY = NUMBER,
	shape = enum({ "trapezoid" }),
	plateau = NUMBER,
	depth = BOOLEAN,
	dry = BOOLEAN,
	buried = NUMBER,
} :: { [string]: Check }

local MILESTONE = record({ category = STRING, key = STRING, count = NUMBER, text = STRING }, { "category", "text" })
Schema.AGE_FIELDS = {
	id = STRING,
	name = STRING,
	level = NUMBER,
	milestones = listOf(MILESTONE),
	reward = NUMBER,
	color = RGB,
} :: { [string]: Check }

Schema.MANIFEST_FIELDS = {
	order = NUMBER,
	description = STRING,
	requires = STRINGS,
} :: { [string]: Check }

--[[ The kinds ]]

-- Every kind a pack may hold, in the order a pack's modules load (`pack` first).
Schema.KINDS = table.freeze({ "blocks", "items", "recipes", "tags", "textures", "loot", "ores", "ages", "lore" })
-- Each kind's entries' name in messages.
Schema.SINGULAR = table.freeze({
	blocks = "block",
	items = "item",
	recipes = "recipe",
	tags = "tag",
	textures = "texture",
	loot = "loot table",
	ores = "ore feature",
	ages = "Age",
	lore = "lore",
}) :: { [string]: string }
-- The kinds that are lists of entries (the rest are tables of names).
Schema.LISTS =
	table.freeze({ blocks = true, items = true, recipes = true, ores = true, ages = true }) :: { [string]: boolean }

-- Each kind's entry check, for the kinds whose entries are records.
local ENTRY_FIELDS: { [string]: { [string]: Check } } = {
	blocks = Schema.BLOCK_FIELDS,
	items = Schema.ITEM_FIELDS,
	recipes = Schema.RECIPE_FIELDS,
	textures = Schema.TEXTURE_FIELDS,
	ores = Schema.ORE_FIELDS,
	ages = Schema.AGE_FIELDS,
}
-- What the other kinds' values must be.
local VALUE_CHECKS: { [string]: Check } = {
	tags = STRINGS,
	loot = LOOT_TABLE,
	lore = STRING,
}

--[[
	What is wrong with one entry of `kind` (nil: nothing): an unknown field ("harndess is no field
	it may have (did you mean hardness?)"), a wrong type ("color[2] must be a number 0..255, not
	300") or a missing field the kind needs.
]]
function Schema.check(kind: string, entry: any): string?
	local fields = ENTRY_FIELDS[kind]
	if fields == nil then
		local check = VALUE_CHECKS[kind]
		local problem = check(entry)
		return if problem then `it{problem}` else nil
	end
	if type(entry) ~= "table" then
		return `it must be a table, not {describe(entry)}`
	end
	for key, value in entry do
		if type(key) ~= "string" then
			return `it has a key that is no name, {describe(key)}`
		end
		local check = fields[key]
		if check == nil then
			return unknownField(key, fields)
		end
		local problem = check(value)
		if problem then
			return `{key}{problem}`
		end
	end
	local override = entry.override == true
	local needs: { string } = if kind == "blocks"
		then { "name" }
		elseif kind == "items" then (if override then { "name" } else { "name", "model" })
		elseif kind == "textures" then (if override then {} else { "Color", "Material" })
		elseif kind == "ores" then { "name", "block", "veins", "size", "minY", "maxY" }
		elseif kind == "ages" then { "id", "name", "level", "milestones", "reward", "color" }
		else {}
	if kind == "recipes" then
		local rule = Schema.RECIPE_TYPES[entry.type]
		if rule == nil then
			return "type is missing (shaped, shapeless or smelting)"
		end
		needs = rule.needs
		for key in entry do
			if key ~= "type" and not table.find(rule.needs, key) and not table.find(rule.may, key) then
				return `{key} is no field a {entry.type} recipe has`
			end
		end
	end
	for _, key in needs do
		if entry[key] == nil then
			return `{key} is missing`
		end
	end
	return nil
end

-- What is wrong with a pack's manifest (nil: nothing).
function Schema.checkManifest(manifest: any): string?
	local problem = record(Schema.MANIFEST_FIELDS, { "order" })(manifest)
	return if problem then `its manifest{problem}` else nil
end

return Schema
