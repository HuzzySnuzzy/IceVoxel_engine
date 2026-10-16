--!strict
--[[
	The camera in the manner of DayZ, on Roblox's own camera scripts (Player/CameraRules has the
	rules and numbers, Config.Camera the knobs). Roblox's camera stays the source of the rotation
	and of the mouse lock: the player's CameraMode is LockFirstPerson for good (as spectating
	someone already was), so PlayerModule turns the camera from the mouse, the stick and touch
	(with Player/MouseLook's hook: invert, zoom, recoil, freelook's room and snap back), locks the
	mouse to the centre, and has no wheel zoom, no shift lock and no Popper. Every frame it rebuilds
	its look from camera.CFrame.LookVector alone, so this rig, at Camera + 1 after it, writes the
	camera's position and keeps its rotation: the next frame starts from the same look.

	  third    over the shoulder: CameraRules' rig on the body Player/MovementController pushes
	           every frame before the camera (`setBody`: the hull's eyes, the body's yaw, speed,
	           jump, stance). The profile by stance and hands (`setPosture`: Player/AimCamera)
	           eases over DayZ's blend times, the side from the Shoulder setting
	           (`setShoulderSide`), the pivot lags a jump. Roblox's near plane never enters a
	           block (CameraRules.collide, sized every frame from the camera's NearPlaneZ, field of
	           view and viewport: CameraRules.setLens): the eyes to the pivot are cast and
	           clipped, the pivot moves off blocks beside it until the near plane fits there, then
	           the boom behind it is cast from its centre and the near plane's corners, on the
	           world's blocks (Shared/World/VoxelRaycast.distance on Shared/Blocks/Shapes.sight's
	           collision boxes; spectators skip it); a block pulls the boom in at once and it eases
	           back out (CameraRules.boomStep).
	  first    from the eyes (CameraRules.firstPersonEye: ahead of the hull's eyes, past the
	           chest looking down), back towards Roblox's own first-person camera where a block
	           would cut the near plane (CameraRules.firstPersonClear); the body drawn by
	           Player/FirstPersonBody.
	  sights   the third-person sights (V) look from the same eye point; back to the shoulder
	           over DayZ's 0.2 s (CameraRules.eyeShare).
	The view starts from the Camera setting (`setDefaultView`: applied only when its value
	changes, since the boot's "camera" effect runs it again for every camera setting) and Toggle
	Perspective switches it (its key, the gamepad's D-pad up, the touch VIEW button: `touchView`),
	never while a weapon is raised or a melee guard is up and never for spectators, as in DayZ.
	Spectators always see from the eyes.

	Aim and freelook: the aim (`aimYaw`, `aimPitch`, `aimHeading`: where the body walks and faces,
	the pose others see) is the camera's own, except while freelooking (the Freelook key held, or
	toggled with the Freelook setting; R3 held while nothing is raised; the touch LOOK button
	held: `touchLook`), when it holds still while the camera turns up to Config.Camera.FreelookYaw
	each way (FreelookYawFirst in first person: the room goes to MouseLook.setRoom every frame).
	Let go, the camera comes back to the aim (CameraRules.snapStep, queued with MouseLook.turn)
	while input still moves the aim. Not in the sights, for spectators, while dead, without the
	hook, with a screen open, or across a view toggle. `freelooking` tells targeting and firing to
	wait (CameraRules.suspends: until the camera is back within 2 degrees of the aim, the
	crosshair is not where the hands point), `freelookOffset` the head and the hands (until the
	swing back ends). `onAim` listeners (Player/MovementController) hear the aim as soon as it is
	known, after Roblox's camera, so a body that turns at once faces this frame's aim.

	Focus (DayZ's eye zoom): `focusing` while the Focus key is held, playing and nothing raised;
	Player/MovementController eases the field of view (CameraRules.focusFov) and the mouse's share.
	The view bob shows in first person and the sights only (`bobShare`).

	The mouse is locked (by Roblox's camera) and its icon hidden while playing (`playing`): the
	rig active and none of the `mouseFree` predicates the boot passes to `start` (open screens, the
	chat, the switcher, typing, the title screen, the world map, Roblox's menu) holds; their own
	steps free the mouse. `locked` (the mouse at the centre) tells Interaction/BlockInteraction to
	draw the crosshair.

	The rig places the camera (`active`) while it has a body and the player spectates no one
	(`setSpectating`: Player/MovementController; spectating keeps Roblox's own first person on the
	target's eyes). A death holds the last body (`hold`): the camera stays where it was while the
	body tips over in view; a new character resumes it, and a body that moved far in one frame (a
	teleport, a respawn) starts the rig afresh there instead of easing. Only relative values are
	kept between frames (render studs of last frame's body move with Shared/World/Origin), so a
	move of the render origin needs nothing else. Nothing is allocated per frame but the camera's
	CFrame. While it places the camera for a player who isn't a spectator, Roblox's own fade of the
	character is held off (Player/CameraFade): Player/FirstPersonBody draws the body then.

	Config.Camera.Enabled = false: none of the above. Roblox's camera alone places the camera as it
	did before (its zoom, shift lock where the place allows it: the server sets
	Player.DevEnableMouseLock, which a client can't, from Config.Camera.Enabled, Player/AimCamera's
	raised shoulder); first person is geometric (within 1 stud of the camera's focus, measured here
	after Roblox's camera updated), the aim is the camera's own, the mouse counts as locked while it
	is LockCenter, the view bob always shows, nothing is ever freelooked or focused, and the rig is
	never active.

	Requires no Ui/ or Interaction/ module, nor Player/MovementController or Player/AimCamera
	(they require this): what it needs of them comes in (`start`'s predicates, `setBody`,
	`setPosture`, `setSpectating`).
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Origin = require(Shared.World.Origin)
local Shapes = require(Shared.Blocks.Shapes)
local VoxelRaycast = require(Shared.World.VoxelRaycast)

local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local Keybinds = require(script.Parent.Parent.Settings.Keybinds)
local CameraFade = require(script.Parent.CameraFade)
local CameraRules = require(script.Parent.CameraRules)
local MouseLook = require(script.Parent.MouseLook)

local CAMERA = Config.Camera
local BLOCK = Config.BlockSize
-- After Roblox's camera (Camera 200), with the screens' mouse steps.
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1
local RENDER_STEP = "IceVoxelCameraRig"
-- The camera counts as first person this close (studs) to its focus (Roblox's camera switches to
-- first person below 1 stud of zoom): Config.Camera.Enabled = false only.
local FIRST_PERSON_DISTANCE = 1
-- The gamepad's D-pad up (Toggle Perspective) and R3 (freelook), over Interaction/Firearms' R3
-- (High: the sights, which gets R3 while a gun is raised). (The touch VIEW and LOOK buttons are
-- the game's own, Ui/TouchButtons': none of ContextActionService's seven touch slots.)
local INPUT_PRIORITY = Enum.ContextActionPriority.High.Value + 1
local GAMEPAD_VIEW = "IceVoxelCameraView"
local GAMEPAD_LOOK = "IceVoxelCameraLook"

local CameraRig = {}

local started = false
-- Config.Camera.Enabled when the rig started (read live before).
local enabled = CAMERA.Enabled
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
local given: Given = {
	world = nil,
	mouseFree = {},
	guard = false,
	gun = false,
	defaultView = if CAMERA.DefaultView == "first" then "first" else "third",
	side = 1,
	freelookToggle = CAMERA.FreelookToggle == true,
}
local body: CameraRules.Body? = nil
local holding = false
local spectating = false
local posture: CameraRules.Posture = "lowered"
-- The view the player chose (the setting, then Toggle Perspective).
local chosen: CameraRules.Chosen = given.defaultView
-- Roblox's camera in first person, as measured after it updated this frame (Enabled = false).
local realFirstPerson = false

-- The world's blocks for the camera's collision (block units: VoxelRaycast), from `start`.
local getBlock: ((x: number, y: number, z: number) -> number?)? = nil
local sightStops: (id: number) -> boolean = function()
	return false
end
local sightOutline: ((id: number, x: number, y: number, z: number) -> { number }?)? = nil

-- The body the camera follows: a copy of the last pushed one (kept while holding or without a
-- character; its eyes move with the render origin).
local function newBody(): CameraRules.Body
	return {
		eyeX = 0,
		eyeY = 0,
		eyeZ = 0,
		yaw = 0,
		speed = 0,
		airborne = 0,
		rise = 0,
		noClip = false,
		stance = {
			sprinting = false,
			sneaking = false,
			tilt = 0,
			climbing = false,
			swimming = false,
			flying = false,
			onGround = true,
		},
	}
end
local last = newBody()
local haveLast = false

-- The third-person rig: its profile and blend, the boom (studs) and the rig's length last frame,
-- the lag when the feet left the ground, and the eye point's share (sights -> shoulder).
local rig = CameraRules.newRig(CameraRules.profile("standing"), 1)
local rigKey = "standing"
local blend = 0
local boom = rig.distance
local boomBefore = rig.distance
local takeoffLag = 0
local wasAirborne = false
-- The eyes' height (studs) when the feet last left the ground, while the lag lasts (nil: none).
local takeoffEyes: number? = nil
local eyeShare, eyeShareVel = 0, 0
local lastView: CameraRules.View = "third"
-- Start afresh next frame (no easing from the old place): a teleport, a respawn, a return.
local fresh = true
-- The camera's axes and near plane this frame (CameraRules.setLens), for the collision.
local lens = CameraRules.newLens()
-- The viewport's aspect (width over height), read again only when the camera or its viewport
-- changes (a Vector2 a frame would be made otherwise).
local aspect = 16 / 9
local aspectCamera: Camera? = nil
local aspectConnection: RBXScriptConnection? = nil

local function aspectOf(camera: Camera): number
	if camera ~= aspectCamera then
		aspectCamera = camera
		if aspectConnection then
			aspectConnection:Disconnect()
		end
		local function read()
			local size = camera.ViewportSize
			aspect = size.X / math.max(size.Y, 1)
		end
		aspectConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(read)
		read()
	end
	return aspect
end

-- Freelook and the aim (radians); `aimValid` once the aim was read after Roblox's camera.
local look = CameraRules.newLook()
local aimValid = false
-- Targeting and presses wait this frame (CameraRules.suspends, after this frame's aim).
local suspended = false
-- The Freelook inputs: a press this frame (toggle mode), R3 and the touch LOOK button held, and a
-- view toggle this frame (it ends freelook).
local freelookPressed = false
local gamepadLook = false
local touchLook = false
local viewToggled = false
-- The mouse icon hidden here once (given back whenever the player isn't playing).
local iconEverHidden = false
-- Told the aim each frame after Roblox's camera (`onAim`).
local aimListeners: { (yaw: number, pitch: number) -> () } = {}

local function isSpectator(): boolean
	return GameMode.isSpectatorOf(Players.LocalPlayer)
end

local function mouseFree(): boolean
	for _, free in given.mouseFree do
		if free() then
			return true
		end
	end
	return false
end

local function copyBody(from: CameraRules.Body)
	last.eyeX, last.eyeY, last.eyeZ = from.eyeX, from.eyeY, from.eyeZ
	last.yaw, last.speed, last.noClip = from.yaw, from.speed, from.noClip
	last.airborne, last.rise = from.airborne, from.rise
	local to, stance = last.stance, from.stance
	to.sprinting, to.sneaking, to.tilt = stance.sprinting, stance.sneaking, stance.tilt
	to.climbing, to.swimming, to.flying, to.onGround = stance.climbing, stance.swimming, stance.flying, stance.onGround
end

--[[
	How far (studs) a ray from (ox, oy, oz) along (dx, dy, dz) (render studs, any length) goes
	before a block stops it, looking `max` studs far; math.huge when nothing does.
]]
local function cast(ox: number, oy: number, oz: number, dx: number, dy: number, dz: number, max: number): number
	local blocks = getBlock
	if blocks == nil then
		return math.huge
	end
	local hit = VoxelRaycast.distance(
		(ox + Origin.x) / BLOCK,
		oy / BLOCK,
		(oz + Origin.z) / BLOCK,
		dx,
		dy,
		dz,
		max / BLOCK,
		blocks,
		sightStops,
		sightOutline
	)
	return if hit then hit * BLOCK else math.huge
end

-- The view drawn now (the rig on).
local function viewNow(): CameraRules.View
	return CameraRules.view(chosen, posture, isSpectator())
end

local function toggleView()
	local nextView: CameraRules.Chosen = CameraRules.toggle(chosen, posture, isSpectator(), given.guard)
	if nextView ~= chosen then
		chosen = nextView
		viewToggled = true
	end
end

local function freelookHeld(): boolean
	return gamepadLook or touchLook or Keybinds.isDown("freelook")
end

--[[
	Does the rig place `camera` now: on (and started), spectating no one, with a body (pushed now or
	kept), Roblox's camera following it (CameraType Custom)?
]]
local function placing(camera: Camera): boolean
	return enabled
		and started
		and not spectating
		and (haveLast or body ~= nil)
		and camera.CameraType == Enum.CameraType.Custom
end

--[[
	Places the camera (the rig active) for the view `view`: rotation (r00 .. r22) and pitch as
	Roblox's camera left them this frame.
]]
local function place(
	camera: Camera,
	view: CameraRules.View,
	dt: number,
	camPitch: number,
	r00: number,
	r01: number,
	r02: number,
	r10: number,
	r11: number,
	r12: number,
	r20: number,
	r21: number,
	r22: number
)
	local b = last
	local ex, ey, ez = b.eyeX, b.eyeY, b.eyeZ
	-- The rig eases in every view, so the shoulder is ready whenever the view comes back to it.
	local key = CameraRules.profileKey(b.stance, posture, given.guard)
	if fresh then
		local profile = CameraRules.profile(key)
		rig.distance, rig.shoulder = profile.distance, profile.shoulder
		rig.height, rig.forward = profile.height, profile.forward
		rig.side, rig.lag = given.side, 0
		rig.distanceVel, rig.shoulderVel, rig.heightVel = 0, 0, 0
		rig.forwardVel, rig.sideVel, rig.lagVel = 0, 0, 0
		rigKey, blend = key, 0
		boomBefore = rig.distance
		wasAirborne = false
		takeoffEyes = nil
	elseif key ~= rigKey then
		blend = CameraRules.transition(rigKey, key)
		rigKey = key
	end
	CameraRules.easeRig(rig, CameraRules.profile(key), given.side, dt, blend)
	-- The jump's lag (a held body jumps no more), the rise kept after landing until it is gone.
	local airborne = if body ~= nil and not holding then b.airborne else 0
	if airborne > 0 then
		if not wasAirborne then
			takeoffLag = rig.lag
		end
		takeoffEyes = ey - b.rise
	end
	wasAirborne = airborne > 0
	local from = takeoffEyes
	local rise = if from then ey - from else 0
	rig.lag, rig.lagVel = CameraRules.heightLag(rig.lag, rig.lagVel, rise, airborne, takeoffLag, dt)
	if airborne <= 0 and rig.lag == 0 then
		takeoffEyes = nil
	end

	if fresh then
		eyeShare, eyeShareVel = if view == "third" then 0 else 1, 0
	else
		eyeShare, eyeShareVel = CameraRules.eyeShare(eyeShare, eyeShareVel, view, lastView, dt)
	end
	lastView = view

	local x, y, z = CameraRules.firstPersonEye(ex, ey, ez, b.yaw, camPitch)
	if eyeShare > 0 and not b.noClip then
		-- (From the eyes: back where a block would cut the near plane.)
		x, y, z = CameraRules.firstPersonClear(ex, ey, ez, x, y, z, lens, cast)
	end
	if eyeShare < 1 then
		local px, py, pz = CameraRules.pivot(ex, ey, ez, b.yaw, rig)
		-- (The view's look.)
		local lx, ly, lz = lens.lx, lens.ly, lens.lz
		local free = math.huge
		if not b.noClip then
			px, py, pz, free = CameraRules.collide(ex, ey, ez, px, py, pz, rig.distance, lens, cast)
		end
		if fresh or eyeShare > 0 then
			-- (Afresh, and while coming out of the sights: the boom as long as it may be.)
			boom = math.clamp(math.min(free, rig.distance), 0, rig.distance)
		else
			boom = CameraRules.boomStep(boom, rig.distance, boomBefore, free, dt)
		end
		local cx, cy, cz = px - lx * boom, py - ly * boom, pz - lz * boom
		local s = eyeShare
		x, y, z = cx + (x - cx) * s, cy + (y - cy) * s, cz + (z - cz) * s
	else
		-- (Back over the shoulder, a block in the way pulls the boom in at once.)
		boom = rig.distance
	end
	boomBefore = rig.distance
	fresh = false
	camera.CFrame = CFrame.new(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
end

-- After Roblox's camera: the aim, freelook, the mouse's icon, then the camera's place.
local function step(dt: number)
	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end
	if not enabled then
		realFirstPerson = (camera.CFrame.Position - camera.Focus.Position).Magnitude < FIRST_PERSON_DISTANCE
		return
	end
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = camera.CFrame:GetComponents()
	local hx, hz = CameraRules.heading(r00, r01, r02, r12, r22)
	local camYaw = CameraRules.yawOf(hx, hz)
	local camPitch = math.asin(math.clamp(-r12, -1, 1))
	CameraRules.setLens(
		lens,
		r00,
		r01,
		r02,
		r10,
		r11,
		r12,
		r20,
		r21,
		r22,
		camera.NearPlaneZ,
		camera.FieldOfView,
		aspectOf(camera)
	)

	-- The body pushed this frame (none kept while holding); far from the last one: start afresh.
	local pushed = body
	local live = pushed ~= nil and not holding
	if
		pushed
		and live
		and haveLast
		and CameraRules.movedFar(last.eyeX, last.eyeY, last.eyeZ, pushed.eyeX, pushed.eyeY, pushed.eyeZ)
	then
		fresh = true
	end
	local active = placing(camera)
	local spectator = isSpectator()
	local view: CameraRules.View = CameraRules.view(chosen, posture, spectator)
	local playing = active and not mouseFree()

	-- Freelook, then the aim (every frame, idle too: it is what a press freezes).
	local allowed = playing and live and view ~= "sights" and not spectator and not viewToggled and MouseLook.hooked()
	viewToggled = false
	local pressed = freelookPressed
	freelookPressed = false
	CameraRules.freelook(look, freelookHeld(), allowed, given.freelookToggle, pressed)
	if not active then
		-- (The camera is on someone else's eyes: nothing to bring back.)
		look.snapping = false
		look.yaw, look.pitch, look.yawVel, look.pitchVel = 0, 0, 0, 0
	end
	CameraRules.aim(look, camYaw, camPitch)
	-- (The camera's offset from the aim as it is drawn this frame, before the snap's next turn.)
	suspended = CameraRules.suspends(look)
	if look.snapping then
		local dx, dy = CameraRules.snapStep(look, camYaw, camPitch, dt)
		MouseLook.turn(dx, dy)
	end
	MouseLook.setRoom(CameraRules.clampRoom(look, camYaw, camPitch, view))
	aimValid = true

	-- The mouse's icon: hidden while playing, given back otherwise (also after a screen that
	-- opened meanwhile gave back the hidden icon it found).
	if playing then
		if UserInputService.MouseIconEnabled then
			UserInputService.MouseIconEnabled = false
		end
		iconEverHidden = true
	elseif iconEverHidden and not UserInputService.MouseIconEnabled then
		UserInputService.MouseIconEnabled = true
	end

	-- The body may turn to this frame's aim before it is drawn (Player/MovementController), then
	-- the camera follows the body as it is now.
	if active and live then
		for _, listener in aimListeners do
			listener(look.aimYaw, look.aimPitch)
		end
	end
	if pushed and live then
		copyBody(pushed)
		haveLast = true
	end
	if not active or not haveLast then
		fresh = true
		lastView = view
		return
	end
	place(camera, view, dt, camPitch, r00, r01, r02, r10, r11, r12, r20, r21, r22)
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
	enabled = CAMERA.Enabled
	given.world = clientWorld
	given.mouseFree = mouseFreePredicates
	local player = Players.LocalPlayer
	if not enabled then
		-- (As before the rig. Shift lock is the server's: IceVoxel_Server sets DevEnableMouseLock,
		-- which a client can't, from Config.Camera.Enabled.)
		RunService:BindToRenderStep(RENDER_STEP, RENDER_PRIORITY, step)
		return
	end
	local function blocks(x: number, y: number, z: number): number?
		return clientWorld:getBlock(x, y, z)
	end
	getBlock = blocks
	sightStops, sightOutline = Shapes.sight(blocks)
	-- Roblox's camera for its rotation and the locked mouse only (see the header; no shift lock:
	-- default.project.json's EnableMouseLockOption, and the server's DevEnableMouseLock).
	player.CameraMode = Enum.CameraMode.LockFirstPerson
	MouseLook.hookCamera()
	-- Roblox's fade of the character held off while the first-person body draws it.
	CameraFade.hook(function(): boolean
		return CameraRig.active() and not isSpectator()
	end)
	-- (Last frame's body is in render studs: it moves with the origin.)
	Origin.onRebase(function(dx: number, dz: number)
		last.eyeX -= dx
		last.eyeZ -= dz
	end)

	-- Toggle Perspective and Freelook's key (its press, for the toggle mode; held is read).
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or not CameraRig.playing() then
			return
		end
		if Keybinds.matches("toggleView", input) then
			toggleView()
		end
		if Keybinds.matches("freelook", input) then
			freelookPressed = true
		end
	end)
	-- The gamepad: D-pad up toggles the view (spectators' D-pad up stays Ui/Hud's); R3 held is
	-- freelook while nothing is raised (else Interaction/Firearms' sights toggle gets it).
	ContextActionService:BindActionAtPriority(GAMEPAD_VIEW, function(_, state: Enum.UserInputState)
		if state ~= Enum.UserInputState.Begin or not CameraRig.playing() or isSpectator() then
			return Enum.ContextActionResult.Pass
		end
		toggleView()
		return Enum.ContextActionResult.Sink
	end, false, INPUT_PRIORITY, Enum.KeyCode.DPadUp)
	ContextActionService:BindActionAtPriority(GAMEPAD_LOOK, function(_, state: Enum.UserInputState)
		if state == Enum.UserInputState.Begin then
			if not CameraRig.playing() or isSpectator() or posture ~= "lowered" then
				return Enum.ContextActionResult.Pass
			end
			gamepadLook = true
			freelookPressed = true
			return Enum.ContextActionResult.Sink
		elseif gamepadLook then
			gamepadLook = false
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end, false, INPUT_PRIORITY, Enum.KeyCode.ButtonR3)
	RunService:BindToRenderStep(RENDER_STEP, RENDER_PRIORITY, step)
end

-- The touch VIEW button (Ui/TouchButtons) was tapped: Toggle Perspective, while playing.
function CameraRig.touchView()
	if CameraRig.playing() then
		toggleView()
	end
end

-- The touch LOOK button (Ui/TouchButtons) went down (true) or up: freelook while it is held.
function CameraRig.touchLook(held: boolean)
	if held and not touchLook then
		freelookPressed = true
	end
	touchLook = held
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

-- Spectating someone (Player/MovementController.spectate): Roblox's camera looks from their eyes
-- and the rig keeps off.
function CameraRig.setSpectating(on: boolean)
	spectating = on
end

-- How the hands are held (Player/AimCamera, every frame): a firearm's posture, a melee guard,
-- and whether a firearm is in hand.
function CameraRig.setPosture(value: CameraRules.Posture, guard: boolean, gun: boolean)
	posture = value
	given.guard = guard
	given.gun = gun
end

-- The Camera setting: the view to start in (applies when it changes and at join; the boot's
-- "camera" effect calls this for every camera setting, so an unchanged value keeps the live view).
function CameraRig.setDefaultView(view: CameraRules.Chosen)
	if view ~= given.defaultView then
		given.defaultView = view
		if chosen ~= view then
			chosen = view
			viewToggled = true
		end
	end
end

-- The Shoulder setting: +1 right, -1 left.
function CameraRig.setShoulderSide(side: number)
	given.side = if side < 0 then -1 else 1
end

-- The Freelook setting: true toggles, false holds.
function CameraRig.setFreelookToggle(on: boolean)
	given.freelookToggle = on
end

--[[
	Calls `listener(aimYaw, aimPitch)` every frame the rig is active, as soon as the aim is known
	after Roblox's camera and before the camera is placed (Player/MovementController turns the body
	to it there, so it faces this frame's aim, not last frame's).
]]
function CameraRig.onAim(listener: (yaw: number, pitch: number) -> ())
	table.insert(aimListeners, listener)
end

--[[ What the rig says ]]

-- Is the rig on (Config.Camera.Enabled), whether or not it places the camera now?
function CameraRig.enabled(): boolean
	return enabled
end

-- Does the rig place the camera (Config.Camera.Enabled, started, not spectating someone)?
function CameraRig.active(): boolean
	local camera = workspace.CurrentCamera
	return camera ~= nil and placing(camera)
end

-- The view drawn: "third", "first" or "sights" (CameraRules.view).
function CameraRig.view(): CameraRules.View
	if enabled then
		return viewNow()
	elseif realFirstPerson then
		return "first"
	end
	return if posture == "sights" then "sights" else "third"
end

-- Is the chosen view first person (for the aim's rules: Player/AimRules' Input.firstPerson)?
function CameraRig.firstPerson(): boolean
	if enabled then
		return viewNow() == "first"
	end
	return realFirstPerson
end

-- Is the view the player's eyes (first person, or the sights from third person)?
function CameraRig.eyesView(): boolean
	if enabled then
		return viewNow() ~= "third"
	end
	return realFirstPerson or posture == "sights"
end

-- Is a weapon raised or a guard up (no Toggle Perspective, no focus, the body turns at once)?
function CameraRig.raised(): boolean
	return posture ~= "lowered" or given.guard
end

--[[
	Is the player playing: the rig active and none of `start`'s mouse-free predicates holding (the
	mouse is then locked and its icon hidden)?
]]
function CameraRig.playing(): boolean
	if not CameraRig.active() then
		return false
	end
	return not mouseFree()
end

-- Is the mouse locked to the centre (the crosshair then shows on a computer too)?
function CameraRig.locked(): boolean
	return UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
end

--[[
	Is the camera freelooking (the aim held still; targeting and presses suspended)? Also while it
	comes back to the aim, until it is within 2 degrees of it (CameraRules.suspends: the crosshair
	is then where the hands point; Interaction/BlockInteraction plays the presses made meanwhile).
]]
function CameraRig.freelooking(): boolean
	return enabled and suspended
end

-- Is the camera coming back to the aim after freelook, the Freelook input let go (presses made
-- now are kept for when it is back: Interaction/BlockInteraction)?
function CameraRig.comingBack(): boolean
	return enabled and suspended and not look.active
end

-- The camera's turn from the aim while freelooking (radians: yaw left, pitch up); 0, 0 otherwise.
function CameraRig.freelookOffset(): (number, number)
	if look.active or look.snapping then
		return look.yaw, look.pitch
	end
	return 0, 0
end

-- Do the eyes focus (the Focus key held while playing, nothing raised, alive)?
function CameraRig.focusing(): boolean
	return enabled
		and not holding
		and body ~= nil
		and not CameraRig.raised()
		and Keybinds.isDown("focus")
		and CameraRig.playing()
end

-- The aim's heading on the ground (unit x, z): where forward input walks and the body faces.
function CameraRig.aimHeading(): (number, number)
	if enabled and aimValid then
		return -math.sin(look.aimYaw), -math.cos(look.aimYaw)
	end
	local camera = workspace.CurrentCamera
	if camera == nil then
		return 0, -1
	end
	local _, _, _, r00, r01, r02, _, _, r12, _, _, r22 = camera.CFrame:GetComponents()
	return CameraRules.heading(r00, r01, r02, r12, r22)
end

-- The aim's yaw (radians, CFrame.Angles(0, yaw, 0)).
function CameraRig.aimYaw(): number
	if enabled and aimValid then
		return look.aimYaw
	end
	local x, z = CameraRig.aimHeading()
	return CameraRules.yawOf(x, z)
end

-- The aim's pitch (radians, up positive).
function CameraRig.aimPitch(): number
	if enabled and aimValid then
		return look.aimPitch
	end
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
	if CameraRig.active() then
		local b = if haveLast then last else body
		if b then
			return Vector3.new(b.eyeX, b.eyeY, b.eyeZ)
		end
	end
	local camera = workspace.CurrentCamera
	return if camera then camera.CFrame.Position else nil
end

-- The share of Minecraft's view bob that shows (CameraRules.bobShare: none over the shoulder).
function CameraRig.bobShare(): number
	if CameraRig.active() then
		return CameraRules.bobShare(viewNow())
	end
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
