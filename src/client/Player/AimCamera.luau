--!strict
--[[
	The camera of a raised firearm, in the manner of DayZ (Interaction/Firearms says how the gun is
	held every frame: `set`, `setStance`; Player/AimRules has the numbers). It works on Roblox's
	own camera scripts (PlayerModule), never replacing them:

	  Raised    third person: the camera over the right shoulder (Config.Weapons.ShoulderOffset,
	            eased in and out: Player/MovementController.setShoulder), the mouse locked to the
	            centre (UserInputService.MouseBehavior LockCenter, written every frame at Camera + 1,
	            after Roblox's camera wrote its own: a held right button would otherwise drag the
	            camera with a free mouse, which turns it all the same) and its icon hidden (put back
	            when lowered, also after a screen that opened meanwhile gave back the hidden icon it
	            found), so the character faces where the camera looks (MovementController's
	            facing follows a locked mouse) and walks at RaisedSpeed without sprinting
	            (`setAimSlow`; a melee weapon's guard, Interaction/MeleeInput, at GuardSpeed).
	  Sights    in first person the camera already looks from the eyes; V in third person moves it
	            there too: every frame after Roblox's camera (Camera + 5) it is put at the camera's
	            focus (the hull's eyes: the shoulder offset is taken off at once) and the
	            character is hidden (LocalTransparencyModifier, as Roblox's own first person does;
	            given back on leaving), so the gun in Player/HeldItems' first-person view lies
	            down the sight line. The field of view is divided by the zoom (AimRules.zoom,
	            eased: MovementController.setAimZoom), the turn's share is 1 / zoom
	            (Player/MouseLook.setZoomSensitivity), the speed SightsSpeed.
	  Sway      AimRules / Handling.sway's figure eight (with the breath's factor: holding it in the
	            sights steadies the aim, then the player is out of breath) turns the view after
	            the camera, the view bob and the screen effects (Camera + 5) and is taken off again
	            before the camera updates (Camera - 2, before the view bob comes off at Camera - 1),
	            only when nothing else moved the camera meanwhile, as the view bob is; a move of
	            the render origin shifts what it keeps.
	  Recoil    a shot's kick (`kick`) turns the camera through Roblox's camera input (MouseLook
	            .kick), so the turn stays, and its recoverable share comes back down over
	            RecoilRecoverSeconds; without the hook the kick shows as a passing turn of the view
	            with the sway instead.

	`firstPerson` (Roblox's camera in first person: within 1 stud of its focus, measured after it
	updated), `sightsView` (the view is down the sights), `zoom`, `scoped` (a scope's zoom: Ui/
	WeaponHud draws its overlay, HeldItems hides the model) and `posture` are read by HeldItems,
	WeaponPoses' callers and the HUD. Nothing is created per frame.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Handling = require(Shared.Weapons.Handling)
local Origin = require(Shared.World.Origin)
local Weapons = require(Shared.Weapons)

local Screens = require(script.Parent.Parent.Ui.Screens)
local AimRules = require(script.Parent.AimRules)
local CameraRig = require(script.Parent.CameraRig)
local MouseLook = require(script.Parent.MouseLook)
local MovementController = require(script.Parent.MovementController)

local CAMERA = Enum.RenderPriority.Camera.Value
-- Before the view bob comes off (MovementController: Camera - 1).
local UNSWAY_PRIORITY = CAMERA - 2
-- After Roblox's camera (with the screens' own mouse steps).
local LOCK_PRIORITY = CAMERA + 1
-- After the view bob (Camera + 4).
local SWAY_PRIORITY = CAMERA + 5
-- The camera counts as first person this close (studs) to its focus.
local FIRST_PERSON_DISTANCE = 1
-- Easing rates (per second): the zoom and the shoulder.
local ZOOM_RATE = 14
local SHOULDER_RATE = 12

local AimCamera = {}

local started = false
local posture: AimRules.Posture = "lowered"
local spec: Weapons.FirearmSpec? = nil
local targetZoom = 1
local zoom = 1
local shoulderShare = 0
local realFirstPerson = false
-- os.clock() when it was raised (for the sway's growing in).
local raisedAt: number? = nil
local recoil = AimRules.newRecoil()
local breath = Handling.newBreath()
local breathFactor = 1
local stance: Handling.SwayStance = { sights = false, moving = false, crouching = false, hurt = false }
local holdingBreath = false
-- What the sway step did to the camera last frame (to undo it).
local swayCamera: Camera? = nil
local swayClean = CFrame.identity
local swaySet = CFrame.identity
-- The mouse icon hidden here (and once ever: a screen may give the hidden icon back later).
local iconHidden = false
local iconEverHidden = false
-- The local character hidden for third-person sights, and its parts.
local hiddenCharacter: Model? = nil
local hiddenParts: { Instance } = {}
-- The slowness last given to MovementController: a posture, or "guard".
local slowFor = "lowered"

-- The shoulder offset (studs, the character's space).
local function shoulderOffset(): Vector3
	local o = Config.Weapons.ShoulderOffset
	return Vector3.new(o[1] or 0, o[2] or 0, o[3] or 0)
end

-- Is the view in the sights from third person (the camera moved to the eyes)?
local function thirdPersonSights(): boolean
	return posture == "sights" and not realFirstPerson
end

local function setHidden(character: Model?, hidden: boolean)
	if hidden and character then
		if hiddenCharacter ~= character then
			setHidden(hiddenCharacter, false)
			hiddenCharacter = character
			table.clear(hiddenParts)
			for _, part in character:GetDescendants() do
				if part:IsA("BasePart") or part:IsA("Decal") then
					table.insert(hiddenParts, part)
				end
			end
		end
		for _, part in hiddenParts do
			local thing = part :: any
			if thing.LocalTransparencyModifier ~= 1 then
				thing.LocalTransparencyModifier = 1
			end
		end
	elseif not hidden and hiddenCharacter then
		-- (Given back as Roblox's camera wants it: hidden in its own first person.)
		local back = if realFirstPerson then 1 else 0
		for _, part in hiddenParts do
			if part.Parent ~= nil then
				(part :: any).LocalTransparencyModifier = back
			end
		end
		hiddenCharacter = nil
		table.clear(hiddenParts)
	end
end

-- Takes last frame's sway off the camera, if nothing else moved it (before the camera updates).
local function unsway()
	local camera = swayCamera
	if camera then
		swayCamera = nil
		if camera.CFrame == swaySet then
			camera.CFrame = swayClean
		end
	end
end

-- After Roblox's camera: first person or not, the locked mouse and its icon.
local function lockStep()
	local camera = workspace.CurrentCamera
	if camera then
		realFirstPerson = (camera.CFrame.Position - camera.Focus.Position).Magnitude < FIRST_PERSON_DISTANCE
	end
	local raised = posture ~= "lowered" and not Screens.isOpen()
	if raised then
		if UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		end
		if UserInputService.MouseIconEnabled then
			UserInputService.MouseIconEnabled = false
			iconHidden = true
			iconEverHidden = true
		end
	elseif iconHidden or (iconEverHidden and not Screens.isOpen() and not UserInputService.MouseIconEnabled) then
		-- (A screen opened while it was hidden keeps "hidden" as what to give back on closing.)
		UserInputService.MouseIconEnabled = true
		iconHidden = false
	end
end

-- After the camera and the view bob: zoom, shoulder, recoil's recovery, the sway, the sights.
local function swayStep(dt: number)
	local now = os.clock()
	-- Zoom (the field of view and the turn's share).
	zoom = AimRules.ease(zoom, targetZoom, dt, ZOOM_RATE)
	MovementController.setAimZoom(1 / zoom)
	MouseLook.setZoomSensitivity(AimRules.sensitivity(zoom))
	-- Over the shoulder while raised in third person (at once off for the sights from there).
	local shoulderTarget = if posture == "raised" and not realFirstPerson then 1 else 0
	shoulderShare = if posture == "sights" then 0 else AimRules.ease(shoulderShare, shoulderTarget, dt, SHOULDER_RATE)
	MovementController.setShoulder(if shoulderShare > 0 then shoulderOffset() * shoulderShare else Vector3.zero)
	-- Recoil: the kick, then its recovery, through the camera's input.
	local kickPitch, kickYaw = AimRules.takeKick(recoil)
	local back = AimRules.recover(recoil, dt)
	local hooked = MouseLook.kicks()
	if hooked then
		if kickPitch ~= 0 or kickYaw ~= 0 or back ~= 0 then
			MouseLook.kick(kickYaw, kickPitch - back)
		end
	end
	-- Breath and sway.
	breathFactor = Handling.breathStep(breath, holdingBreath and posture == "sights", dt)
	local camera = workspace.CurrentCamera
	local player = Players.LocalPlayer
	local eyes = thirdPersonSights()
	setHidden(player.Character, eyes)
	if camera == nil or (posture == "lowered" and recoil.back <= 0) then
		return
	end
	local yaw, pitch = 0, 0
	local gun = spec
	if gun and posture ~= "lowered" and raisedAt then
		local blend = math.clamp((now - raisedAt) / AimRules.SWAY_IN, 0, 1)
		yaw, pitch = Handling.sway(gun, stance, now, breathFactor)
		yaw *= blend
		pitch *= blend
	end
	if not hooked then
		-- (No hook: the recoil shows as a passing turn.)
		pitch += recoil.back
	end
	if yaw == 0 and pitch == 0 and not eyes then
		return
	end
	local clean = camera.CFrame
	local cframe = if eyes then CFrame.new(camera.Focus.Position) * clean.Rotation else clean
	camera.CFrame = cframe * CFrame.Angles(0, math.rad(-yaw), 0) * CFrame.Angles(math.rad(pitch), 0, 0)
	swayCamera, swayClean, swaySet = camera, clean, camera.CFrame
end

function AimCamera.start()
	if started then
		return
	end
	started = true
	MouseLook.hookCamera()
	RunService:BindToRenderStep("IceVoxelAimUnsway", UNSWAY_PRIORITY, unsway)
	RunService:BindToRenderStep("IceVoxelAimLock", LOCK_PRIORITY, lockStep)
	RunService:BindToRenderStep("IceVoxelAimSway", SWAY_PRIORITY, swayStep)
	-- (What the sway keeps is in render studs: the origin's moves shift it.)
	Origin.onRebase(function(dx: number, dz: number)
		local d = Vector3.new(dx, 0, dz)
		swayClean -= d
		swaySet -= d
	end)
end

--[[
	How the gun in hand is held this frame (Interaction/Firearms): its posture, its spec (nil:
	no firearm) and the optic mounted (an item; nil: none); `guard`: a melee weapon guarding
	instead (Interaction/MeleeInput: GuardSpeed, no sprinting). Cheap when nothing changed.
]]
function AimCamera.set(value: AimRules.Posture, gun: Weapons.FirearmSpec?, optic: number?, now: number, guard: boolean?)
	if value ~= "lowered" and posture == "lowered" then
		raisedAt = now
	elseif value == "lowered" then
		raisedAt = nil
	end
	posture = value
	spec = gun
	targetZoom = AimRules.zoom(value, gun, optic)
	-- (The camera's rig follows the hands: its profile, and no Toggle Perspective while raised.)
	CameraRig.setPosture(value, guard == true, gun ~= nil)
	local slow = if guard then "guard" else value
	if slow ~= slowFor then
		slowFor = slow
		local factor, noSprint = AimRules.speed(value, guard)
		MovementController.setAimSlow(factor, noSprint)
	end
	if value == "lowered" and gun == nil then
		AimRules.clearRecoil(recoil)
	end
end

-- How the shooter stands (for the sway): moving, crouching, hurt (under half health), and whether
-- the sprint key is held (holding breath in the sights).
function AimCamera.setStance(moving: boolean, crouching: boolean, hurt: boolean, breathKey: boolean)
	stance.sights = posture == "sights"
	stance.moving = moving
	stance.crouching = crouching
	stance.hurt = hurt
	holdingBreath = breathKey
end

-- A shot's kick (degrees up, right): see the header.
function AimCamera.kick(pitch: number, yaw: number)
	AimRules.kick(recoil, pitch, yaw)
end

-- The posture the camera follows.
function AimCamera.posture(): AimRules.Posture
	return posture
end

-- Is Roblox's camera in first person (measured after it updated this frame)?
function AimCamera.firstPerson(): boolean
	return realFirstPerson
end

-- Is the view down the sights (first person raised, or V in third person: the camera at the eyes)?
function AimCamera.sightsView(): boolean
	return posture == "sights"
end

-- Is the view the player's eyes (first person, or the sights from third person)?
function AimCamera.eyesView(): boolean
	return realFirstPerson or posture == "sights"
end

-- The zoom now (eased).
function AimCamera.zoom(): number
	return zoom
end

-- Is the view a scope's (its zoom at AimRules.SCOPE_ZOOM or more, in the sights)?
function AimCamera.scoped(): boolean
	return posture == "sights" and AimRules.scoped(targetZoom) and AimRules.scoped(zoom * 1.25)
end

-- Is the breath held (the steadied phase)?
function AimCamera.holdingBreath(): boolean
	return breath.phase == "holding"
end

return AimCamera
