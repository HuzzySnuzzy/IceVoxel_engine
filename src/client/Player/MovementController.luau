--!strict
--[[
	The local player's movement: a Minecraft-style hull (Shared/Movement/PlayerPhysics) simulated
	against the client's block data at 20 ticks per second. The Roblox character is purely
	cosmetic: it is put where the hull is every frame and never touches anything itself.

	  Input     the default control scripts' move vector (PlayerModule: keyboard, gamepad, touch;
	            Humanoid.MoveDirection if a game replaces them), turned by the camera like the
	            default controls do, and Humanoid.Jump. Sprint and sneak keys / touch buttons
	            (Config.Movement): the sprint key toggles sprinting (or is held, ToggleSprint =
	            false); double tapping forward sprints too.
	  Ticks     fixed 50 ms steps like Minecraft; the character is drawn interpolated between the
	            last two ticks (as Minecraft does), before the camera updates each frame. Steps up
	            (Config.Movement.StepHeight, just over a block) are drawn as a quick climb.
	  Character its parts are in a collision group that collides with nothing (Rig), the Humanoid
	            is held in the Physics state (it applies no forces of its own), a VectorForce
	            cancels gravity, and the root part is moved with CFrame + velocity. The client owns
	            its character, so that replicates to everyone like normal movement. In the
	            swimming / crawling pose the body lies down (pitched with the view when swimming),
	            as Roblox's own Swimming state and Minecraft's renderer do.
	  Facing    towards where the character walks, or where the camera looks in first person and
	            with shift lock.
	  Camera    at the hull's eye height (eased like Minecraft's when crouching / crawling); the
	            field of view widens while flying (x 1.1) and sprinting (Config.Movement.SprintFov),
	            eased like Minecraft's FOV modifier, on top of whatever the camera's field of view
	            is.
	  Flying    creative players (the game mode attribute, GameMode) may fly: double tap jump.
	            Switching to survival stops it.
	  Screens   while an inventory screen is open (Ui/Screens) the input is neutral: the player
	            stops (a sprint toggled on stays on).
	  Waiting   until the full detail chunks under the hull are visible (after spawning and
	            teleports), it stays frozen in place.
	  Teleports the server sets the feet position as attributes (Rig); other scripts moving the
	            character far are noticed too, and the hull follows.
	  Damage    landings after falls are reported to the server for fall damage. The Physics state
	            does not die on its own, so the controller puts the Humanoid into Dead itself.
	  Sounds    after every tick, Audio/MovementSounds plays the footsteps, swimming, splashes and
	            hurting landings of what the hull did.

	CharacterAnimator plays the avatar's animations from the hull state.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Protocol = require(Shared.Net.Protocol)
local PlayerPhysics = require(Shared.Movement.PlayerPhysics)
local Rig = require(Shared.Movement.Rig)

local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local Screens = require(script.Parent.Parent.Ui.Screens)
local MovementSounds = require(script.Parent.Parent.Audio.MovementSounds)

local BLOCK = Config.BlockSize
local Movement = Config.Movement
local TICK_RATE = PlayerPhysics.TICK_RATE
local TICK = 1 / TICK_RATE
-- Ticks run at most per frame (a long hitch does not fast-forward the player).
local MAX_TICKS_PER_FRAME = 5
-- Runs right before the camera, so the camera follows this frame's position.
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value - 1
-- The server moves new characters to the spawn first; don't trust their position before that.
local SPAWN_SETTLE = 3
-- A root part further than this (studs) from where the controller left it was moved by a script.
local MOVED_TOLERANCE = 4
-- Studs per block per tick -> studs per second.
local VELOCITY_SCALE = BLOCK * TICK_RATE
-- Minecraft eases the camera's eye height and the field of view half the remaining way each tick.
local EASE_PER_TICK = 0.5
-- How fast the body lies down / gets up (Minecraft's swimAmount: 0.09 per tick).
local TILT_PER_SECOND = 0.09 * TICK_RATE
-- After a step up the drawn character catches up with the hull at this rate (per second), at
-- most this many blocks behind.
local STEP_CATCH_UP = 14
local MAX_STEP_LAG = 1.5
-- The camera counts as first person this close (studs) to its focus (Roblox's camera switches to
-- first person below 1 stud of zoom).
local FIRST_PERSON_DISTANCE = 1
-- Roblox's camera can't go wider than this.
local MAX_FOV = 120
-- Field of view modifier while flying (AbstractClientPlayer.getFieldOfViewModifier).
local FLYING_FOV = 1.1

type Streamer = { isReady: (self: any, x: number, z: number) -> boolean }

export type View = {
	-- Hull state (blocks), updated every tick; also whether the player may fly (creative) and
	-- flies (state.mayFly, state.flying).
	state: PlayerPhysics.State,
	-- Where the hull is drawn this frame (feet, blocks, between the last two ticks) and the
	-- character's facing (radians around Y).
	feet: Vector3,
	yaw: number,
	-- How far the body lies down: 0 upright .. 1 in the swimming / crawling pose.
	tilt: number,
	-- Horizontal speed over the last tick (blocks per second).
	speed: number,
	-- os.clock() of the last jump.
	jumpedAt: number,
	-- Waiting for the ground to load (after spawning / teleports).
	frozen: boolean,
}

local MovementController = {}

-- The local player's movement while a character exists (BlockInteraction, the F3 overlay, the
-- animator read it).
MovementController.current = nil :: View?

