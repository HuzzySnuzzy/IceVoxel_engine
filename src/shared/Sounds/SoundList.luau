--!strict
--[[
	Every sound the game makes: Minecraft's sound events (`block.stone.break`, `entity.item.pickup`,
	`ui.button.click`...) and what each one plays. Shared/Sounds numbers them into the catalogue;
	clients play them (Audio/SoundPlayer) and the server says which ones to play where (server
	Audio/Sounds, Protocol `Sound`).

	The sounds are files every Roblox client ships with (rbxasset://sounds/...), so the game makes
	sound with nothing uploaded. They are stand-ins, told apart by pitch and volume. To use real
	sounds, put Sound instances named like the events in a folder (README, "Sounds"), or change the
	`id`s here to your own rbxassetid://. The game's own recordings (the data sheets') are here
	where an event has none to replace: every block's break and place (BLOCK_TYPES, with the
	stand-in as each clip's `fallback`), the eating and drinking loops (whose fallback is the old
	clicks), the cave moods (Sounds/MusicList); the weather's and the zombies' replace their
	stand-ins from SoundService.IceVoxelSounds (src/sounds) instead.

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

-- The fourth data sheet's "Main SFX": a block broken and a block placed ("Fallback block break
-- sound", "Fallback block place sound"), for every block sound type (BLOCK_TYPES).
local GENERIC_BREAK = "rbxassetid://73168198865721"
local GENERIC_PLACE = "rbxassetid://101534882480796"

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
	Block sound types. With one break, one place and one footstep recording for everything, the
	pitch tells the materials apart, each type a step above the last when broken or placed: wool
	0.6, gravel 0.72, stone 0.8, sand 0.88, wood 0.96, grass 1.08, ringing metal 1.2 (Minecraft's
	metal is its stone sounds at pitch 1.5), snow 1.32. Glass is placed, walked on and hit like
	stone, as in Minecraft, and shatters when broken; water uses the splash and swimming sounds.
	Breaking and placing play the sheet's recordings (GENERIC_BREAK, GENERIC_PLACE: each type's
	`actions`, added below the list from its `dig` clip's volume, pitch and variance, so every
	type keeps its own); `dig`, the thud, is their fallback should a recording fail to load. A
	developer's Sound named block.<type>.break (or block.break) still replaces them.
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
	--[[
		Ladders, rope, vines (and hanging roots) and moss (Minecraft's SoundType.LADDER, VINE and
		MOSS / MOSS_CARPET, Supplementaries' rope): a ladder a woody step just under wood's (a
		climber hears it every metre and a half), rope a dull low one, vines a light rustle above
		grass, moss a soft step between wood and grass. Every step pitch stays apart from the others'.
	]]
	{
		name = "ladder",
		volume = 1,
		pitch = 1,
		dig = { id = LAND, volume = 0.8, pitch = 1.05, pitchVariance = 0.05 },
		step = { id = STEPS, volume = 1.6, pitchVariance = 0.05, duration = ONE_STEP },
	},
	{
		name = "rope",
		volume = 0.8,
		pitch = 0.85,
		dig = { id = LAND, volume = 0.6, pitchVariance = 0.05 },
		step = { id = STEPS, volume = 1.2, pitch = 0.85, pitchVariance = 0.05, duration = ONE_STEP },
	},
	{
		name = "vine",
		volume = 1,
		pitch = 1.45,
		dig = { id = LAND, volume = 0.7, pitchVariance = 0.08 },
		step = { id = STEPS, volume = 1.4, pitchVariance = 0.08, duration = ONE_STEP },
	},
	{
		name = "moss",
		volume = 1,
		pitch = 1.25,
		dig = { id = LAND, volume = 0.7, pitch = 0.95, pitchVariance = 0.08 },
		step = { id = STEPS, volume = 1.4, pitchVariance = 0.08, duration = ONE_STEP },
	},
} :: { BlockType }

--[[
	Every type's break and place clip: the sheet's recording at the type's `dig` volume, pitch and
	variance (so Minecraft's per type scaling, ACTIONS, still tells the materials apart), with the
	`dig` clip itself as the fallback. A type's own clip for an action stays (glass's shatter);
	water keeps its splash for both (Minecraft's bucket, not a block's).
]]
SoundList.RECORDED = table.freeze({ ["break"] = GENERIC_BREAK, place = GENERIC_PLACE }) :: { [string]: string }
for _, blockType in SoundList.BLOCK_TYPES do
	if blockType.name ~= "water" then
		local dig = blockType.dig
		local actions: { [string]: Clip } = blockType.actions or {}
		blockType.actions = actions
		for action, id in SoundList.RECORDED do
			if actions[action] == nil then
				actions[action] = {
					id = id,
					volume = dig.volume,
					pitch = dig.pitch,
					pitchVariance = dig.pitchVariance,
					fallback = { id = dig.id, volume = dig.volume, pitch = dig.pitch, duration = dig.duration },
				}
			end
		end
	end
