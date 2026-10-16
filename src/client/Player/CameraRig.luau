--!strict
--[[
	The camera in the manner of DayZ, on Roblox's own camera scripts (Player/CameraRules has the
	rules and numbers, Config.Camera the knobs). Roblox's camera stays the source of the rotation
	and of the mouse lock; this rig writes the position, at Camera + 1:

	  third    over the shoulder (CameraRules' rig on the body Player/MovementController pushes:
	           `setBody`), never inside a block (Shared/World/VoxelRaycast.distance on the world's
	           blocks), the side from the Shoulder setting
	  first    from the eyes (CameraRules.firstPersonEye), the body drawn by Player/FirstPersonBody
	  sights   the third-person sights look from the same eye point
	The view starts from the Camera setting (`setDefaultView`) and Toggle Perspective switches it
	(not while raised: `setPosture` from Player/AimCamera). Freelook (`freelooking`,
	`freelookOffset`) turns the camera while the aim (`aimYaw`, `aimPitch`, `aimHeading`: where the
	body walks and faces) holds still. The mouse is locked and its icon hidden while playing:
	the rig is active and none of the `mouseFree` predicates the boot passes to `start` (open
	screens, the chat, the switcher, typing, the title screen, the world map, Roblox's menu) holds.

	FOUNDATION STUB: the API below is frozen (Player/ builders add functions, never change one);
	the bodies keep today's behaviour, where Roblox's camera alone places the camera: first person
	is geometric (within 1 stud of the camera's focus, measured after Roblox's camera updated, as
	Player/AimCamera does), the aim is the camera's own, the mouse counts as locked while it is
	LockCenter, the view bob always shows, nothing is ever freelooked, and the rig is never active.

	Requires no Ui/ or Interaction/ module, nor Player/MovementController or Player/AimCamera
	(they require this): what it needs of them comes in (`start`'s predicates, `setBody`,
	`setPosture`).
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local CameraRules = require(script.Parent.CameraRules)

-- After Roblox's camera (Camera 200), with the screens' mouse steps.
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1
local RENDER_STEP = "IceVoxelCameraRig"
-- The camera counts as first person this close (studs) to its focus (Roblox's camera switches to
-- first person below 1 stud of zoom).
local FIRST_PERSON_DISTANCE = 1

local CameraRig = {}

local started = false
-- What the rig was given and told: `start`'s world and mouse-free predicates, the hands
-- (`setPosture`) and the camera settings (the boot's "camera" effect).
type Given = {
	world: ClientWorld.ClientWorld?,
	mouseFree: { () -> boolean },
	guard: boolean,
	gun: boolean,
	defaultView: CameraRules.Chosen,
	side: number,
	freelookToggle: boolean,
}
local rig: Given = {
	world = nil,
	mouseFree = {},
	guard = false,
	gun = false,
	defaultView = "third",
	side = 1,
	freelookToggle = false,
}
local body: CameraRules.Body? = nil
local holding = false
local posture: CameraRules.Posture = "lowered"
-- Roblox's camera in first person, as measured after it updated this frame.
local realFirstPerson = false

-- After Roblox's camera: is it in first person?
local function step()
	local camera = workspace.CurrentCamera
	if camera then
		realFirstPerson = (camera.CFrame.Position - camera.Focus.Position).Magnitude < FIRST_PERSON_DISTANCE
	end
end

--[[
	Starts the rig: `clientWorld`'s blocks for the camera's collision, and `mouseFreePredicates`,
	each true while something needs a free mouse (an open screen, the chat, typing...).
]]
function CameraRig.start(clientWorld: ClientWorld.ClientWorld, mouseFreePredicates: { () -> boolean })
	if started then
		return
	end
	started = true
	rig.world = clientWorld
	rig.mouseFree = mouseFreePredicates
	RunService:BindToRenderStep(RENDER_STEP, RENDER_PRIORITY, step)
end

--[[ What the rig is told ]]

--[[
	The local body this frame (Player/MovementController, every frame before Roblox's camera; nil
	without a character). A new body ends a `hold`.
]]
function CameraRig.setBody(value: CameraRules.Body?)
	body = value
	if value ~= nil then
		holding = false
	end
end

-- The local character died: the camera stays where it was, on the last body, until a new one.
function CameraRig.hold()
	holding = true
end

-- How the hands are held (Player/AimCamera, every frame): a firearm's posture, a melee guard,
-- and whether a firearm is in hand.
function CameraRig.setPosture(value: CameraRules.Posture, guard: boolean, gun: boolean)
	posture = value
	rig.guard = guard
	rig.gun = gun
end

-- The Camera setting: the view to start in (applies when it changes and at join).
function CameraRig.setDefaultView(view: CameraRules.Chosen)
	rig.defaultView = view
end

-- The Shoulder setting: +1 right, -1 left.
function CameraRig.setShoulderSide(side: number)
	rig.side = if side < 0 then -1 else 1
end

-- The Freelook setting: true toggles, false holds.
function CameraRig.setFreelookToggle(on: boolean)
	rig.freelookToggle = on
end

--[[ What the rig says ]]

-- Does the rig place the camera (Config.Camera.Enabled, started, not spectating someone)?
function CameraRig.active(): boolean
	return false
end

-- The view drawn: "third", "first" or "sights" (CameraRules.view).
function CameraRig.view(): CameraRules.View
	if realFirstPerson then
		return "first"
	end
	return if posture == "sights" then "sights" else "third"
end

-- Is the chosen view first person (for the aim's rules: Player/AimRules' Input.firstPerson)?
function CameraRig.firstPerson(): boolean
	return realFirstPerson
end

-- Is the view the player's eyes (first person, or the sights from third person)?
function CameraRig.eyesView(): boolean
	return realFirstPerson or posture == "sights"
end

--[[
	Is the player playing: the rig active and none of `start`'s mouse-free predicates holding (the
	mouse is then locked and its icon hidden)?
]]
function CameraRig.playing(): boolean
	if not CameraRig.active() then
		return false
	end
	for _, free in rig.mouseFree do
		if free() then
			return false
		end
	end
	return true
end

-- Is the mouse locked to the centre (the crosshair then shows on a computer too)?
function CameraRig.locked(): boolean
	return UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
end

-- Is the camera freelooking (the aim held still; targeting and presses suspended)?
function CameraRig.freelooking(): boolean
	return false
end

-- The camera's turn from the aim while freelooking (radians: yaw left, pitch up); 0, 0 otherwise.
function CameraRig.freelookOffset(): (number, number)
	return 0, 0
end

-- The aim's heading on the ground (unit x, z): where forward input walks and the body faces.
function CameraRig.aimHeading(): (number, number)
	local camera = workspace.CurrentCamera
	if camera == nil then
		return 0, -1
	end
	local _, _, _, r00, r01, r02, _, _, r12, _, _, r22 = camera.CFrame:GetComponents()
	return CameraRules.heading(r00, r01, r02, r12, r22)
end

-- The aim's yaw (radians, CFrame.Angles(0, yaw, 0)).
function CameraRig.aimYaw(): number
	local x, z = CameraRig.aimHeading()
	return CameraRules.yawOf(x, z)
end

-- The aim's pitch (radians, up positive).
function CameraRig.aimPitch(): number
	local camera = workspace.CurrentCamera
	if camera == nil then
		return 0
	end
	return math.asin(math.clamp(camera.CFrame.LookVector.Y, -1, 1))
end

--[[
	Where targeting looks from (render studs): the hull's eyes while the rig is active (the
	camera's ray starts at their plane and is checked for line of sight from them), the camera
	itself otherwise (no plane to skip, the same ray). nil without a camera.
]]
function CameraRig.eyes(): Vector3?
	local camera = workspace.CurrentCamera
	return if camera then camera.CFrame.Position else nil
end

-- The share of Minecraft's view bob that shows (CameraRules.bobShare: none over the shoulder).
function CameraRig.bobShare(): number
	return 1
end

-- The body last pushed (`setBody`): nil before any, and after a nil one.
function CameraRig.body(): CameraRules.Body?
	return body
end

-- Is the camera holding the last body (the character died)?
function CameraRig.holding(): boolean
	return holding
end

return CameraRig