local function keyCodes(names: { string }): { Enum.KeyCode }
	local codes = {}
	for _, name in names do
		local ok, code = pcall(function()
			return (Enum.KeyCode :: any)[name]
		end)
		if ok and code then
			table.insert(codes, code)
		else
			warn(`[IceVoxel] Config.Movement: unknown key {name}`)
		end
	end
	return codes
end

local function setGroup(part: Instance, group: string)
	if part:IsA("BasePart") then
		part.CollisionGroup = group
	end
end

-- Yaw (radians around Y) that faces direction (x, z); Roblox characters look down -Z.
local function yawOf(x: number, z: number): number
	return math.atan2(-x, -z)
end

local function angleDifference(a: number, b: number): number
	return (a - b + math.pi) % (2 * math.pi) - math.pi
end

-- Fraction of the way to ease this frame for something Minecraft eases EASE_PER_TICK per tick.
local function ease(dt: number): number
	return 1 - EASE_PER_TICK ^ (dt * TICK_RATE)
end

--[[
	The camera's heading on the ground (unit x, z): where "forward" input goes. Same as the default
	control scripts (ControlModule calculateRawMoveVector), which use the up vector when the camera
	looks straight up or down.
]]
local function cameraHeading(cframe: CFrame): (number, number)
	local _, _, _, r00, r01, r02, _, _, r12, _, _, r22 = cframe:GetComponents()
	local c, s = r22, r02
	if r12 >= 1 or r12 <= -1 then
		c, s = r00, -r01 * math.sign(r12)
	end
	local norm = math.sqrt(c * c + s * s)
	if norm < 1e-6 then
		return 0, -1
	end
	return -s / norm, -c / norm
end

