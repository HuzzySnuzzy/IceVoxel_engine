--!strict
--[[
	Breaking, using and placing blocks, as in Minecraft.

	  Mouse    left (hold) = break; right click = open a chest / place the held block (held down it
	           repeats in first person and with shift lock; with a free mouse, right dragging turns
	           the camera, so only a short click counts); middle click = pick block;
	           Q = drop one of the held item, Ctrl+Q the whole stack
	  Gamepad  R2 = break, L2 = use / place (aiming at the screen centre, shown by a crosshair),
	           DPad down = drop one
	  Touch    (Bedrock's scheme) tap = use / place, hold still = break, aiming under the finger
	           (not in the movement thumbstick's corner)

	  Survival  mining takes time: Shared/Mining's progress is added at a fixed 20 ticks per second
	            (slower in the air and with the eyes under water) and the block breaks at 1, then a
	            Mining.DELAY_TICKS pause comes before the next one. The server is told when mining
	            starts and stops (ClientMessage.Mine) and checks the time before it accepts the
	            break. CrackOverlay shows the progress. Placing uses up the held block:
	            ClientInventory.place predicts it and numbers it, and the Edit carries the number.
	  Creative  breaking is instant and repeats every Config.Interaction.BreakInterval while held;
	            any block item places without being used up.

	Right clicking a container block (a chest) asks the server to open it (ClientMessage.Use), unless
	the player sneaks with something in hand (Minecraft's secondary use). Holding the use button
	repeats every Config.Interaction.RepeatInterval. A block is never placed where it would overlap
	a player's standing hull (the server checks the same and would undo it).

	Targeting is a voxel raycast on the client's block data, so it is exact and independent of the
	parts. Edits are predicted locally and confirmed / corrected by the server. Nothing happens
	while an inventory screen is open (Ui/Screens). Broken blocks throw a few debris particles in
	their colour; hitting, placing, using and dropping swing the held item (Player/HeldItems).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Blocks = require(Shared.Blocks)
local Items = require(Shared.Items)
local Mining = require(Shared.Mining)
local Protocol = require(Shared.Net.Protocol)
local VoxelRaycast = require(Shared.World.VoxelRaycast)
local Hull = require(Shared.Movement.Hull)
local PlayerPhysics = require(Shared.Movement.PlayerPhysics)
local Rig = require(Shared.Movement.Rig)

local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local Screens = require(script.Parent.Parent.Ui.Screens)
local MovementController = require(script.Parent.Parent.Player.MovementController)
local HeldItems = require(script.Parent.Parent.Player.HeldItems)
local CrackOverlay = require(script.Parent.CrackOverlay)

local BLOCK = Config.BlockSize
local REACH = Config.Interaction.Reach
-- Mining runs at Minecraft's tick rate; a long frame runs at most this many ticks.
local TICK = 1 / Mining.TICK_RATE
local MAX_TICKS_PER_FRAME = 5
-- A right click shorter than this (seconds) that moved the mouse less than CLICK_MOVE pixels is a
-- click; anything else turned the camera.
local CLICK_TIME = 0.3
local CLICK_MOVE = 8
-- Touch: held this long (seconds) without moving more than TOUCH_MOVE pixels starts breaking;
-- released sooner it is a tap.
local TOUCH_HOLD = 0.3
local TOUCH_MOVE = 14
-- Debris of a broken block.
local PARTICLES_PER_BREAK = 8
local MAX_PARTICLES = 40
local PARTICLE_GRAVITY = 45 -- studs / s^2
-- The arm swing restarts once it is half done (LivingEntity.swing; a swing lasts 6 ticks).
local SWING_RESTART = 0.15

local BlockInteraction = {}

type Hit = VoxelRaycast.Hit

-- A block being mined (survival).
type MinedBlock = { x: number, y: number, z: number, block: number, progress: number }

type Particle = {
	part: Part,
	velocity: Vector3,
	spin: CFrame,
	age: number,
	life: number,
	size: number,
	transparency: number,
}

type Touch = {
	input: InputObject,
	origin: Vector2,
	position: Vector2,
	startedAt: number,
	-- Dragged before the hold time (a camera turn: no tap, no hold).
	moved: boolean,
	holding: boolean,
}

local function material(name: string): Enum.Material
	local ok, value = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	return if ok and value then value else Enum.Material.SmoothPlastic
end

function BlockInteraction.start(world: ClientWorld.ClientWorld)
	local player = Players.LocalPlayer

	local highlight = Instance.new("Part")
	highlight.Name = "IceVoxelSelection"
	highlight.Anchored = true
	highlight.CanCollide = false
	highlight.CanQuery = false
	highlight.CanTouch = false
	highlight.Transparency = 1
	highlight.Size = Vector3.one * (BLOCK + 0.05)
	local selection = Instance.new("SelectionBox")
	selection.Adornee = highlight
	selection.LineThickness = 0.04
	selection.Color3 = Color3.new(0.1, 0.1, 0.1)
	selection.SurfaceTransparency = 1
	selection.Parent = highlight
	highlight.Parent = workspace.CurrentCamera

	local cracks = CrackOverlay.new()

	local crosshairGui = Instance.new("ScreenGui")
	crosshairGui.Name = "IceVoxelCrosshair"
	crosshairGui.IgnoreGuiInset = true
	crosshairGui.ResetOnSpawn = false
	local crosshair = Instance.new("Frame")
	crosshair.AnchorPoint = Vector2.new(0.5, 0.5)
	crosshair.Position = UDim2.fromScale(0.5, 0.5)
	crosshair.Size = UDim2.fromOffset(6, 6)
	crosshair.BackgroundColor3 = Color3.new(1, 1, 1)
	crosshair.Visible = false
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = crosshair
	local outline = Instance.new("UIStroke")
	outline.Parent = crosshair
	crosshair.Parent = crosshairGui
	crosshairGui.Parent = player:WaitForChild("PlayerGui")

	local function getBlock(x: number, y: number, z: number): number?
		return world:getBlock(x, y, z)
	end

	local function rootPart(): BasePart?
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			return root
		end
		return nil
	end

	-- Block under a viewport position (or a GUI position when `gui` is set), within reach.
	local function targetAt(point: Vector2, gui: boolean?): Hit?
		local root = rootPart()
		if root == nil then
			return nil
		end
		local camera = workspace.CurrentCamera
		local ray = if gui
			then camera:ScreenPointToRay(point.X, point.Y)
			else camera:ViewportPointToRay(point.X, point.Y)
		local origin = ray.Origin / BLOCK
		local maxDistance = (ray.Origin - root.Position).Magnitude / BLOCK + REACH
		local hit = VoxelRaycast.cast(
			origin.X,
			origin.Y,
			origin.Z,
			ray.Direction.X,
			ray.Direction.Y,
			ray.Direction.Z,
			maxDistance,
			getBlock,
			Blocks.isTargetable
		)
		if hit then
			local center = Vector3.new(hit.x + 0.5, hit.y + 0.5, hit.z + 0.5) * BLOCK
			if (center - root.Position).Magnitude > REACH * BLOCK then
				return nil
			end
		end
		return hit
	end

	-- Where the player aims, in viewport coordinates: the mouse while it is the active input and
	-- free, otherwise the screen centre. (A PC with a controller still has a mouse, so
	-- MouseEnabled alone would aim at wherever the hidden cursor was left.)
	local function pointer(): Vector2
		local preferred = UserInputService.PreferredInput
		crosshair.Visible = preferred == Enum.PreferredInput.Gamepad or preferred == Enum.PreferredInput.MicroGamepad
		if
			preferred == Enum.PreferredInput.KeyboardAndMouse
			and UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter
		then
			-- GetMouseLocation ignores the GUI inset, i.e. it is in viewport coordinates.
			return UserInputService:GetMouseLocation()
		end
		local size = workspace.CurrentCamera.ViewportSize
		return Vector2.new(size.X / 2, size.Y / 2)
	end

	--[[ Placement checks ]]

	local function overlaps(min: Vector3, max: Vector3, x: number, y: number, z: number): boolean
		return max.X > x and min.X < x + 1 and max.Y > y and min.Y < y + 1 and max.Z > z and min.Z < z + 1
	end

	--[[
		Would a solid block at (x, y, z) overlap a player? The local player is checked with the
		standing hull (as the server does, whatever the pose) at the hull's position and where the
		character is drawn (what the server sees); other players at their characters.
	]]
	local function blocksCharacter(x: number, y: number, z: number): boolean
		local view = MovementController.current
		if view then
			local standing = PlayerPhysics.STANDING
			local state = view.state
			local box = Hull.box(state.x, state.y, state.z, standing.width, standing.height)
			if
				overlaps(Vector3.new(box.minX, box.minY, box.minZ), Vector3.new(box.maxX, box.maxY, box.maxZ), x, y, z)
			then
				return true
			end
			local half = Vector3.new(standing.width / 2, 0, standing.width / 2)
			local top = Vector3.new(standing.width / 2, standing.height, standing.width / 2)
			if overlaps(view.feet - half, view.feet + top, x, y, z) then
				return true
			end
		end
		for _, other in Players:GetPlayers() do
			local character = other.Character
			if other ~= player and character then
				local min, max = Rig.hull(character)
				if min and max and overlaps(min, max, x, y, z) then
					return true
				end
			end
		end
		return false
	end

	--[[ Debris particles ]]

	local particleFolder = Instance.new("Folder")
	particleFolder.Name = "IceVoxelParticles"
	particleFolder.Parent = workspace.CurrentCamera
	local particles: { Particle } = {}
	local spare: { Part } = {}

	local function spawnDebris(x: number, y: number, z: number, block: number)
		local def = Blocks.get(block)
		local colour = Color3.fromRGB(def.color[1], def.color[2], def.color[3])
		local look = material(def.material)
		if particleFolder.Parent ~= workspace.CurrentCamera then
			particleFolder.Parent = workspace.CurrentCamera
		end
		for _ = 1, PARTICLES_PER_BREAK do
			local part: Part
			if #particles >= MAX_PARTICLES then
				-- Recycle the oldest.
				local oldest = table.remove(particles, 1) :: Particle
				part = oldest.part
			else
				part = table.remove(spare) or Instance.new("Part")
			end
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
			part.TopSurface = Enum.SurfaceType.Smooth
			part.BottomSurface = Enum.SurfaceType.Smooth
			part.Material = look
			local shade = 0.85 + math.random() * 0.3
			part.Color =
				Color3.new(math.min(colour.R * shade, 1), math.min(colour.G * shade, 1), math.min(colour.B * shade, 1))
			part.Transparency = def.transparency
			local size = BLOCK * (0.09 + math.random() * 0.07)
			part.Size = Vector3.one * size
			-- From a random point in the block, outwards from its centre and up.
			local offset = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5)
			local position = (Vector3.new(x + 0.5, y + 0.5, z + 0.5) + offset * 0.8) * BLOCK
			part.CFrame = CFrame.new(position)
				* CFrame.Angles(math.random() * math.pi, math.random() * math.pi, math.random() * math.pi)
			part.Parent = particleFolder
			local velocity = (offset * 2.2 + Vector3.new(0, 0.8 + math.random() * 0.6, 0)) * BLOCK * 2
			table.insert(particles, {
				part = part,
				velocity = velocity,
				spin = CFrame.Angles(math.random() * 6 - 3, math.random() * 6 - 3, math.random() * 6 - 3),
				age = 0,
				life = 0.4 + math.random() * 0.25,
				size = size,
				transparency = def.transparency,
			})
		end
	end

	local function updateDebris(dt: number)
		for i = #particles, 1, -1 do
			local p = particles[i]
			p.age += dt
			if p.age >= p.life then
				table.remove(particles, i)
				p.part.Parent = nil
				table.insert(spare, p.part)
			else
				p.velocity -= Vector3.new(0, PARTICLE_GRAVITY * dt, 0)
				local spin = CFrame.identity:Lerp(p.spin, dt)
				p.part.CFrame = (p.part.CFrame + p.velocity * dt) * spin
				-- Fade and shrink over the second half of the life.
				local fade = math.clamp((p.age / p.life - 0.5) * 2, 0, 1)
				p.part.Transparency = p.transparency + (1 - p.transparency) * fade
				p.part.Size = Vector3.one * p.size * (1 - 0.5 * fade)
			end
		end
	end

	-- Swings the held item (HeldItems), restarting a swing only once it is half done.
	local lastSwing = -math.huge
	local function swing()
		local now = os.clock()
		if now - lastSwing >= SWING_RESTART then
			lastSwing = now
			HeldItems.swing()
		end
	end

	--[[ Breaking ]]

	local function breakBlock(hit: Hit)
		world:breakBlock(hit.x, hit.y, hit.z)
		spawnDebris(hit.x, hit.y, hit.z, hit.block)
	end

	-- Sources holding the break / use buttons down ("mouse", "gamepad", "touch").
	local attackHeld: { [string]: boolean } = {}
	local useHeld: { [string]: boolean } = {}
	local function anyHeld(held: { [string]: boolean }): boolean
		return next(held) ~= nil
	end

	local target: Hit? = nil
	local mining: MinedBlock? = nil
	-- Ticks left before mining can start again after a break.
	local destroyDelay = 0
	local tickClock = 0
	local lastCreativeBreak = -math.huge

	local function stopMining()
		local current = mining
		if current then
			mining = nil
			ClientNet.send(Protocol.ClientMessage.Mine, Protocol.encodeMine(false, current.x, current.y, current.z))
		end
		cracks:hide()
	end

	-- One survival mining tick (Minecraft's MultiPlayerGameMode.continueDestroyBlock).
	local function miningTick()
		local hit = target
		if not anyHeld(attackHeld) or hit == nil or ClientInventory.isCreative() or Screens.isOpen() then
			stopMining()
			return
		end
		local current = mining
		if
			current and (current.x ~= hit.x or current.y ~= hit.y or current.z ~= hit.z or current.block ~= hit.block)
		then
			-- Another block now: the old one's progress is lost.
			stopMining()
			current = nil
		end
		-- Hitting a block swings the arm every tick, also while waiting or getting nowhere.
		swing()
		if destroyDelay > 0 then
			destroyDelay -= 1
			return
		end
		local view = MovementController.current
		local onGround = if view then view.state.onGround else true
		local underWater = if view then view.state.eyeInWater else false
		local perTick = Mining.progressPerTick(hit.block, onGround, underWater)
		if perTick <= 0 then
			-- Unbreakable.
			return
		end
		if current == nil then
			current = { x = hit.x, y = hit.y, z = hit.z, block = hit.block, progress = 0 }
			mining = current
			ClientNet.send(Protocol.ClientMessage.Mine, Protocol.encodeMine(true, hit.x, hit.y, hit.z))
		end
		assert(current, "mining state")
		current.progress += perTick
		if current.progress >= 1 then
			-- (No "stopped" message: the break itself ends it.)
			mining = nil
			cracks:hide()
			destroyDelay = Mining.DELAY_TICKS
			breakBlock(hit)
		else
			-- Minecraft's destroy stage: nothing below 10%, then stages 0..9.
			local stage = math.floor(current.progress * 10) - 1
			if stage >= 0 then
				cracks:show(hit.x, hit.y, hit.z, stage)
			else
				cracks:hide()
			end
		end
	end

	-- Creative: instant breaking, again every BreakInterval while held.
	local function creativeBreak(now: number)
		local hit = target
		if hit == nil then
			return
		end
		swing()
		if now - lastCreativeBreak >= Config.Interaction.BreakInterval and Blocks.get(hit.block).breakable then
			lastCreativeBreak = now
			breakBlock(hit)
		end
	end

	--[[ Using and placing ]]

	-- After opening a container, the held use button does nothing more until released.
	local useSpent = false
	local lastUse = -math.huge

	local function useAt(hit: Hit?)
		if hit == nil or useSpent or Screens.isOpen() then
			return
		end
		local view = MovementController.current
		local stack = ClientInventory.selectedStack()
		-- Containers open, unless sneaking with something in hand (Minecraft's secondary use).
		local sneaking = view ~= nil and view.state.sneaking
		if Blocks.get(hit.block).container > 0 and not (sneaking and stack ~= nil) then
			useSpent = true
			ClientNet.send(Protocol.ClientMessage.Use, Protocol.encodeUse(hit.x, hit.y, hit.z))
			swing()
			return
		end
		if stack == nil then
			return
		end
		local def = Items.get(stack.item)
		local block = def and def.block
		if block == nil then
			return
		end
		-- Into the clicked block if it can be replaced, else against the clicked face.
		local x, y, z = hit.x, hit.y, hit.z
		if not Blocks.isReplaceable(hit.block) then
			x, y, z = x + hit.nx, y + hit.ny, z + hit.nz
		end
		local current = world:getBlock(x, y, z)
		if current == nil or not Blocks.isReplaceable(current) then
			return
		end
		if Blocks.isSolid(block) and blocksCharacter(x, y, z) then
			return
		end
		-- Survival uses one up (predicted); creative only numbers the action.
		local seq = ClientInventory.place(stack.item)
		world:placeBlock(x, y, z, block, seq)
		swing()
	end

	-- A single click / tap (not a held button).
	local function useOnce(hit: Hit?)
		if not anyHeld(useHeld) then
			useAt(hit)
			useSpent = false
		end
	end

	-- Throws the held item (Q): one, or the whole stack.
	local function drop(all: boolean)
		if ClientInventory.selectedStack() ~= nil then
			ClientInventory.dropSelected(all)
			swing()
		end
	end

	local function pickAt(hit: Hit?)
		if hit and Items.ofBlock(hit.block) ~= nil then
			ClientInventory.pickBlock(hit.block)
		end
	end

	--[[ Buttons ]]

	local function beginAttack(source: string)
		if Screens.isOpen() then
			return
		end
		local first = not anyHeld(attackHeld)
		attackHeld[source] = true
		if not first then
			return
		end
		if ClientInventory.isCreative() then
			-- A press breaks at once (Minecraft's startDestroyBlock in creative).
			lastCreativeBreak = -math.huge
			creativeBreak(os.clock())
		else
			-- Start on this frame rather than the next tick.
			tickClock = 0
			miningTick()
		end
	end

	local function endAttack(source: string)
		attackHeld[source] = nil
		if not anyHeld(attackHeld) then
			stopMining()
		end
	end

	local function beginUse(source: string, hit: Hit?)
		if Screens.isOpen() then
			return
		end
		local first = not anyHeld(useHeld)
		useHeld[source] = true
		if first then
			lastUse = os.clock()
			useAt(hit)
		end
	end

	local function endUse(source: string)
		useHeld[source] = nil
		if not anyHeld(useHeld) then
			useSpent = false
		end
	end

	-- Touch currently aiming (a hold or a possible tap), and a right click in progress (free
	-- mouse: it may turn into a camera drag).
	local touch: Touch? = nil
	local rightDownAt: number? = nil
	local rightMoved = 0

	local function releaseAll()
		table.clear(attackHeld)
		table.clear(useHeld)
		useSpent = false
		touch = nil
		rightDownAt = nil
		stopMining()
	end

	Screens.changed:Connect(function(open: boolean)
		if open then
			releaseAll()
		end
	end)
	-- Key releases are missed while the window has no focus.
	UserInputService.WindowFocusReleased:Connect(releaseAll)

	-- The movement thumbstick's corner of the screen (DynamicThumbstick: the left 40 %, lower two
	-- thirds in landscape; the lower 40 % in portrait). Touches starting there move the player.
	local function inThumbstickArea(position: Vector2): boolean
		local size = workspace.CurrentCamera.ViewportSize
		if size.X >= size.Y then
			return position.X < size.X * 0.4 and position.Y > size.Y / 3
		end
		return position.Y > size.Y * 0.6
	end

	--[[ Every frame ]]

	RunService.RenderStepped:Connect(function(dt: number)
		local now = os.clock()
		local open = Screens.isOpen()

		-- A touch held still long enough starts breaking.
		local t = touch
		local startHold = false
		if t and not t.moved and not t.holding and now - t.startedAt >= TOUCH_HOLD and not open then
			t.holding = true
			startHold = true
		end

		-- Aim: under a breaking finger, else the mouse / screen centre (with a touch screen only
		-- where a finger is).
		local aim = pointer()
		if t and t.holding then
			target = targetAt(t.position, true)
		elseif UserInputService.PreferredInput == Enum.PreferredInput.Touch then
			target = nil
		else
			target = targetAt(aim)
		end
		if startHold then
			beginAttack("touch")
		end
		local hit = target
		if hit then
			if highlight.Parent ~= workspace.CurrentCamera then
				highlight.Parent = workspace.CurrentCamera
			end
			highlight.CFrame = CFrame.new((hit.x + 0.5) * BLOCK, (hit.y + 0.5) * BLOCK, (hit.z + 0.5) * BLOCK)
			selection.Visible = true
		else
			selection.Visible = false
		end

		if open then
			if anyHeld(attackHeld) or anyHeld(useHeld) or mining then
				releaseAll()
			end
		else
			-- Breaking.
			if ClientInventory.isCreative() then
				if mining then
					stopMining()
				end
				if anyHeld(attackHeld) then
					creativeBreak(now)
				end
			else
				tickClock = math.min(tickClock + dt, TICK * MAX_TICKS_PER_FRAME)
				while tickClock >= TICK do
					tickClock -= TICK
					miningTick()
				end
			end
			-- Using / placing, repeated while held.
			if anyHeld(useHeld) and now - lastUse >= Config.Interaction.RepeatInterval then
				lastUse = now
				useAt(hit)
			end
		end

		updateDebris(dt)
	end)

	--[[ Input ]]

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or Screens.isOpen() then
			return
		end
		local kind, key = input.UserInputType, input.KeyCode
		if kind == Enum.UserInputType.MouseButton1 then
			beginAttack("mouse")
		elseif key == Enum.KeyCode.ButtonR2 then
			beginAttack("gamepad")
		elseif key == Enum.KeyCode.ButtonL2 then
			beginUse("gamepad", target)
		elseif kind == Enum.UserInputType.MouseButton2 then
			if UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
				-- First person / shift lock: right dragging does not turn the camera.
				beginUse("mouse", target)
			else
				rightDownAt = os.clock()
				rightMoved = 0
			end
		elseif kind == Enum.UserInputType.MouseButton3 then
			pickAt(target)
		elseif key == Enum.KeyCode.Q then
			local all = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
				or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
			drop(all)
		elseif key == Enum.KeyCode.DPadDown then
			drop(false)
		elseif kind == Enum.UserInputType.Touch then
			local position = Vector2.new(input.Position.X, input.Position.Y)
			if touch == nil and not inThumbstickArea(position) then
				touch = {
					input = input,
					origin = position,
					position = position,
					startedAt = os.clock(),
					moved = false,
					holding = false,
				}
			end
		end
	end)

	UserInputService.InputChanged:Connect(function(input: InputObject)
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseMovement then
			if rightDownAt then
				rightMoved += input.Delta.Magnitude
			end
		elseif kind == Enum.UserInputType.Touch then
			local t = touch
			if t and t.input == input then
				t.position = Vector2.new(input.Position.X, input.Position.Y)
				if not t.holding and (t.position - t.origin).Magnitude > TOUCH_MOVE then
					t.moved = true
				end
			end
		end
	end)

	-- (Releases count even over GUI, so nothing stays held.)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		local kind, key = input.UserInputType, input.KeyCode
		if kind == Enum.UserInputType.MouseButton1 then
			endAttack("mouse")
		elseif key == Enum.KeyCode.ButtonR2 then
			endAttack("gamepad")
		elseif key == Enum.KeyCode.ButtonL2 then
			endUse("gamepad")
		elseif kind == Enum.UserInputType.MouseButton2 then
			if useHeld.mouse then
				endUse("mouse")
			elseif rightDownAt then
				-- Right drag turns the camera (the mouse stays put meanwhile, so count its
				-- movement); only a short click uses / places.
				local click = os.clock() - rightDownAt < CLICK_TIME and rightMoved < CLICK_MOVE
				rightDownAt = nil
				if click and not Screens.isOpen() then
					useOnce(target)
				end
			end
		elseif kind == Enum.UserInputType.Touch then
			local t = touch
			if t and t.input == input then
				touch = nil
				if t.holding then
					endAttack("touch")
				elseif not t.moved and os.clock() - t.startedAt < TOUCH_HOLD and not Screens.isOpen() then
					useOnce(targetAt(t.position, true))
				end
			end
		end
	end)
end

return BlockInteraction