end

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
	-- Wooden doors opening and closing (DoorBlock.playSound: BlockSetType's door sounds, volume 1,
	-- pitch 0.9 to 1). The player using one hears it at once (Blocks/Doors predicts the door);
	-- a double door plays once. Swap them for real recordings in SoundService.IceVoxelSounds.
	{
		name = "block.wooden_door.open",
		id = GET_UP,
		volume = 0.7,
		pitch = 0.8,
		pitchVariance = 0.05,
		source = "blocks",
		side = "predicted",
	},
	{
		name = "block.wooden_door.close",
		id = LAND,
		volume = 0.8,
		pitch = 0.85,
		pitchVariance = 0.05,
		source = "blocks",
		side = "predicted",
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
		else; a sip from a water source with an empty hand (TAN's hand drinking) plays it once. The
		gulps every 4 ticks now play only when the drinking loop's recording fails to load
		(entity.generic.drinking, below); the last one and the sip always. A Glass Bottle or a
		canteen filled at water: item.bottle.fill (BottleItem, volume 1). Stand-ins: a short swim
		stroke pitched up into a gulp, and the splash pitched high.
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

	--[[
		Fire (Minecraft 1.20.1). BaseFireBlock.animateTick: a fire crackles one time in 24 that the
		client's random display tick picks it (block.fire.ambient, cue volume 1..2, pitch 0.3..1;
		Audio/Ambience, SoundRules.fireCrackle), each client by itself. Punching a fire out sounds like
		level event 1009 (block.fire.extinguish, volume 0.5, pitch 2.6 +- 0.8, as lava's fizz): it
		is the Fire block's break sound (BLOCK_SOUNDS below), so the player who breaks it hears it
		at once and the server sends it to everyone else. Flint and steel striking
		(item.flintandsteel.use, FlintAndSteelItem.useOn: volume 1, pitch 0.8..1.2), from the
		server (Players/ItemUse). Stand-ins: the falling wind pitched down into a low roar for the
		crackle and up into a hiss for the extinguish, the volume slider's tick pitched down for
		the strike. No asset of Minecraft's: give a Sound of the event's name to use a real one
		(README, "Sounds").
	]]
	{
		name = "block.fire.ambient",
		id = FALLING,
		volume = 0.3,
		pitch = 0.9,
		pitchVariance = 0.1,
		duration = 1.2,
		fallback = { id = STEPS, volume = 0.6, pitch = 0.5, duration = ONE_STEP },
		source = "blocks",
		side = "client",
	},
	{
		name = "block.fire.extinguish",
		-- (Fire's break sound: a developer's block.break Sound replaces it too.)
		category = "block.break",
		id = FALLING,
		volume = 0.5,
		pitch = 2.6,
		pitchVariance = 0.3,
		duration = 0.6,
		fallback = { id = SPLASH, pitch = 2.2 },
		source = "blocks",
		side = "predicted",
	},
	{
		name = "item.flintandsteel.use",
		id = TICK,
		volume = 0.8,
		pitch = 0.7,
		pitchVariance = 0.2,
		duration = 0.25,
		fallback = { id = LAND, volume = 0.5, pitch = 2.4 },
		source = "blocks",
		side = "server",
	},

	--[[
		TNT and the Nuke (server Behaviours/Tnt, World/Nuke). Lighting TNT hisses
		(entity.tnt.primed: PrimedTnt's constructor plays it at volume 1, pitch 1, from the server):
		the falling wind pitched up into a fizz, cut short. The Nuke (no Minecraft sound; this
		game's): every second while it is lit an alarm beeps (entity.nuke.alarm: the volume tick
		pitched up, loud, heard 64 blocks away), and it goes off with a deep, long boom
		(entity.nuke.explode: the explosion pitched far down, heard 256 blocks away). Stand-ins;
		give a Sound of the event's name to use a real one (README, "Sounds").
	]]
	{
		name = "entity.tnt.primed",
		id = FALLING,
		volume = 0.7,
		pitch = 2.2,
		duration = 1.5,
		fallback = { id = SPLASH, pitch = 2.6 },
		source = "blocks",
		side = "server",
	},
	{
		name = "entity.nuke.alarm",
		id = TICK,
		volume = 1,
		pitch = 1.6,
		duration = 0.4,
		fallback = { id = LAND, pitch = 3 },
		maxDistance = 64,
		source = "blocks",
		side = "server",
	},
	{
		name = "entity.nuke.explode",
		id = EXPLOSION,
		volume = 1,
		pitch = 0.35,
		pitchVariance = 0.05,
		maxDistance = 256,
		source = "blocks",
		side = "server",
	},
} :: { EventSpec }

--[[
	Blocks whose action sounds are their own rather than their sound type's (Sounds.block): by
	block name, action -> event. Punching fire out is Minecraft's level event 1009 (the
	extinguish hiss), not a wool block's break.
]]
SoundList.BLOCK_SOUNDS = {
	Fire = { ["break"] = "block.fire.extinguish" },
} :: { [string]: { [string]: string } }

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
	-- (Tough As Nails' straw and leaf armor: soft, like leather.)
	{ prefix = "Straw", sound = "item.armor.equip_leather" },
	{ prefix = "Leaf", sound = "item.armor.equip_leather" },
} :: { { prefix: string, sound: string } }
SoundList.ARMOR_DEFAULT = "item.armor.equip_generic"

-- A hurting landing of more half hearts than this sounds big.
SoundList.SMALL_FALL_MAX = 4

--[[
	Tough As Nails' campfire (BlockList Campfire, Shared/ToughAsNails/Boiling): dirty water held
	over it boils clean with a bubbling hiss (block.campfire.boil, this game's: Minecraft's
	campfire cooks food, it boils nothing), from the server (Players/ItemUse) at the campfire. The
	campfire's crackle is fire's (block.fire.ambient, Audio/Ambience). Stand-in: the splash pitched
	up and cut short; give a Sound of the event's name to use a real one (README, "Sounds").
]]
table.insert(SoundList.EVENTS, {
	name = "block.campfire.boil",
	id = SPLASH,
	volume = 0.5,
	pitch = 1.3,
	pitchVariance = 0.1,
	duration = 0.6,
	fallback = { id = FALLING, pitch = 2.4 },
	source = "blocks",
	side = "server",
})

--[[
	Mobs (Shared/Entities/MobList, server Mobs/MobWorld), from the server to everyone near: each
	voice's hurt and death (Minecraft's entity.<kind>.hurt and .death: LivingEntity.playHurtSound,
	die): the farm animals, the zombie (which most zombie kinds use) and the runner's, brute's and
	screamer's own voices; a player's hit landing (entity.player.attack.strong, or .weak before
	the weapon recovered: Player.attack, 1.9's attack strength) and eating (entity.generic.eat
	every 4 ticks from the 7th of the 32 tick hold, and entity.player.burp at the end: Player.eat;
	the eater's client plays its own, the server the last one to everyone else; the bites now play
	only when the eating loop's recording fails to load: entity.generic.eating). Stand-ins told
	apart by pitch: the ouch and the oof for hurts and deaths (low for cows and the brute, high for
	chickens and the screamer), the landing thud into the hits, a footstep into a bite. The
	zombies' groans, door bashing and screams, and the bunker hatch, are with the apocalypse's
	sounds at the end of the list.

	The zombies' real voices (the sheet's "Mob SFX": a growl for every hurt, two deaths) ship as
	Sounds named like these events in SoundService.IceVoxelSounds (src/sounds/Zombies.model.json),
	which play instead of the stand-ins; the stand-ins stay, for a game without that folder (or
	a recording that fails to load: Audio/SoundPlayer then plays the event's own sound again).
	Each voice has its own Sounds, named by the event, never by the category: entity.mob.hurt
	would make the cows growl too. A replacement plays at its own PlaybackSpeed varied by the
	event's variance as a share of its pitch (Audio/SoundRules.playback): when hurt about +-13%
	for the zombie, +-10% the runner, +-22% the brute and +-6% the screamer, half that or less
	dying. So the model pitches the kinds 1, 1.3, 0.65 and 1.6, in the stand-ins' order and, as
	theirs, with no two kinds' spreads overlapping (tests/spec/ZombieVoices checks it).
]]
-- Each voice's event name and the pitch of its hurt and death.
local MOB_VOICES: { { kind: string, hurt: number, death: number } } = {
	{ kind = "cow", hurt = 0.55, death = 0.5 },
	{ kind = "sheep", hurt = 1.35, death = 1.3 },
	{ kind = "pig", hurt = 1.15, death = 1.1 },
	{ kind = "chicken", hurt = 1.9, death = 1.8 },
	{ kind = "zombie", hurt = 0.75, death = 0.7 },
	{ kind = "zombie_runner", hurt = 1.05, death = 1.0 },
	{ kind = "zombie_brute", hurt = 0.45, death = 0.4 },
	{ kind = "zombie_screamer", hurt = 1.55, death = 1.5 },
}
for _, voice in MOB_VOICES do
	local kind, hurt, death = voice.kind, voice.hurt, voice.death
	table.insert(SoundList.EVENTS, {
		name = `entity.{kind}.hurt`,
		category = "entity.mob.hurt",
		id = OUCH,
		volume = 0.5,
		pitch = hurt,
		pitchVariance = 0.1,
		source = "players",
		side = "server",
	})
	table.insert(SoundList.EVENTS, {
		name = `entity.{kind}.death`,
		category = "entity.mob.death",
		id = OOF,
		volume = 0.6,
		pitch = death,
		pitchVariance = 0.05,
		source = "players",
		side = "server",
	})
end
for _, event in
	{
		{
			name = "entity.player.attack.strong",
			category = "entity.player.attack",
			id = LAND,
			volume = 0.6,
			pitch = 1.3,
			pitchVariance = 0.1,
			source = "players",
			side = "server",
		},
		{
			name = "entity.player.attack.weak",
			category = "entity.player.attack",
			id = LAND,
			volume = 0.35,
			pitch = 1.8,
			pitchVariance = 0.1,
			source = "players",
			side = "server",
		},
		{
			name = "entity.generic.eat",
			id = STEPS,
			volume = 0.5,
			pitch = 1.8,
			pitchVariance = 0.2,
			duration = 0.15,
			source = "players",
			side = "predicted",
		},
		{
			name = "entity.player.burp",
			id = SWIM,
			volume = 0.5,
			pitch = 0.7,
			pitchVariance = 0.1,
			duration = 0.4,
			source = "players",
			side = "predicted",
		},
	} :: { EventSpec }
do
	table.insert(SoundList.EVENTS, event)
end

--[[
	Progression (Shared/Progression, client Player/ProgressionState): knowledge gained plays
	Minecraft's entity.experience_orb.pickup (at most a few a second), a level gained
	entity.player.levelup (Minecraft plays it every 5 levels; here every level, the skill point
	it gives being worth hearing), and an Age reached ui.toast.challenge_complete with its
	banner (Minecraft's challenge advancement toast). The player's own client plays them, flat.
	Stand-ins: the menu's tick pitched up into a chime, then lower and longer for the fanfare.
]]
table.insert(SoundList.EVENTS, {
	name = "entity.experience_orb.pickup",
	id = TICK,
	volume = 0.3,
	pitch = 1.8,
	pitchVariance = 0.25,
	duration = 0.2,
	ui = true,
	source = "ui",
	side = "client",
})
table.insert(SoundList.EVENTS, {
	name = "entity.player.levelup",
	id = TICK,
	volume = 0.6,
	pitch = 1.25,
	duration = 0.6,
	ui = true,
	source = "ui",
	side = "client",
})
table.insert(SoundList.EVENTS, {
	name = "ui.toast.challenge_complete",
	id = TICK,
	volume = 0.7,
	pitch = 0.75,
	duration = 1.2,
	ui = true,
	source = "ui",
	side = "client",
})

--[[
	Weather (Minecraft 1.20.1; client Weather/PrecipitationView and Weather/LightningView, each
	client by itself, as Minecraft's sound source WEATHER, which here is the ambient volume).
	LevelRenderer.tickRain: rain landing near the player (weather.rain, volume 0.2, pitch 1) or on
	a roof over them (weather.rain.above, 0.1, 0.5), a sound every 2-3 ticks while it rains,
	louder with the precipitation here (Shared/Weather.rainSound: those volumes are the cue's);
	LightningBolt.tick: thunder (entity.lightning_bolt.thunder, Minecraft's volume 10000, heard
	everywhere, pitch 0.8..1) and the strike's crack (entity.lightning_bolt.impact, volume 2,
	pitch 0.5..0.7), the thunder later the farther the bolt (Shared/Weather.thunderDelay).
	Stand-ins: the falling wind pitched up into a hiss for rain (down and muffled on a roof), the
	explosion pitched far down into a rumble for thunder and half down for the crack. Give a Sound
	of the event's name to use a real one (README, "Sounds").
]]
for _, event in
	{
		{
			name = "weather.rain",
			id = FALLING,
			volume = 0.9,
			pitch = 1.9,
			pitchVariance = 0.1,
			duration = 1.6,
			source = "ambient",
			side = "client",
		},
		{
			name = "weather.rain.above",
			id = FALLING,
			volume = 1,
			pitch = 1.1,
			pitchVariance = 0.08,
			duration = 1.6,
			source = "ambient",
			side = "client",
		},
		{
			name = "entity.lightning_bolt.thunder",
			id = EXPLOSION,
			volume = 1,
			pitch = 0.32,
			pitchVariance = 0.05,
			maxDistance = 48,
			source = "ambient",
			side = "client",
		},
		{
			name = "entity.lightning_bolt.impact",
			id = EXPLOSION,
			volume = 0.8,
			pitch = 0.6,
			pitchVariance = 0.1,
			maxDistance = 32,
			source = "ambient",
			side = "client",
		},
	} :: { EventSpec }
do
	table.insert(SoundList.EVENTS, event)
end

--[[
	Distant storms (not Minecraft's, which has no weather far off; client Weather/LightningView and
	Weather/StormView): thunder from a strike or a flash in the clouds far away
	(entity.lightning_bolt.thunder.far: the thunder's stand-in pitched lower still; its category is
	the thunder, so a developer's Sound named entity.lightning_bolt.thunder plays here too unless
	one of this name is given), played muffled, lower and longer the farther it is
	(Weather/DistantStorms), and the hiss of rain falling nearby but not here (weather.rain.far:
	the rain's stand-in, lower, looped and muffled while it lasts). Both are played by each client
	by itself, at the ambient volume, and come after the rest so no other event's number changed.
]]
for _, event in
	{
		{
			name = "entity.lightning_bolt.thunder.far",
			category = "entity.lightning_bolt.thunder",
			id = EXPLOSION,
			volume = 1,
			pitch = 0.27,
			pitchVariance = 0.06,
			maxDistance = 48,
			source = "ambient",
			side = "client",
		},
		{
			name = "weather.rain.far",
			id = FALLING,
			volume = 0.7,
			pitch = 1.45,
			pitchVariance = 0,
			source = "ambient",
			side = "client",
		},
	} :: { EventSpec }
do
	table.insert(SoundList.EVENTS, event)
end

--[[
	Terraria's things (not Minecraft's; Config.Accessories, Mana): a Cloud in a Bottle's jump in
	the air (entity.player.double_jump: Terraria's puff; the jumper's client plays it at once and
	the others' clients when they see the air jump), a Mana Crystal used (item.mana_crystal.use:
	Terraria's crystal chime, from the server), a magic weapon cast (item.magic.cast: predicted,
	like an attack) and its projectile hitting something (entity.magic.hit, from the server), a
	Fallen Star falling (entity.fallen_star.fall: Terraria's whoosh, from the server near it), and
	mana full again after it was spent (entity.player.mana_full: Terraria's soft chime, the player's
	own client, flat). Stand-ins: the rustle pitched up into a puff, the menu's tick as chimes, the
	splash pitched up into a fizz, the falling wind pitched up; after the rest, so no other event's
	number changed. Give a Sound of the event's name to use a real one (README, "Sounds").
]]
for _, event in
	{
		{
			name = "entity.player.double_jump",
			id = GET_UP,
			volume = 0.5,
			pitch = 1.5,
			pitchVariance = 0.05,
			source = "players",
			side = "client",
		},
		{
			name = "item.mana_crystal.use",
			id = TICK,
			volume = 0.8,
			pitch = 1.4,
			duration = 0.8,
			source = "players",
			side = "server",
		},
		{
			name = "item.magic.cast",
			id = SPLASH,
			volume = 0.35,
			pitch = 2.2,
			pitchVariance = 0.1,
			duration = 0.3,
			source = "players",
			side = "predicted",
		},
		{
			name = "entity.magic.hit",
			id = SPLASH,
			volume = 0.4,
			pitch = 1.7,
			pitchVariance = 0.15,
			duration = 0.4,
			source = "players",
			side = "server",
		},
		{
			name = "entity.fallen_star.fall",
			id = FALLING,
			volume = 0.6,
			pitch = 1.8,
			pitchVariance = 0.1,
			duration = 1.5,
			maxDistance = 48,
			source = "ambient",
			side = "server",
		},
		{
			name = "entity.player.mana_full",
			id = TICK,
			volume = 0.4,
			pitch = 2,
			duration = 0.4,
			ui = true,
			source = "ui",
			side = "client",
		},
	} :: { EventSpec }
do
	table.insert(SoundList.EVENTS, event)
end

--[[
	Wind (not Minecraft's, which has none: client Weather/WindSound and Weather/StormView): a loop
	around the player outdoors (weather.wind), louder in a stronger wind, in a storm and high up,
	quieter and duller under a roof, silent underground. The stand-in is the falling wind pitched
	down; the game ships a real loop in SoundService.IceVoxelSounds (src/sounds). After the rest,
	so no other event's number changed.
]]
table.insert(
	SoundList.EVENTS,
	{
		name = "weather.wind",
		id = FALLING,
		volume = 0.5,
		pitch = 0.6,
		pitchVariance = 0,
		source = "ambient",
		side = "client",
	} :: EventSpec
)

--[[
	The zombie apocalypse (server Mobs/, Apocalypse/, Players/ToggleUse; client Entities/
	ZombieVoices, Ui/SurvivorHud), after the rest. Stand-ins:
	  entity.zombie.ambient              a zombie's groan: the oof pitched down. Each client plays
	                                     it from the zombies it tracks (no server event), at the
	                                     gait's pitch (ZombieVoices.PITCH). The game ships the
	                                     sheet's three groans in SoundService.IceVoxelSounds
	                                     (src/sounds/Zombies.model.json): one of them plays.
	  entity.zombie.attack_wooden_door   a zombie bashing the block it breaks: a heavy thud
	  entity.zombie.break_wooden_door    the block giving way: the explosion's crack pitched up
	  entity.zombie_screamer.scream      a screamer's shriek: the falling wind pitched far up
	  block.bunker_hatch.open / .close   the steel hatch: low thuds
	  item.bandage.apply                 a bandage or poultice wrapped on: a rustle
	  item.medkit.use                    a medkit used: a longer rustle
	  item.pills.swallow                 pills swallowed: the swim gulp pitched up
	  ambient.blood_moon.rise            a blood moon rising: a long, deep boom, flat
	Every one is an ordinary event, so a Sound of its name in SoundService.IceVoxelSounds (or the
	override folder) replaces it.
]]
for _, event in
	{
		{
			name = "entity.zombie.ambient",
			id = OOF,
			volume = 0.35,
			pitch = 0.45,
			pitchVariance = 0.12,
			maxDistance = 16,
			source = "players",
			side = "client",
		},
		{
			name = "entity.zombie.attack_wooden_door",
			id = LAND,
			volume = 0.9,
			pitch = 0.7,
			pitchVariance = 0.1,
			maxDistance = 24,
			source = "players",
			side = "server",
		},
		{
			name = "entity.zombie.break_wooden_door",
			id = EXPLOSION,
			volume = 0.45,
			pitch = 1.8,
			duration = 0.5,
			maxDistance = 32,
			source = "players",
			side = "server",
		},
		{
			name = "entity.zombie_screamer.scream",
			id = FALLING,
			volume = 1.0,
			pitch = 2.4,
			duration = 1.6,
			maxDistance = 64,
			source = "players",
			side = "server",
		},
		{
			name = "block.bunker_hatch.open",
			category = "block.bunker_hatch",
			id = LAND,
			volume = 0.8,
			pitch = 0.55,
			maxDistance = 16,
			source = "blocks",
			side = "server",
		},
		{
			name = "block.bunker_hatch.close",
			category = "block.bunker_hatch",
			id = LAND,
			volume = 0.9,
			pitch = 0.45,
			maxDistance = 16,
			source = "blocks",
			side = "server",
		},
		{
			name = "item.bandage.apply",
			id = GET_UP,
			volume = 0.5,
			pitch = 1.4,
			pitchVariance = 0.1,
			duration = 0.5,
			maxDistance = 16,
			source = "players",
			side = "predicted",
		},
		{
			name = "item.medkit.use",
			id = GET_UP,
			volume = 0.6,
			pitch = 1.0,
			duration = 0.6,
			maxDistance = 16,
			source = "players",
			side = "predicted",
		},
		{
			name = "item.pills.swallow",
			id = SWIM,
			volume = 0.4,
			pitch = 1.6,
			duration = 0.3,
			maxDistance = 16,
			source = "players",
			side = "predicted",
		},
		{
			name = "ambient.blood_moon.rise",
			id = EXPLOSION,
			volume = 0.7,
			pitch = 0.3,
			duration = 3.0,
			ui = true,
			source = "ambient",
			side = "client",
		},
	} :: { EventSpec }
do
	table.insert(SoundList.EVENTS, event)
end

--[[
	Eating and drinking loops (the fourth sheet's "Main SFX": "loop this during eating", "loop this
	during drinking"; this game's, as Minecraft clicks entity.generic.eat / .drink every 4 ticks
	instead). While a player holds the use button on a food (not medicine, which keeps its own
	sound) or a drink, the recording loops at their mouth and stops the moment the use ends:
	finished, cancelled, the slot changed, dead or gone (client Audio/UseSounds, by the rules of
	Audio/UseSoundRules). The user's own client plays theirs at once from its own hold, every other
	client from the server's player attribute (Inventory/Types.USE_ATTRIBUTE), so each client
	plays them itself. Only when a recording fails to load (Audio/SoundPlayer.loads) do the old
	clicks play instead, never both; the burp after a food and the last gulp after a drink stay.
	The ids are the recordings themselves (no stand-in: the clicks are the fallback); swap one
	here, or give a Sound of the event's name in SoundService.IceVoxelSounds, which loops too.
	After the rest, so no other event's number changed.
]]
for _, event in
	{
		{
			name = "entity.generic.eating",
			id = "rbxassetid://124005963174357",
			volume = 0.6,
			pitchVariance = 0.05,
			source = "players",
			side = "client",
		},
		{
			name = "entity.generic.drinking",
			id = "rbxassetid://79766888063175",
			volume = 0.6,
			pitchVariance = 0.03,
			source = "players",
			side = "client",
		},
	} :: { EventSpec }
do
	table.insert(SoundList.EVENTS, event)
end

--[[
	Weapons (Shared/Weapons; client Interaction/Firearms and Rendering/ShotView, server Weapons/),
	after the rest so no other event's number changed. Stand-ins on the shipped files: a gun's
	shot is the explosion's crack, cut short and pitched by its class (a pistol high and short, a
	heavy rifle low and long; every class's fire event shares the category item.firearm.fire, so
	one Sound of that name replaces them all); a suppressed shot a soft, short crack; far away
	(beyond Config.Weapons.FarSound) a low rolling boom; the crossbow's twang a rustle pitched up.
	A dry trigger and a jam click the volume tick; reloading, chambering and attaching are thuds
	pitched up; a round loaded a tick; unloading a rustle. Bullets hitting a block a high tap,
	flesh a dull thud. The melee rework's swing and heavy swing are rustles, a blocked hit a thud.

	  side       client: each client plays them (the shooter at once, the others from the Shots
	             message), never sent; predicted: the player's own client at once, the server to
	             everyone else when it accepts the action (reload, a round, chambering); server:
	             the server to everyone near (a blocked zombie hit).
	The fire event of a gun is item.firearm.<class>.fire (Shared/Weapons' FirearmSpec `sound`),
	the crossbow's item.crossbow.fire. Every one is an ordinary event: a Sound of its name in
	SoundService.IceVoxelSounds (or the override folder) replaces it.
]]
local function shot(class: string, volume: number, pitch: number, duration: number, maxDistance: number): EventSpec
	return {
		name = `item.firearm.{class}.fire`,
		category = "item.firearm.fire",
		id = EXPLOSION,
		volume = volume,
		pitch = pitch,
		pitchVariance = 0.04,
		duration = duration,
		maxDistance = maxDistance,
		source = "players",
		side = "client",
	}
end
for _, event in
	{
		shot("pistol", 0.9, 2.4, 0.25, 128),
		shot("revolver", 1.0, 2.0, 0.3, 144),
		shot("smg", 0.8, 2.7, 0.18, 128),
		shot("shotgun", 1.2, 1.3, 0.45, 160),
		shot("rifle", 1.1, 1.8, 0.35, 192),
		shot("heavy", 1.3, 1.25, 0.5, 224),
		shot("small", 0.45, 3.2, 0.12, 48),
		{
			name = "item.crossbow.fire",
			id = GET_UP,
			volume = 0.6,
			pitch = 2.2,
			duration = 0.25,
			maxDistance = 16,
			source = "players",
			side = "client",
		},
		{
			name = "item.firearm.suppressed",
			id = EXPLOSION,
			volume = 0.3,
			pitch = 3.6,
			pitchVariance = 0.1,
			duration = 0.08,
			maxDistance = 32,
			source = "players",
			side = "client",
		},
		{
			name = "item.firearm.far",
			id = EXPLOSION,
			volume = 0.5,
			pitch = 0.7,
			duration = 0.8,
			maxDistance = 256,
			source = "players",
			side = "client",
		},
		{
			name = "item.firearm.dry",
			id = TICK,
			volume = 0.5,
			pitch = 0.6,
			maxDistance = 8,
			source = "players",
			side = "client",
		},
		{
			name = "item.firearm.jam",
			id = TICK,
			volume = 0.7,
			pitch = 0.4,
			maxDistance = 8,
			source = "players",
			side = "client",
		},
		{
			name = "item.firearm.reload",
			id = LAND,
			volume = 0.5,
			pitch = 2.6,
			duration = 0.2,
			maxDistance = 16,
			source = "players",
			side = "predicted",
		},
		{
			name = "item.firearm.load_round",
			id = TICK,
			volume = 0.5,
			pitch = 1.6,
			maxDistance = 12,
			source = "players",
			side = "predicted",
		},
		{
			name = "item.firearm.chamber",
			id = LAND,
			volume = 0.6,
			pitch = 3.2,
			duration = 0.12,
			maxDistance = 16,
			source = "players",
			side = "predicted",
		},
		{
			name = "item.firearm.unload",
			id = GET_UP,
			volume = 0.4,
			pitch = 2.0,
			duration = 0.2,
			maxDistance = 8,
			source = "players",
			side = "client",
		},
		{
			name = "item.firearm.attach",
			id = LAND,
			volume = 0.4,
			pitch = 2.8,
			duration = 0.1,
			maxDistance = 8,
			source = "players",
			side = "client",
		},
		{
			name = "entity.bullet.impact",
			id = LAND,
			volume = 0.35,
			pitch = 2.2,
			pitchVariance = 0.2,
			maxDistance = 24,
			source = "players",
			side = "client",
		},
		{
			name = "entity.bullet.flesh",
			id = LAND,
			volume = 0.5,
			pitch = 1.1,
			pitchVariance = 0.1,
			maxDistance = 24,
			source = "players",
			side = "client",
		},
		{
			name = "item.melee.swing",
			id = GET_UP,
			volume = 0.4,
			pitch = 1.9,
			duration = 0.15,
			maxDistance = 12,
			source = "players",
			side = "client",
		},
		{
			name = "item.melee.heavy",
			id = GET_UP,
			volume = 0.6,
			pitch = 1.3,
			duration = 0.25,
			maxDistance = 16,
			source = "players",
			side = "client",
		},
		{
			name = "item.melee.block",
			id = LAND,
			volume = 0.8,
			pitch = 1.6,
			maxDistance = 16,
			source = "players",
			side = "server",
		},
	} :: { EventSpec }
do
	table.insert(SoundList.EVENTS, event)
end

--[[
	The seasons (Shared/Seasons), after the rest so no other event's number changed. Stand-ins on
	the shipped files, each replaced by a Sound of its name in SoundService.IceVoxelSounds (or the
	override folder):
	  block.electric_heater.hum      a working Electric Heater: the falling wind pitched down, low
	  block.air_conditioner.hum      a working Air Conditioner: the same, a little higher
	  block.fan.loop                 a running Electric Fan: the wind pitched up
	  block.wood_stove.crackle       a burning Wood Stove: the furnace's crackle, deeper
	  block.oil_heater.burn          a burning Oil Heater: the wind pitched far down, a roar
	  ui.thermostat.click            a thermostat's button: the volume tick
	  ambient.season.autumn | winter | spring | summer   a season's turn: a long low boom, flat
	                                 (category ambient.season)
	  ambient.season.heat_wave       a heat wave's dawn
	The machines' loops play at the machine while it works (client Audio/Ambience, from the
	machines' records: TransmitterRenderer.activeMachines); the turns' stingers with their toasts.
]]
for _, event in
	{
		{
			name = "block.electric_heater.hum",
			id = FALLING,
			volume = 0.25,
			pitch = 0.45,
			maxDistance = 12,
			source = "blocks",
			side = "client",
		},
		{
			name = "block.air_conditioner.hum",
			id = FALLING,
			volume = 0.25,
			pitch = 0.6,
			maxDistance = 12,
			source = "blocks",
			side = "client",
		},
		{
			name = "block.fan.loop",
			id = FALLING,
			volume = 0.2,
			pitch = 1.4,
			maxDistance = 10,
			source = "blocks",
			side = "client",
		},
		{
			name = "block.wood_stove.crackle",
			id = STEPS,
			volume = 0.35,
			pitch = 1.8,
			pitchVariance = 0.3,
			duration = 0.1,
			maxDistance = 12,
			source = "blocks",
			side = "client",
		},
		{
			name = "block.oil_heater.burn",
			id = FALLING,
			volume = 0.3,
			pitch = 0.3,
			maxDistance = 12,
			source = "blocks",
			side = "client",
		},
		{
			name = "ui.thermostat.click",
			id = TICK,
			volume = 0.5,
			pitch = 1.3,
			ui = true,
			source = "ui",
			side = "client",
		},
		{
			name = "ambient.season.autumn",
			category = "ambient.season",
			id = EXPLOSION,
			volume = 0.5,
			pitch = 0.4,
			duration = 3.0,
			ui = true,
			source = "ambient",
			side = "client",
		},
		{
			name = "ambient.season.winter",
			category = "ambient.season",
			id = EXPLOSION,
			volume = 0.5,
			pitch = 0.32,
			duration = 3.0,
			ui = true,
			source = "ambient",
			side = "client",
		},
		{
			name = "ambient.season.spring",
			category = "ambient.season",
			id = EXPLOSION,
			volume = 0.5,
			pitch = 0.5,
			duration = 3.0,
			ui = true,
			source = "ambient",
			side = "client",
		},
		{
			name = "ambient.season.summer",
			category = "ambient.season",
			id = EXPLOSION,
			volume = 0.5,
			pitch = 0.45,
			duration = 3.0,
			ui = true,
			source = "ambient",
			side = "client",
		},
		{
			name = "ambient.season.heat_wave",
			category = "ambient.season",
			id = FALLING,
			volume = 0.5,
			pitch = 0.5,
			duration = 3.0,
			ui = true,
			source = "ambient",
			side = "client",
		},
	} :: { EventSpec }
do
	table.insert(SoundList.EVENTS, event)
end

--[[
	Turrets and the Metal Miner (Shared/Turrets, Shared/Machines kinds "miner" and "press"), after
	the seasons so no other event's number changed. Loops on the shipped files, each replaced by a
	Sound of its name in SoundService.IceVoxelSounds (or the override folder):
	  block.turret.servo         a turret turning its gun: the falling wind pitched up, faint (at
	                             most Config.Turrets.Client.ServoLoops of them, the nearest)
	  block.metal_miner.drill    a working Metal Miner: the footsteps pitched down, a rapid clatter
	  block.ammo_press.stamp     a working Ammo Press: the volume tick pitched down, a thud
	The client plays them (the servo at a turning turret: Rendering/TurretView; the drill and the
	stamp while the machine works, from its record: Rendering/TransmitterModel.machineLoop). A
	turret's shots are the stand-in gun's own fire sounds (Rendering/ShotView), its dry click
	item.firearm.dry.
]]
for _, event in
	{
		{
			name = "block.turret.servo",
			id = FALLING,
			volume = 0.15,
			pitch = 1.8,
			maxDistance = 12,
			source = "blocks",
			side = "client",
		},
		{
			name = "block.metal_miner.drill",
			id = STEPS,
			volume = 0.3,
			pitch = 0.6,
			maxDistance = 12,
			source = "blocks",
			side = "client",
		},
		{
			name = "block.ammo_press.stamp",
			id = TICK,
			volume = 0.4,
			pitch = 0.5,
			maxDistance = 12,
			source = "blocks",
			side = "client",
		},
	} :: { EventSpec }
do
	table.insert(SoundList.EVENTS, event)
end

return SoundList
