--!strict
--[[
	The local player's movement: a Minecraft-style hull (Shared/Movement/PlayerPhysics) simulated
	against the client's block data at 20 ticks per second. The Roblox character is purely
	cosmetic: it is put where the hull is every frame and never touches anything itself.

	  Input     Humanoid.MoveDirection (the default controls: keyboard, gamepad and touch, already
	            turned by the camera) and Humanoid.Jump; sprint and sneak keys / touch buttons
	            (Config.Movement), double tap forward to sprint.
	  Ticks     fixed 50 ms steps like Minecraft; the character is drawn interpolated between the
	            last two ticks (as Minecraft does), before the camera updates each frame.
	  Character its parts are in a collision group that collides with nothing (Rig), the Humanoid
	            is held in the Physics state (it applies no forces of its own), a VectorForce
	            cancels gravity, and the root part is moved with CFrame + velocity. The client owns
	            its character, so that replicates to everyone like normal movement.
	  Facing    towards where the character walks, or where the camera looks in first person and
	            with shift lock.
	  Waiting   until the full detail chunks under the hull are visible (after spawning and
	            teleports), it stays frozen in place.
	  Teleports the server sets the feet position as attributes (Rig); other scripts moving the
	            character far are noticed too, and the hull follows.
	  Damage    landings after falls are reported to the server for fall damage.

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
local TICK = 1 / PlayerPhysics.TICK_RATE
-- Ticks run at most per frame (a long hitch does not fast-forward the player).
local MAX_TICKS_PER_FRAME = 5
-- Runs right before the camera, so the camera follows this frame's position.
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value - 1
-- The server moves new characters to the spawn first; don't trust their position before that.
local SPAWN_SETTLE = 3
-- A root part further than this (studs) from where the controller left it was moved by a script.
local MOVED_TOLERANCE = 4
-- Studs per block per tick -> studs per second.
local VELOCITY_SCALE = BLOCK * PlayerPhysics.TICK_RATE

type Streamer = { isReady: (self: any, x: number, z: number) -> boolean }

export type View = {
	-- Hull state (blocks), updated every tick.
	state: PlayerPhysics.State,
	-- Where the character is drawn this frame (feet, blocks) and its facing (radians around Y).
	feet: Vector3,
	yaw: number,
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

function MovementController.start(world: ClientWorld.ClientWorld, streamer: Streamer)
	local player = Players.LocalPlayer
	local physicsWorld: PlayerPhysics.World = {
		getBlock = function(x: number, y: number, z: number): number?
			return world:getBlock(x, y, z)
		end,
	}

	-- Sprint / sneak keys and touch toggles.
	local sprintHeld, sneakHeld = false, false
	local sprintToggle, sneakToggle = false, false
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
	bind("IceVoxelSprint", Movement.SprintKeys, "Sprint", function(held, touch)
		if touch then
			if held then
				sprintToggle = not sprintToggle
			end
		else
			sprintHeld = held
		end
	end)
	bind("IceVoxelSneak", Movement.SneakKeys, "Sneak", function(held, touch)
		if touch then
			if held then
				sneakToggle = not sneakToggle
			end
		else
			sneakHeld = held
		end
	end)

	local connections: { RBXScriptConnection } = {}
	local function disconnectAll()
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
		RunService:UnbindFromRenderStep("IceVoxelMovement")
		MovementController.current = nil
	end

	local function onCharacter(character: Model)
		disconnectAll()
		local root = character:WaitForChild("HumanoidRootPart", 10)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if root == nil or humanoid == nil or not root:IsA("BasePart") or not humanoid:IsA("Humanoid") then
			return
		end
		local rootPart: BasePart, hum: Humanoid = root, humanoid

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
		local view: View = { state = state, feet = start, yaw = 0, frozen = true }
		local _, rootYaw = rootPart.CFrame:ToOrientation()
		view.yaw = rootYaw
		MovementController.current = view

		local previous = start
		local accumulator = 0
		local jumpLatched = false
		-- Where the root part was put last frame (studs) and its velocity then.
		local lastPlaced: Vector3? = nil
		local lastVelocity = Vector3.zero
		local settled = typeof(feet) == "Vector3"

		local function snap(position: Vector3)
			PlayerPhysics.place(state, position.X, position.Y, position.Z)
			previous = position
			view.feet = position
			view.frozen = true
			accumulator = 0
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
			for _, part in character:GetDescendants() do
				setGroup(part, "Default")
			end
		end
		table.insert(connections, hum.Died:Connect(release))

		local function input(dt: number): PlayerPhysics.Input
			local move = hum.MoveDirection
			local moveX, moveZ = move.X, move.Z
			local length = math.sqrt(moveX * moveX + moveZ * moveZ)
			if length > 1 then
				moveX, moveZ, length = moveX / length, moveZ / length, 1
			end

			-- Facing: the camera's direction in first person and with shift lock, else where the
			-- character walks (turning smoothly).
			local camera = workspace.CurrentCamera
			local look = camera.CFrame.LookVector
			local head = character:FindFirstChild("Head")
			local firstPerson = head ~= nil
				and head:IsA("BasePart")
				and (camera.CFrame.Position - head.Position).Magnitude < 1.5
			local lockedToCamera = firstPerson or UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
			local facingX, facingZ, forward
			if lockedToCamera and look.X * look.X + look.Z * look.Z > 1e-6 then
				local flat = Vector3.new(look.X, 0, look.Z).Unit
				facingX, facingZ = flat.X, flat.Z
				forward = math.max(0, moveX * facingX + moveZ * facingZ)
				view.yaw = yawOf(facingX, facingZ)
			else
				if length > 1e-3 then
					facingX, facingZ = moveX / length, moveZ / length
					local target = yawOf(facingX, facingZ)
					local turn = angleDifference(target, view.yaw)
					local maxTurn = Movement.TurnSpeed * dt
					view.yaw += math.clamp(turn, -maxTurn, maxTurn)
				else
					facingX, facingZ = -math.sin(view.yaw), -math.cos(view.yaw)
				end
				forward = length
			end

			jumpLatched = jumpLatched or hum.Jump
			return {
				moveX = moveX,
				moveZ = moveZ,
				forward = forward,
				facingX = facingX,
				facingZ = facingZ,
				jump = jumpLatched,
				sneak = sneakHeld or sneakToggle,
				sprint = sprintHeld or sprintToggle,
			}
		end

		RunService:BindToRenderStep("IceVoxelMovement", RENDER_PRIORITY, function(dt: number)
			if rootPart.Parent == nil or hum.Health <= 0 then
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

			local frameInput = input(dt)
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
					if events.landed and events.damage > 0 and Movement.FallDamage then
						ClientNet.send(Protocol.ClientMessage.Fall, Protocol.encodeFall(events.fallDistance))
					end
				end
			end

			-- Draw the character between the last two ticks.
			local alpha = if view.frozen then 1 else accumulator / TICK
			local current = Vector3.new(state.x, state.y, state.z)
			view.feet = previous:Lerp(current, alpha)
			local position = view.feet * BLOCK + Vector3.new(0, Rig.rootOffset(character), 0)
			local velocity = if view.frozen
				then Vector3.zero
				else Vector3.new(state.vx, state.vy, state.vz) * VELOCITY_SCALE
			rootPart.CFrame = CFrame.new(position) * CFrame.Angles(0, view.yaw, 0)
			rootPart.AssemblyLinearVelocity = velocity
			rootPart.AssemblyAngularVelocity = Vector3.zero
			lastPlaced, lastVelocity = position, velocity

			-- Lower the camera with the eyes (crouching, crawling).
			local eyeDrop = PlayerPhysics.eyeHeight(state) - PlayerPhysics.STANDING.eye
			hum.CameraOffset = hum.CameraOffset:Lerp(Vector3.new(0, eyeDrop * BLOCK, 0), math.min(1, dt * 12))
		end)
	end

	player.CharacterAdded:Connect(onCharacter)
	player.CharacterRemoving:Connect(disconnectAll)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end
end

return MovementController
