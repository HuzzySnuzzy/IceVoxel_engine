--!strict
--[[
	Mob kinds: Minecraft 1.20.1's farm animals and the four classic monsters, as simple hitboxes
	moving about (server Mobs/MobWorld runs them, client Entities/MobRenderer draws them). A kind's
	id is its position in this list (sent as a u8: append, never reorder).

	  Kind      box (w x h)  eye   health  speed  does
	  Cow       0.9 x 1.4    1.3   10      0.2    wanders, panics when hurt (x2 speed)
	  Sheep     0.9 x 1.3    1.235 8       0.23   the same (x1.25); white, now and then black,
	                                              grey, light grey, brown or pink
	  Pig       0.9 x 0.9    0.765 10      0.25   the same (x1.25)
	  Chicken   0.4 x 0.7    0.644 4       0.25   the same (x1.4); falls slowly, no fall damage
	  Zombie    0.6 x 1.95   1.74  20      0.23   hunts players, hits 3 (armor 2); burns in
	                                              daylight under the open sky
	  Skeleton  0.6 x 1.99   1.74  20      0.25   shoots players within 15 blocks (3-5 a hit,
	                                              a shot every 3 s); burns in daylight
	  Creeper   0.6 x 1.7    1.445 20      0.25   walks up to players and hisses within 3
	                                              blocks: 30 ticks later it explodes (power 3),
	                                              unless they get 7 blocks away first
	  Spider    1.4 x 0.9    0.65  16      0.3    hunts players in the dark, hits 2, climbs
	                                              walls, leaps; neutral in daylight

	Fields (blocks, ticks, half hearts):
	  name, displayName   `MobList.find` takes the name in any case ("zombie", "minecraft:zombie")
	  hostile             a monster (Minecraft's MobCategory.MONSTER: spawns in the dark, counts
	                      against the hostile caps, despawns far from players); else a creature
	                      (spawns on grass in the light, persists)
	  width, height, eye  the hitbox and the eyes above the feet (EntityType dimensions,
	                      getStandingEyeHeight)
	  health, speed       Attributes.MAX_HEALTH and MOVEMENT_SPEED; `armor` Attributes.ARMOR
	  wander, panic       the speed modifiers of RandomStrollGoal and PanicGoal (x speed)
	  chase               MeleeAttackGoal's / approach speed modifier
	  attack              melee damage (Attributes.ATTACK_DAMAGE on normal difficulty)
	  follow              how far (blocks) it notices a player (task: 16 for every monster)
	  burnsInDaylight     Zombie / AbstractSkeleton.aiStep: isSunBurnTick sets it on fire for 8 s
	  fallDamage          false: no fall damage (chickens)
	  slowFall            Chicken.aiStep: falling speed x 0.6 a tick
	  climbs              Spider: climbs when walking into a wall (onClimbable)
	  darkOnly            Spider: only notices players where it is dark (brightness < 0.5);
	                      by day only hits back
	  leap                LeapAtTargetGoal's jump at a target 2-4 blocks away (0.4)
	  fuse                Creeper's SwellGoal: { ticks = 30, power = 3, start = 3, cancel = 7 }
	  bow                 RangedBowAttackGoal: { range = 15, draw = 20, interval = 40, min = 3,
	                      max = 5 } (normal difficulty: a shot every 60 ticks)
	  drops               Minecraft's loot tables (no Looting): { item, min, max, chance?,
	                      byPlayer? (killed_by_player) }; raw meat drops cooked when the mob dies
	                      burning (Shared/Items/Foods.COOKED)
	  spawn               { weight, group = { min, max } }: Minecraft's plains spawn weights
	                      (sheep 12, pig 10, chicken 10, cow 8; spider 100, zombie 95, skeleton
	                      100, creeper 100); creatures need grass under the open sky
	  sounds              hurt and death events (Shared/Sounds)
	  parts               how the client draws it, at most 2 boxes (the hitbox and a head on the
	                      facing side, +Z forward): { size = { x, y, z }, offset = { x, y, z },
	                      color } in blocks from the feet; `variants` recolour the first box
	                      ({ color, weight }: Sheep.getRandomSheepColor's odds)
	  color               WAILA's icon colour

	The registry below checks at load that every drop names an item and that each kind has at
	most MAX_PARTS boxes.
]]