-- Height (studs) above the HumanoidRootPart, in its space, that Roblox's camera aims at
-- (CameraModule BaseCamera: R6 and scaled R15 1.5 plus half the root part's growth, else 2).
local function cameraHeight(hum: Humanoid, root: BasePart): number
	if hum.RigType == Enum.HumanoidRigType.R15 then
		if hum.AutomaticScalingEnabled then
			return 1.5 + (root.Size.Y - 2) / 2
		end
		return 2
	end
	return 1.5
end

function MovementController.start(world: ClientWorld.ClientWorld, streamer: Streamer)
	local player = Players.LocalPlayer
	local physicsWorld: PlayerPhysics.World = {
		getBlock = function(x: number, y: number, z: number): number?
			return world:getBlock(x, y, z)
		end,
	}

	-- The default control scripts, if the game has them (false: tried and failed).
	local controls: any = nil
	local function controlMoveVector(): Vector3?
		if controls == nil then
			local scripts = player:FindFirstChildOfClass("PlayerScripts")
			local module = scripts and scripts:FindFirstChild("PlayerModule")
			if module == nil or not module:IsA("ModuleScript") then
				return nil
			end
			local ok, result = pcall(function()
				return (require :: any)(module):GetControls()
			end)
			controls = if ok and result then result else false
		end
		if not controls then
			return nil
		end
		local ok, vector = pcall(function()
			return controls:GetMoveVector()
		end)
		return if ok and typeof(vector) == "Vector3" then vector else nil
	end

	-- Sprint / sneak keys and touch toggles.
	local sprintHeld, sprintOn = false, false
	local sneakHeld, sneakOn = false, false
	local function bind(name: string, keys: { string }, title: string, onChange: (held: boolean, touch: boolean) -> ())
		ContextActionService:BindActionAtPriority(name, function(_, inputState: Enum.UserInputState, input: InputObject)
			local touch = input.UserInputType == Enum.UserInputType.Touch
			-- In an inventory screen, gamepad buttons (B closes it) and touches go on to the
			-- screens; releases still count, so nothing stays held.
			local pass = Screens.isOpen() and input.UserInputType ~= Enum.UserInputType.Keyboard
			if inputState == Enum.UserInputState.Begin then
				if not pass then
					onChange(true, touch)
				end
			elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
				onChange(false, touch)
			end
			-- Keep Shift from also toggling the shift lock.
			return if pass then Enum.ContextActionResult.Pass else Enum.ContextActionResult.Sink
		end, Movement.TouchButtons, Enum.ContextActionPriority.High.Value, table.unpack(keyCodes(keys)))
		if Movement.TouchButtons then
			ContextActionService:SetTitle(name, title)
		end
	end
	local function setTitle(name: string, title: string)
		if Movement.TouchButtons then
			ContextActionService:SetTitle(name, title)
		end
	end
	bind("IceVoxelSprint", Movement.SprintKeys, "Sprint", function(held, touch)
		if touch or Movement.ToggleSprint then
			-- (Ctrl+Q in an inventory screen must not toggle sprinting.)
			if held and not Screens.isOpen() then
				-- Toggles what the player sees: a sprint started by double tapping stops too.
				local view = MovementController.current
				sprintOn = not (sprintOn or (view ~= nil and view.state.sprinting))
				if not sprintOn and view then
					view.state.sprinting = false
				end
				setTitle("IceVoxelSprint", if sprintOn then "Sprinting" else "Sprint")
			end
		else
			sprintHeld = held
		end
	end)
	bind("IceVoxelSneak", Movement.SneakKeys, "Sneak", function(held, touch)
		if touch then
			if held then
				sneakOn = not sneakOn
				setTitle("IceVoxelSneak", if sneakOn then "Sneaking" else "Sneak")
			end
		else
			sneakHeld = held
		end
	end)

	-- Sprinting widens the camera's field of view (whatever it is set to) by Movement.SprintFov.
	local fovModifier = 1
	local fovCamera: Camera? = nil
	local baseFov = 70
	-- What this controller last set the field of view to (nil: nothing yet).
	local setFov: number? = nil
	local function updateFov(dt: number, target: number)
		local camera = workspace.CurrentCamera
		if camera == nil then
			return
		end
		if camera ~= fovCamera or setFov == nil or math.abs(camera.FieldOfView - setFov) > 1e-3 then
			-- First frame, a new camera, or another script changed it: that is the base now.
			fovCamera = camera
			baseFov = camera.FieldOfView
		end
		fovModifier += (target - fovModifier) * ease(dt)
		if math.abs(target - fovModifier) < 1e-4 then
			fovModifier = target
		end
		camera.FieldOfView = math.clamp(baseFov * fovModifier, 1, MAX_FOV)
		setFov = camera.FieldOfView
	end
	local function resetFov()
		local camera = fovCamera
		if camera and setFov and math.abs(camera.FieldOfView - setFov) <= 1e-3 then
			camera.FieldOfView = baseFov
		end
		fovModifier, fovCamera, setFov = 1, nil, nil
	end

	local connections: { RBXScriptConnection } = {}
	local function disconnectAll()
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
		RunService:UnbindFromRenderStep("IceVoxelMovement")
		MovementController.current = nil
		resetFov()
	end

	local function onCharacter(character: Model)
		disconnectAll()
		local root = character:WaitForChild("HumanoidRootPart", 10)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if root == nil or humanoid == nil or not root:IsA("BasePart") or not humanoid:IsA("Humanoid") then
			return
		end
		local rootPart: BasePart, hum: Humanoid = root, humanoid
		if hum.Health <= 0 or character.Parent == nil then
			return
		end

		-- Cosmetic rig: no collisions, no humanoid forces, no gravity.
		for _, part in character:GetDescendants() do
			setGroup(part, Rig.COLLISION_GROUP)
		end
		table.insert(
			connections,
			character.DescendantAdded:Connect(function(part)
				setGroup(part, Rig.COLLISION_GROUP)
			end)
		)
		-- Parts leaving the character (a dropped tool) collide normally again.
		table.insert(
			connections,
			character.DescendantRemoving:Connect(function(part)
				setGroup(part, "Default")
			end)
		)
		hum.AutoRotate = false
		hum:ChangeState(Enum.HumanoidStateType.Physics)
		local attachment = Instance.new("Attachment")
		attachment.Name = "IceVoxelMovement"
		attachment.Parent = rootPart
		local antiGravity = Instance.new("VectorForce")
		antiGravity.Name = "IceVoxelAntiGravity"
		antiGravity.Attachment0 = attachment
		antiGravity.RelativeTo = Enum.ActuatorRelativeTo.World
		antiGravity.ApplyAtCenterOfMass = true
		antiGravity.Parent = rootPart
		-- The joint holding the body to the root part (R15 LowerTorso.Root, R6 RootJoint). The
		-- step-up catch-up lowers the body through it, so the root part (the player's position for
		-- the server and other players) always stays on the hull.
		local rootJoint: Motor6D? = nil
		local rootJointC0 = CFrame.identity
		for _, descendant in character:GetDescendants() do
			if descendant:IsA("Motor6D") and descendant.Part0 == rootPart then
				rootJoint = descendant
				rootJointC0 = descendant.C0
				break
			end
		end

		-- Hull, starting where the server put the character.
		local spawnedAt = os.clock()
		local feet = character:GetAttribute(Rig.TELEPORT_FEET)
		local start = if typeof(feet) == "Vector3" then feet else Rig.feet(character) or Vector3.zero
		local state = PlayerPhysics.new(start.X, start.Y, start.Z)
		state.stepHeight = Movement.StepHeight
		state.mayFly = GameMode.isCreative(player)
		local _, rootYaw = rootPart.CFrame:ToOrientation()
		local view: View = {
			state = state,
			feet = start,
			yaw = rootYaw,
			tilt = 0,
			speed = 0,
			jumpedAt = -math.huge,
			frozen = true,
		}
		MovementController.current = view

		local previous = start
		local accumulator = 0
		local jumpLatched = false
		-- Blocks the drawn character is below the hull after stepping up.
		local stepLag = 0
		-- Eye height (blocks) the camera is at, easing towards the hull's.
		local eye = PlayerPhysics.eyeHeight(state)
		-- Where the root part was put last frame (studs), its velocity then and that frame's length.
		local lastPlaced: Vector3? = nil
		local lastVelocity = Vector3.zero
		local lastDt = 0
		local settled = typeof(feet) == "Vector3"

		local function snap(position: Vector3)
			PlayerPhysics.place(state, position.X, position.Y, position.Z)
			previous = position
			view.feet = position
			view.speed = 0
			view.frozen = true
			accumulator = 0
			stepLag = 0
		end
		local function onTeleport()
			local target = character:GetAttribute(Rig.TELEPORT_FEET)
			if typeof(target) == "Vector3" then
				settled = true
				snap(target)
			end
		end
		table.insert(connections, character:GetAttributeChangedSignal(Rig.TELEPORT_FEET):Connect(onTeleport))
		table.insert(connections, character:GetAttributeChangedSignal(Rig.TELEPORT_COUNT):Connect(onTeleport))

		local function release()
			disconnectAll()
			antiGravity:Destroy()
			attachment:Destroy()
			hum.CameraOffset = Vector3.zero
			if rootJoint then
				rootJoint.C0 = rootJointC0
			end
			for _, part in character:GetDescendants() do
				setGroup(part, "Default")
			end
		end
		table.insert(connections, hum.Died:Connect(release))
		-- The Physics state does not die by itself when health runs out.
		local function dieIfDead()
			if hum.Health <= 0 and hum:GetState() ~= Enum.HumanoidStateType.Dead then
				hum:ChangeState(Enum.HumanoidStateType.Dead)
			end
		end
		table.insert(connections, hum.HealthChanged:Connect(dieIfDead))

		-- Jump held now (never while a screen is open).
		local function jumpHeld(): boolean
			return hum.Jump and not Screens.isOpen()
		end

		local function readInput(dt: number): PlayerPhysics.Input
			-- An open inventory screen takes the input: stand still, keep facing the same way.
			if Screens.isOpen() then
				jumpLatched = false
				return {
					moveX = 0,
					moveZ = 0,
					forward = 0,
					facingX = -math.sin(view.yaw),
					facingZ = -math.cos(view.yaw),
					lookY = math.clamp(workspace.CurrentCamera.CFrame.LookVector.Y, -1, 1),
					jump = false,
					sneak = false,
					sprint = false,
				}
			end
			local camera = workspace.CurrentCamera
			local cameraCFrame = camera.CFrame
			local headingX, headingZ = cameraHeading(cameraCFrame)
			local rightX, rightZ = -headingZ, headingX

			-- Input relative to the camera (keyboard diagonals are longer than 1, as in Minecraft;
			-- the physics normalises them).
			local strafe, ahead
			local vector = controlMoveVector()
			if vector then
				strafe, ahead = vector.X, -vector.Z
			else
				local move = hum.MoveDirection
				strafe = move.X * rightX + move.Z * rightZ
				ahead = move.X * headingX + move.Z * headingZ
			end
			local moveX = rightX * strafe + headingX * ahead
			local moveZ = rightZ * strafe + headingZ * ahead
			local length = math.sqrt(strafe * strafe + ahead * ahead)

			-- Facing: the camera's direction in first person and with shift lock, else where the
			-- character walks (turning smoothly).
			local firstPerson = (cameraCFrame.Position - camera.Focus.Position).Magnitude < FIRST_PERSON_DISTANCE
			local lockedToCamera = firstPerson or UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
			local facingX, facingZ, forward
			if lockedToCamera then
				facingX, facingZ, forward = headingX, headingZ, ahead
				view.yaw = yawOf(headingX, headingZ)
			else
				if length > 1e-3 then
					facingX, facingZ = moveX / length, moveZ / length
					local turn = angleDifference(yawOf(facingX, facingZ), view.yaw)
					local maxTurn = Movement.TurnSpeed * dt
					view.yaw += math.clamp(turn, -maxTurn, maxTurn)
				else
					facingX, facingZ = -math.sin(view.yaw), -math.cos(view.yaw)
				end
				forward = math.min(length, 1)
			end

			jumpLatched = jumpLatched or jumpHeld()
			return {
				moveX = moveX,
				moveZ = moveZ,
				forward = forward,
				facingX = facingX,
				facingZ = facingZ,
				lookY = math.clamp(cameraCFrame.LookVector.Y, -1, 1),
				jump = jumpLatched,
				sneak = sneakHeld or sneakOn,
				sprint = sprintHeld or sprintOn,
			}
		end

		RunService:BindToRenderStep("IceVoxelMovement", RENDER_PRIORITY, function(dt: number)
			if rootPart.Parent == nil then
				return
			end
			if hum.Health <= 0 then
				dieIfDead()
				return
			end
			-- Stay in the Physics state (anything else would apply humanoid forces).
			local humanoidState = hum:GetState()
			if humanoidState ~= Enum.HumanoidStateType.Physics and humanoidState ~= Enum.HumanoidStateType.Dead then
				hum:ChangeState(Enum.HumanoidStateType.Physics)
			end
			antiGravity.Force = Vector3.new(0, rootPart.AssemblyMass * workspace.Gravity, 0)

			-- Moved by some other script? Follow it. Roblox physics moves the root along its velocity
			-- in between, for a step that need not match this frame's dt (hitches), so allow for
			-- the velocity over both frames.
			local placed = lastPlaced
			local drift = lastVelocity.Magnitude * (dt + lastDt)
			if placed and (rootPart.Position - placed).Magnitude > MOVED_TOLERANCE + drift then
				local moved = Rig.feet(character)
				if moved then
					snap(moved)
				end
			end

			local frameInput = readInput(dt)
			stepLag *= math.exp(-STEP_CATCH_UP * dt)
			if view.frozen then
				-- Wait for the server's spawn teleport (fresh characters) and for the ground.
				if not settled and os.clock() - spawnedAt > SPAWN_SETTLE then
					settled = true
				end
				-- Jumps pressed while waiting don't fire afterwards.
				jumpLatched = false
				if settled and streamer:isReady(math.floor(state.x), math.floor(state.z)) then
					view.frozen = false
					accumulator = 0
				end
			else
				accumulator = math.min(accumulator + dt, TICK * MAX_TICKS_PER_FRAME)
				while accumulator >= TICK do
					accumulator -= TICK
					previous = Vector3.new(state.x, state.y, state.z)
					local events = PlayerPhysics.tick(state, frameInput, physicsWorld)
					MovementSounds.tick(state, events, previous, physicsWorld.getBlock)
					frameInput.jump = jumpHeld()
					jumpLatched = false
					view.speed = math.sqrt((state.x - previous.X) ^ 2 + (state.z - previous.Z) ^ 2) * TICK_RATE
					if events.jumped then
						view.jumpedAt = os.clock()
					end
					if events.stepUp > 0 then
						-- A step up is a whole block in one tick: draw it as a quick climb instead.
						previous += Vector3.new(0, events.stepUp, 0)
						stepLag = math.min(stepLag + events.stepUp, MAX_STEP_LAG)
					end
					if events.landed and events.damage > 0 and Movement.FallDamage then
						ClientNet.send(Protocol.ClientMessage.Fall, Protocol.encodeFall(events.fallDistance))
					end
				end
			end

			-- Draw the character between the last two ticks.
			local alpha = if view.frozen then 1 else accumulator / TICK
			local hull = previous:Lerp(Vector3.new(state.x, state.y, state.z), alpha)
			view.feet = hull

			-- Lie down in the swimming / crawling pose: face down, or along the view when swimming
			-- (Minecraft's PlayerRenderer), the body's middle at the middle of the low hull.
			local lying = state.pose == "crawling"
			view.tilt = math.clamp(view.tilt + (if lying then dt else -dt) * TILT_PER_SECOND, 0, 1)
			local bodyPitch = math.pi / 2
			if state.inWater then
				bodyPitch = math.clamp(math.pi / 2 - math.asin(frameInput.lookY), 0, math.pi)
			end
			local rootHeight = Rig.rootHeight(character, view.tilt)
			local cframe = CFrame.new(view.feet * BLOCK + Vector3.new(0, rootHeight, 0))
				* CFrame.Angles(0, view.yaw, 0)
				* CFrame.Angles(-bodyPitch * view.tilt, 0, 0)
			local velocity = if view.frozen
				then Vector3.zero
				else Vector3.new(state.vx, state.vy, state.vz) * VELOCITY_SCALE
			rootPart.CFrame = cframe
			rootPart.AssemblyLinearVelocity = velocity
			rootPart.AssemblyAngularVelocity = Vector3.zero
			lastPlaced, lastVelocity, lastDt = cframe.Position, velocity, dt

			-- The camera looks from the hull's eyes, whatever the body does (Roblox's camera adds
			-- CameraOffset in the root part's space).
			eye += (PlayerPhysics.eyeHeight(state) - eye) * ease(dt)
			local lag = Vector3.new(0, -stepLag * BLOCK, 0)
			if rootJoint then
				rootJoint.C0 = CFrame.new(cframe:VectorToObjectSpace(lag)) * rootJointC0
			end
			local toEye = Vector3.new(0, eye * BLOCK - rootHeight, 0) + lag
			hum.CameraOffset = cframe:VectorToObjectSpace(toEye) - Vector3.new(0, cameraHeight(hum, rootPart), 0)

			-- Minecraft's FOV modifier: x 1.1 flying, x SprintFov sprinting.
			local fov = 1
			if not view.frozen then
				fov = (if state.flying then FLYING_FOV else 1) * (if state.sprinting then Movement.SprintFov else 1)
			end
			updateFov(dt, fov)
		end)
	end

	-- The server sets the game mode; switching to survival stops flying at once.
	player:GetAttributeChangedSignal(GameMode.ATTRIBUTE):Connect(function()
		local view = MovementController.current
		if view then
			view.state.mayFly = GameMode.isCreative(player)
			if not view.state.mayFly then
				view.state.flying = false
			end
		end
	end)

	player.CharacterAdded:Connect(onCharacter)
	player.CharacterRemoving:Connect(disconnectAll)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end
end

return MovementController
