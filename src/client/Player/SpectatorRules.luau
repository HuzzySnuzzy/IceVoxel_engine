--!strict
--[[
	Who sees, hears and aims at spectators (pure, so the tests run it; Player/SpectatorView,
	Player/HeldItems, Map/Minimap, Audio/MovementSounds, Ui/Waila and Interaction/BlockInteraction
	follow it):

	  seeing    a spectator is invisible to everyone but spectators (Entity.isInvisibleTo), who see
	            only its head, translucent: Minecraft's PlayerRenderer hides every other part of a
	            spectator and LivingEntityRenderer draws a body that is invisible but not to the
	            viewer at alpha 0.15. No name, no held item, no minimap dot where it is invisible.
	  hearing   spectators make no sounds (no physics: no footsteps, swimming, splashes or
	            landings), for anyone.
	  aiming    spectators are never aimed at (EntitySelector.NO_SPECTATORS): WAILA does not name
	            them, they don't keep blocks from being placed and can't be spectated. Nor is the
	            player being spectated: the camera is inside them (GameRenderer.pick leaves out the
	            camera entity), so a click goes to whoever is in front of them.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local GameMode = require(Shared.GameMode)

local SpectatorRules = {}

-- A spectator's head as other spectators see it (alpha 0.15).
SpectatorRules.HEAD_TRANSPARENCY = 0.85

--[[
	What of a character is hidden with it: every class with a LocalTransparencyModifier, as Roblox's
	TransparencyController hides them in first person. Not only its parts: a decal or texture on a
	part (the classic face on the head) and effects (an accessory's particles, beams, trails, fire,
	smoke, sparkles) are drawn whatever their part's transparency.
]]
SpectatorRules.HIDDEN_CLASSES =
	table.freeze({ "BasePart", "Decal", "Beam", "ParticleEmitter", "Trail", "Fire", "Smoke", "Sparkles" })

-- Is an object hidden with its character? `isA` is its Instance.IsA (a class or a base class).
function SpectatorRules.hidden(isA: (class: string) -> boolean): boolean
	for _, class in SpectatorRules.HIDDEN_CLASSES do
		if isA(class) then
			return true
		end
	end
	return false
end

-- Does a player in `viewer` mode see one in `target` mode at all?
function SpectatorRules.sees(viewer: string, target: string): boolean
	return not GameMode.isSpectator(target) or GameMode.isSpectator(viewer)
end

--[[
	The least transparency (LocalTransparencyModifier) a part of a `target` mode character gets for
	a `viewer` mode player: 0 (drawn as it is) unless the target spectates; then 1, except its head
	(and what is worn on it) for a spectator viewer.
]]
function SpectatorRules.transparency(viewer: string, target: string, head: boolean): number
	if not GameMode.isSpectator(target) then
		return 0
	elseif head and GameMode.isSpectator(viewer) then
		return SpectatorRules.HEAD_TRANSPARENCY
	end
	return 1
end

-- Can a player in `target` mode be aimed at (WAILA, spectating by a click, blocking placements)?
function SpectatorRules.targetable(target: string): boolean
	return not GameMode.isSpectator(target)
end

-- Can this player aim at another in `target` mode (WAILA, spectating by a click)? `spectated`: it
-- is the player this one spectates, whose eyes the camera is in.
function SpectatorRules.aimable(target: string, spectated: boolean): boolean
	return SpectatorRules.targetable(target) and not spectated
end

-- Does a player in `target` mode make movement sounds?
function SpectatorRules.audible(target: string): boolean
	return not GameMode.isSpectator(target)
end

return SpectatorRules
