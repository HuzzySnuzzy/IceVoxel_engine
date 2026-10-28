--!strict
--[[
	The Apocalypse pack's own sound helpers (its sounds/weapons module uses them): a gun class's
	shot and a calibre's recorded shots.
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)

type SoundSpec = Schema.SoundSpec

-- A firearm class's shot (sounds/weapons' CLASSES): its volume, pitch, the seconds of the crack
-- played and how far it carries.
export type ClassShot = { class: string, volume: number, pitch: number, duration: number, maxDistance: number }

-- A calibre's recordings (sounds/weapons' CALIBRES): its shot, the same through a suppressor, and
-- the class whose shot is its fallback.
export type CalibreShot = { calibre: string, fire: string, suppressed: string, class: string }

local EXPLOSION = Define.SHIPPED.EXPLOSION

local Sounds = {}

--[[
	A class's fire event, item.firearm.<class>.fire (Shared/Weapons' FirearmSpec `sound`): the
	explosion's crack cut short and pitched, client side (the shooter at once, the others from the
	Shots message), in the category item.firearm.fire, so one Sound of that name replaces them all.
]]
function Sounds.shot(spec: ClassShot): SoundSpec
	return {
		name = `item.firearm.{spec.class}.fire`,
		category = "item.firearm.fire",
		id = EXPLOSION,
		volume = spec.volume,
		pitch = spec.pitch,
		pitchVariance = 0.04,
		duration = spec.duration,
		maxDistance = spec.maxDistance,
		source = "players",
		side = "client",
	}
end

--[[
	A calibre's two events (`class`: its class's shot, from `shot`): item.firearm.<calibre>.fire,
	in the category item.firearm.fire, heard as far as its class's, the class's shot its
	fallback; and item.firearm.<calibre>.suppressed, in the category item.firearm.suppressed, the
	generic suppressed shot its fallback.
]]
function Sounds.calibreShots(spec: CalibreShot, class: SoundSpec): { SoundSpec }
	return {
		{
			name = `item.firearm.{spec.calibre}.fire`,
			category = "item.firearm.fire",
			id = spec.fire,
			volume = 1,
			pitchVariance = 0.04,
			fallback = { id = class.id, volume = class.volume, pitch = class.pitch, duration = class.duration },
			maxDistance = class.maxDistance,
			source = "players",
			side = "client",
		},
		{
			name = `item.firearm.{spec.calibre}.suppressed`,
			category = "item.firearm.suppressed",
			id = spec.suppressed,
			volume = 0.6,
			pitchVariance = 0.04,
			fallback = { id = EXPLOSION, volume = 0.3, pitch = 3.6, duration = 0.08 },
			maxDistance = 32,
			source = "players",
			side = "client",
		},
	}
end

return Sounds
