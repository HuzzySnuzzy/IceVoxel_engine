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
	            field of view widens while sprinting (Config.Movement.SprintFov, eased like
	            Minecraft's FOV modifier) on top of whatever the camera's field of view is.
	  Waiting   until the full detail chunks under the hull are visible (after spawning and
	            teleports), it stays frozen in place.
	  Teleports the server sets the feet position as attributes (Rig); other scripts moving the
	            character far are noticed too, and the hull follows.
	  Damage    landings after falls are reported to the server for fall damage. The Physics state
	            does not die on its own, so the controller puts the Humanoid into Dead itself.

	CharacterAnimator plays the avatar's animations from the hull state.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Protocol = require(Shared.Net.Protocol)
local PlayerPhysics = require(Shared.Movement.PlayerPhysics)
local Rig = require(Shared.Movement.Rig)

local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local ClientNet = require(script.Parent.Parent.Net.ClientNet)

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
-- Height (studs) of the root part above the feet when lying: the middle of the crawling hull.
local LYING_ROOT = PlayerPhysics.dimensions("crawling").height / 2 * BLOCK
-- After a step up the drawn character catches up with the hull at this rate (per second), at
-- most this many blocks behind.
local STEP_CATCH_UP = 14
local MAX_STEP_LAG = 1.5
-- The camera counts as first person this close (studs) to its focus (Roblox's camera switches to
-- first person below 1 stud of zoom).
local FIRST_PERSON_DISTANCE = 1
-- Roblox's camera can't go wider than this.
local MAX_FOV = 120

type Streamer = { isReady: (self: any, x: number, z: number) -> boolean }

export type View = {
	-- Hull state (blocks), updated every tick.
	state: PlayerPhysics.State,
	-- Where the character is drawn this frame (feet, blocks) and its facing (radians around Y).
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
			if inputState == Enum.UserInputState.Begin then
				onChange(true, touch)
			elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
				onChange(false, touch)
			end
			-- Keep Shift from also toggling the shift lock.
			return Enum.ContextActionResult.Sink
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
			if held then
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
	local function updateFov(dt: number, sprinting: boolean)
		local camera = workspace.CurrentCamera
		if camera == nil then
			return
		end
		if camera ~= fovCamera or setFov == nil or math.abs(camera.FieldOfView - setFov) > 1e-3 then
			-- First frame, a new camera, or another script changed it: that is the base now.
			fovCamera = camera
			baseFov = camera.FieldOfView
		end
		local target = if sprinting then Movement.SprintFov else 1
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

		-- Hull, starting where the server put the character.
		local spawnedAt = os.clock()
		local feet = character:GetAttribute(Rig.TELEPORT_FEET)
		local start = if typeof(feet) == "Vector3" then feet else Rig.feet(character) or Vector3.zero
		local state = PlayerPhysics.new(start.X, start.Y, start.Z)
		state.stepHeight = Movement.StepHeight
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
		-- Where the root part was put last frame (studs) and its velocity then.
		local lastPlaced: Vector3? = nil
		local lastVelocity = Vector3.zero
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

		local function readInput(dt: number): PlayerPhysics.Input
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

			jumpLatched = jumpLatched or hum.Jump
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

			-- Moved by some other script? Follow it.
			local placed = lastPlaced
			if placed and (rootPart.Position - (placed + lastVelocity * dt)).Magnitude > MOVED_TOLERANCE then
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
					frameInput.jump = hum.Jump
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
			view.feet = hull - Vector3.new(0, stepLag, 0)

			-- Lie down in the swimming / crawling pose: face down, or along the view when swimming
			-- (Minecraft's PlayerRenderer), the body's middle at the middle of the low hull.
			local lying = state.pose == "crawling"
			view.tilt = math.clamp(view.tilt + (if lying then dt else -dt) * TILT_PER_SECOND, 0, 1)
			local bodyPitch = math.pi / 2
			if state.inWater then
				bodyPitch = math.clamp(math.pi / 2 - math.asin(frameInput.lookY), 0, math.pi)
			end
			local standingRoot = Rig.rootOffset(character)
			local rootHeight = standingRoot + (LYING_ROOT - standingRoot) * view.tilt
			local cframe = CFrame.new(view.feet * BLOCK + Vector3.new(0, rootHeight, 0))
				* CFrame.Angles(0, view.yaw, 0)
				* CFrame.Angles(-bodyPitch * view.tilt, 0, 0)
			local velocity = if view.frozen
				then Vector3.zero
				else Vector3.new(state.vx, state.vy, state.vz) * VELOCITY_SCALE
			rootPart.CFrame = cframe
			rootPart.AssemblyLinearVelocity = velocity
			rootPart.AssemblyAngularVelocity = Vector3.zero
			lastPlaced, lastVelocity = cframe.Position, velocity

			-- The camera looks from the hull's eyes, whatever the body does (Roblox's camera adds
			-- CameraOffset in the root part's space).
			eye += (PlayerPhysics.eyeHeight(state) - eye) * ease(dt)
			local toEye = Vector3.new(0, eye * BLOCK - rootHeight, 0)
			hum.CameraOffset = cframe:VectorToObjectSpace(toEye) - Vector3.new(0, cameraHeight(hum, rootPart), 0)

			updateFov(dt, state.sprinting and not view.frozen)
		end)
	end

	player.CharacterAdded:Connect(onCharacter)
	player.CharacterRemoving:Connect(disconnectAll)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end
end

return MovementController