local Items = require(script.Parent.Parent.Items)

export type Drop = { item: string, min: number, max: number, chance: number?, byPlayer: boolean? }
export type Part = { size: { number }, offset: { number }, color: { number } }
export type Variant = { color: { number }, weight: number }
export type Fuse = { ticks: number, power: number, start: number, cancel: number }
export type Bow = { range: number, draw: number, interval: number, min: number, max: number }

export type Spec = {
	name: string,
	displayName: string?,
	hostile: boolean,
	width: number,
	height: number,
	eye: number,
	health: number,
	speed: number,
	armor: number?,
	wander: number,
	panic: number?,
	chase: number?,
	attack: number?,
	follow: number?,
	burnsInDaylight: boolean?,
	fallDamage: boolean?,
	slowFall: boolean?,
	climbs: boolean?,
	darkOnly: boolean?,
	leap: boolean?,
	fuse: Fuse?,
	bow: Bow?,
	drops: { Drop },
	spawn: { weight: number, group: { number } },
	sounds: { hurt: string, death: string },
	parts: { Part },
	variants: { Variant }?,
	color: { number },
}

-- A resolved drop: item ids.
export type KindDrop = { item: number, min: number, max: number, chance: number, byPlayer: boolean }

-- A kind as the game uses it: its spec with its id and resolved drops.
export type Kind = Spec & { id: number, displayName: string, kindDrops: { KindDrop } }

local MobList = {}

-- Boxes the client draws a mob with, at most.
MobList.MAX_PARTS = 2
-- Monsters notice players this far (blocks).
MobList.FOLLOW = 16

local list: { Spec } = {}

--[[ Creatures ]]

table.insert(list, {
	name = "Cow",
	hostile = false,
	width = 0.9,
	height = 1.4,
	eye = 1.3,
	health = 10,
	speed = 0.2,
	wander = 1,
	panic = 2,
	drops = {
		{ item = "Leather", min = 0, max = 2 },
		{ item = "RawBeef", min = 1, max = 3 },
	},
	spawn = { weight = 8, group = { 2, 4 } },
	sounds = { hurt = "entity.cow.hurt", death = "entity.cow.death" },
	parts = {
		{ size = { 0.9, 1.0, 0.9 }, offset = { 0, 0.6, 0 }, color = { 74, 54, 40 } },
		{ size = { 0.55, 0.5, 0.4 }, offset = { 0, 1.1, 0.55 }, color = { 226, 220, 212 } },
	},
	color = { 74, 54, 40 },
})
table.insert(list, {
	name = "Sheep",
	hostile = false,
	width = 0.9,
	height = 1.3,
	eye = 1.235,
	health = 8,
	speed = 0.23,
	wander = 1,
	panic = 1.25,
	drops = {
		{ item = "WhiteWool", min = 1, max = 1 },
		{ item = "RawMutton", min = 1, max = 2 },
	},
	spawn = { weight = 12, group = { 2, 4 } },
	sounds = { hurt = "entity.sheep.hurt", death = "entity.sheep.death" },
	parts = {
		{ size = { 0.9, 0.9, 0.9 }, offset = { 0, 0.75, 0 }, color = { 234, 236, 237 } },
		{ size = { 0.4, 0.45, 0.4 }, offset = { 0, 1.0, 0.55 }, color = { 214, 178, 152 } },
	},
	-- (Sheep.getRandomSheepColor: white 81.836%, black, grey and light grey 5% each, brown 3%,
	-- pink 0.164%.)
	variants = {
		{ color = { 234, 236, 237 }, weight = 81836 },
		{ color = { 30, 27, 27 }, weight = 5000 },
		{ color = { 71, 79, 82 }, weight = 5000 },
		{ color = { 142, 142, 134 }, weight = 5000 },
		{ color = { 114, 71, 40 }, weight = 3000 },
		{ color = { 237, 141, 172 }, weight = 164 },
	},
	color = { 234, 236, 237 },
})
table.insert(list, {
	name = "Pig",
	hostile = false,
	width = 0.9,
	height = 0.9,
	eye = 0.765,
	health = 10,
	speed = 0.25,
	wander = 1,
	panic = 1.25,
	drops = { { item = "RawPorkchop", min = 1, max = 3 } },
	spawn = { weight = 10, group = { 2, 4 } },
	sounds = { hurt = "entity.pig.hurt", death = "entity.pig.death" },
	parts = {
		{ size = { 0.9, 0.6, 0.9 }, offset = { 0, 0.45, 0 }, color = { 240, 162, 160 } },
		{ size = { 0.5, 0.5, 0.35 }, offset = { 0, 0.6, 0.55 }, color = { 228, 136, 140 } },
	},
	color = { 240, 162, 160 },
})
table.insert(list, {
	name = "Chicken",
	hostile = false,
	width = 0.4,
	height = 0.7,
	eye = 0.644,
	health = 4,
	speed = 0.25,
	wander = 1,
	panic = 1.4,
	fallDamage = false,
	slowFall = true,
	drops = {
		{ item = "Feather", min = 0, max = 2 },
		{ item = "RawChicken", min = 1, max = 1 },
	},
	spawn = { weight = 10, group = { 2, 4 } },
	sounds = { hurt = "entity.chicken.hurt", death = "entity.chicken.death" },
	parts = {
		{ size = { 0.4, 0.45, 0.4 }, offset = { 0, 0.3, 0 }, color = { 242, 242, 238 } },
		{ size = { 0.25, 0.3, 0.2 }, offset = { 0, 0.6, 0.22 }, color = { 214, 52, 40 } },
	},
	color = { 242, 242, 238 },
})

