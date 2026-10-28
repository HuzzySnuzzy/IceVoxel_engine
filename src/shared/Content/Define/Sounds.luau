--!strict
--[[
	Content/Define's sound events (Content/Schema's SoundSpec; Content/Define lists them): the
	files every Roblox client ships and the game's recordings several packs play, the block sound
	type family (a type's five events, scaled per action as Minecraft does) and a mob's voice (its
	hurt and death).

	The files a client ships (content/sounds in Roblox's file manifest, checked for version 0.741):
	action_falling.ogg, action_footsteps_plastic.mp3, action_get_up.mp3, action_jump.mp3,
	action_jump_land.mp3, action_swim.mp3, impact_explosion_03.mp3, impact_water.mp3, oof.ogg,
	ouch.ogg and volume_slider.ogg. The game makes sound with those alone, stand-ins told apart by
	pitch and volume; the classic gear sounds (glassbreak.wav, snap.wav, button.wav,
	swordslash.wav, unsheath.wav...) and uuhhh.mp3 are no longer shipped. How long the files are
	was not checked: `duration` cuts the walking loop to its first footstep (ONE_STEP) and the
	explosion to its crack on a guess.

	Block sound types (`blockSounds`, Minecraft's SoundType): a type has a volume and pitch (`v`,
	`p`), a `dig` clip (breaking and placing) and a `step` clip (walking, hitting, falling), and may
	give single actions a clip of their own (glass shatters). Its events are
	block.<type>.<action> for BLOCK_ACTIONS, with Minecraft's scaling of the clip's volume and pitch
	(Block / LivingEntity / MultiPlayerGameMode):
	  break  dig,  volume x (v + 1) / 2, pitch x p x 0.8
	  place  dig,  volume x (v + 1) / 2, pitch x p x 0.8
	  hit    step, volume x (v + 1) / 8, pitch x p x 0.5   (every 4 ticks while mining)
	  step   step, volume x v x 0.15,    pitch x p
	  fall   step, volume x v x 0.5,     pitch x p x 0.75  (a landing that hurts)
	Breaking and placing play the fourth data sheet's recordings (RECORDINGS.BREAK, .PLACE: "Main
	SFX", the fallback block break and place sounds) at the type's `dig` volume, pitch and variance,
	so the per type scaling still tells the materials apart, the `dig` clip itself their fallback
	should one fail to load; unless the type gives that action its own clip (glass's shatter) or
	`recorded = false` (water: a bucket's splash, not a block's). The events are final: the
	catalogue (Shared/Sounds) plays their volume and pitch as they are, and a developer's Sound
	named block.<type>.break (or block.break) still replaces them. A block names its type
	(`sound = "stone"`); a type is one once the packs' sounds give its five events (Shared/Blocks
	.SOUND_TYPES).
]]

local Schema = require(script.Parent.Parent.Schema)

type SoundSpec = Schema.SoundSpec
type FallbackSpec = Schema.FallbackSpec

-- A clip of a block sound type: its file and how it is played (Schema's SoundSpec fields).
export type Clip = {
	id: string,
	volume: number?,
	pitch: number?,
	pitchVariance: number?,
	duration: number?,
	fallback: FallbackSpec?,
}

-- A block sound type (`blockSounds`).
export type BlockSoundType = {
	name: string,
	-- Minecraft's SoundType volume and pitch.
	volume: number,
	pitch: number,
	dig: Clip,
	step: Clip,
	-- Clips for single actions, instead of `dig` / `step` (scaled the same way).
	actions: { [string]: Clip }?,
	-- false: breaking and placing play `dig`, not the game's recordings.
	recorded: boolean?,
}

-- One of Minecraft's actions on blocks: which clip of the type it plays, its scaling of the type's
-- volume (v x volumeScale + volumeAdd) and pitch (p x pitch), who plays it and its voice limit.
export type BlockAction = {
	name: string,
	clip: string,
	volumeScale: number,
	volumeAdd: number,
	pitch: number,
	side: string,
	limit: number?,
}

-- A mob's voice (`mobVoice`): its name in the events and the pitch of its hurt and death.
export type MobVoice = { kind: string, hurt: number, death: number }

local Sounds = {}

-- Sound.Volume of an event that gives none (Shared/Sounds.DEFAULT_VOLUME).
Sounds.DEFAULT_VOLUME = 0.5

-- The files every client ships (the header); RbxCharacterSounds uses most of them.
Sounds.SHIPPED = table.freeze({
	-- A thud.
	LAND = "rbxasset://sounds/action_jump_land.mp3",
	-- Footsteps (the walking loop).
	STEPS = "rbxasset://sounds/action_footsteps_plastic.mp3",
	SWIM = "rbxasset://sounds/action_swim.mp3",
	SPLASH = "rbxasset://sounds/impact_water.mp3",
	-- Wind (the free fall loop).
	FALLING = "rbxasset://sounds/action_falling.ogg",
	-- A rustle.
	GET_UP = "rbxasset://sounds/action_get_up.mp3",
	-- Explosion's boom.
	EXPLOSION = "rbxasset://sounds/impact_explosion_03.mp3",
	OOF = "rbxasset://sounds/oof.ogg",
	OUCH = "rbxasset://sounds/ouch.ogg",
	-- The settings menu's volume tick.
	TICK = "rbxasset://sounds/volume_slider.ogg",
})

--[[
	The data sheets' recordings more than one pack plays (each pack's own stay in its sounds):
	the fourth sheet's "Main SFX", a block broken and a block placed ("Fallback block break sound",
	"Fallback block place sound": every block sound type's, `blockSounds`), and the fifth sheet's
	"Entity Hit" ("replace all entity hit sounds with this": a blow or a bullet landing on a mob or
	a player) and the machines' hums ("Electric Hum", 7 s looped; "Heavy Electric Hum", 9 s looped,
	"For more consuming machines").
]]
Sounds.RECORDINGS = table.freeze({
	BREAK = "rbxassetid://73168198865721",
	PLACE = "rbxassetid://101534882480796",
	ENTITY_HIT = "rbxassetid://139520673393967",
	ELECTRIC_HUM = "rbxassetid://120250063764346",
	HEAVY_HUM = "rbxassetid://138159989881933",
})

