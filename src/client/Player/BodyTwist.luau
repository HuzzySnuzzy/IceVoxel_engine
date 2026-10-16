--!strict
--[[
	Every shown character's body turning as in DayZ, drawn by each client from what it already has
	(nothing is sent), at Camera + 6 (after the camera, the view bob and the sway; before
	Player/HeldItems, whose hands and arms then follow the turned body):

	  legs     the way the drawn feet move (the local player's from Player/MovementController.
	           current, everyone else's from Player/RemotePlayers: per player, the last feet and
	           their smoothed velocity) against the body's facing (the root's yaw: the hull's view
	           yaw, the pose's yaw) twists the legs at the hips towards a strafe, up to 45 degrees,
	           folded so a backpedal walks backwards (Player/BodyRules.legs, with hysteresis about
	           a pure strafe). The local walk and run play reversed for it (Player/
	           CharacterAnimator asks `backwards`), and the Animator replicates that. Another
	           player's legs go by their drawn feet as well; the way their own client plays their
	           walk (the tracks their Animator plays, Animator.AnimationPlayed) only settles a
	           move near a pure strafe, where the feet can't tell (BodyRules.remoteLegs: the feet
	           and the tracks arrive with different delays). Upright only: not lying (crawling,
	           swimming), not on a ladder.
	  waist    the local upper body leads an idle turn (the aim ahead of the lagging body, Player/
	           CameraRig.aimYaw, within 45 degrees) and takes freelook's yaw beyond the neck's 70
	           (CameraRig.freelookOffset, within 30), while the rig is active, and leans forward
	           in a gun's sights seen from the eyes (BodyRules.lean by Player/FirstPersonBody
	           .held's sights share, true first person only: both shoulders forward under the gun
	           for both hands); the other players' waists stay (BodyRules.waist).
	  shuffle  `turnRate` is the local body's turn rate (smoothed), for CharacterAnimator's
	           idle-turn shuffle (BodyRules.shuffle).

	Joints (R15; R6 rigs have no twist): LeftUpperLeg.LeftHip, RightUpperLeg.RightHip and
	UpperTorso.Waist, whose C0 is turned about the joint in its Part0's axes and the animation kept
	(C0 = base turned: a yaw, the waist's lean about the turned right; never Transform). They are
	only written when an angle moved, put back as they were when a character is not drawn (dead,
	gone, untracked, spectating someone) and found again when the rig is rebuilt (a body part
	replaced) or rescaled (the base C0 moves). Nothing is allocated per frame: one record per player
	(a weak table), the players from RemotePlayers' `onTracked`.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local PlayerSync = require(Shared.Net.PlayerSync)

local BodyRules = require(script.Parent.BodyRules)
local CameraRig = require(script.Parent.CameraRig)
local FirstPersonBody = require(script.Parent.FirstPersonBody)
local MovementController = require(script.Parent.MovementController)
local RemotePlayers = require(script.Parent.RemotePlayers)

-- After the view bob (+4) and the sway (+5), before the held items' hands (+7).
local RENDER_STEP = "IceVoxelBodyTwist"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 6
-- Time constants (seconds): the feet's velocity, the legs' and the waist's turn, the turn rate.
local VELOCITY_SECONDS = 0.1
local LEGS_SECONDS = 0.12
local WAIST_SECONDS = 0.06
local TURN_SECONDS = 0.1
-- Drawn feet that jump further in a frame (blocks) were teleported, and a frame longer than this
-- (seconds) is a hitch: the velocity starts over. A yaw that jumps more in a frame (radians) was
-- set (a teleport's), not turned.
local TELEPORT = 4
local LONG_FRAME = 0.5
local SNAP_TURN = 1.5
-- Upright: tilted less than this (lying 0..1, MovementController's and the poses' tilt).
local UPRIGHT = 0.05
-- A joint is written when its angle moved this much (radians); smaller angles easing to rest are
-- rest. Its base is taken again when its C0 moved further than REBASE (studs) from the last write.
local WRITE_EPSILON = 1e-3
local REBASE = 1e-4
-- Missing joints (or a missing Animator) are looked for again at most this often (seconds).
local LOOKUP_SECONDS = 1
-- A replicated track playing slower than this plays reversed (a backpedal).
local REVERSED = -0.01
local CLIMBING = PlayerSync.Flag.Climbing

-- A joint this turns: its Motor6D, its own C0, the C0 last written and the angles in it (a yaw,
-- then a pitch about the turned joint's right: the waist's lean).
type Joint = { motor: Motor6D, base: CFrame, written: CFrame, yaw: number, pitch: number }

-- A player's body (see the header).
type Twist = {
	character: Model?,
	humanoid: Humanoid?,
	left: Joint?,
	right: Joint?,
	waist: Joint?,
	-- R15 with its joints found (an R6 rig is complete with none).
	rigged: boolean,
	complete: boolean,
	lookedAt: number,
	-- The drawn feet last frame (world blocks) and their smoothed velocity (blocks a second).
	seen: boolean,
	x: number,
	z: number,
	vx: number,
	vz: number,
	-- The drawn angles (radians), the way the legs walk, and the frame it was last drawn in.
	legYaw: number,
	waistYaw: number,
	waistLean: number,
	backwards: boolean,
	frame: number,
	-- Another player's: the tracks their Animator played (replicated) and its connection.
	tracks: { AnimationTrack },
	played: RBXScriptConnection?,
}

local BodyTwist = {}

local started = false
local localPlayer: Player? = nil
local twists: { [Player]: Twist } = setmetatable({}, { __mode = "k" }) :: any
-- The other players RemotePlayers tracks.
local tracked: { [Player]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local frame = 0
-- The local body: walking backwards, its last yaw and its turn rate (radians a second).
local localBackwards = false
local lastYaw: number? = nil
local turnRate = 0

-- `motor` as a Joint at rest.
local function jointOf(motor: Motor6D): Joint
	local c0 = motor.C0
	return { motor = motor, base = c0, written = c0, yaw = 0, pitch = 0 }
end

-- Turns `joint` to `yaw` (then `pitch`, nil none) about its joint, in its Part0's axes, the
-- animation kept (see the header).
local function setYaw(joint: Joint?, yaw: number, pitch: number?)
	if joint == nil then
		return
	end
	local p = pitch or 0
	local still = math.abs(yaw - joint.yaw) < WRITE_EPSILON and (yaw ~= 0 or joint.yaw == 0)
	if still and math.abs(p - joint.pitch) < WRITE_EPSILON and (p ~= 0 or joint.pitch == 0) then
		return
	end
	local motor = joint.motor
	if motor.Parent == nil then
		return
	end
	-- (Rescaled since the last write: the rig's own C0 moved, its turn didn't.)
	local at = motor.C0.Position
	if (at - joint.written.Position).Magnitude > REBASE then
		joint.base = CFrame.new(at) * joint.base.Rotation
	end
	local base = joint.base
	local c0 = if yaw == 0 and p == 0
		then base
		else CFrame.new(base.Position) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(p, 0, 0) * base.Rotation
	motor.C0 = c0
	joint.written = c0
	joint.yaw = yaw
	joint.pitch = p
end

-- Puts `twist`'s joints back as they were (the body not drawn), and starts its feet over.
local function rest(twist: Twist)
	twist.seen = false
	twist.vx, twist.vz = 0, 0
	twist.legYaw, twist.waistYaw, twist.waistLean = 0, 0, 0
	twist.backwards = false
	setYaw(twist.left, 0)
	setYaw(twist.right, 0)
	setYaw(twist.waist, 0, 0)
end

-- Lets go of `twist`'s character: its joints back, its Animator's connection off.
local function release(twist: Twist)
	rest(twist)
	local played = twist.played
	if played then
		played:Disconnect()
		twist.played = nil
	end
	table.clear(twist.tracks)
	twist.left, twist.right, twist.waist = nil, nil, nil
	twist.humanoid = nil
	twist.rigged, twist.complete = false, false
end

-- Does `joint` hang in a part no longer in `character` (the rig rebuilt)?
local function gone(joint: Joint?, character: Model?): boolean
	if joint == nil then
		return false
	end
	local part = joint.motor.Parent
	return part == nil or part.Parent ~= character
end

-- Does any of `twist`'s joints hang in a part no longer in its character?
local function orphaned(twist: Twist): boolean
	local character = twist.character
	return gone(twist.left, character) or gone(twist.right, character) or gone(twist.waist, character)
end

-- The Motor6D `name` in `character`'s part `partName`: `joint` when it is that one still, else a
-- new Joint (`joint`'s motor put back first), or nil.
local function refind(joint: Joint?, character: Model, partName: string, name: string): Joint?
	local part = character:FindFirstChild(partName)
	local motor = if part then part:FindFirstChild(name) else nil
	if joint and joint.motor == motor then
		return joint
	end
	if joint then
		setYaw(joint, 0)
	end
	if motor and motor:IsA("Motor6D") then
		return jointOf(motor)
	end
	return nil
end

--[[
	Finds `twist`'s character's humanoid and joints (keeping the ones found before), and for another
	player connects to their Animator's tracks: complete when all are there.
]]
local function lookup(twist: Twist, remote: boolean)
	local character = twist.character
	twist.lookedAt = os.clock()
	twist.complete = false
	if character == nil then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	twist.humanoid = humanoid
	if humanoid == nil then
		return
	end
	if humanoid.RigType ~= Enum.HumanoidRigType.R15 then
		-- (R6: no twist; nothing to look for again.)
		twist.rigged, twist.complete = false, true
		return
	end
	twist.left = refind(twist.left, character, "LeftUpperLeg", "LeftHip")
	twist.right = refind(twist.right, character, "RightUpperLeg", "RightHip")
	twist.waist = refind(twist.waist, character, "UpperTorso", "Waist")
	twist.rigged = twist.left ~= nil and twist.right ~= nil
	local listening = not remote or twist.played ~= nil
	if not listening then
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if animator then
			local tracks = twist.tracks
			for _, track in animator:GetPlayingAnimationTracks() do
				table.insert(tracks, track)
			end
			twist.played = animator.AnimationPlayed:Connect(function(track: AnimationTrack)
				-- (Stopped ones go when another starts: the list stays the few the rig plays.)
				for i = #tracks, 1, -1 do
					if not tracks[i].IsPlaying then
						table.remove(tracks, i)
					end
				end
				if table.find(tracks, track) == nil then
					table.insert(tracks, track)
				end
			end)
			listening = true
		end
	end
	twist.complete = twist.rigged and twist.waist ~= nil and listening
end

-- `player`'s record for `character` this frame (a new character starts over).
local function twistFor(player: Player, character: Model, remote: boolean): Twist
	local twist = twists[player]
	if twist == nil then
		local new: Twist = {
			character = nil,
			humanoid = nil,
			left = nil,
			right = nil,
			waist = nil,
			rigged = false,
			complete = false,
			lookedAt = -math.huge,
			seen = false,
			x = 0,
			z = 0,
			vx = 0,
			vz = 0,
			legYaw = 0,
			waistYaw = 0,
			waistLean = 0,
			backwards = false,
			frame = 0,
			tracks = {},
			played = nil,
		}
		twists[player] = new
		twist = new
	end
	assert(twist, "twist")
	if twist.character ~= character then
		release(twist)
		twist.character = character
		lookup(twist, remote)
	elseif (not twist.complete or orphaned(twist)) and os.clock() - twist.lookedAt >= LOOKUP_SECONDS then
		lookup(twist, remote)
	end
	return twist
end

-- The drawn feet (world blocks) this frame: their smoothed velocity.
local function move(twist: Twist, x: number, z: number, dt: number)
	if not twist.seen or dt <= 0 or dt > LONG_FRAME then
		twist.seen = true
		twist.x, twist.z = x, z
		twist.vx, twist.vz = 0, 0
		return
	end
	local dx, dz = x - twist.x, z - twist.z
	twist.x, twist.z = x, z
	if dx * dx + dz * dz > TELEPORT * TELEPORT then
		twist.vx, twist.vz = 0, 0
		return
	end
	twist.vx = BodyRules.ease(twist.vx, dx / dt, VELOCITY_SECONDS, dt)
	twist.vz = BodyRules.ease(twist.vz, dz / dt, VELOCITY_SECONDS, dt)
end

-- `angle` eased towards `target`, rest once it is all but there.
local function towards(angle: number, target: number, seconds: number, dt: number): number
	local value = BodyRules.ease(angle, target, seconds, dt)
	if target == 0 and math.abs(value) < WRITE_EPSILON then
		return 0
	end
	return value
end

--[[
	Draws `twist`'s body facing `yaw` (upright or not) this frame: the legs from its feet (walked
	backwards as `replicated` says when known: another player's), the waist from `lead`,
	`freelook` (BodyRules.waist) and its lean from the `sights` share (BodyRules.lean).
]]
local function pose(
	twist: Twist,
	yaw: number,
	upright: boolean,
	lead: number,
	freelook: number,
	sights: number,
	dt: number,
	replicated: boolean?
)
	twist.frame = frame
	local legs, backwards = 0, false
	if upright then
		local vx, vz = twist.vx, twist.vz
		local speed = math.sqrt(vx * vx + vz * vz)
		local angle = BodyRules.moveAngle(vx, vz, yaw)
		legs, backwards = BodyRules.remoteLegs(angle, speed, twist.backwards, replicated)
	end
	twist.backwards = backwards
	twist.legYaw = towards(twist.legYaw, legs, LEGS_SECONDS, dt)
	local waist = if upright then BodyRules.waist(lead, twist.legYaw, freelook) else 0
	twist.waistYaw = towards(twist.waistYaw, waist, WAIST_SECONDS, dt)
	twist.waistLean = towards(twist.waistLean, if upright then BodyRules.lean(sights) else 0, WAIST_SECONDS, dt)
	if twist.rigged then
		setYaw(twist.left, twist.legYaw)
		setYaw(twist.right, twist.legYaw)
		setYaw(twist.waist, twist.waistYaw, twist.waistLean)
	end
end

--[[
	Does another player's walk play reversed (their client's backpedal, replicated)? nil while none
	of their Animator's tracks is seen playing.
]]
local function reversed(twist: Twist): boolean?
	local playing = false
	for _, track in twist.tracks do
		if track.IsPlaying then
			if track.Speed < REVERSED then
				return true
			end
			playing = true
		end
	end
	return if playing then false else nil
end

-- The local body's turn rate this frame (radians a second, smoothed), from its yaw.
local function turn(yaw: number?, dt: number)
	local last = lastYaw
	lastYaw = yaw
	if yaw == nil or last == nil or dt <= 0 or dt > LONG_FRAME then
		turnRate = 0
		return
	end
	local delta = BodyRules.wrap(yaw - last)
	if math.abs(delta) > SNAP_TURN then
		delta = 0
	end
	turnRate = BodyRules.ease(turnRate, delta / dt, TURN_SECONDS, dt)
end

local function step(dt: number)
	frame += 1

	-- The local character (not while spectating someone: the camera is in their eyes).
	local player = localPlayer
	local view = MovementController.current
	local character = if player then player.Character else nil
	turn(if view then view.yaw else nil, dt)
	localBackwards = false
	if player and view and character and MovementController.spectating() == nil then
		local twist = twistFor(player, character, false)
		local humanoid = twist.humanoid
		if humanoid and humanoid.Health > 0 then
			local state = view.state
			local upright = view.tilt < UPRIGHT and not state.swimming and not (state.climbing and not state.onGround)
			move(twist, view.feetX, view.feetZ, dt)
			-- (The upper body leads only while the rig turns the body after the aim.)
			local lead, freelook, sights = 0, 0, 0
			if CameraRig.active() and not CameraRig.holding() then
				lead = BodyRules.wrap(CameraRig.aimYaw() - view.yaw)
				freelook = CameraRig.freelookOffset()
			end
			-- (A gun's sights seen from the eyes lean the upper body forward: Player/HeldItems' share.)
			if FirstPersonBody.trueFirstPerson() then
				local held = FirstPersonBody.held()
				if held.kind == "firearm" then
					sights = held.sightsShare
				end
			end
			pose(twist, view.yaw, upright, lead, freelook, sights, dt, nil)
			localBackwards = twist.backwards
		end
	end

	-- Everyone else drawn here.
	for other in tracked do
		local remote = RemotePlayers.get(other)
		local body = if remote then remote.character else nil
		if remote and body and remote.alive and RemotePlayers.shown(other) then
			local twist = twistFor(other, body, true)
			local upright = remote.tilt < UPRIGHT and not bit32.btest(remote.flags, CLIMBING)
			move(twist, remote.x, remote.z, dt)
			pose(twist, remote.yaw, upright, 0, 0, 0, dt, reversed(twist))
		end
	end

	-- Bodies not drawn this frame stand as they were.
	for _, twist in twists do
		if twist.frame ~= frame then
			rest(twist)
		end
	end
end

-- Starts the twist (once, after Player/RemotePlayers and Player/MovementController started).
function BodyTwist.start()
	if started then
		return
	end
	started = true
	localPlayer = Players.LocalPlayer
	RemotePlayers.onTracked(function(player: Player, isTracked: boolean)
		if isTracked then
			tracked[player] = true
		else
			tracked[player] = nil
		end
	end)
	for player in RemotePlayers.each() do
		tracked[player] = true
	end
	RunService:BindToRenderStep(RENDER_STEP, RENDER_PRIORITY, step)
end

-- Do the local legs walk backwards (a backpedal): Player/CharacterAnimator plays the walk reversed.
function BodyTwist.backwards(): boolean
	return localBackwards
end

-- The local body's turn rate (radians a second, smoothed; positive left), for the idle shuffle.
function BodyTwist.turnRate(): number
	return turnRate
end

return BodyTwist
