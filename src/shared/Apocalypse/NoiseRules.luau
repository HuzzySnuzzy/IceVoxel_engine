--!strict
--[[
	Which sounds are noises zombies hear, and how far (blocks), pure: the zombie apocalypse's
	noise rules (server Apocalypse/NoiseBus turns every sound the server plays into a noise
	through `lut`; Mobs/MobAI sends zombies that hear one to look). `s` is
	Config.Apocalypse.Noise.

	  block.<type>.break               a block broken: Break (10), glass shattering Glass (16)
	  block.<type>.place               a block placed: Place (6)
	  block.wooden_door.*,
	  block.bunker_hatch.*             a door or the hatch opened or shut: Door (10)
	  block.<container>.open / .close  a chest (any container's lid: Shared/Sounds' MENUS) opened
	                                   or shut: Container (6)
	  entity.player.attack.*           a player's hit landing: Hit (8)
	  entity.player.hurt*              a player hurt: Hurt (10)
	Everything else is silent to zombies (0): mining hits, steps and falls (`block.<type>.hit` and
	the other client-side events never reach the server), and every mob's own sounds
	(`entity.<mob>.*`: a zombie's groan or death draws no crowd). Explosions, sprinting and
	screams are noises the server makes itself (NoiseBus.explosion, emit).
]]

-- What the rules read of Config.Apocalypse.Noise.
export type Settings = {
	Break: number,
	Glass: number,
	Place: number,
	Door: number,
	Container: number,
	Hit: number,
	Hurt: number,
}

local NoiseRules = {}

-- The noise radius (blocks) of sound event `name`: 0 for none (see the header).
function NoiseRules.radius(name: string, s: Settings): number
	local blockType, action = string.match(name, "^block%.([%w_]+)%.([%w_]+)$")
	if blockType and action then
		if blockType == "wooden_door" or blockType == "bunker_hatch" then
			return s.Door
		elseif action == "break" then
			return if blockType == "glass" then s.Glass else s.Break
		elseif action == "place" then
			return s.Place
		elseif action == "open" or action == "close" then
			return s.Container
		end
		return 0
	end
	if string.match(name, "^block%.wooden_door%.") or string.match(name, "^block%.bunker_hatch%.") then
		return s.Door
	elseif string.match(name, "^entity%.player%.attack%.") then
		return s.Hit
	elseif string.match(name, "^entity%.player%.hurt") then
		return s.Hurt
	end
	return 0
end

-- Each event's noise radius (u8 at the event's index, 1..#events; Shared/Sounds.events).
function NoiseRules.lut(events: { { name: string } }, s: Settings): buffer
	local lut = buffer.create(#events + 1)
	for index, event in events do
		buffer.writeu8(lut, index, math.clamp(math.floor(NoiseRules.radius(event.name, s)), 0, 255))
	end
	return lut
end

return NoiseRules
