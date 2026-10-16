--!strict
--[[
	The local player's body seen in true first person (the First-Person Body setting): at
	Camera + 2, after Roblox's camera faded the character, the one writer of the local
	character's LocalTransparencyModifier while Player/CameraRig places the camera and the player
	is alive and not a spectator. The head and what is worn on it are hidden in first person and
	the sights, and any part within Config.Camera.NearClear of the camera in every view
	(Player/FirstPersonRules); the rest is drawn, so looking down shows the chest, legs and feet.
	The held item is the world model in camera space (Player/HeldItems: `setHeld`) and the arms
	reach it by two-bone IK (`poseArms`, right after HeldItems placed it). OFF (`setEnabled`):
	Minecraft's hand as before (the body hidden, HeldItems' first-person view).

	FOUNDATION STUB: the API below is frozen (add functions, never change one); the bodies keep
	today's behaviour: nothing is written, no true first person (`trueFirstPerson` false: HeldItems
	keeps its first-person view), nothing hidden for others (`hides` false), arms left to the
	animation.

	Requires only Player/CameraRig, Player/FirstPersonRules, Player/SpectatorRules and Config:
	Player/EquipmentLooks requires this, and Player/MovementController requires EquipmentLooks.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)

--[[
	What the local player holds, as Player/HeldItems draws it (`setHeld`, every frame): the kind of
	grip ("empty": the bare hand; "firearm"; "tool": tools and melee weapons; "block": blocks and
	other items), whether a scope's view hides the gun and the arms (`scoped`), the share of the
	way from the hip to the sights (`sightsShare`, 0..1), a long gun (the left hand on its fore end)
	and a melee guard (the left hand on the handle).
]]
export type HeldKind = "empty" | "firearm" | "tool" | "block"
export type HeldState = {
	kind: HeldKind,
	scoped: boolean,
	sightsShare: number,
	long: boolean?,
	guard: boolean?,
}

local FirstPersonBody = {}

local started = false
local enabled = Config.Camera.FirstPersonBody
local held: HeldState = { kind = "empty", scoped = false, sightsShare = 0 }

function FirstPersonBody.start()
	if started then
		return
	end
	started = true
end

-- The First-Person Body setting (false: Minecraft's hand).
function FirstPersonBody.setEnabled(on: boolean)
	enabled = on
end

-- The First-Person Body setting as last set.
function FirstPersonBody.enabled(): boolean
	return enabled
end

--[[
	Is the local body drawn in true first person now (the rig in first person or the sights, the
	setting ON, an R15 body, alive)? HeldItems then places the world model in camera space instead
	of its first-person view.
]]
function FirstPersonBody.trueFirstPerson(): boolean
	return false
end

--[[
	Is `part` of the local character hidden by this module now (Player/EquipmentLooks hides a piece
	whose anchor part is)?
]]
function FirstPersonBody.hides(_part: Instance): boolean
	return false
end

-- What the local player holds this frame (Player/HeldItems).
function FirstPersonBody.setHeld(state: HeldState)
	held = state
end

-- What the local player holds, as last set.
function FirstPersonBody.held(): HeldState
	return held
end

--[[
	Puts the local character's hands on the held item (right on `right`, left on `left`: world
	CFrames of the grips; nil leaves that arm to the animation), by two-bone IK on the shoulders,
	elbows and wrists (C0 only), right after Player/HeldItems placed the item this frame.
]]
function FirstPersonBody.poseArms(_character: Model, _right: CFrame?, _left: CFrame?)
	-- (No true first person yet: the animation keeps the arms.)
end

return FirstPersonBody