-- The first footstep of the walking loop (seconds of the file).
Sounds.ONE_STEP = 0.3

-- Minecraft's actions on blocks and its scaling of the type's volume (v) and pitch (p), in the
-- order a type's events come; `limit` the most of a kind playing at once (Audio/SoundRules: a
-- hit lasts about 0.6 s and comes every 0.2 s; footsteps pile up in a crowd).
Sounds.BLOCK_ACTIONS = table.freeze({
	{ name = "break", clip = "dig", volumeScale = 0.5, volumeAdd = 0.5, pitch = 0.8, side = "predicted" },
	{ name = "place", clip = "dig", volumeScale = 0.5, volumeAdd = 0.5, pitch = 0.8, side = "predicted" },
	{ name = "hit", clip = "step", volumeScale = 0.125, volumeAdd = 0.125, pitch = 0.5, side = "client", limit = 3 },
	{ name = "step", clip = "step", volumeScale = 0.15, volumeAdd = 0, pitch = 1, side = "client", limit = 6 },
	{ name = "fall", clip = "step", volumeScale = 0.5, volumeAdd = 0, pitch = 0.75, side = "predicted" },
} :: { BlockAction })

-- The recordings breaking and placing play (the header).
local RECORDED: { [string]: string } = { ["break"] = Sounds.RECORDINGS.BREAK, place = Sounds.RECORDINGS.PLACE }

--[[
	A block sound type's five events, block.<name>.<action> (category block.<action>, source
	blocks), its clips scaled per action (the header), fallbacks too; the recordings for breaking
	and placing unless it says otherwise.
]]
function Sounds.blockSounds(soundType: BlockSoundType): { SoundSpec }
	local own = soundType.actions or {}
	local events: { SoundSpec } = {}
	for _, action in Sounds.BLOCK_ACTIONS do
		local clip = own[action.name]
		local recording = RECORDED[action.name]
		if clip == nil and recording and soundType.recorded ~= false then
			local dig = soundType.dig
			clip = {
				id = recording,
				volume = dig.volume,
				pitch = dig.pitch,
				pitchVariance = dig.pitchVariance,
				fallback = { id = dig.id, volume = dig.volume, pitch = dig.pitch, duration = dig.duration },
			}
		end
		local played: Clip = clip or (if action.clip == "dig" then soundType.dig else soundType.step)
		local volumeScale = soundType.volume * action.volumeScale + action.volumeAdd
		local pitchScale = soundType.pitch * action.pitch
		local volume = played.volume or Sounds.DEFAULT_VOLUME
		local pitch = played.pitch or 1
		local fallback = played.fallback
		table.insert(events, {
			name = `block.{soundType.name}.{action.name}`,
			category = `block.{action.name}`,
			id = played.id,
			volume = volume * volumeScale,
			pitch = pitch * pitchScale,
			-- (The variance scales with the pitch, as it is part of it.)
			pitchVariance = (played.pitchVariance or 0) * pitchScale,
			duration = played.duration,
			fallback = if fallback
				then {
					id = fallback.id,
					volume = (fallback.volume or volume) * volumeScale,
					pitch = (fallback.pitch or pitch) * pitchScale,
					duration = fallback.duration or played.duration,
				}
				else nil,
			source = "blocks",
			side = action.side,
			limit = action.limit,
		})
	end
	return events
end

--[[
	A mob's voice: entity.<kind>.hurt and entity.<kind>.death (Minecraft's LivingEntity
	.playHurtSound, die), from the server to everyone near, in the categories entity.mob.hurt and
	entity.mob.death. Stand-ins told apart by pitch: the ouch hurts, the oof dies (low for cows and
	the brute, high for chickens and the screamer).
]]
function Sounds.mobVoice(voice: MobVoice): { SoundSpec }
	return {
		{
			name = `entity.{voice.kind}.hurt`,
			category = "entity.mob.hurt",
			id = Sounds.SHIPPED.OUCH,
			volume = 0.5,
			pitch = voice.hurt,
			pitchVariance = 0.1,
			source = "players",
			side = "server",
		},
		{
			name = `entity.{voice.kind}.death`,
			category = "entity.mob.death",
			id = Sounds.SHIPPED.OOF,
			volume = 0.6,
			pitch = voice.death,
			pitchVariance = 0.05,
			source = "players",
			side = "server",
		},
	}
end

return Sounds
