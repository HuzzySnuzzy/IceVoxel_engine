--!strict
--[[
	Breaking, using and placing blocks, as in Minecraft.

	  Mouse    left (hold) = break; right click = open a chest, crafting table or furnace / place
	           the held block (held down it repeats in first person and with shift lock; with a
	           free mouse, right dragging turns the camera, so only a short click counts); middle
	           click = pick block; Q = drop one of the held item, Ctrl+Q the whole stack. These
	           are the key bindings Attack/Destroy, Use Item/Place Block, Pick Block and Drop
	           Selected Item (Settings/Keybinds; any key or mouse button: a use bound to a key
	           repeats while held, only the right button drags the camera)
	  Gamepad  R2 = break, L2 = use / place (aiming at the screen centre, shown by a crosshair),
	           DPad down = drop one
	  Touch    (Bedrock's scheme) tap = use / place, hold still = break, aiming under the finger
	           (not in the movement thumbstick's corner)

	  Survival  mining takes time: Shared/Mining's progress for the held tool (its speed on the
	            block's kind, and whether it can harvest it, times the player's own speed: the
	            status effects' Haste and Mining Fatigue, Player/EffectState, and Progression's
	            mining perks, Player/ProgressionState, joined by Mining.playerFactor as the
	            server's check) is added at a fixed 20 ticks per second (slower in the air and with
	            the eyes under water) and the block breaks at 1, then a
	            Mining.DELAY_TICKS pause comes before the next one. Switching to another item starts
	            the block over (Minecraft's sameDestroyTarget). The server is told when mining
	            starts and stops (ClientMessage.Mine) and checks the time, with the tool in hand,
	            before it accepts the break; it also wears the tool. CrackOverlay shows the
	            progress. Placing uses up the held block: ClientInventory.place predicts it and
	            numbers it, and the Edit carries the number.
	  Creative  breaking is instant and repeats every Config.Interaction.BreakInterval while held;
	            any block item places without being used up.
	  Adventure (no mayBuild) nothing is broken, placed or used on blocks (no buckets, no
	            Configurator, no shears): a click only swings the arm. Blocks with a menu still
	            open. No block is outlined (Minecraft outlines blocks in adventure only for items
	            with CanDestroy / CanPlaceOn tags, which the game has none of); WAILA still names
	            them.
	  Spectator only blocks with a menu are aimed at and outlined, and a right click opens them
	            (read only: Inventory/ClientInventory refuses the clicks), without a swing. A left
	            click on a player spectates them (Player/MovementController; sneak leaves), the
	            middle click is the spectator menu's (Ui/SpectatorGui), and nothing is thrown.
	            Game modes come from Shared/GameMode's abilities (mayBuild, instabuild...), never
	            from comparing modes.

	Right clicking a block with a menu (BlockList `menu`: a chest, crafting table or furnace) asks the
	server to open it (ClientMessage.Use), unless the player sneaks with something in hand
	(Minecraft's secondary use). Holding the use button repeats every
	Config.Interaction.RepeatInterval. A block is never placed where it would overlap a player's
	standing hull (the server checks the same and would undo it).

	Creative only blocks (structure blocks, structure voids, jigsaws: BlockList `creativeOnly`) are
	Minecraft's operator blocks: only creative players open their screens (the server answers the
	Use with the screen, or says they may not: Structures/Permission) and place them; for survival
	players a structure block is an ordinary block to build against. Jigsaws face the way
	Minecraft's placement gives them (Blocks.placementFor: the clicked face, then the look).

	Items that are no block act on what they point at (ClientMessage.UseItem, never predicted: the
	server answers with world edits, records and the inventory snapshot), one use per press, and
	only where the server would do something (Transmitters/UseRules):
	  Configurator  on a Mekanism transmitter: the side it points at (TransmitterModel.pickSide,
	                as Mekanism's: the arm hit, else the face of the core hit, else the cell's face
	                the ray hit) and whether the player sneaks (sneaking: a transporter's colour;
	                pipes have none).
	  Bucket        Minecraft's BucketItem: its own ray, which also stops at the sources of every
	                fluid a bucket carries (water, lava, oil, fuel and the cave twins: Fluids
	                .isSource, ClipContext.Fluid.SOURCE_ONLY), picks up a source or takes from a
	                Fluid Tank or a machine's fluid tanks.
	  Full buckets  (Water, Lava, Oil, Fuel Bucket: Fluids.ofBucket) the ordinary aim (through
	                fluids): into a Fluid Tank or a machine's fluid tanks, else the fluid is poured
	                into the clicked block if it can be replaced, else in front of the clicked face.
	  Flint and     Minecraft's FlintAndSteelItem: fire in front of the clicked face, where fire
	  Steel         may burn (Fire.canPlaceAt: an empty cell on a sturdy block or next to a
	                flammable one). Breaking a fire puts it out (it breaks at once). On TNT or a
	                Nuke, any face: the server lights it (TntBlock.use).
	Tough As Nails' campfire, after a block's menu: dirty water (a bottle, a canteen) clicked on a
	Campfire boils clean, one a click and at most one every Boiling.INTERVAL ticks (half that with
	Progression's Firekeeper: ProgressionState.boilSpeed, as the server's check) (a click too
	soon sends nothing; held, it boils when the water is ready) (Shared/ToughAsNails/Boiling, the
	campfire's own use: in adventure too, not sneaking; sent as a UseItem, not predicted).
	Tough As Nails' water (Interaction/Drinking), after a block's menu and before anything else, in
	adventure too: a Glass Bottle or a canteen fills at the water source its own ray (stopping at
	water sources, as a bucket's) finds, an empty hand sips from it, and a filled bottle or canteen
	is drunk by holding the use button 32 ticks (letting go cancels; a tap or a free mouse's short
	click, which has no hold, drinks it all).
	Food (Interaction/Eating: the meat mobs drop, rotten flesh) is eaten the same way, holding the
	use button 32 ticks, after a block's menu, in adventure too, while the player may eat
	(Shared/Items/Foods.canEat: hurt, or in creative).
	Magic (Interaction/Casting: Terraria's magic weapons and Mana Crystals), after a block's menu
	and food, in adventure and creative too: a magic weapon casts along the aim (towards what the
	camera's ray hits) every use time of the weapon while the use button is held (checked every
	frame, not at the repeat interval; a touch held on a weapon casts at the finger instead of
	breaking), predicted (the projectile, the sound, the mana); a Mana Crystal is used once a
	press.
	Rope (Shared/Rope, Supplementaries'), before anything is placed, in survival and creative, not
	sneaking: Rope clicked on a rope lets one more down under the bottom of its column, an empty
	hand pulls the bottom one up (Rope.wantsUse); sent as a UseItem, not predicted (the world's
	edit and the inventory snapshot bring it), repeated while the button is held as placing is.
	Sneaking with Rope places it against the clicked face like any block.
	Mobs (Entities/MobRenderer) are aimed at before blocks: the nearest mob box on the aim, within
	Minecraft's entity reach of the eyes (Shared/Entities/Combat: 3 blocks, 6 in creative; none
	for spectators), hides the block behind it (no outline, no mining), and a press of the break
	button (a tap on touch screens, or a hold's start) hits it instead: an Attack message with its
	id and a swing, in survival, creative and adventure alike; the server checks it and answers
	with the hurt (server Mobs/Mobs). One hit a press, as Minecraft.
	A block with a menu still opens first, unless the player sneaks, except a machine with fluid
	tanks clicked with a bucket that fills or empties one of them as far as its Machines record
	shows (TankUse): the bucket goes to its tanks, else the screen opens (Mekanism's BlockFluidTank:
	handleTankInteraction first, the GUI when it moves nothing). A sneaking player's bucket skips
	tanks and machines (it acts on the world, as Minecraft skips a block's use).

	Torches and lanterns go where something holds them (Blocks.placementFor, Minecraft's rules): a
	torch on top of a block stands, on a side it is a wall torch facing away from it, under a
	ceiling it goes on a wall or the floor next to the spot (by where the player looks) or nowhere;
	a lantern clicked under a block hangs from it. The variant's block id is what is sent; the
	server checks the support again. Ladders go on the clicked wall, else the first wall in the
	look order; a ladder clicked on the front of a ladder goes nowhere (LadderBlock.
	getStateForPlacement), rails lie along the way the player faces.

	A block goes into the clicked block when that can be replaced, else against the clicked face;
	a replaceable block is not replaced by its own item (Items.isReplacedBy: Short Grass clicked on
	short grass goes beside it, as in Minecraft).

	Plants go the same way: only on their soil, and a tall plant's lower half only with room for
	its top (a replaceable cell inside the world; Blocks.canPlace). Placing or breaking one half of
	a tall plant predicts that half alone: the server places or removes the other and replicates it
	as an ordinary edit, which ClientWorld applies like any other (block edits carry no action
	number; an inventory snapshot settles the item). Until it arrives the other half stands alone;
	breaking it meanwhile is answered with air, like any break of a block that is already gone.

	Targeting is a voxel raycast on the client's block data, so it is exact and independent of the
	parts; blocks smaller than their cell (torches, lanterns) are aimed at and outlined by their own
	box (Blocks.outline), so the ray passes beside a torch to the wall behind it. Edits are
	predicted locally and confirmed / corrected by the server. Nothing happens while an inventory
	screen is open (Ui/Screens). Broken blocks throw a few debris particles in their colour;
	hitting, placing, using and dropping swing the held item (Player/HeldItems).

	Frames (Shared/World/Origin): the camera's ray starts in render studs and is cast from world
	blocks as doubles (`Origin.renderToBlocks`), exact however far out; reach compares render
	positions with render positions (the block's centre and the root part). The outline and the
	debris are placed at `Origin.blocksToRender`; live debris moves with the render origin
	(a Rendering/Rebase mover). Other players (placement obstruction, the spectator's pick) are
	Player/RemotePlayers' (their characters, or the server's relay by interest).

	`target()`, `targetSide()` (the transmitter side the Configurator would act on) and
	`miningProgress()` let other modules (Ui/Waila) read what is aimed at and how far mining has
	got, without changing anything.

	Sounds (Audio/SoundPlayer), played here at once as Minecraft's client does (the server sends
	them to everyone else): a block's break sound when it breaks, its place sound when placed (the
	variant placed), and while mining in survival its hit sound every 4 ticks on one block
	(SoundRules.hitTick), unbreakable ones too.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Blocks = require(Shared.Blocks)
local Doors = require(Shared.Blocks.Doors)
local Fire = require(Shared.Fire)
local Fluids = require(Shared.Fluids)
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Machines = require(Shared.Machines)
local Mining = require(Shared.Mining)
local Protocol = require(Shared.Net.Protocol)
local Origin = require(Shared.World.Origin)
local VoxelRaycast = require(Shared.World.VoxelRaycast)
local Hull = require(Shared.Movement.Hull)
local PlayerPhysics = require(Shared.Movement.PlayerPhysics)
local Transmitters = require(Shared.Transmitters)
local Drinks = require(Shared.ToughAsNails.Drinks)
local Boiling = require(Shared.ToughAsNails.Boiling)
local Combat = require(Shared.Entities.Combat)
local Rope = require(Shared.Rope)

local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local Screens = require(script.Parent.Parent.Ui.Screens)
local GameModeSwitcher = require(script.Parent.Parent.Ui.GameModeSwitcher)
local SpectatorGui = require(script.Parent.Parent.Ui.SpectatorGui)
local WailaInfo = require(script.Parent.Parent.Ui.WailaInfo)
local UiScale = require(script.Parent.Parent.Ui.UiScale)
local MovementController = require(script.Parent.Parent.Player.MovementController)
local HeldItems = require(script.Parent.Parent.Player.HeldItems)
local RemotePlayers = require(script.Parent.Parent.Player.RemotePlayers)
local SpectatorRules = require(script.Parent.Parent.Player.SpectatorRules)
local Rebase = require(script.Parent.Parent.Rendering.Rebase)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
local SoundRules = require(script.Parent.Parent.Audio.SoundRules)
local TransmitterModel = require(script.Parent.Parent.Rendering.TransmitterModel)
local TransmitterRenderer = require(script.Parent.Parent.Rendering.TransmitterRenderer)
local ProgressionState = require(script.Parent.Parent.Player.ProgressionState)
local CrackOverlay = require(script.Parent.CrackOverlay)
local TankUse = require(script.Parent.TankUse)
local Drinking = require(script.Parent.Drinking)
local Eating = require(script.Parent.Eating)
local Casting = require(script.Parent.Casting)
local MobRenderer = require(script.Parent.Parent.Entities.MobRenderer)
local EffectState = require(script.Parent.Parent.Player.EffectState)
local Keybinds = require(script.Parent.Parent.Settings.Keybinds)
local AttackIndicator = require(script.Parent.Parent.Ui.AttackIndicator)

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
-- A whole cell, as Blocks.outline gives boxes.
local FULL_OUTLINE = { 0, 0, 0, 1, 1, 1 }
-- Mobs whose feet are this close to a cell may reach into it (the biggest box: 1.4 wide, 2 tall).
local MOB_NEAR = 3
-- Items used on blocks (UseItem): the Configurator and the empty Bucket (full buckets: Fluids).
local CONFIGURATOR = Items.id.Configurator
local BUCKET = Items.id.Bucket
local FLINT_AND_STEEL = Items.id.FlintAndSteel
local LADDER = Blocks.id.Ladder

-- The fluid a full bucket pours (a carriable fluid's: Fluids.ofBucket), 0 for any other item.
local function bucketFluid(item: number): number
	local fluid = Fluids.ofBucket(item)
	return if Fluids.carriable(fluid) then fluid else 0
end

-- Does an empty bucket take `block` (a carriable fluid's source or cave twin)?
local function bucketTakes(block: number): boolean
	return Fluids.isSource(block) and Fluids.carriable(Fluids.ofBlock(block))
end

-- Does `block` hold fluid a bucket fills from or pours into (a Fluid Tank, a machine with tanks)?
local function holdsFluid(block: number): boolean
	return Transmitters.isTank(block) or Machines.hasTanks(block)
end

local BlockInteraction = {}

type Hit = VoxelRaycast.Hit

-- The ray an aim was cast along: its origin in world blocks (doubles: x, y, z; `origin` is the
-- same as a float32 Vector3, for readers near it), `direction` a unit vector, and how far it went.
type Ray = { x: number, y: number, z: number, origin: Vector3, direction: Vector3, maxDistance: number }

-- A block being mined (survival), and the item in hand when it started (nil: bare hands).
type MinedBlock = { x: number, y: number, z: number, block: number, tool: number?, progress: number }

-- Read-only views of the aim and the mining state, for other modules (set by start).
local readTarget: () -> Hit? = function()
	return nil
end
local readProgress: () -> number? = function()
	return nil
end
local readSide: () -> number? = function()
	return nil
end
local readMob: () -> MobRenderer.MobView? = function()
	return nil
end

-- The mob the player aims at this frame (in reach, before any block), or nil. Read only.
function BlockInteraction.mobTarget(): MobRenderer.MobView?
	return readMob()
end

-- The block the player aims at this frame (the highlighted one, in reach), or nil. Read only.
function BlockInteraction.target(): Hit?
	return readTarget()
end

-- Survival mining progress (0..1) of the aimed-at block while it is being mined, else nil.
function BlockInteraction.miningProgress(): number?
	return readProgress()
end

-- The side of the aimed-at transmitter the Configurator would act on, or nil. Read only.
function BlockInteraction.targetSide(): number?
	return readSide()
end

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

-- Does right clicking `block` open a menu for a player in game `mode`? (Creative only blocks'
-- screens are for creative players; to others they are plain blocks.)
local function opensMenu(block: number, mode: string): boolean
	if Blocks.get(block).menu == nil then
		return false
	elseif Blocks.isDoor(block) then
		-- (Doors open for everyone but spectators: Players/DoorUse.)
		return GameMode.canInteract(mode)
	end
	return not Blocks.isCreativeOnly(block) or GameMode.instabuild(mode)
end

local function material(name: string): Enum.Material
	local ok, value = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	return if ok and value then value else Enum.Material.SmoothPlastic
end

function BlockInteraction.start(world: ClientWorld.ClientWorld)
	local player = Players.LocalPlayer
	Drinking.start()
	Eating.start()

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

	--[[
		Minecraft's crosshair: a plus of 1 GUI pixel lines 9 GUI pixels across, at the GUI scale
		(Ui/UiScale), in the camera's centre (the whole screen, notches included). Minecraft draws
		it inverting what is behind it; Roblox has no such blend, so it is white with a dark outline.
	]]
	local crosshairGui =
		UiScale.screenGui("IceVoxelCrosshair", "Crosshair", { inset = true, full = true, kind = "scaled" })
	local CROSSHAIR, CROSSHAIR_OUTLINE = 9, Color3.fromRGB(24, 24, 24)
	local crosshair = Instance.new("Frame")
	crosshair.Name = "Crosshair"
	crosshair.AnchorPoint = Vector2.new(0.5, 0.5)
	crosshair.Position = UDim2.fromScale(0.5, 0.5)
	crosshair.Size = UDim2.fromOffset(CROSSHAIR, CROSSHAIR)
	crosshair.BackgroundTransparency = 1
	crosshair.Visible = false
	local centre = CROSSHAIR // 2
	local function crosshairLine(x: number, y: number, w: number, h: number, outline: boolean)
		local bar = Instance.new("Frame")
		bar.BorderSizePixel = 0
		bar.Position = UDim2.fromOffset(x, y)
		bar.Size = UDim2.fromOffset(w, h)
		bar.BackgroundColor3 = if outline then CROSSHAIR_OUTLINE else Color3.new(1, 1, 1)
		bar.BackgroundTransparency = if outline then 0.4 else 0
		bar.ZIndex = if outline then 1 else 2
		bar.Parent = crosshair
	end
	-- (The dark outline one pixel around both lines, then the white lines over it.)
	crosshairLine(-1, centre - 1, CROSSHAIR + 2, 3, true)
	crosshairLine(centre - 1, -1, 3, CROSSHAIR + 2, true)
	crosshairLine(0, centre, CROSSHAIR, 1, false)
	crosshairLine(centre, 0, 1, CROSSHAIR, false)
	local crosshairScale = Instance.new("UIScale")
	crosshairScale.Parent = crosshair
	UiScale.follow(function()
		crosshairScale.Scale = UiScale.base()
	end)
	crosshair.Parent = crosshairGui
	crosshairGui.Parent = player:WaitForChild("PlayerGui")

	local function getBlock(x: number, y: number, z: number): number?
		return world:getBlock(x, y, z)
	end
	-- Each block's outline where it is (Blocks.outline; a fire's from the walls it clings to).
	local outlineAt = Fire.outlineAt(getBlock)

	local function rootPart(): BasePart?
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			return root
		end
		return nil
	end

	-- The first block `isTarget` accepts on `ray`, within reach of the character.
	local function cast(ray: Ray, isTarget: (id: number) -> boolean): Hit?
		local root = rootPart()
		if root == nil then
			return nil
		end
		local direction = ray.direction
		local hit = VoxelRaycast.cast(
			ray.x,
			ray.y,
			ray.z,
			direction.X,
			direction.Y,
			direction.Z,
			ray.maxDistance,
			getBlock,
			isTarget,
			outlineAt
		)
		if hit then
			-- (Both in render studs.)
			if (Origin.blockCentreToRender(hit.x, hit.y, hit.z) - root.Position).Magnitude > REACH * BLOCK then
				return nil
			end
		end
		return hit
	end

	--[[
		Block under a viewport position (or a GUI position when `gui` is set), within reach, and the
		ray it was looked for along (nil without a character).
	]]
	local function targetAt(point: Vector2, gui: boolean?): (Hit?, Ray?)
		local root = rootPart()
		if root == nil then
			return nil, nil
		end
		local camera = workspace.CurrentCamera
		local ray = if gui
			then camera:ScreenPointToRay(point.X, point.Y)
			else camera:ViewportPointToRay(point.X, point.Y)
		-- (The camera is in render studs: world blocks from it, as doubles.)
		local x, y, z = Origin.renderToBlocks(ray.Origin)
		local aim: Ray = {
			x = x,
			y = y,
			z = z,
			origin = Vector3.new(x, y, z),
			direction = ray.Direction.Unit,
			maxDistance = (ray.Origin - root.Position).Magnitude / BLOCK + REACH,
		}
		return cast(aim, Blocks.isTargetable), aim
	end

	--[[
		The mob on the aim `ray` (Entities/MobRenderer: the nearest box it enters) whose box is
		within the game mode's entity reach of the eyes (Combat.reach: none for spectators), and how
		far along the ray it is.
	]]
	local function mobOn(ray: Ray): (MobRenderer.MobView?, number)
		local view = MovementController.current
		local reach = Combat.reach(ClientInventory.mode())
		if view == nil or reach <= 0 then
			return nil, 0
		end
		local mob, distance = MobRenderer.pick(ray.origin, ray.direction, ray.maxDistance)
		if mob == nil then
			return nil, 0
		end
		local state = view.state
		local half = mob.kind.width / 2
		local fromEyes = Combat.boxDistance(
			state.x,
			state.y + Combat.EYE,
			state.z,
			mob.x - half,
			mob.y,
			mob.z - half,
			mob.x + half,
			mob.y + mob.kind.height,
			mob.z + half
		)
		if fromEyes > reach then
			return nil, 0
		end
		return mob, distance
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

	-- Does the box min..max overlap `cell` (Blocks.obstruction: block units within the cell) at
	-- (x, y, z)? Boxes that only touch don't.
	local function overlaps(min: Vector3, max: Vector3, x: number, y: number, z: number, cell: { number }): boolean
		return max.X > x + cell[1]
			and min.X < x + cell[4]
			and max.Y > y + cell[2]
			and min.Y < y + cell[5]
			and max.Z > z + cell[3]
			and min.Z < z + cell[6]
	end

	--[[
		Would a block whose obstruction box is `cell` (solid blocks: the whole cell; lanterns: their
		outline) at (x, y, z) overlap a player or a mob? Mirrors the server's EditRules.obstructs
		and Mobs.occupied. The local player is checked with the standing hull (as the server does,
		whatever the pose) at the hull's position and where the character is drawn (what the
		server sees); other players where Player/RemotePlayers has them, mobs where they are drawn.
	]]
	local function blocksCharacter(x: number, y: number, z: number, cell: { number }): boolean
		local view = MovementController.current
		if view then
			local standing = PlayerPhysics.STANDING
			local state = view.state
			local box = Hull.box(state.x, state.y, state.z, standing.width, standing.height)
			if
				overlaps(
					Vector3.new(box.minX, box.minY, box.minZ),
					Vector3.new(box.maxX, box.maxY, box.maxZ),
					x,
					y,
					z,
					cell
				)
			then
				return true
			end
			local half = Vector3.new(standing.width / 2, 0, standing.width / 2)
			local top = Vector3.new(standing.width / 2, standing.height, standing.width / 2)
			if overlaps(view.feet - half, view.feet + top, x, y, z, cell) then
				return true
			end
		end
		-- (Spectators are in nobody's way.)
		for other in RemotePlayers.each() do
			if SpectatorRules.targetable(GameMode.of(other)) then
				local min, max = RemotePlayers.hull(other)
				if min and max and overlaps(min, max, x, y, z, cell) then
					return true
				end
			end
		end
		-- Nor a mob, where they are drawn (the server refuses it too: Mobs.occupied).
		for _, mob in MobRenderer.mobsNear(x + 0.5, y, z + 0.5, MOB_NEAR) do
			local half = mob.kind.width / 2
			local min = Vector3.new(mob.x - half, mob.y, mob.z - half)
			local max = Vector3.new(mob.x + half, mob.y + mob.kind.height, mob.z + half)
			if overlaps(min, max, x, y, z, cell) then
				return true
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
	-- Flying debris moves on from where it is: a move of the render origin carries it along.
	Rebase.register("BlockInteraction debris", function(dx: number, dz: number, parts, cframes)
		local d = Vector3.new(dx, 0, dz)
		for _, p in particles do
			table.insert(parts, p.part)
			table.insert(cframes, p.part.CFrame - d)
		end
	end)

	-- The colour of `block`'s debris at (x, y, z): a tinted plant's (grass, ferns) is tinted by its
	-- soil as the terrain draws it (GreedyMesher, Rendering/ChunkRenderer).
	local function debrisColour(block: number, x: number, y: number, z: number): Color3
		local def = Blocks.get(block)
		local c = def.color
		if def.tinted then
			-- (Below the top of a tall plant is its lower half; the soil is under that.)
			local soil = world:getBlock(x, y - 1, z)
			if soil and Blocks.isValid(soil) and Blocks.get(soil).tinted then
				soil = world:getBlock(x, y - 2, z)
			end
			local tint = if soil and Blocks.isValid(soil) then buffer.readu8(Blocks.tintLut, soil) else 0
			local m = Blocks.FOLIAGE_TINTS[tint]
			if m then
				return Color3.fromRGB(
					math.min(255, c[1] * m[1]),
					math.min(255, c[2] * m[2]),
					math.min(255, c[3] * m[3])
				)
			end
		end
		return Color3.fromRGB(c[1], c[2], c[3])
	end

	local function spawnDebris(x: number, y: number, z: number, block: number)
		local def = Blocks.get(block)
		local colour = debrisColour(block, x, y, z)
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
			-- From a random point in the block, outwards from its centre and up (render studs).
			local offset = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5)
			local position =
				Origin.blocksToRender(x + 0.5 + offset.X * 0.8, y + 0.5 + offset.Y * 0.8, z + 0.5 + offset.Z * 0.8)
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

	-- Swings the held item (HeldItems), restarting a swing only once it is half done. Spectators
	-- have no arm to swing.
	local lastSwing = -math.huge
	local function swing()
		if GameMode.isSpectator(ClientInventory.mode()) then
			return
		end
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
		SoundPlayer.playBlock(hit.block, "break", hit.x, hit.y, hit.z)
	end

	-- Sources holding the break / use buttons down ("mouse", "gamepad", "touch").
	local attackHeld: { [string]: boolean } = {}
	local useHeld: { [string]: boolean } = {}
	local function anyHeld(held: { [string]: boolean }): boolean
		return next(held) ~= nil
	end

	local target: Hit? = nil
	local targetRay: Ray? = nil
	local mining: MinedBlock? = nil
	-- The mob aimed at (before any block), if any.
	local mobTarget: MobRenderer.MobView? = nil
	readTarget = function()
		return target
	end
	readMob = function()
		return mobTarget
	end
	readProgress = function()
		local current, hit = mining, target
		if
			current
			and hit
			and current.x == hit.x
			and current.y == hit.y
			and current.z == hit.z
			and current.block == hit.block
		then
			return current.progress
		end
		return nil
	end
	-- Ticks left before mining can start again after a break.
	local destroyDelay = 0
	local tickClock = 0
	-- When the break button went down (the first frame after it only counts the time since).
	local pressedAt: number? = nil
	local lastCreativeBreak = -math.huge
	-- Ticks spent hitting one block, for its hit sound (Minecraft's destroyTicks).
	local hits = SoundRules.newHitClock()

	-- The item in hand (a tool or anything else; nil: bare hands), for Mining's speeds.
	local function heldItem(): number?
		local stack = ClientInventory.selectedStack()
		return if stack then stack.item else nil
	end

	local function stopMining()
		SoundRules.resetHits(hits)
		local current = mining
		if current then
			mining = nil
			ClientNet.send(Protocol.ClientMessage.Mine, Protocol.encodeMine(false, current.x, current.y, current.z))
		end
		cracks:hide()
	end

	-- Does the player's game mode mine blocks over time (survival: mayBuild without instabuild)?
	local function mines(): boolean
		local mode = ClientInventory.mode()
		return GameMode.mayBuild(mode) and not GameMode.instabuild(mode)
	end

	-- One survival mining tick (Minecraft's MultiPlayerGameMode.continueDestroyBlock).
	local function miningTick()
		local hit = target
		if not anyHeld(attackHeld) or hit == nil or not mines() or Screens.isOpen() then
			stopMining()
			return
		end
		local current = mining
		local tool = heldItem()
		if
			current
			and (
				current.x ~= hit.x
				or current.y ~= hit.y
				or current.z ~= hit.z
				or current.block ~= hit.block
				or current.tool ~= tool
			)
		then
			-- Another block or another item in hand now: the old progress is lost.
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
		-- (Haste, Mining Fatigue and the perks: the server checks with the same factor.)
		local factor = Mining.playerFactor(EffectState.levels(), ProgressionState.perks(), tool)
		local perTick = Mining.progressPerTick(hit.block, onGround, underWater, tool, factor)
		if perTick <= 0 then
			-- Unbreakable: it only sounds hit.
			if SoundRules.hitTick(hits, hit.x, hit.y, hit.z, hit.block) then
				SoundPlayer.playBlock(hit.block, "hit", hit.x, hit.y, hit.z)
			end
			return
		end
		local starting = current == nil
		if current == nil then
			-- Minecraft's startDestroyBlock: the first tick on a block only starts it, unless it
			-- breaks at once.
			current = { x = hit.x, y = hit.y, z = hit.z, block = hit.block, tool = tool, progress = 0 }
			mining = current
			ClientNet.send(Protocol.ClientMessage.Mine, Protocol.encodeMine(true, hit.x, hit.y, hit.z))
			SoundRules.resetHits(hits)
			if perTick < 1 then
				return
			end
		end
		assert(current, "mining state")
		current.progress += perTick
		-- The hit sound, from the tick after the start (continueDestroyBlock).
		if not starting and SoundRules.hitTick(hits, hit.x, hit.y, hit.z, hit.block) then
			SoundPlayer.playBlock(hit.block, "hit", hit.x, hit.y, hit.z)
		end
		if current.progress >= 1 then
			-- (No "stopped" message: the break itself ends it.)
			mining = nil
			cracks:hide()
			destroyDelay = Mining.DELAY_TICKS
			breakBlock(hit)
		else
			-- Minecraft's destroy stage (MultiPlayerGameMode.getDestroyStage): 0..9 once started,
			-- on the block's outline like the highlight (a lantern's box, not its cell).
			cracks:show(
				hit.x,
				hit.y,
				hit.z,
				math.floor(current.progress * 10),
				outlineAt(hit.block, hit.x, hit.y, hit.z)
			)
		end
	end

	-- Creative: instant breaking, again every BreakInterval while held.
	local function creativeBreak(now: number)
		local hit = target
		if hit == nil then
			return
		end
		swing()
		-- Minecraft's SwordItem.canAttackBlock: no breaking with a sword in creative.
		local tool = Items.tool(heldItem())
		if tool and tool.kind == "sword" then
			return
		end
		if now - lastCreativeBreak >= Config.Interaction.BreakInterval and Blocks.get(hit.block).breakable then
			lastCreativeBreak = now
			breakBlock(hit)
		end
	end

	--[[ Using items on blocks (the Configurator, buckets) ]]

	--[[
		The side of the transmitter `hit` the Configurator acts on (TransmitterModel.pickSide): the
		arm the ray hits, else the face of the core it hits, else the face of the cell it hit (the
		axis on which the hit point is furthest from the cell's centre).
	]]
	local function transmitterSide(hit: Hit, ray: Ray): number
		local linked, acceptors = TransmitterRenderer.connections(hit.x, hit.y, hit.z)
		local d = ray.direction
		local side = TransmitterModel.pickSide(
			ray.x,
			ray.y,
			ray.z,
			d.X,
			d.Y,
			d.Z,
			hit.x,
			hit.y,
			hit.z,
			linked,
			acceptors,
			hit.block
		)
		if side == nil then
			local t = hit.distance
			side = TransmitterModel.sideFromPoint(
				ray.x + d.X * t - hit.x - 0.5,
				ray.y + d.Y * t - hit.y - 0.5,
				ray.z + d.Z * t - hit.z - 0.5
			)
		end
		return side or Transmitters.sideOf(hit.nx, hit.ny, hit.nz) or Transmitters.UP
	end

	-- The clicked face of `hit` as a side (a ray starting inside the block: the face towards it).
	local function faceSide(hit: Hit, ray: Ray): number
		local d = ray.direction
		return Transmitters.sideOf(hit.nx, hit.ny, hit.nz)
			or TransmitterModel.sideFromPoint(-d.X, -d.Y, -d.Z)
			or Transmitters.UP
	end

	readSide = function()
		local hit, ray = target, targetRay
		if hit and ray and Transmitters.isTransmitter(hit.block) then
			return transmitterSide(hit, ray)
		end
		return nil
	end

	local function sendUseItem(x: number, y: number, z: number, side: number, sneaking: boolean): boolean
		if
			y < 0
			or y >= Config.WorldHeight
			or math.abs(x) > Protocol.MAX_COORDINATE
			or math.abs(z) > Protocol.MAX_COORDINATE
		then
			return false
		end
		ClientNet.send(Protocol.ClientMessage.UseItem, Protocol.encodeUseItem(x, y, z, side, sneaking))
		return true
	end

	-- Minecraft's empty bucket: its own ray, which stops at fluid sources as well as blocks.
	local function bucketTarget(ray: Ray): Hit?
		return cast(ray, function(id: number): boolean
			return bucketTakes(id) or Blocks.isTargetable(id)
		end)
	end

	--[[
		Uses `item` (no block) on what the player points at: `hit` (the aimed-at block, nil when
		none is in reach) along `ray`. True when something was sent to the server.
	]]
	local function useItem(item: number, hit: Hit?, ray: Ray?, sneaking: boolean): boolean
		if ray == nil then
			return false
		end
		if item == CONFIGURATOR then
			if hit == nil or not Transmitters.isTransmitter(hit.block) then
				return false
			end
			-- (Sneaking colours transporters; Mechanical Pipes have no colour.)
			if sneaking and Transmitters.kindOf(hit.block) ~= "item" then
				return false
			end
			return sendUseItem(hit.x, hit.y, hit.z, transmitterSide(hit, ray), sneaking)
		elseif item == BUCKET then
			local source = bucketTarget(ray)
			if source and (bucketTakes(source.block) or (not sneaking and holdsFluid(source.block))) then
				return sendUseItem(source.x, source.y, source.z, faceSide(source, ray), sneaking)
			end
			return false
		elseif bucketFluid(item) ~= 0 then
			if hit == nil then
				return false
			end
			if sneaking or not holdsFluid(hit.block) then
				-- Only where the server could pour it: the clicked block when it can be replaced,
				-- else the one in front of the clicked face.
				local x, y, z = hit.x, hit.y, hit.z
				if not Blocks.isReplaceable(hit.block) then
					x, y, z = x + hit.nx, y + hit.ny, z + hit.nz
				end
				local current = if y >= 0 and y < Config.WorldHeight then world:getBlock(x, y, z) else nil
				if current == nil or not Blocks.isReplaceable(current) then
					return false
				end
			end
			return sendUseItem(hit.x, hit.y, hit.z, faceSide(hit, ray), sneaking)
		elseif item == FLINT_AND_STEEL then
			if hit == nil then
				return false
			end
			-- Only where the server would light it: TNT and Nukes on any face, else in front of
			-- the clicked face (Fire.canPlaceAt).
			local side = faceSide(hit, ray)
			local dx, dy, dz = Transmitters.offset(side)
			local explosive = hit.block == Blocks.id.Tnt or hit.block == Blocks.id.Nuke
			if not explosive and not Fire.canPlaceAt(getBlock, hit.x + dx, hit.y + dy, hit.z + dz) then
				return false
			end
			return sendUseItem(hit.x, hit.y, hit.z, side, sneaking)
		end
		return false
	end

	--[[ Using and placing ]]

	-- After opening a block's menu or using an item on a block, the held use button does nothing
	-- more until released.
	local useSpent = false
	local lastUse = -math.huge
	-- When (os.clock()) this player last boiled water on a campfire (Boiling.ready).
	local lastBoil: number? = nil

	local function useAt(hit: Hit?, ray: Ray?)
		if useSpent or Screens.isOpen() then
			return
		end
		local mode = ClientInventory.mode()
		local view = MovementController.current
		local stack = ClientInventory.selectedStack()
		-- Blocks with a menu open, unless sneaking with something in hand (Minecraft's secondary use;
		-- spectators hold nothing).
		local sneaking = view ~= nil and view.state.sneaking
		local secondary = sneaking and stack ~= nil and GameMode.canInteract(mode)
		-- (A bucket on a machine with fluid tanks fills or empties them instead of opening it, when
		-- it can: else nothing would happen, and the screen opens.)
		local tankUse = stack ~= nil
			and hit ~= nil
			and Machines.hasTanks(hit.block)
			and GameMode.mayBuild(mode)
			and TankUse.acts(hit.block, stack.item, TransmitterRenderer.machine(hit.x, hit.y, hit.z))
		if hit and opensMenu(hit.block, mode) and not secondary and not tankUse then
			useSpent = true
			-- A door (and its double door partner) opens at once, as the server will open it
			-- (Blocks/Doors, Players/DoorUse), with its sound for this player.
			local changes: { Doors.Change } = {}
			if Blocks.isDoor(hit.block) then
				changes = Doors.use(hit.block, getBlock, hit.x, hit.y, hit.z)
			end
			for _, change in changes do
				world:predict(change.x, change.y, change.z, change.block)
			end
			local first = changes[1]
			if first then
				local sound = if Doors.opens(changes) then "block.wooden_door.open" else "block.wooden_door.close"
				SoundPlayer.play(sound, first.x + 0.5, first.y + 1, first.z + 0.5)
			end
			ClientNet.send(Protocol.ClientMessage.Use, Protocol.encodeUse(hit.x, hit.y, hit.z))
			swing()
			return
		end
		-- Tough As Nails: dirty water on a campfire boils clean (Shared/ToughAsNails/Boiling: the
		-- campfire's own use, so in adventure too, not sneaking), before drinking would take the
		-- click. Not predicted: the inventory snapshot brings the purified water. Too soon after
		-- the last, nothing goes and the use stays unspent, so a held button boils the next one
		-- when the water is ready.
		if hit and ray and Boiling.applies(hit.block, stack, mode, sneaking) then
			local now = os.clock()
			if
				Boiling.ready(if lastBoil then now - lastBoil else nil, nil, ProgressionState.boilSpeed())
				and sendUseItem(hit.x, hit.y, hit.z, faceSide(hit, ray), sneaking)
			then
				lastBoil = now
				useSpent = true
				swing()
			end
			return
		end
		-- Tough As Nails (Interaction/Drinking): drinking a bottle or canteen (held), filling one or
		-- a sip with an empty hand at a water source, along a ray that stops at water sources as a
		-- bucket's does (Minecraft's BottleItem); in adventure too (no mayBuild needed).
		if ray and Drinking.handles(stack) then
			local action = Drinking.use(stack, mode, function(): Drinking.Source?
				local source = cast(ray, function(id: number): boolean
					return Drinks.isWaterSource(id) or Blocks.isTargetable(id)
				end)
				return if source and Drinks.isWaterSource(source.block) then source else nil
			end)
			if action then
				useSpent = true
				if action ~= "drink" then
					swing()
				end
				return
			end
		end
		-- Food (Interaction/Eating): held 32 ticks, wherever the player looks, in adventure too.
		if Eating.handles(stack) then
			if Eating.use(stack, mode) then
				useSpent = true
			end
			return
		end
		-- Magic (Interaction/Casting): a magic weapon casts along the aim at its own pace while
		-- the button is held (the frame's check below), a Mana Crystal is used once a press; in
		-- adventure and creative too, never by spectators.
		if stack and Casting.handles(stack) then
			local used = if ray then Casting.use(stack, mode, ray, if hit then hit.distance else nil) else nil
			if used then
				useSpent = used == "crystal"
				swing()
			end
			return
		end
		-- Rope on a rope lets one more down, an empty hand pulls one up (Shared/Rope; not sneaking,
		-- not in adventure). Not predicted; a held button repeats it.
		if
			hit
			and ray
			and GameMode.mayBuild(mode)
			and Rope.wantsUse(if stack then stack.item else nil, hit.block, sneaking)
		then
			if sendUseItem(hit.x, hit.y, hit.z, faceSide(hit, ray), sneaking) then
				swing()
			end
			return
		end
		-- Adventure and spectator players may not build: nothing is used on blocks or placed
		-- (ItemStack.useOn and BucketItem's mayUseItemAt want mayBuild).
		if stack == nil or not GameMode.mayBuild(mode) then
			return
		end
		local def = Items.get(stack.item)
		if def and def.block == nil then
			-- (Not predicted: the server's edits, records and snapshot bring the result.)
			if useItem(stack.item, hit, ray, sneaking) then
				useSpent = true
				swing()
			end
			return
		end
		local block = def and def.block
		if hit == nil or block == nil then
			return
		end
		-- Creative only blocks are placed in creative only (the server refuses the rest).
		if Blocks.isCreativeOnly(block) and not GameMode.instabuild(mode) then
			return
		end
		-- Into the clicked block if it can be replaced (not by its own item), else against the
		-- clicked face.
		local x, y, z = hit.x, hit.y, hit.z
		if not Items.isReplacedBy(hit.block, stack.item) then
			-- (A ladder on the front of a ladder: nowhere, LadderBlock.getStateForPlacement.)
			if stack.item == LADDER and Items.ofBlock(hit.block) == LADDER then
				local sx, sy, sz = Blocks.supportOffset(hit.block)
				if sx == -hit.nx and sy == -hit.ny and sz == -hit.nz then
					return
				end
			end
			x, y, z = x + hit.nx, y + hit.ny, z + hit.nz
		end
		-- Inside the world's build limits only (the server refuses the rest).
		if
			y < 0
			or y >= Config.WorldHeight
			or math.abs(x) > Protocol.MAX_COORDINATE
			or math.abs(z) > Protocol.MAX_COORDINATE
		then
			return
		end
		local current = world:getBlock(x, y, z)
		if current == nil or not Items.isReplacedBy(current, stack.item) then
			return
		end
		-- Torches and lanterns: the variant that something holds there (the clicked face first,
		-- then the way the player looks), or nothing.
		local look = workspace.CurrentCamera.CFrame.LookVector
		-- (Where in the cell placed into the click landed: a door's hinge goes on that half.)
		local hx, hz = nil, nil
		if ray then
			hx = ray.x + ray.direction.X * hit.distance - x
			hz = ray.z + ray.direction.Z * hit.distance - z
		end
		local variant =
			Blocks.placementFor(block, hit.nx, hit.ny, hit.nz, look.X, look.Y, look.Z, getBlock, x, y, z, hx, hz)
		if variant == nil then
			return
		end
		block = variant
		-- Like the server (EditRules.obstructs): solid blocks and lanterns may not go inside a
		-- player; torches may.
		local obstruction = Blocks.obstruction(block)
		if obstruction and blocksCharacter(x, y, z, obstruction) then
			return
		end
		-- Survival uses one up (predicted); creative only numbers the action.
		local seq = ClientInventory.place(stack.item)
		world:placeBlock(x, y, z, block, seq)
		SoundPlayer.playBlock(block, "place", x, y, z)
		swing()
	end

	-- A single click / tap (not a held button).
	local function useOnce(hit: Hit?, ray: Ray?)
		if not anyHeld(useHeld) then
			useAt(hit, ray)
			useSpent = false
		end
	end

	-- Throws the held item (Q): one, or the whole stack (not spectators: ClientInventory).
	local function drop(all: boolean)
		if ClientInventory.dropSelected(all) then
			swing()
		end
	end

	-- The middle click: pick block, or a spectator's menu (SpectatorGui.onMouseMiddleClick).
	local function pickAt(hit: Hit?)
		if GameMode.isSpectator(ClientInventory.mode()) then
			SpectatorGui.middleClick()
		elseif hit and Items.ofBlock(hit.block) ~= nil then
			ClientInventory.pickBlock(hit.block)
		end
	end

	--[[ Spectating a player (a spectator's left click) ]]

	--[[
		The player on the aim `ray` (another player's standing hull, not a spectator's, nor the one
		spectated, whose eyes the camera is in), in reach and not behind a block: what a spectator's
		left click spectates (also while spectating someone, ServerPlayer.attack's setCamera).
	]]
	local function playerAt(ray: Ray): Player?
		local root = rootPart()
		if root == nil then
			return nil
		end
		local direction, maxDistance = ray.direction, ray.maxDistance
		-- (The root's centre in world blocks, doubles.)
		local bx, by, bz = Origin.renderToBlocks(root.Position)
		local wall = VoxelRaycast.cast(
			ray.x,
			ray.y,
			ray.z,
			direction.X,
			direction.Y,
			direction.Z,
			maxDistance,
			getBlock,
			Blocks.isTargetable,
			outlineAt
		)
		local best: Player? = nil
		local nearest = if wall then wall.distance else maxDistance
		local spectated = MovementController.spectating()
		local half, height = PlayerPhysics.STANDING.width / 2, PlayerPhysics.STANDING.height
		-- (Other players this client knows of: their characters, or the server's relay.)
		for other, remote in RemotePlayers.each() do
			local character = other.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if
				humanoid
				and humanoid.Health > 0
				and remote.alive
				and SpectatorRules.aimable(GameMode.of(other), other == spectated)
			then
				-- Their standing hull's centre within reach of the body.
				local dx, dy, dz = remote.x - bx, remote.y + height / 2 - by, remote.z - bz
				if dx * dx + dy * dy + dz * dz <= REACH * REACH then
					local t = WailaInfo.rayBox(
						ray.x,
						ray.y,
						ray.z,
						direction.X,
						direction.Y,
						direction.Z,
						remote.x - half,
						remote.y,
						remote.z - half,
						remote.x + half,
						remote.y + height,
						remote.z + half
					)
					if t and t < nearest then
						best, nearest = other, t
					end
				end
			end
		end
		return best
	end

	--[[ Hitting mobs ]]

	-- Hits `mob` (the server checks the reach, the sight and the game mode, then hurts it).
	local function attack(mob: MobRenderer.MobView)
		ClientNet.send(Protocol.ClientMessage.Attack, Protocol.encodeAttack(mob.id))
		-- (The weapon starts recovering: the attack indicator, Ui/AttackIndicator.)
		AttackIndicator.attacked()
		swing()
	end

	--[[ Buttons ]]

	local function beginAttack(source: string)
		if Screens.isOpen() or GameModeSwitcher.isOpen() then
			return
		end
		local first = not anyHeld(attackHeld)
		attackHeld[source] = true
		if not first then
			return
		end
		local mode = ClientInventory.mode()
		local mob = mobTarget
		if mob and not GameMode.isSpectator(mode) then
			-- A mob in front of the block: hit it (one hit a press), mine nothing.
			stopMining()
			attack(mob)
			return
		end
		if GameMode.isSpectator(mode) then
			-- A spectator's attack spectates the player aimed at (ServerPlayer.attack: setCamera).
			local ray = targetRay
			local other = if ray then playerAt(ray) else nil
			if other then
				MovementController.spectate(other)
			end
			return
		elseif not GameMode.mayBuild(mode) then
			-- Adventure: the arm swings, nothing breaks (blockActionRestricted).
			swing()
			return
		elseif GameMode.instabuild(mode) then
			-- A press breaks at once (Minecraft's startDestroyBlock in creative).
			lastCreativeBreak = -math.huge
			creativeBreak(os.clock())
		else
			-- Start on this frame rather than the next tick.
			tickClock = 0
			pressedAt = os.clock()
			miningTick()
		end
	end

	local function endAttack(source: string)
		attackHeld[source] = nil
		if not anyHeld(attackHeld) then
			stopMining()
		end
	end

	local function beginUse(source: string, hit: Hit?, ray: Ray?)
		if Screens.isOpen() or GameModeSwitcher.isOpen() then
			return
		end
		local first = not anyHeld(useHeld)
		useHeld[source] = true
		if first then
			lastUse = os.clock()
			useAt(hit, ray)
		end
	end

	local function endUse(source: string)
		useHeld[source] = nil
		if not anyHeld(useHeld) then
			useSpent = false
			Drinking.stop()
			Eating.stop()
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
		Drinking.stop()
		Eating.stop()
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

	-- The outline the highlight was last sized for.
	local outlined: { number }? = nil

	RunService.RenderStepped:Connect(function(dt: number)
		local now = os.clock()
		local open = Screens.isOpen() or GameModeSwitcher.isOpen()

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
			target, targetRay = targetAt(t.position, true)
		elseif UserInputService.PreferredInput == Enum.PreferredInput.Touch then
			target, targetRay = nil, nil
		else
			target, targetRay = targetAt(aim)
		end
		-- Spectators aim at blocks with a menu only (they pass through the rest), and only those are
		-- outlined; adventure players outline nothing (GameRenderer.shouldRenderBlockOutline).
		local mode = ClientInventory.mode()
		local aimed = target
		if aimed and GameMode.isSpectator(mode) and not opensMenu(aimed.block, mode) then
			-- (The ray stays: it is what the spectator's click looks for players along.)
			target = nil
		end
		-- A mob in reach in front of the block hides it (Minecraft's entity pick wins).
		mobTarget = nil
		local ray = targetRay
		if ray and not open then
			local mob, distance = mobOn(ray)
			local block = target
			if mob and (block == nil or distance < block.distance) then
				mobTarget = mob
				target = nil
			end
		end
		if startHold then
			-- (With a magic weapon a held finger casts at it instead of breaking: Interaction/Casting.)
			if Casting.handles(ClientInventory.selectedStack()) and not GameMode.isSpectator(mode) then
				beginUse("touch", target, targetRay)
			else
				beginAttack("touch")
			end
		end
		local hit = target
		if hit and (GameMode.mayBuild(mode) or GameMode.isSpectator(mode)) then
			if highlight.Parent ~= workspace.CurrentCamera then
				highlight.Parent = workspace.CurrentCamera
			end
			-- The block's outline: its cell, or the box of a torch, lantern or fire.
			local box = outlineAt(hit.block, hit.x, hit.y, hit.z) or FULL_OUTLINE
			if box ~= outlined then
				outlined = box
				highlight.Size = Vector3.new(box[4] - box[1], box[5] - box[2], box[6] - box[3]) * BLOCK
					+ Vector3.one * 0.05
			end
			-- (Every frame, in the render frame of the moment.)
			highlight.CFrame = CFrame.new(
				Origin.blocksToRender(
					hit.x + (box[1] + box[4]) / 2,
					hit.y + (box[2] + box[5]) / 2,
					hit.z + (box[3] + box[6]) / 2
				)
			)
			selection.Visible = true
		else
			selection.Visible = false
		end

		if open then
			if anyHeld(attackHeld) or anyHeld(useHeld) or mining then
				releaseAll()
			end
		else
			-- Breaking: at once with instabuild, over time in survival, never without mayBuild.
			if GameMode.instabuild(mode) then
				if mining then
					stopMining()
				end
				if anyHeld(attackHeld) then
					creativeBreak(now)
				end
			elseif not GameMode.mayBuild(mode) then
				if mining then
					stopMining()
				end
			else
				-- Right after a press, only the time since it counts (not the whole frame).
				local elapsed = dt
				local pressed = pressedAt
				if pressed then
					elapsed = math.clamp(now - pressed, 0, dt)
					pressedAt = nil
				end
				tickClock = math.min(tickClock + elapsed, TICK * MAX_TICKS_PER_FRAME)
				while tickClock >= TICK do
					tickClock -= TICK
					miningTick()
				end
			end
			-- A magic weapon held: it casts at its own use time (Interaction/Casting), every frame
			-- looked at, not the repeat's.
			local held = ClientInventory.selectedStack()
			if anyHeld(useHeld) and not useSpent and held and Casting.handles(held) and targetRay then
				if Casting.use(held, mode, targetRay, if hit then hit.distance else nil) then
					swing()
				end
			end
			-- Using / placing, repeated while held.
			if anyHeld(useHeld) and now - lastUse >= Config.Interaction.RepeatInterval then
				lastUse = now
				useAt(hit, targetRay)
			end
		end

		updateDebris(dt)
	end)

	--[[ Input ]]

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or Screens.isOpen() or GameModeSwitcher.isOpen() then
			return
		end
		local kind, key = input.UserInputType, input.KeyCode
		-- The key bindings (each on its own: one input bound to two actions does both, as in
		-- Minecraft), then the gamepad and touch controls.
		if Keybinds.matches("attack", input) then
			beginAttack("mouse")
		end
		if Keybinds.matches("use", input) then
			if
				kind == Enum.UserInputType.MouseButton2
				and UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter
			then
				-- A free mouse's right drag turns the camera: only a short click uses.
				rightDownAt = os.clock()
				rightMoved = 0
			else
				-- First person / shift lock, or another button or key: held, it repeats.
				beginUse("mouse", target, targetRay)
			end
		end
		if Keybinds.matches("pickItem", input) then
			pickAt(target)
		end
		if Keybinds.matches("drop", input) and not Keybinds.isDown("debug") then
			-- (The debug key + Q is the debug keys' list: Debug/DebugKeys.)
			local all = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
				or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
			drop(all)
		end
		if key == Enum.KeyCode.ButtonR2 then
			beginAttack("gamepad")
		elseif key == Enum.KeyCode.ButtonL2 then
			beginUse("gamepad", target, targetRay)
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
		if Keybinds.matches("attack", input) then
			endAttack("mouse")
		end
		if Keybinds.matches("use", input) then
			if useHeld.mouse then
				endUse("mouse")
			elseif rightDownAt then
				-- Right drag turns the camera (the mouse stays put meanwhile, so count its
				-- movement); only a short click uses / places.
				local click = os.clock() - rightDownAt < CLICK_TIME and rightMoved < CLICK_MOVE
				rightDownAt = nil
				if click and not Screens.isOpen() then
					useOnce(target, targetRay)
				end
			end
		end
		if key == Enum.KeyCode.ButtonR2 then
			endAttack("gamepad")
		elseif key == Enum.KeyCode.ButtonL2 then
			endUse("gamepad")
		elseif kind == Enum.UserInputType.Touch then
			local t = touch
			if t and t.input == input then
				touch = nil
				if t.holding then
					endAttack("touch")
					if useHeld.touch then
						endUse("touch")
					end
				elseif not t.moved and os.clock() - t.startedAt < TOUCH_HOLD and not Screens.isOpen() then
					-- A tap on a mob hits it (Bedrock's touch controls), else it uses.
					local hit, ray = targetAt(t.position, true)
					local mob, distance = nil, 0
					if ray then
						mob, distance = mobOn(ray)
					end
					if
						mob
						and (hit == nil or distance < hit.distance)
						and not GameMode.isSpectator(ClientInventory.mode())
					then
						attack(mob)
					else
						useOnce(hit, ray)
					end
				end
			end
		end
	end)
end

return BlockInteraction