--[[ Monsters ]]

table.insert(list, {
	name = "Zombie",
	hostile = true,
	width = 0.6,
	height = 1.95,
	eye = 1.74,
	health = 20,
	speed = 0.23,
	armor = 2,
	wander = 1,
	chase = 1,
	attack = 3,
	follow = MobList.FOLLOW,
	burnsInDaylight = true,
	drops = {
		{ item = "RottenFlesh", min = 0, max = 2 },
		{ item = "IronIngot", min = 1, max = 1, chance = 0.025, byPlayer = true },
	},
	spawn = { weight = 95, group = { 1, 4 } },
	sounds = { hurt = "entity.zombie.hurt", death = "entity.zombie.death" },
	parts = {
		{ size = { 0.6, 1.45, 0.6 }, offset = { 0, 0.725, 0 }, color = { 44, 128, 140 } },
		{ size = { 0.5, 0.5, 0.5 }, offset = { 0, 1.7, 0.1 }, color = { 98, 140, 70 } },
	},
	color = { 98, 140, 70 },
})
table.insert(list, {
	name = "Skeleton",
	hostile = true,
	width = 0.6,
	height = 1.99,
	eye = 1.74,
	health = 20,
	speed = 0.25,
	wander = 1,
	chase = 1,
	follow = MobList.FOLLOW,
	burnsInDaylight = true,
	bow = { range = 15, draw = 20, interval = 40, min = 3, max = 5 },
	drops = { { item = "Bone", min = 0, max = 2 } },
	spawn = { weight = 100, group = { 1, 4 } },
	sounds = { hurt = "entity.skeleton.hurt", death = "entity.skeleton.death" },
	parts = {
		{ size = { 0.5, 1.49, 0.4 }, offset = { 0, 0.745, 0 }, color = { 188, 188, 184 } },
		{ size = { 0.5, 0.5, 0.5 }, offset = { 0, 1.74, 0.05 }, color = { 214, 214, 210 } },
	},
	color = { 214, 214, 210 },
})
table.insert(list, {
	name = "Creeper",
	hostile = true,
	width = 0.6,
	height = 1.7,
	eye = 1.445,
	health = 20,
	speed = 0.25,
	wander = 0.8,
	chase = 1,
	follow = MobList.FOLLOW,
	fuse = { ticks = 30, power = 3, start = 3, cancel = 7 },
	drops = { { item = "Gunpowder", min = 0, max = 2 } },
	spawn = { weight = 100, group = { 1, 4 } },
	sounds = { hurt = "entity.creeper.hurt", death = "entity.creeper.death" },
	parts = {
		{ size = { 0.5, 1.2, 0.5 }, offset = { 0, 0.6, 0 }, color = { 82, 168, 70 } },
		{ size = { 0.55, 0.5, 0.55 }, offset = { 0, 1.45, 0.03 }, color = { 104, 190, 86 } },
	},
	color = { 82, 168, 70 },
})
table.insert(list, {
	name = "Spider",
	hostile = true,
	width = 1.4,
	height = 0.9,
	eye = 0.65,
	health = 16,
	speed = 0.3,
	wander = 0.8,
	chase = 1,
	attack = 2,
	follow = MobList.FOLLOW,
	climbs = true,
	darkOnly = true,
	leap = true,
	drops = { { item = "String", min = 0, max = 2 } },
	spawn = { weight = 100, group = { 1, 4 } },
	sounds = { hurt = "entity.spider.hurt", death = "entity.spider.death" },
	parts = {
		{ size = { 1.4, 0.6, 1.1 }, offset = { 0, 0.45, -0.1 }, color = { 52, 44, 40 } },
		{ size = { 0.5, 0.5, 0.45 }, offset = { 0, 0.5, 0.6 }, color = { 120, 28, 30 } },
	},
	color = { 52, 44, 40 },
})

