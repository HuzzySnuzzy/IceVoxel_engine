--!strict
--[[
	Mob kinds: Minecraft 1.20.1's farm animals and the zombie apocalypse's zombies, as simple
	hitboxes moving about (server Mobs/MobWorld runs them, client Entities/MobRenderer draws them).
	A kind's id is its position in this list (sent as a u8: append, never reorder; monsters are
	never saved, so the three monsters this list once had gave their ids 6-8 to zombie kinds).

	  Kind               box (w x h)  eye   health  speed  does
	  Cow                0.9 x 1.4    1.3   10      0.2    wanders, panics when hurt (x2 speed)
	  Sheep              0.9 x 1.3    1.235 8       0.23   the same (x1.25); white, now and then
	                                                       black, grey, light grey, brown or pink
	  Pig                0.9 x 0.9    0.765 10      0.25   the same (x1.25)
	  Chicken            0.4 x 0.7    0.644 4       0.25   the same (x1.4); falls slowly, no fall
	                                                       damage
	  Zombie             0.6 x 1.95   1.74  20      0.23   the ordinary dead: hunts players, hits 3
	                                                       (armor 2), comes in civilian clothes
	  Runner             0.6 x 1.9    1.7   12      0.31   fast (x1.2 chasing), frail, hits 2
	  Brute              0.75 x 1.99  1.8   60      0.18   slow, huge (drawn 1.1 wide, 2.3 tall),
	                                                       hits 7, breaks blocks three times as fast,
	                                                       shrugs off knockback
	  Crawler            0.75 x 0.6   0.45  14      0.12   legless, drags itself along; fits under
	                                                       anything a block high (drawn 0.8 wide;
	                                                       the box fits an open door's 13/16)
	  Screamer           0.6 x 1.9    1.7   16      0.25   shrieks when it spots a player: every
	                                                       zombie within 48 blocks comes to look
	  Soldier Zombie     0.6 x 1.95   1.74  30      0.23   armoured (10), hits 4; gunpowder, 5.56
	                                                       rounds, now and then a rifle magazine
	  Police Zombie      0.6 x 1.95   1.74  24      0.23   armoured (6); city streets; 9mm rounds,
	                                                       now and then a pistol magazine
	  Firefighter Zombie 0.6 x 1.95   1.74  26      0.22   armoured (6), fire can't hurt it; breaks
	                                                       blocks 1.5 times as fast
	  Construction Zombie 0.6 x 1.95  1.74  24      0.23   hits 4, breaks blocks twice as fast;
	                                                       nails and scrap, rarely a pipe wrench
	  Doctor Zombie      0.6 x 1.95   1.74  18      0.23   carries bandages, pills, antibiotics

	Fields (blocks, ticks, half hearts):
	  name, displayName   `MobList.find` takes the name in any case, with an optional
	                      "minecraft:" prefix, or in snake case ("zombie_brute")
	  hostile             a monster (Minecraft's MobCategory.MONSTER: spawns in the dark, counts
	                      against the hostile caps, despawns far from players); else a creature
	                      (spawns on grass in the light, persists)
	  width, height, eye  the hitbox and the eyes above the feet (EntityType dimensions,
	                      getStandingEyeHeight)
	  health, speed       Attributes.MAX_HEALTH and MOVEMENT_SPEED; `armor` Attributes.ARMOR
	  wander, panic       the speed modifiers of RandomStrollGoal and PanicGoal (x speed)
	  chase               MeleeAttackGoal's / approach speed modifier
	  attack              melee damage (Attributes.ATTACK_DAMAGE on normal difficulty)
	  follow              how far (blocks) it notices a player (MobList.FOLLOW, 16, when absent)
	  burnsInDaylight     Mob.isSunBurnTick: sets it on fire for 8 s in the sun (no zombie does)
	  fallDamage          false: no fall damage (chickens)
	  slowFall            Chicken.aiStep: falling speed x 0.6 a tick
	  drops               Minecraft's loot tables (no Looting): { item, min, max, chance?,
	                      byPlayer? (killed_by_player) }: min + floor(r x (max - min + 1)) of the
	                      item, then the chance; raw meat drops cooked when the mob dies burning
	                      (Shared/Items/Foods.COOKED)
	  spawn               { weight, group = { min, max }, cityWeight?, hordeWeight?, hordeGrowth? }:
	                      Minecraft's plains spawn weights for creatures (sheep 12, pig 10, chicken
	                      10, cow 8: they need grass under the open sky); a zombie's weight in the
	                      wild, in a city (`cityWeight`, default `weight`) and in a blood moon's
	                      waves (`hordeWeight`, default `weight`, grown by `hordeGrowth` a moon)
	  sounds              hurt and death events (Shared/Sounds; checked here when this loads)
	  parts               how the client draws it, at most 2 boxes (the hitbox and a head on the
	                      facing side, +Z forward): { size = { x, y, z }, offset = { x, y, z },
	                      color } in blocks from the feet; `variants` recolour the first box
	                      ({ color, weight }: Sheep.getRandomSheepColor's odds). A zombie's are
	                      its far stand-in (client Entities/MobRenderer draws its rig nearer).
	  color               WAILA's icon colour
	The zombie apocalypse's (server Mobs/, Apocalypse/; client Entities/):
	  zombie              the apocalypse's rules: infection, noise, breaking blocks, day spawning,
	                      blood moon hordes
	  rig                 { kind = "R15", gait, height?, width?, hide? }: drawn as a Roblox R15
	                      body of parts (client Entities/MobRig): `gait` "shamble", "run",
	                      "brute", "crawl" or "lurch"; `height` blocks tall (default the box's),
	                      `width` times the 4 stud R15 width (default 0.8, drawn only); `hide`
	                      R15 part names not drawn (the crawler's lower legs and feet)
	  looks, looksFrom    outfits (Look below) the zombies of the kind wear, or another kind's
	                      (`looksFrom`: the crawler wears the zombie's); a mob's `variant` is a look
	                      and a skin tone (MobList.lookVariant), picked once at spawn
	  infect, bleed       the chances a landed hit infects the player (before armor) and opens
	                      Bleeding (server Apocalypse/Survival)
	  breakPower          progress a tick on a block's `zombieBreak` (Shared/Blocks; default 1)
	  hearing             how far it hears a noise, times the noise's radius (default 1)
	  knockbackResist     0..1 taken off every knockback it takes
	  fireImmune          no fire or lava damage (the firefighter)
	  scream              { radius, cooldown }: the screamer's shriek, a noise of `radius` blocks,
	                      at most every `cooldown` ticks
	A look (`looks`, client Entities/ZombieLooks colours the rig): `name` (docs and spec
	messages only, never shown), `weight`, `shirt` (nil: shirtless), `pants`, `shoes` (nil:
	barefoot), `sleeves` ("long", "short" (default: lower arms bare) or "none"), `legs` ("long"
	(default) or "shorts"), `gloves`, and at most two of `vest` (a box over the upper torso:
	police vest, hi-vis, plate carrier, overall bib), `stripes` (a reflective band round the
	torso) and `hat` ({ kind = "cap" | "helmet" | "hardhat" | "firehelmet" | "beanie", color }),
	so a full rig is at most 17 parts; `torn` (0..1, default 0.2) and `blood` (default 0.3), the
	chances each cloth part shows skin or blood.

	The registry below checks at load that every drop names an item, every sound an event, each
	kind has at most MAX_PARTS boxes, each zombie a rig, and each look at most two extras.
]]

local Items = require(script.Parent.Parent.Items)
local Sounds = require(script.Parent.Parent.Sounds)

export type Drop = { item: string, min: number, max: number, chance: number?, byPlayer: boolean? }
export type Part = { size: { number }, offset: { number }, color: { number } }
export type Variant = { color: { number }, weight: number }
export type Hat = { kind: "cap" | "helmet" | "hardhat" | "firehelmet" | "beanie", color: { number } }
export type Look = {
	-- (Docs and spec messages only: not shown in game.)
	name: string,
	weight: number,
	-- nil: shirtless (skin).
	shirt: { number }?,
	pants: { number },
	-- nil: barefoot (skin).
	shoes: { number }?,
	-- Default "short" (lower arms skin); "none": upper arms skin too.
	sleeves: ("long" | "short" | "none")?,
	-- Default "long"; "shorts": lower legs skin.
	legs: ("long" | "shorts")?,
	-- Hands (else skin).
	gloves: { number }?,
	-- A box over the upper torso (police vest, hi-vis, plate carrier, overall bib).
	vest: { number }?,
	-- One reflective band round the torso (firefighter, tracksuit).
	stripes: { number }?,
	hat: Hat?,
	-- 0..1 chance each cloth part shows skin (default 0.2), and is blood-stained (default 0.3).
	torn: number?,
	blood: number?,
}
export type Rig = {
	kind: "R15",
	-- Blocks the rig is drawn tall (default: the kind's height).
	height: number?,
	-- Times the 4 stud R15 width (default 0.8); drawn only, the box is the kind's `width`.
	width: number?,
	gait: "shamble" | "run" | "brute" | "crawl" | "lurch",
	-- R15 part names not drawn (the crawler's lower legs and feet).
	hide: { string }?,
}
export type Scream = { radius: number, cooldown: number }
export type Spawn = {
	weight: number,
	group: { number },
	-- (Zombies: the weight in a city, default `weight`; in a blood moon's waves, default
	-- `weight`, grown by `hordeGrowth` x (moon - 1).)
	cityWeight: number?,
	hordeWeight: number?,
	hordeGrowth: number?,
}

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
	drops: { Drop },
	spawn: Spawn,
	sounds: { hurt: string, death: string },
	parts: { Part },
	variants: { Variant }?,
	color: { number },
	-- The zombie apocalypse (see the header).
	zombie: boolean?,
	rig: Rig?,
	looks: { Look }?,
	looksFrom: string?,
	infect: number?,
	bleed: number?,
	breakPower: number?,
	hearing: number?,
	knockbackResist: number?,
	fireImmune: boolean?,
	scream: Scream?,
}

-- A resolved drop: item ids.
export type KindDrop = { item: number, min: number, max: number, chance: number, byPlayer: boolean }

-- A kind as the game uses it: its spec with its id and resolved drops.
export type Kind = Spec & { id: number, displayName: string, kindDrops: { KindDrop } }

local MobList = {}

-- Boxes the client draws a mob with, at most (a zombie's far stand-in too).
MobList.MAX_PARTS = 2
-- Monsters notice players this far (blocks) unless their kind says otherwise.
MobList.FOLLOW = 16
-- Extras (vest, stripes, hat) a look may have: a full R15 rig is then at most 17 parts.
MobList.MAX_EXTRAS = 2

--[[
	Zombies' skin tones (a look's bare parts and head): pale green, olive, ashen, sallow, dark
	and bruised. A variant is a look and one of these (MobList.lookVariant).
]]
MobList.SKIN_TONES = table.freeze({
	table.freeze({ 140, 170, 128 }),
	table.freeze({ 116, 138, 92 }),
	table.freeze({ 150, 150, 140 }),
	table.freeze({ 170, 160, 118 }),
	table.freeze({ 92, 98, 74 }),
	table.freeze({ 130, 120, 128 }),
})
-- Skin slots a look takes in a variant (u8: up to 31 looks of 8 tones; 6 used).
local SKIN_SLOTS = 8

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

--[[
	The zombies (the apocalypse's kinds: ids 5-14). Their impostor (`parts`): the body in the
	first look's shirt (a shirtless one's skin) and the head in olive skin; the crawler's lies low
	with its head forward.
]]

local SKIN = { 116, 138, 92 }
local SHOES = { 36, 34, 32 }
local ZOMBIE_SOUNDS = { hurt = "entity.zombie.hurt", death = "entity.zombie.death" }
-- What every zombie drops (the brute more of both).
local FLESH: Drop = { item = "RottenFlesh", min = 0, max = 2 }
local BONE: Drop = { item = "Bone", min = 1, max = 1, chance = 0.25 }

-- The impostor of a standing zombie `w` wide and `h` tall, its body in `shirt`.
local function standing(w: number, h: number, shirt: { number }): { Part }
	return {
		{ size = { w, 0.74 * h, w * 0.75 }, offset = { 0, 0.37 * h, 0 }, color = shirt },
		{ size = { 0.5, 0.5, 0.5 }, offset = { 0, h - 0.25, 0.05 }, color = SKIN },
	}
end

-- A kind's looks (typed here so each look literal checks against Look).
local function wardrobe(looks: { Look }): { Look }
	return looks
end

-- A zombie kind: the shared fields, then the kind's own (`spec` wins).
local function zombie(spec: { [string]: any }): Spec
	local full: { [string]: any } = {
		hostile = true,
		zombie = true,
		burnsInDaylight = false,
		wander = 1,
		chase = 1,
		armor = 0,
		follow = 24,
		breakPower = 1,
		hearing = 1,
		infect = 0.04,
		bleed = 0.15,
		sounds = ZOMBIE_SOUNDS,
		color = SKIN,
	}
	for key, value in spec do
		full[key] = value
	end
	return full :: Spec
end

table.insert(
	list,
	zombie({
		name = "Zombie",
		width = 0.6,
		height = 1.95,
		eye = 1.74,
		health = 20,
		speed = 0.23,
		armor = 2,
		attack = 3,
		drops = { FLESH, BONE, { item = "IronIngot", min = 1, max = 1, chance = 0.025, byPlayer = true } },
		spawn = { weight = 100, cityWeight = 100, hordeWeight = 100, group = { 2, 5 } },
		rig = { kind = "R15", gait = "shamble", width = 0.8 },
		looks = wardrobe({
			{ name = "Red tee", weight = 10, shirt = { 196, 64, 52 }, pants = { 52, 72, 112 }, shoes = SHOES },
			{ name = "Blue tee", weight = 10, shirt = { 60, 110, 170 }, pants = { 70, 64, 58 }, shoes = SHOES },
			{
				name = "Grey hoodie",
				weight = 10,
				shirt = { 88, 92, 98 },
				sleeves = "long",
				pants = { 40, 44, 60 },
				shoes = { 200, 200, 196 },
			},
			{
				name = "Flannel",
				weight = 8,
				shirt = { 150, 40, 40 },
				sleeves = "long",
				pants = { 58, 74, 110 },
				shoes = { 92, 64, 40 },
			},
			{
				name = "Office",
				weight = 8,
				shirt = { 220, 220, 214 },
				sleeves = "long",
				pants = { 40, 40, 48 },
				shoes = { 20, 20, 20 },
			},
			{
				name = "Green jacket",
				weight = 8,
				shirt = { 74, 96, 58 },
				sleeves = "long",
				pants = { 46, 46, 40 },
				shoes = SHOES,
			},
			{ name = "Yellow tee", weight = 6, shirt = { 214, 180, 60 }, pants = { 84, 60, 44 }, shoes = SHOES },
			{
				name = "Tank top",
				weight = 6,
				shirt = { 230, 230, 226 },
				sleeves = "none",
				pants = { 60, 80, 120 },
				legs = "shorts",
				shoes = { 200, 60, 50 },
			},
			{
				name = "Pink sweater",
				weight = 6,
				shirt = { 200, 120, 150 },
				sleeves = "long",
				pants = { 52, 56, 70 },
				shoes = { 230, 230, 230 },
			},
			{
				name = "Overalls",
				weight = 6,
				shirt = { 180, 170, 150 },
				pants = { 60, 80, 120 },
				vest = { 60, 80, 120 },
				shoes = { 80, 56, 36 },
			},
			{
				name = "Beanie",
				weight = 4,
				shirt = { 70, 70, 74 },
				sleeves = "long",
				pants = { 40, 40, 44 },
				shoes = SHOES,
				hat = { kind = "beanie", color = { 160, 40, 40 } },
			},
		}),
		parts = standing(0.6, 1.95, { 196, 64, 52 }),
	})
)
table.insert(
	list,
	zombie({
		name = "ZombieRunner",
		displayName = "Runner",
		width = 0.6,
		height = 1.9,
		eye = 1.7,
		health = 12,
		-- (0.33 at first: x 1.2 chasing that is 5.64 blocks a second, past a sprinting player's
		-- 5.6; 0.31 chases at 4.98, between a walk's 4.3 and a sprint, Mobs/MobAI's tuning.)
		speed = 0.31,
		chase = 1.2,
		attack = 2,
		follow = 32,
		breakPower = 0.5,
		hearing = 1.2,
		infect = 0.03,
		drops = { FLESH, BONE, { item = "SodaCan", min = 1, max = 1, chance = 0.05, byPlayer = true } },
		spawn = { weight = 25, cityWeight = 30, hordeWeight = 40, hordeGrowth = 0.25, group = { 1, 3 } },
		sounds = { hurt = "entity.zombie_runner.hurt", death = "entity.zombie_runner.death" },
		rig = { kind = "R15", gait = "run", width = 0.75 },
		looks = wardrobe({
			{
				name = "Tracksuit",
				weight = 10,
				shirt = { 40, 60, 140 },
				sleeves = "long",
				pants = { 40, 60, 140 },
				stripes = { 230, 230, 230 },
				shoes = { 230, 230, 230 },
			},
			{
				name = "Jogger",
				weight = 8,
				shirt = { 230, 90, 40 },
				sleeves = "none",
				pants = { 30, 30, 34 },
				legs = "shorts",
				shoes = { 60, 160, 220 },
			},
			{
				name = "Black hoodie",
				weight = 6,
				shirt = { 30, 30, 34 },
				sleeves = "long",
				pants = { 50, 54, 70 },
				shoes = SHOES,
			},
		}),
		parts = standing(0.6, 1.9, { 40, 60, 140 }),
	})
)
table.insert(
	list,
	zombie({
		name = "ZombieBrute",
		displayName = "Brute",
		-- (0.75: it fits 2-high doorways, an open door's 13/16 and a 1 x 1 ladder shaft; drawn
		-- 1.1 wide and 2.3 tall, its shoulders and head clip frames and lintels.)
		width = 0.75,
		height = 1.99,
		eye = 1.8,
		health = 60,
		speed = 0.18,
		armor = 4,
		attack = 7,
		breakPower = 3,
		hearing = 0.8,
		infect = 0.08,
		bleed = 0.3,
		knockbackResist = 0.8,
		drops = { { item = "RottenFlesh", min = 2, max = 4 }, { item = "Bone", min = 1, max = 2 } },
		spawn = { weight = 4, cityWeight = 6, hordeWeight = 8, hordeGrowth = 0.35, group = { 1, 1 } },
		sounds = { hurt = "entity.zombie_brute.hurt", death = "entity.zombie_brute.death" },
		rig = { kind = "R15", gait = "brute", width = 1.1, height = 2.3 },
		looks = wardrobe({
			{
				name = "Prison orange",
				weight = 10,
				shirt = { 230, 120, 40 },
				pants = { 230, 120, 40 },
				shoes = SHOES,
			},
			{
				name = "Mechanic",
				weight = 8,
				shirt = { 40, 50, 80 },
				sleeves = "long",
				pants = { 40, 50, 80 },
				vest = { 40, 50, 80 },
				gloves = { 30, 30, 30 },
				shoes = SHOES,
			},
			{ name = "Shirtless", weight = 6, pants = { 50, 60, 80 }, shoes = { 60, 44, 30 } },
		}),
		-- (Its stand-in as tall as its rig is drawn.)
		parts = standing(1.0, 2.3, { 230, 120, 40 }),
	})
)
table.insert(
	list,
	zombie({
		name = "ZombieCrawler",
		displayName = "Crawler",
		-- (0.75 like the brute's, so it lines up with an open door's 13/16; drawn 0.8 wide.)
		width = 0.75,
		height = 0.6,
		eye = 0.45,
		health = 14,
		speed = 0.12,
		attack = 2,
		follow = 16,
		breakPower = 0.5,
		hearing = 0.8,
		infect = 0.06,
		bleed = 0.1,
		drops = { FLESH, BONE },
		spawn = { weight = 12, cityWeight = 12, hordeWeight = 6, group = { 1, 2 } },
		rig = {
			kind = "R15",
			gait = "crawl",
			width = 0.8,
			height = 1.9,
			hide = { "LeftLowerLeg", "RightLowerLeg", "LeftFoot", "RightFoot" },
		},
		looksFrom = "Zombie",
		parts = {
			{ size = { 0.8, 0.4, 0.8 }, offset = { 0, 0.2, -0.05 }, color = { 196, 64, 52 } },
			{ size = { 0.45, 0.45, 0.45 }, offset = { 0, 0.25, 0.42 }, color = SKIN },
		},
	})
)
table.insert(
	list,
	zombie({
		name = "ZombieScreamer",
		displayName = "Screamer",
		width = 0.6,
		height = 1.9,
		eye = 1.7,
		health = 16,
		speed = 0.25,
		chase = 1.1,
		attack = 2,
		follow = 32,
		breakPower = 0.5,
		hearing = 1.3,
		infect = 0.02,
		bleed = 0.1,
		scream = { radius = 48, cooldown = 400 },
		drops = { FLESH, BONE },
		spawn = { weight = 5, cityWeight = 6, hordeWeight = 0, group = { 1, 1 } },
		sounds = { hurt = "entity.zombie_screamer.hurt", death = "entity.zombie_screamer.death" },
		rig = { kind = "R15", gait = "lurch", width = 0.75 },
		looks = wardrobe({
			{
				name = "Hospital gown",
				weight = 10,
				shirt = { 170, 200, 210 },
				pants = { 170, 200, 210 },
				legs = "shorts",
				torn = 0.4,
				blood = 0.5,
			},
			{
				name = "Nightgown",
				weight = 6,
				shirt = { 226, 220, 230 },
				pants = { 226, 220, 230 },
				legs = "shorts",
			},
		}),
		parts = standing(0.6, 1.9, { 170, 200, 210 }),
	})
)
do
	local BOOTS = { 40, 34, 28 }
	local GLOVES = { 40, 38, 34 }
	local function soldier(name: string, weight: number, cloth: { number }, vest: { number }, helmet: { number }): Look
		return {
			name = name,
			weight = weight,
			shirt = cloth,
			sleeves = "long",
			pants = cloth,
			shoes = BOOTS,
			gloves = GLOVES,
			vest = vest,
			hat = { kind = "helmet", color = helmet },
		}
	end
	table.insert(
		list,
		zombie({
			name = "ZombieSoldier",
			displayName = "Soldier Zombie",
			width = 0.6,
			height = 1.95,
			eye = 1.74,
			health = 30,
			speed = 0.23,
			armor = 10,
			attack = 4,
			bleed = 0.2,
			drops = {
				FLESH,
				BONE,
				{ item = "Gunpowder", min = 0, max = 2 },
				{ item = "MilitaryRation", min = 1, max = 1, chance = 0.1, byPlayer = true },
				-- (Its rifle's rounds and now and then a magazine: Shared/Weapons.)
				{ item = "Rounds556", min = 3, max = 10, chance = 0.2, byPlayer = true },
				{ item = "RifleMagazine", min = 1, max = 1, chance = 0.04, byPlayer = true },
			},
			spawn = { weight = 3, cityWeight = 1, hordeWeight = 4, group = { 1, 3 } },
			rig = { kind = "R15", gait = "shamble", width = 0.85 },
			looks = wardrobe({
				soldier("Woodland", 10, { 78, 92, 56 }, { 66, 74, 48 }, { 70, 80, 52 }),
				soldier("Desert", 8, { 176, 150, 108 }, { 150, 128, 90 }, { 160, 138, 98 }),
				soldier("Urban", 6, { 110, 112, 116 }, { 60, 62, 66 }, { 70, 72, 76 }),
			}),
			parts = standing(0.6, 1.95, { 78, 92, 56 }),
		})
	)
end
table.insert(
	list,
	zombie({
		name = "ZombiePolice",
		displayName = "Police Zombie",
		width = 0.6,
		height = 1.95,
		eye = 1.74,
		health = 24,
		speed = 0.23,
		armor = 6,
		attack = 3,
		drops = {
			FLESH,
			BONE,
			{ item = "IronNugget", min = 1, max = 3, chance = 0.3 },
			{ item = "Bandage", min = 1, max = 1, chance = 0.08 },
			-- (Its sidearm's rounds and now and then a magazine: Shared/Weapons.)
			{ item = "Rounds9mm", min = 2, max = 6, chance = 0.15, byPlayer = true },
			{ item = "PistolMagazine", min = 1, max = 1, chance = 0.03, byPlayer = true },
		},
		spawn = { weight = 0, cityWeight = 12, hordeWeight = 6, group = { 1, 2 } },
		rig = { kind = "R15", gait = "shamble", width = 0.82 },
		looks = wardrobe({
			{
				name = "Patrol",
				weight = 10,
				shirt = { 32, 44, 84 },
				sleeves = "long",
				pants = { 28, 32, 48 },
				shoes = { 20, 20, 20 },
				vest = { 30, 30, 34 },
				hat = { kind = "cap", color = { 28, 34, 64 } },
			},
			{
				name = "Summer",
				weight = 8,
				shirt = { 120, 160, 210 },
				pants = { 28, 32, 48 },
				shoes = { 20, 20, 20 },
				vest = { 30, 30, 34 },
			},
		}),
		parts = standing(0.6, 1.95, { 32, 44, 84 }),
	})
)
do
	local TURNOUT = { 176, 150, 90 }
	local function turnout(name: string, weight: number, helmet: { number }): Look
		return {
			name = name,
			weight = weight,
			shirt = TURNOUT,
			sleeves = "long",
			pants = TURNOUT,
			stripes = { 230, 230, 120 },
			gloves = { 60, 50, 40 },
			shoes = { 30, 30, 30 },
			hat = { kind = "firehelmet", color = helmet },
		}
	end
	table.insert(
		list,
		zombie({
			name = "ZombieFirefighter",
			displayName = "Firefighter Zombie",
			width = 0.6,
			height = 1.95,
			eye = 1.74,
			health = 26,
			speed = 0.22,
			armor = 6,
			attack = 3,
			breakPower = 1.5,
			fireImmune = true,
			drops = { FLESH, BONE, { item = "FireAxe", min = 1, max = 1, chance = 0.02, byPlayer = true } },
			spawn = { weight = 0, cityWeight = 6, hordeWeight = 3, group = { 1, 2 } },
			rig = { kind = "R15", gait = "shamble", width = 0.85 },
			looks = wardrobe({
				turnout("Turnout red", 10, { 200, 40, 30 }),
				turnout("Turnout yellow", 8, { 230, 200, 40 }),
			}),
			parts = standing(0.6, 1.95, TURNOUT),
		})
	)
end
do
	-- (The hi-vis vest reads as the stripe, so no separate band: vest and hard hat are two.)
	local JEANS = { 58, 74, 110 }
	local WORK_BOOTS = { 120, 84, 40 }
	table.insert(
		list,
		zombie({
			name = "ZombieWorker",
			displayName = "Construction Zombie",
			width = 0.6,
			height = 1.95,
			eye = 1.74,
			health = 24,
			speed = 0.23,
			armor = 4,
			attack = 4,
			breakPower = 2,
			drops = {
				FLESH,
				BONE,
				{ item = "Nails", min = 1, max = 4, chance = 0.5 },
				{ item = "ScrapMetal", min = 1, max = 2, chance = 0.3 },
				{ item = "PipeWrench", min = 1, max = 1, chance = 0.02, byPlayer = true },
			},
			spawn = { weight = 4, cityWeight = 8, hordeWeight = 4, group = { 1, 3 } },
			rig = { kind = "R15", gait = "shamble", width = 0.85 },
			looks = wardrobe({
				{
					name = "Hi-vis orange",
					weight = 10,
					shirt = { 200, 200, 190 },
					pants = JEANS,
					shoes = WORK_BOOTS,
					vest = { 240, 140, 30 },
					hat = { kind = "hardhat", color = { 240, 200, 40 } },
				},
				{
					name = "Hi-vis lime",
					weight = 8,
					shirt = { 90, 90, 96 },
					sleeves = "long",
					pants = JEANS,
					shoes = WORK_BOOTS,
					vest = { 200, 230, 40 },
					hat = { kind = "hardhat", color = { 236, 236, 230 } },
				},
			}),
			parts = standing(0.6, 1.95, { 200, 200, 190 }),
		})
	)
end
do
	local SCRUB_GLOVES = { 200, 210, 230 }
	table.insert(
		list,
		zombie({
			name = "ZombieDoctor",
			displayName = "Doctor Zombie",
			width = 0.6,
			height = 1.95,
			eye = 1.74,
			health = 18,
			speed = 0.23,
			attack = 3,
			drops = {
				FLESH,
				BONE,
				{ item = "Bandage", min = 1, max = 1, chance = 0.15 },
				{ item = "Painkillers", min = 1, max = 1, chance = 0.05 },
				{ item = "Antibiotics", min = 1, max = 1, chance = 0.12, byPlayer = true },
			},
			spawn = { weight = 2, cityWeight = 5, hordeWeight = 2, group = { 1, 1 } },
			rig = { kind = "R15", gait = "shamble", width = 0.78 },
			looks = wardrobe({
				{
					name = "White coat",
					weight = 10,
					shirt = { 236, 236, 232 },
					sleeves = "long",
					pants = { 60, 70, 90 },
					shoes = { 30, 30, 30 },
				},
				{
					name = "Scrubs teal",
					weight = 8,
					shirt = { 80, 160, 170 },
					pants = { 80, 160, 170 },
					gloves = SCRUB_GLOVES,
					shoes = SHOES,
				},
				{
					name = "Scrubs blue",
					weight = 8,
					shirt = { 70, 110, 170 },
					pants = { 70, 110, 170 },
					gloves = SCRUB_GLOVES,
					shoes = SHOES,
				},
				{
					name = "Scrubs pink",
					weight = 6,
					shirt = { 210, 130, 160 },
					pants = { 210, 130, 160 },
					shoes = SHOES,
				},
			}),
			parts = standing(0.6, 1.95, { 236, 236, 232 }),
		})
	)
end

--[[ The registry ]]

local kinds: { Kind } = {}
local byName: { [string]: number } = {}

--[[
	A kind name in snake case: "ZombieBrute" -> "zombie_brute" (MobList's own copy of
	Generation/Locate.snake's rule, as Entities must not require Generation): /summon's ids.
]]
function MobList.snake(name: string): string
	local s = string.gsub(name, "(%l)(%u)", "%1_%2")
	s = string.gsub(s, "(%d)(%u)", "%1_%2")
	s = string.gsub(s, "[%s%-]+", "_")
	return string.lower(s)
end

local GAITS = { shamble = true, run = true, brute = true, crawl = true, lurch = true }
local HATS = { cap = true, helmet = true, hardhat = true, firehelmet = true, beanie = true }
local function isColour(value: any): boolean
	return type(value) == "table" and #value == 3
end
local function checkLook(kind: string, look: Look)
	local where = `Mob {kind}'s look {look.name}`
	assert(type(look.name) == "string" and look.weight > 0, `{where} needs a name and a weight above 0`)
	assert(isColour(look.pants), `{where} has no pants colour`)
	for _, field in { "shirt", "shoes", "gloves", "vest", "stripes" } do
		local value = (look :: any)[field]
		assert(value == nil or isColour(value), `{where} has a bad {field} colour`)
	end
	assert(
		look.sleeves == nil or look.sleeves == "long" or look.sleeves == "short" or look.sleeves == "none",
		`{where} has bad sleeves`
	)
	assert(look.legs == nil or look.legs == "long" or look.legs == "shorts", `{where} has bad legs`)
	assert(look.hat == nil or (HATS[look.hat.kind] and isColour(look.hat.color)), `{where} has a bad hat`)
	local extras = (if look.vest then 1 else 0) + (if look.stripes then 1 else 0) + (if look.hat then 1 else 0)
	assert(extras <= MobList.MAX_EXTRAS, `{where} has more than {MobList.MAX_EXTRAS} of vest, stripes and hat`)
end

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
	for _, event in { spec.sounds.hurt, spec.sounds.death } do
		assert(Sounds.find(event) ~= nil, `Mob {spec.name} plays unknown sound {event}`)
	end
	if spec.zombie then
		local rig = spec.rig
		assert(rig ~= nil and rig.kind == "R15" and GAITS[rig.gait], `Zombie {spec.name} needs an R15 rig with a gait`)
		assert(spec.looks ~= nil or spec.looksFrom ~= nil, `Zombie {spec.name} has no looks`)
	end
	if spec.looks then
		assert(#spec.looks >= 1 and #spec.looks <= 31, `Mob {spec.name} has 1..31 looks`)
		for _, look in spec.looks do
			checkLook(spec.name, look)
		end
	end
	local kind = table.clone(spec) :: any
	kind.id = id
	kind.displayName = spec.displayName or spec.name
	kind.kindDrops = resolved
	kinds[id] = table.freeze(kind) :: Kind
	byName[string.lower(spec.name)] = id
	byName[MobList.snake(spec.name)] = id
end
assert(#kinds < 256, "mob kinds must fit a u8")
for _, kind in kinds do
	local from = kind.looksFrom
	if from then
		local other = byName[string.lower(from)]
		assert(other ~= nil and kinds[other].looks ~= nil, `Mob {kind.name} wears the looks of {from}, which has none`)
	end
end

-- Every kind, by id (1..COUNT).
MobList.kinds = table.freeze(kinds)
MobList.COUNT = #kinds

-- The kind with id `id`, or nil.
function MobList.get(id: number): Kind?
	return kinds[id]
end

-- The id of the kind named `name` (any case, an optional "minecraft:" prefix, or snake case:
-- "zombie_brute"), or nil.
function MobList.find(name: string): number?
	local key = string.lower(name)
	if string.sub(key, 1, 10) == "minecraft:" then
		key = string.sub(key, 11)
	end
	return byName[key]
end

-- Is the kind (a Kind or an id) one of the apocalypse's zombies?
function MobList.isZombie(kind: Kind | number): boolean
	local resolved = if type(kind) == "number" then kinds[kind] else kind
	return resolved ~= nil and resolved.zombie == true
end

-- The looks a kind's mobs wear (its own, or those of its `looksFrom`), nil for kinds without.
function MobList.looksOf(kind: Kind): { Look }?
	if kind.looks then
		return kind.looks
	end
	local from = kind.looksFrom
	if from then
		local other = kinds[byName[string.lower(from)]]
		return other and other.looks
	end
	return nil
end

-- The variant (u8) of look `look` (1..) in skin tone `skin` (1..#SKIN_TONES).
function MobList.lookVariant(look: number, skin: number): number
	return (look - 1) * SKIN_SLOTS + skin
end

--[[
	The look and skin colour of a kind's `variant` (MobList.lookVariant): a variant out of range
	gives the first look and the first skin (nil look for kinds without looks).
]]
function MobList.look(kind: Kind, variant: number): (Look?, { number })
	local looks = MobList.looksOf(kind)
	local index = (variant - 1) // SKIN_SLOTS + 1
	local skin = (variant - 1) % SKIN_SLOTS + 1
	if looks == nil or variant ~= variant or variant < 1 or index > #looks or skin > #MobList.SKIN_TONES then
		return if looks then looks[1] else nil, MobList.SKIN_TONES[1]
	end
	return looks[index], MobList.SKIN_TONES[skin]
end

-- The kind's variant colour `variant` (1..): a look's shirt (its skin when shirtless) for kinds
-- with looks, a `variants` colour, else its first part's colour.
function MobList.variantColor(kind: Kind, variant: number): { number }
	if MobList.looksOf(kind) then
		local look, skin = MobList.look(kind, variant)
		return if look and look.shirt then look.shirt else skin
	end
	local variants = kind.variants
	if variants and variants[variant] then
		return variants[variant].color
	end
	return kind.parts[1].color
end

-- An index of `weighted` picked by weight (`random()` in 0..1).
local function pickWeighted(weighted: { any }, random: () -> number): number
	local total = 0
	for _, entry in weighted do
		total += entry.weight
	end
	local pick = random() * total
	for index, entry in weighted do
		pick -= entry.weight
		if pick < 0 then
			return index
		end
	end
	return #weighted
end

--[[
	A random variant of `kind` (`random()` in 0..1): for kinds with looks a look by weight, then a
	skin tone, uniformly (MobList.lookVariant); a `variants` colour by weight; else 1.
]]
function MobList.randomVariant(kind: Kind, random: () -> number): number
	local looks = MobList.looksOf(kind)
	if looks then
		local look = pickWeighted(looks, random)
		local skin = math.min(math.floor(random() * #MobList.SKIN_TONES) + 1, #MobList.SKIN_TONES)
		return MobList.lookVariant(look, skin)
	end
	local variants = kind.variants
	if variants == nil then
		return 1
	end
	return pickWeighted(variants, random)
end

return MobList
