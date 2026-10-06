--!strict
--[[
	Every sound the game makes: Minecraft's sound events (`block.stone.break`, `entity.item.pickup`,
	`ui.button.click`...) and what each one plays. Shared/Sounds numbers them into the catalogue;
	clients play them (Audio/SoundPlayer) and the server says which ones to play where (server
	Audio/Sounds, Protocol `Sound`).

	The sounds are files every Roblox client ships with (rbxasset://sounds/...), so the game makes
	sound with nothing uploaded. They are stand-ins, told apart by pitch and volume. To use real
	sounds, put Sound instances named like the events in a folder (README, "Sounds"), or change the
	`id`s here to your own rbxassetid://.

	Built-in files: a client ships only eleven sounds (content/sounds in Roblox's file manifest,
	checked for version 0.741): action_falling.ogg, action_footsteps_plastic.mp3,
	action_get_up.mp3, action_jump.mp3, action_jump_land.mp3, action_swim.mp3,
	impact_explosion_03.mp3, impact_water.mp3, oof.ogg, ouch.ogg and volume_slider.ogg. Only those
	are used. The classic gear sounds (glassbreak.wav, snap.wav, button.wav, swordslash.wav,
	unsheath.wav...) and uuhhh.mp3 are no longer shipped. A `fallback` is still played when a file
	fails to load. How long the files are was not checked: `duration` cuts the walking loop to its
	first footstep (and the explosion to its crack) on a guess.

	Fields of a clip (EVENTS, and the clips of BLOCK_TYPES):
	  id             rbxasset://sounds/... or rbxassetid://...
	  volume         Sound.Volume (default 0.5)
	  pitch          Sound.PlaybackSpeed (default 1)
	  pitchVariance  the pitch varies randomly by up to this much either way (default 0)
	  duration       seconds of the file to play (it stops at that TimePosition); nil: all of it
	  fallback       a clip played instead when `id` fails to load; its missing fields are the
	                 clip's own
	Events also have:
	  name           Minecraft's event name
	  category       the name with the variant left out, which a developer's Sound may also have
	                 to replace every variant at once (item.armor.equip for equip_iron...)
	  maxDistance    blocks it is heard from (default 16, Minecraft's); it fades out linearly
	  source         the volume it follows (Config.Sounds.Sources): "blocks", "players", "ambient"
	                 or "ui"
	  ui             played flat (2D) for the local player alone instead of at a position
	  side           who plays it:
	                   "server"     the server sends it to everyone near (the player who caused it
	                                too); clients only play what it sends
	                   "predicted"  the player who caused it hears it at once from their own
	                                client, and the server sends it to everyone else
	                   "client"     clients play it by themselves; the server never sends it

	Block sounds come by type (Blocks `sound`, Minecraft's SoundType): each type has a volume and
	pitch (`v`, `p`), a `dig` clip (breaking and placing) and a `step` clip (walking, hitting,
	falling), and may give single actions a clip of their own (glass shatters). The catalogue makes
	block.<type>.<action> for the ACTIONS below with Minecraft's scaling of the clip's volume and
	pitch (Block / LivingEntity / MultiPlayerGameMode):
	  break  dig,  volume x (v + 1) / 2, pitch x p x 0.8
	  place  dig,  volume x (v + 1) / 2, pitch x p x 0.8
	  hit    step, volume x (v + 1) / 8, pitch x p x 0.5   (every 4 ticks while mining)
	  step   step, volume x v x 0.15,    pitch x p
	  fall   step, volume x v x 0.5,     pitch x p x 0.75  (a landing that hurts)
]]

export type Clip = {
	id: string,
	volume: number?,
	pitch: number?,
	pitchVariance: number?,
	duration: number?,
	fallback: Fallback?,
}

-- A fallback clip: fields left out are the clip's own.
export type Fallback = {
	id: string,
	volume: number?,
	pitch: number?,
	duration: number?,
}

export type EventSpec = {
	name: string,
	id: string,
	volume: number?,
	pitch: number?,
	pitchVariance: number?,
	duration: number?,
	fallback: Fallback?,
	category: string?,
	maxDistance: number?,
	source: string,
	ui: boolean?,
	side: string,
}

export type BlockType = {
	-- One of Blocks.SOUND_TYPES.
	name: string,
	-- Minecraft's SoundType volume and pitch.
	volume: number,
	pitch: number,
	dig: Clip,
	step: Clip,
	-- Clips for single actions, instead of `dig` / `step` (scaled the same way).
	actions: { [string]: Clip }?,
}

export type Action = {
	name: string,
	-- Which clip of the type it plays.
	clip: string,
	-- volume x (v x volumeScale + volumeAdd), pitch x p x pitch.
	volumeScale: number,
	volumeAdd: number,
	pitch: number,
	side: string,
}

-- The cave moods (and the music, played by Audio/Music, not through this catalogue).
local MusicList = require(script.Parent.MusicList)

-- The files every client ships (content/sounds); RbxCharacterSounds uses most of them.
local LAND = "rbxasset://sounds/action_jump_land.mp3" -- a thud
local STEPS = "rbxasset://sounds/action_footsteps_plastic.mp3" -- footsteps (the walking loop)
local SWIM = "rbxasset://sounds/action_swim.mp3"
local SPLASH = "rbxasset://sounds/impact_water.mp3"
local FALLING = "rbxasset://sounds/action_falling.ogg" -- wind (the free fall loop)
local GET_UP = "rbxasset://sounds/action_get_up.mp3" -- a rustle
local EXPLOSION = "rbxasset://sounds/impact_explosion_03.mp3" -- Explosion's boom
local OOF = "rbxasset://sounds/oof.ogg"
local OUCH = "rbxasset://sounds/ouch.ogg"
local TICK = "rbxasset://sounds/volume_slider.ogg" -- the settings menu's volume tick

-- The first footstep of the walking loop (seconds of the file).
local ONE_STEP = 0.3

local SoundList = {}

-- Minecraft's actions on blocks and its scaling of the type's volume (v) and pitch (p).
SoundList.ACTIONS = {
	{ name = "break", clip = "dig", volumeScale = 0.5, volumeAdd = 0.5, pitch = 0.8, side = "predicted" },
	{ name = "place", clip = "dig", volumeScale = 0.5, volumeAdd = 0.5, pitch = 0.8, side = "predicted" },
	{ name = "hit", clip = "step", volumeScale = 0.125, volumeAdd = 0.125, pitch = 0.5, side = "client" },
	{ name = "step", clip = "step", volumeScale = 0.15, volumeAdd = 0, pitch = 1, side = "client" },
	{ name = "fall", clip = "step", volumeScale = 0.5, volumeAdd = 0, pitch = 0.75, side = "predicted" },
} :: { Action }

--[[
	Block sound types. With one thud and one footstep for everything, the pitch tells the materials
	apart, each type a step above the last when broken or placed: wool 0.6, gravel 0.72, stone
	0.8, sand 0.88, wood 0.96, grass 1.08, ringing metal 1.2 (Minecraft's metal is its stone
	sounds at pitch 1.5), snow 1.32. Glass is placed, walked on and hit like stone, as in
	Minecraft, and shatters when broken; water uses the splash and swimming sounds.
]]
SoundList.BLOCK_TYPES = {
	{
		name = "stone",
		volume = 1,
		pitch = 1,
		dig = { id = LAND, volume = 0.8, pitchVariance = 0.05 },
		step = { id = STEPS, volume = 1.6, pitch = 0.9, pitchVariance = 0.05, duration = ONE_STEP },
	},
	{
		name = "wood",
		volume = 1,
		pitch = 1.2,
		dig = { id = LAND, volume = 0.8, pitchVariance = 0.05 },
		step = { id = STEPS, volume = 1.6, pitchVariance = 0.05, duration = ONE_STEP },
	},
	{
		name = "gravel",
		volume = 1,
		pitch = 0.9,
		dig = { id = LAND, volume = 0.85, pitchVariance = 0.1 },
		step = { id = STEPS, volume = 1.6, pitch = 0.85, pitchVariance = 0.1, duration = ONE_STEP },
	},
	{
		name = "grass",
		volume = 0.8,
		pitch = 1.35,
		dig = { id = LAND, volume = 0.8, pitchVariance = 0.08 },
		step = { id = STEPS, volume = 1.6, pitchVariance = 0.08, duration = ONE_STEP },
	},
	{
		name = "sand",
		volume = 0.8,
		pitch = 1.2,
		dig = { id = LAND, volume = 0.8, pitch = 0.92, pitchVariance = 0.08 },
		step = { id = STEPS, volume = 1.6, pitch = 0.9, pitchVariance = 0.08, duration = ONE_STEP },
	},
	{
		name = "glass",
		volume = 1,
		pitch = 1,
		dig = { id = LAND, volume = 0.8, pitchVariance = 0.05 },
		step = { id = STEPS, volume = 1.6, pitch = 0.9, pitchVariance = 0.05, duration = ONE_STEP },
		actions = {
			-- The crack of an explosion, sped up and cut short: a shatter.
			["break"] = {
				id = EXPLOSION,
				volume = 0.25,
				pitch = 2.5,
				pitchVariance = 0.2,
				duration = 0.4,
				fallback = { id = LAND, volume = 0.8, pitch = 2.2 },
			},
		},
	},
	{
		name = "snow",
		volume = 0.8,
		pitch = 1.65,
		dig = { id = LAND, volume = 0.7, pitchVariance = 0.08 },
		step = { id = STEPS, volume = 1.4, pitchVariance = 0.08, duration = ONE_STEP },
	},
	{
		name = "metal",
		volume = 1,
		pitch = 1.5,
		dig = { id = LAND, volume = 0.8, pitchVariance = 0.05 },
		step = { id = STEPS, volume = 1.6, pitchVariance = 0.05, duration = ONE_STEP },
	},
	{
		name = "wool",
		volume = 0.8,
		pitch = 0.75,
		dig = { id = LAND, volume = 0.5, pitchVariance = 0.05 },
		step = { id = STEPS, volume = 1.2, pitch = 0.85, pitchVariance = 0.05, duration = ONE_STEP },
	},
	{
		name = "water",
		volume = 1,
		pitch = 1,
		-- (Placing water is Minecraft's bucket emptying: a splash.)
		dig = { id = SPLASH, volume = 0.5, pitch = 1.25, pitchVariance = 0.1 },
		step = { id = SWIM, volume = 1.6, pitch = 1.6, pitchVariance = 0.1, duration = 0.5 },
	},
} :: { BlockType }

-- Every other event. Block events (block.<type>.<action>) come first in the catalogue, then these
-- in this order.
SoundList.EVENTS = {
	-- Chests: the lid opens for the first viewer and closes after the last (ChestBlockEntity).
	{
		name = "block.chest.open",
		id = GET_UP,
		volume = 0.5,
		pitch = 0.7,
		pitchVariance = 0.03,
		source = "blocks",
		side = "server",
	},
	{
		name = "block.chest.close",
		id = LAND,
		volume = 0.6,
		pitch = 0.95,
		pitchVariance = 0.03,
		source = "blocks",
		side = "server",
	},
	-- A lit furnace crackling (AbstractFurnaceBlock.animateTick), while its window shows it burning.
	{
		name = "block.furnace.fire_crackle",
		id = STEPS,
		volume = 0.3,
		pitch = 2.4,
		pitchVariance = 0.3,
		duration = 0.1,
		source = "blocks",
		side = "client",
	},

	-- Items: picked up (at the item, ItemEntity.playerTouch) and a tool wearing out (at its owner).
	{
		name = "entity.item.pickup",
		id = LAND,
		volume = 0.3,
		pitch = 2.2,
		pitchVariance = 0.6,
		source = "players",
		side = "server",
	},
	{
		name = "entity.item.break",
		id = LAND,
		volume = 0.8,
		pitch = 1.9,
		pitchVariance = 0.2,
		source = "players",
		side = "server",
	},

	-- Players.
	{
		name = "entity.player.hurt",
		id = OUCH,
		volume = 0.6,
		pitchVariance = 0.1,
		source = "players",
		side = "server",
	},
	{ name = "entity.player.death", id = OOF, volume = 0.7, source = "players", side = "server" },
	-- A landing that hurts: up to 4 half hearts small, more big (LivingEntity.getFallDamageSound).
	{ name = "entity.player.small_fall", id = LAND, volume = 0.6, source = "players", side = "predicted" },
	{ name = "entity.player.big_fall", id = LAND, volume = 1, pitch = 0.7, source = "players", side = "predicted" },
	-- Falling into water and swimming.
	{
		name = "entity.generic.splash",
		id = SPLASH,
		volume = 0.5,
		pitchVariance = 0.2,
		source = "players",
		side = "client",
	},
	{
		name = "entity.generic.swim",
		id = SWIM,
		volume = 0.3,
		pitch = 1.6,
		pitchVariance = 0.2,
		source = "players",
		side = "client",
	},

	-- Armor put on (LivingEntity.onEquipItem), by material: a rustle, higher for chainmail and gold,
	-- lower for iron and diamond.
	{
		name = "item.armor.equip_generic",
		category = "item.armor.equip",
		id = GET_UP,
		volume = 0.6,
		source = "players",
		side = "server",
	},
	{
		name = "item.armor.equip_leather",
		category = "item.armor.equip",
		id = GET_UP,
		volume = 0.6,
		pitch = 1.1,
		source = "players",
		side = "server",
	},
	{
		name = "item.armor.equip_chain",
		category = "item.armor.equip",
		id = GET_UP,
		volume = 0.5,
		pitch = 1.45,
		source = "players",
		side = "server",
	},
	{
		name = "item.armor.equip_iron",
		category = "item.armor.equip",
		id = GET_UP,
		volume = 0.6,
		pitch = 0.9,
		source = "players",
		side = "server",
	},
	{
		name = "item.armor.equip_gold",
		category = "item.armor.equip",
		id = GET_UP,
		volume = 0.55,
		pitch = 1.25,
		source = "players",
		side = "server",
	},
	{
		name = "item.armor.equip_diamond",
		category = "item.armor.equip",
		id = GET_UP,
		volume = 0.6,
		pitch = 0.8,
		source = "players",
		side = "server",
	},

	-- Interface: buttons, tabs, page arrows.
	{
		name = "ui.button.click",
		id = TICK,
		volume = 0.5,
		duration = 0.25,
		ui = true,
		source = "ui",
		side = "client",
	},

	-- Minecraft's cave mood (Audio/CaveMood): this stand-in rumble plays only while
	-- Sounds/MusicList has no mood sounds; theirs are ambient.cave.mood1, ... (below).
	{
		name = "ambient.cave",
		id = FALLING,
		volume = 0.25,
		pitch = 0.35,
		pitchVariance = 0.05,
		duration = 6,
		source = "ambient",
		side = "client",
	},

	-- Buckets (BucketItem): filling one at the player (a players sound in Minecraft), emptying one
	-- where the water goes (a blocks sound); with a fluid tank, at the tank. Both are splashes, a
	-- light high one in, a heavier low one out.
	{
		name = "item.bucket.fill",
		id = SPLASH,
		volume = 0.5,
		pitch = 1.35,
		pitchVariance = 0.1,
		source = "players",
		side = "server",
	},
	{
		name = "item.bucket.empty",
		id = SPLASH,
		volume = 0.6,
		pitch = 0.8,
		pitchVariance = 0.1,
		source = "blocks",
		side = "server",
	},
	-- The Configurator changing a transmitter's side or colour: a click.
	{
		name = "item.configurator.click",
		id = TICK,
		volume = 0.5,
		pitch = 0.8,
		pitchVariance = 0.05,
		duration = 0.25,
		source = "players",
		side = "server",
	},

	--[[
		Lava (Minecraft 1.20.1). LavaFluid.animateTick: lava open to the air above pops now and
		then (block.lava.pop, cue volume 0.2..0.4, pitch 0.9..1.05) and bubbles (block.lava.ambient,
		the same), each client by itself (Audio/Ambience). LiquidBlock.fizz: lava hardening against
		water and lava turning water to stone hiss (block.lava.extinguish, volume 0.5, pitch
		2.6 +- 0.8; server Behaviours/Fluid). A bucket filled with lava or oil, or emptied, sounds
		thicker than water (item.bucket.fill_lava, item.bucket.empty_lava; Fluids `fillSound`,
		`emptySound`). Burning: a hurt by lava sizzles (entity.generic.burn, volume 0.4, pitch
		2..2.4: Entity.lavaHurt, a player's or an item's), water putting a burning player out hisses
		(entity.generic.extinguish_fire, volume 0.7, pitch 1.6 +- 0.4, a triangle here flattened to
		+- 0.25). These carry Minecraft's numbers themselves: the server plays them with no cue
		volume or pitch on top. Stand-ins: the splash pitched down for the pop and the buckets, the
		falling wind pitched up into a hiss or down into a rumble.
	]]
	{
		name = "block.lava.pop",
		id = SPLASH,
		volume = 0.7,
		pitch = 2.2,
		pitchVariance = 0.08,
		duration = 0.2,
		source = "blocks",
		side = "client",
	},
	{
		name = "block.lava.ambient",
		id = FALLING,
		volume = 0.6,
		pitch = 0.45,
		pitchVariance = 0.08,
		duration = 1.5,
		source = "blocks",
		side = "client",
	},
	{
		name = "block.lava.extinguish",
		id = FALLING,
		volume = 0.5,
		pitch = 2.6,
		pitchVariance = 0.3,
		duration = 0.6,
		fallback = { id = SPLASH, pitch = 2.2 },
		source = "blocks",
		side = "server",
	},
	{
		name = "item.bucket.fill_lava",
		category = "item.bucket.fill",
		id = SPLASH,
		volume = 0.5,
		pitch = 0.7,
		pitchVariance = 0.1,
		source = "players",
		side = "server",
	},
	{
		name = "item.bucket.empty_lava",
		category = "item.bucket.empty",
		id = SPLASH,
		volume = 0.6,
		pitch = 0.5,
		pitchVariance = 0.1,
		source = "blocks",
		side = "server",
	},
	{
		name = "entity.generic.burn",
		id = FALLING,
		volume = 0.4,
		pitch = 2.2,
		pitchVariance = 0.2,
		duration = 0.35,
		fallback = { id = SPLASH, pitch = 2.5 },
		source = "players",
		side = "server",
	},
	{
		name = "entity.generic.extinguish_fire",
		id = FALLING,
		volume = 0.7,
		pitch = 1.6,
		pitchVariance = 0.25,
		duration = 0.5,
		fallback = { id = SPLASH, pitch = 1.8 },
		source = "players",
		side = "server",
	},
	--[[
		Explosions (server World/Explosions: burning fuel): Minecraft's entity.generic.explode,
		played at volume 4 (heard 64 blocks away, its attenuation distance 16 x 4) and pitch
		(1 + (r1 - r2) x 0.2) x 0.7: 0.7 +- 0.14, a triangle here flattened to +- 0.1. The
		built-in boom (impact_explosion_03), whole, at volume 1 like the loudest events here;
		the server plays it with no cue on top.
	]]
	{
		name = "entity.generic.explode",
		id = EXPLOSION,
		volume = 1,
		pitch = 0.7,
		pitchVariance = 0.1,
		maxDistance = 64,
		source = "blocks",
		side = "server",
	},

	--[[
		Tough As Nails' drinking (Shared/ToughAsNails). Drinking from a bottle or a canteen is
		Minecraft's 32 tick use: entity.generic.drink (volume 0.5, pitch 0.9..1.0,
		LivingEntity.triggerItemUseEffects) every 4 ticks from the 7th and once more at the end,
		which the drinker's client plays itself while the server plays the last one to everyone
		else; a sip from a water source with an empty hand (TAN's hand drinking) plays it once. A
		Glass Bottle or a canteen filled at water: item.bottle.fill (BottleItem, volume 1). Stand-ins:
		a short swim stroke pitched up into a gulp, and the splash pitched high.
	]]
	{
		name = "entity.generic.drink",
		id = SWIM,
		volume = 0.5,
		pitch = 1.5,
		pitchVariance = 0.05,
		duration = 0.25,
		source = "players",
		side = "predicted",
	},
	{
		name = "item.bottle.fill",
		id = SPLASH,
		volume = 0.6,
		pitch = 1.7,
		pitchVariance = 0.05,
		duration = 0.5,
		source = "players",
		side = "server",
	},
} :: { EventSpec }

--[[
	The cave moods (Sounds/MusicList.Moods): ambient.cave.mood1, ambient.cave.mood2, ... in the
	category ambient.cave, so a developer's Sound named "ambient.cave" replaces them all, and one
	plays at a time (SoundRules.CAPS). Minecraft plays a mood at volume 0.5
	(SimpleSoundInstance.forAmbientMood), heard 16 blocks away with a linear fade; a mood whose file
	fails to load plays the stand-in rumble.
]]
SoundList.MOODS = {} :: { string }
for i, id in MusicList.Moods do
	local name = `ambient.cave.mood{i}`
	table.insert(SoundList.MOODS, name)
	table.insert(SoundList.EVENTS, {
		name = name,
		category = "ambient.cave",
		id = id,
		volume = 0.5,
		fallback = { id = FALLING, volume = 0.25, pitch = 0.35, duration = 6 },
		source = "ambient",
		side = "client",
	})
end
table.freeze(SoundList.MOODS)

-- The lid sounds of blocks with a menu (Blocks `menu`). Furnaces and crafting tables have none.
SoundList.MENUS = {
	Chest = { open = "block.chest.open", close = "block.chest.close" },
} :: { [string]: { open: string, close: string } }

-- Armor equip sounds by the start of the item's name (ItemList's armor materials), else
-- ARMOR_DEFAULT.
SoundList.ARMOR = {
	{ prefix = "Leather", sound = "item.armor.equip_leather" },
	{ prefix = "Chainmail", sound = "item.armor.equip_chain" },
	{ prefix = "Iron", sound = "item.armor.equip_iron" },
	{ prefix = "Gold", sound = "item.armor.equip_gold" },
	{ prefix = "Diamond", sound = "item.armor.equip_diamond" },
} :: { { prefix: string, sound: string } }
SoundList.ARMOR_DEFAULT = "item.armor.equip_generic"

-- A hurting landing of more half hearts than this sounds big.
SoundList.SMALL_FALL_MAX = 4

return SoundList