--[[ The registry ]]

local kinds: { Kind } = {}
local byName: { [string]: number } = {}

for id, spec in list do
	assert(#spec.parts >= 1 and #spec.parts <= MobList.MAX_PARTS, `Mob {spec.name} has 1..{MobList.MAX_PARTS} parts`)
	local resolved: { KindDrop } = {}
	for _, drop in spec.drops do
		local item = Items.find(drop.item)
		assert(item, `Mob {spec.name} drops unknown item {drop.item}`)
		table.insert(resolved, {
			item = item,
			min = drop.min,
			max = drop.max,
			chance = drop.chance or 1,
			byPlayer = drop.byPlayer == true,
		})
	end
	local kind = table.clone(spec) :: any
	kind.id = id
	kind.displayName = spec.displayName or spec.name
	kind.kindDrops = resolved
	kinds[id] = table.freeze(kind) :: Kind
	byName[string.lower(spec.name)] = id
end
assert(#kinds < 256, "mob kinds must fit a u8")

-- Every kind, by id (1..COUNT).
MobList.kinds = table.freeze(kinds)
MobList.COUNT = #kinds

-- The kind with id `id`, or nil.
function MobList.get(id: number): Kind?
	return kinds[id]
end

-- The id of the kind named `name` (any case, an optional "minecraft:" prefix), or nil.
function MobList.find(name: string): number?
	local key = string.lower(name)
	if string.sub(key, 1, 10) == "minecraft:" then
		key = string.sub(key, 11)
	end
	return byName[key]
end

-- The kind's variant colour `variant` (1.., its `variants`), else its first part's colour.
function MobList.variantColor(kind: Kind, variant: number): { number }
	local variants = kind.variants
	if variants and variants[variant] then
		return variants[variant].color
	end
	return kind.parts[1].color
end

-- A random variant of `kind` (`random()` in 0..1): 1 for kinds without variants.
function MobList.randomVariant(kind: Kind, random: () -> number): number
	local variants = kind.variants
	if variants == nil then
		return 1
	end
	local total = 0
	for _, variant in variants do
		total += variant.weight
	end
	local pick = random() * total
	for index, variant in variants do
		pick -= variant.weight
		if pick < 0 then
			return index
		end
	end
	return #variants
end

return MobList
