--!strict
--[[
	The item each player holds (their selected hotbar slot), as Minecraft shows it:

	  third person  a small model of the item in every character's right hand. The server sets the
	                player attribute Types.HELD_ATTRIBUTE; every client draws the models itself
	                (anchored, inert, moved with the hand each frame), so nothing extra replicates.
	                The local player's comes from the predicted inventory, so it changes at once.
	  first person  with the body drawn (Player/FirstPersonBody.trueFirstPerson: the camera rig's
	                first person or sights, the First-Person Body setting, an R15 body), the local
	                player's world model in the camera's space, held by both hands (DayZ's true
	                first person, below); otherwise (the setting off, an R6 body, or Roblox's own
	                first person without the rig) the item in the bottom right corner of the
	                screen, in a ViewportFrame, as before. Either dips in a short swing when
	                breaking or placing (`swing`).

	Blocks and most items are held turned like a block. Tools and sticks are held like Minecraft's
	"handheld" items (ItemModels.handPivot / holdPivot): at the handle, upright rather than lying
	diagonally as in their icon. In third person they point forward and up from the fist; in first
	person they rise from the bottom right corner towards the middle, leaning left, their face to
	the camera, and chop forward when swinging. A melee weapon of the melee rework (Shared/Weapons
	.melee) is also held across the chest while guarding and drawn back over the shoulder as a heavy
	attack winds up (Interaction/MeleeInput.guarding and .charge: Player/WeaponPoses.applyMelee in
	third person, other players' guard from Types.AIM_ATTRIBUTE; AimRules.meleeView in first
	person).

	True first person (the world model at the camera, after the view bob and the aim's sway, so the
	hands move with the final view): the anchor is the camera (turned back by the freelook offset,
	Player/CameraRig.freelookOffset, so the item stays on the aim while the head looks around). A
	firearm is held as DayZ holds one, lit by the world (dark at night, its weapon light shining
	from it): in the sights with the cheek on the stock, its sight line on the view's axis and its
	rear FirstPersonRules.sightsDepth ahead (about 0.45 studs, nearer looking up; Player/BodyTwist
	leans the chest forward); lowered, held on the body (FirstPersonRules.lowered on the chest's
	level frame: a long gun across it, a handgun low ahead on the right), eased between the two; a
	tool, a block (or any other item) and a bare fist follow Player/FirstPersonRules.handPose, the
	swing's sin(pi t) over SWING_TIME, the melee guard and wind-up. An item reaching into a block (a
	cast from the camera along the view to its far end, on the world's blocks:
	Shared/World/VoxelRaycast.distance with Shapes.sight) is pulled back, then its far end lifted
	(FirstPersonRules.obstruction: DayZ's weapon lift; the shot still goes from the eyes). Then the
	arms take it (Player/FirstPersonBody.poseArms: the right hand on the grip,
	ItemModels.firearmPoint "grip" for a gun, the left on a long gun's fore end ("fore"), a
	handgun's in its sights or a guarded weapon's handle, FirstPersonRules.leftHand; both under the
	gun, below its sight line: FirstPersonRules.GRIP_TILT, FORE_TILT; the elbows away from the
	camera). A gun never leaves its sight line: in the sights it may slide along the view towards
	the eyes (eased) until the right wrist is comfortably in reach (FirstPersonBody.gripSlide, its
	grip FirstPersonRules.GRIP_CLEAR past the near plane), and the left hand takes the fore end slid
	back towards the right hand where it reaches (FirstPersonBody.foreHold, trying again a little
	back or forward where its arm is in the way: FirstPersonRules.FORE_TRIES); a hand out of reach,
	whose arm the camera's near plane would cut, or (in the sights) whose arm would be in front of
	the sight line (FirstPersonBody.armClips), lets go (eased, a little hysteresis) and the
	animation has that arm while the gun stays put. A part of the gun the near plane would cut (a
	stock reaching back past the eyes) is hidden. A tool or a block follows the right hand where it
	can't reach. What it holds goes to FirstPersonBody.setHeld, and the arms are settled in the same
	step (FirstPersonBody.settleArms: with this frame's camera and scope, so a scope hides them with
	the gun). Player/WeaponPoses is released for the local character meanwhile.

	Firearms (Shared/Weapons), in the manner of DayZ:
	  third person  the gun dressed as it is (ItemModels.buildFirearm: magazine, optic, muzzle
	                device, light; the look key from the predicted inventory for the local player,
	                the player attribute Types.HELD_LOOK_ATTRIBUTE for the others), built at
	                ItemModels.firearmSize, held at the grip in the right hand, which Player/
	                WeaponPoses posed first (lowered across the body or raised along the look: the
	                local player's posture from Player/AimCamera at once, the others' from
	                Types.AIM_ATTRIBUTE; the pitch from Player/MovementController or Player/
	                RemotePlayers). Its weapon light shines from the model (the local player's with
	                shadows, Roblox's lights shine through a hidden model too, so in the corner view
	                it lights where the raised gun points). The local player's head turns with a
	                freelooking camera in third person (WeaponPoses.applyLook).
	  first person  (the view without the body; true first person: above) low on the right, its
	                barrel towards the screen's centre (AimRules.hipPose), or in the sights
	                (Player/AimCamera.sightsView: first person raised, or V in third person, where
	                the view is the eyes' too) with its sight line on the view axis, eased between
	                the two (through a mounted optic's middle, the optic itself hidden there:
	                Ui/WeaponHud draws a red dot's dot); a shot kicks it back and up (`kick`,
	                AimRules.modelKick). A scope's zoom (AimCamera.scoped) hides it: Ui/WeaponHud
	                draws the scope. In the view the viewport covers the whole screen and its camera
	                takes the world camera's field of view every frame, so a point posed in front of
	                it lands where the same point in front of the world camera would.
	  muzzle        `muzzle(player)`: where a held gun's barrel ends in the world (render studs; the
	                local player's in the first-person view through the viewport's pose, by the
	                world camera; in true first person its model kept in the camera's space and
	                placed with the camera of the frame that asks, so a shot fired at Camera + 6
	                starts from the gun drawn that frame; in third person its model's pivot as last
	                placed, at Camera + 7 the frame before), for Rendering/ShotView's flashes and
	                tracers.

	Models are built again when item looks change (ItemModels.generation: the Textures setting,
	texture averages measured a few seconds after joining).

	Nothing is drawn for an empty hand or while a Tool is equipped, nor for spectators (Shared/
	GameMode): their body is invisible or a floating head (Player/SpectatorRules), and in first
	person they have no hand. Nor for a player whose character isn't shown on this client (Player/
	RemotePlayers.shown: with the server's own positions, one it doesn't send this client, parked
	far away, or a body gone after its death). A third person model hides with its character's
	head when the camera fades that out: the local player's in Roblox's first person or with the
	setting off (Player/FirstPersonBody hides the head), and the player a spectator spectates,
	whose eyes the camera is in (Roblox fades the camera subject's character). The models follow
	the hands every frame (PivotTo, in the render frame the characters are placed in), so a move of
	the render origin needs nothing here. A render step at Camera + 7 (after Player/BodyTwist's
	+ 6 turned the waists, before Player/EquipmentLooks' + 8 dresses the posed arms).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Origin = require(Shared.World.Origin)
local Shapes = require(Shared.Blocks.Shapes)
local Types = require(Shared.Inventory.Types)
local VoxelRaycast = require(Shared.World.VoxelRaycast)
local WeaponState = require(Shared.Weapons.WeaponState)
local Weapons = require(Shared.Weapons)

local ItemModels = require(script.Parent.Parent.Rendering.ItemModels)
local MeleeInput = require(script.Parent.Parent.Interaction.MeleeInput)
local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local Screens = require(script.Parent.Parent.Ui.Screens)
local UiScale = require(script.Parent.Parent.Ui.UiScale)
local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local AimCamera = require(script.Parent.AimCamera)
local AimRules = require(script.Parent.AimRules)
local CameraRig = require(script.Parent.CameraRig)
local FirstPersonBody = require(script.Parent.FirstPersonBody)
local FirstPersonRules = require(script.Parent.FirstPersonRules)
local MovementController = require(script.Parent.MovementController)
local RemotePlayers = require(script.Parent.RemotePlayers)
local WeaponPoses = require(script.Parent.WeaponPoses)

local BLOCK = Config.BlockSize
-- After the view bob (+ 4), the aim's sway (+ 5) and the bodies' twist (+ 6); before the worn
-- pieces follow the arms (Player/EquipmentLooks, + 8).
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 7
local RENDER_STEP = "IceVoxelHeldItems"
-- Minecraft's arm swing lasts 6 ticks.
local SWING_TIME = 0.3
-- The corner view's field of view (non-firearms).
local CORNER_FOV = 40
-- How fast the first-person gun moves between the hip and the sights (per second).
local SIGHTS_RATE = 14
-- How fast an item pulls back from a wall and comes out again (per second).
local WALL_IN_RATE = 25
local WALL_OUT_RATE = 10
-- A block (or other item) in a first-person hand: its centre this share of its size past the fist
-- (as ItemModels.handPivot's).
local BLOCK_HOLD = 0.3
-- A guarded weapon's left hand: this far up the handle from the right (studs).
local GUARD_LEFT = 0.55
-- True first person: how fast a gun slides towards the eyes for the hands and back (per second),
-- and how fast a hand takes a gun and lets it go.
local SLIDE_IN_RATE = 30
local SLIDE_OUT_RATE = 10
local HOLD_RATE = 20
-- A hand holding a gun keeps holding it this much (studs) past where it takes hold.
local HOLD_SLACK = 0.05
-- The grip's frame on a gun (its axes: x the barrel, y up, z right; the frame looks along the
-- fingers): the right hand's fingers turned FirstPersonRules.GRIP_TILT from along the barrel up its
-- grip; on a long gun's fore end the left hand under it, its fingers FORE_TILT up from across, its
-- thumb along the barrel. Both hands sit under the gun, below its sight line.
local GUN_GRIP = CFrame.Angles(0, 0, FirstPersonRules.GRIP_TILT) * CFrame.Angles(0, -math.pi / 2, 0)
local FORE_GRIP = (function(): CFrame
	local c, s = math.cos(FirstPersonRules.FORE_TILT), math.sin(FirstPersonRules.FORE_TILT)
	return CFrame.fromMatrix(Vector3.zero, Vector3.new(0, c, -s), Vector3.new(1, 0, 0), Vector3.new(0, -s, -c))
end)()

local HeldItems = {}

local swingStart = -math.huge
local kickStart = -math.huge

-- Plays the first person swing (breaking, placing).
function HeldItems.swing()
	swingStart = os.clock()
end

-- Kicks the first-person gun back and up (a shot).
function HeldItems.kick()
	kickStart = os.clock()
end

--[[
	`parts` and `hidden` let the first person hiding write only when it changes (`clipped`: each
	part cut by the camera's near plane in true first person); `look`: the item look generation the
	model was built with; a firearm's look key, its size, the pivot it was last placed at (for its
	muzzle; in true first person also in the camera's space, `relative`, so a shot this frame
	starts from where the gun is drawn this frame), and its optic's parts (hidden in true first
	person's sights).
]]
type Held = {
	item: number,
	model: Model,
	parts: { BasePart },
	hidden: boolean,
	clipped: { boolean },
	look: number,
	key: string,
	firearm: boolean,
	size: number,
	pivot: CFrame?,
	relative: CFrame?,
	optic: { BasePart },
	opticHidden: boolean,
}

local held: { [Player]: Held } = {}
-- The first-person gun in the view: shown, its item, look key, size and pivot (the viewport
-- camera's space).
local handGun = false
local handGunItem = 0
local handGunKey = ""
local handGunSize = 1
local handGunPivot = CFrame.identity

-- First person pose of a block (or any item but tools) in the corner view: `dip` is the swing,
-- 0..1..0.
local function blockPose(dip: number): CFrame
	return CFrame.new(0.35 - 0.25 * dip, -0.45 - 0.2 * dip, -2.4)
		* CFrame.Angles(math.rad(-15 - 40 * dip), math.rad(40), math.rad(5))
end

--[[
	First person pose of a tool's upright view space in the corner view, at its grip: low in the
	bottom right corner (the handle runs off the bottom), leaning left towards the middle, tipped
	away a little and turned so its face shows. Swinging chops it forward and down towards the
	middle.
]]
local function toolPose(dip: number): CFrame
	return CFrame.new(0.5 - 0.2 * dip, -0.62 - 0.1 * dip, -2.2)
		* CFrame.Angles(math.rad(-25 - 55 * dip), math.rad(-20), 0)
		* CFrame.Angles(0, 0, math.rad(30))
end

-- A gun's frame looking down the view axis: its barrel ahead (-Z), its top up.
local AHEAD = CFrame.fromMatrix(Vector3.zero, Vector3.new(0, 0, -1), Vector3.yAxis)

-- `frame` levelled: at its place, turned only about the vertical to face as it does (lying face
-- down: as its top).
local function levelled(frame: CFrame): CFrame
	local look = frame.LookVector
	if look.X * look.X + look.Z * look.Z < 1e-6 then
		look = -frame.UpVector
	end
	return CFrame.new(frame.Position) * CFrame.Angles(0, math.atan2(-look.X, -look.Z), 0)
end
-- The first-person gun's frames: low on the right aimed at the centre, and in the sights.
local HIP_FRAME = (function(): CFrame
	local x, y, z, yaw, pitch = AimRules.hipPose()
	return CFrame.new(x, y, z) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0) * AHEAD
end)()
local SIGHTS_FRAME = CFrame.new(0, 0, -AimRules.SIGHTS_DEPTH) * AHEAD

-- The local player's held gun's look key (Shared/Weapons/WeaponState.lookKey), kept as the
-- predicted inventory changes.
local localKey = ""

-- The local player's melee guard and heavy wind-up (0..1): Interaction/MeleeInput.guarding and
-- .charge.
local function localGuard(): boolean
	return MeleeInput.guarding()
end

local function localCharge(): number
	return math.clamp(MeleeInput.charge(), 0, 1)
end

-- The parts of `model` named "Optic" (a mounted optic: hidden in the sights).
local function opticOf(model: Model, into: { BasePart })
	for _, part in model:GetChildren() do
		if part.Name == "Optic" and part:IsA("BasePart") then
			table.insert(into, part)
		end
	end
end

--[[
	Starts drawing the held items. `world`: the blocks an item held in true first person keeps out
	of (nil: none, it goes through walls).
]]
function HeldItems.start(world: ClientWorld.ClientWorld?)
	local localPlayer = Players.LocalPlayer
	local folder = Instance.new("Folder")
	folder.Name = "IceVoxelHeldItems"
	folder.Parent = workspace.CurrentCamera

	-- The world's blocks for the wall check (Shapes.sight: their collision boxes).
	local getBlock: ((x: number, y: number, z: number) -> number?)? = nil
	local sightStops: ((id: number) -> boolean)? = nil
	local sightOutline: ((id: number, x: number, y: number, z: number) -> { number }?)? = nil
	if world then
		local function blockAt(x: number, y: number, z: number): number?
			return world:getBlock(x, y, z)
		end
		getBlock = blockAt
		sightStops, sightOutline = Shapes.sight(blockAt)
	end

	local function refreshKey()
		localKey = WeaponState.lookKey(ClientInventory.selectedStack())
	end
	ClientInventory.changed:Connect(refreshKey)
	refreshKey()

	local function clear(player: Player)
		local current = held[player]
		if current then
			current.model:Destroy()
			held[player] = nil
		end
		local character = player.Character
		if character then
			WeaponPoses.release(character)
			if player == localPlayer then
				FirstPersonBody.release(character)
			end
		end
	end

	local function itemOf(player: Player): number
		if GameMode.isSpectator(GameMode.of(player)) then
			return 0
		end
		-- (Not drawn here: untracked, or a body gone.)
		if player ~= localPlayer and not RemotePlayers.shown(player) then
			return 0
		end
		if player == localPlayer then
			local stack = ClientInventory.selectedStack()
			return if stack then stack.item else 0
		end
		local item = player:GetAttribute(Types.HELD_ATTRIBUTE)
		return if type(item) == "number" then item else 0
	end

	-- A held gun's look key: the predicted one for the local player, the attribute for others.
	local function keyOf(player: Player): string
		if player == localPlayer then
			return localKey
		end
		local key = player:GetAttribute(Types.HELD_LOOK_ATTRIBUTE)
		return if type(key) == "string" then key else ""
	end

	-- How `player` holds their gun (for the arms) and the look's pitch (radians).
	local function aimOf(player: Player): (AimRules.Posture, number)
		if player == localPlayer then
			local view = MovementController.current
			local posture: AimRules.Posture = if AimCamera.posture() == "lowered" then "lowered" else "raised"
			return posture, if view then view.pitch else 0
		end
		local raised = player:GetAttribute(Types.AIM_ATTRIBUTE) == Types.AIM_RAISED
		local remote = RemotePlayers.get(player)
		local posture: AimRules.Posture = if raised then "raised" else "lowered"
		return posture, if remote then remote.pitch else 0
	end

	-- Whether `player` guards with their melee weapon, and how far a heavy attack is wound up
	-- (only the local player's: a wind-up isn't sent).
	local function meleeOf(player: Player): (boolean, number)
		if player == localPlayer then
			return localGuard(), localCharge()
		end
		return player:GetAttribute(Types.AIM_ATTRIBUTE) == Types.AIM_GUARD, 0
	end

	-- First person view: a viewport in the bottom right corner (the whole screen for a gun).
	-- (A view of the world, sized by the screen: under everything else. The whole screen, notches
	-- included, as the camera's view is, so a gun's sight line meets its centre on every device.)
	local gui = UiScale.screenGui("IceVoxelHand", "Hand", { inset = true, full = true, kind = "screen" })
	local viewport = Instance.new("ViewportFrame")
	viewport.BackgroundTransparency = 1
	viewport.Ambient = Color3.fromRGB(150, 150, 150)
	viewport.LightColor = Color3.fromRGB(190, 190, 190)
	viewport.LightDirection = Vector3.new(-0.4, -1, -0.6)
	viewport.Visible = false
	viewport.Parent = gui
	local camera = Instance.new("Camera")
	camera.FieldOfView = CORNER_FOV
	camera.CFrame = CFrame.new(0, 0, 0)
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	gui.Parent = localPlayer:WaitForChild("PlayerGui")

	-- The viewport's layout: the corner, or the whole screen for a gun (set when it changes).
	local fullScreen: boolean? = nil
	local function layout(full: boolean)
		if fullScreen == full then
			return
		end
		fullScreen = full
		if full then
			viewport.AnchorPoint = Vector2.zero
			viewport.Position = UDim2.fromScale(0, 0)
			viewport.Size = UDim2.fromScale(1, 1)
			viewport.SizeConstraint = Enum.SizeConstraint.RelativeXY
		else
			viewport.AnchorPoint = Vector2.new(1, 1)
			viewport.Position = UDim2.fromScale(1, 1)
			viewport.Size = UDim2.fromScale(0.45, 0.45)
			viewport.SizeConstraint = Enum.SizeConstraint.RelativeYY
			camera.FieldOfView = CORNER_FOV
		end
	end
	layout(false)

	local handItem = 0
	local handModel: Model? = nil
	local handLook = 0
	local handKey = ""
	-- How far the first-person gun is in the sights (0 hip .. 1 sights); its optic's parts
	-- (hidden in the sights, which look through the optic's middle) and whether they are hidden.
	local sightsShare = 0
	-- How far the first-person melee weapon is in its guard (0..1, eased).
	local guardShare = 0
	local opticParts: { BasePart } = {}
	local opticHidden = false
	-- True first person: how far the item is pulled back from a wall (studs) and lifted (radians),
	-- eased; the grips of this frame's placement (world); what is held (FirstPersonBody.setHeld,
	-- one table reused).
	local pull, lift = 0, 0
	local rightGrip: CFrame? = nil
	local leftGrip: CFrame? = nil
	-- The view axis the item was placed along this frame and the anchor's place (world).
	local placedAlong = -Vector3.zAxis
	local placedFrom = Vector3.zero
	-- A gun's slide towards the eyes for the hands (studs, eased) and how far each hand holds it
	-- (0 the animation .. 1 on it, eased).
	local gunSlide = 0
	local rightHold, leftHold = 0, 0
	local holdsRight, holdsLeft = false, false
	local holding: FirstPersonBody.HeldState =
		{ kind = "empty", scoped = false, sightsShare = 0, long = false, guard = false }

	-- The swing's dip now (0..1..0: Minecraft's swing).
	local function dipAt(now: number): number
		local t = math.clamp((now - swingStart) / SWING_TIME, 0, 1)
		return math.sin(t * math.pi)
	end

	-- The aim's frame at the camera: the camera, turned back by the freelook offset.
	local function anchorOf(view: Camera): CFrame
		local frame = view.CFrame
		local yaw, pitch = CameraRig.freelookOffset()
		if yaw == 0 and pitch == 0 then
			return frame
		end
		local aimPitch = CameraRig.aimPitch()
		return frame * CFrame.Angles(-(aimPitch + pitch), -yaw, 0) * CFrame.Angles(aimPitch, 0, 0)
	end

	--[[
		The wall's push on an item in the anchor's space: it reaches `depth` studs ahead along the
		view, and lifts about `pivot` (the anchor's space). Eased: in fast, out slower.
	]]
	local function wallPush(anchor: CFrame, depth: number, pivot: Vector3, dt: number): CFrame
		local free = math.huge
		if getBlock and sightStops then
			local ox, oy, oz = Origin.renderToBlocks(anchor.Position)
			local look = anchor.LookVector
			local hit = VoxelRaycast.distance(
				ox,
				oy,
				oz,
				look.X,
				look.Y,
				look.Z,
				depth / BLOCK,
				getBlock,
				sightStops,
				sightOutline
			)
			if hit then
				free = hit * BLOCK
			end
		end
		local wantPull, wantLift = FirstPersonRules.obstruction(free, depth)
		pull = AimRules.ease(pull, wantPull, dt, if wantPull > pull then WALL_IN_RATE else WALL_OUT_RATE)
		lift = AimRules.ease(lift, wantLift, dt, if wantLift > lift then WALL_IN_RATE else WALL_OUT_RATE)
		if pull == 0 and lift == 0 then
			return CFrame.identity
		end
		return CFrame.new(pivot.X, pivot.Y, pivot.Z + pull) * CFrame.Angles(lift, 0, 0) * CFrame.new(-pivot)
	end

	--[[
		True first person: where the local player's `item` (a firearm `gun`, built at `size`, look
		`key`) goes in the world this frame (its model's pivot), with the grips its hands take
		(`rightGrip`, `leftGrip`); what it holds goes to `holding`.
	]]
	local function placeFirstPerson(
		view: Camera,
		character: Model,
		item: number,
		gun: Weapons.FirearmSpec?,
		key: string,
		size: number,
		dt: number,
		now: number
	): CFrame
		local anchor = anchorOf(view)
		leftGrip = nil
		placedAlong = anchor.LookVector
		placedFrom = anchor.Position
		if gun then
			sightsShare = AimRules.ease(sightsShare, if AimCamera.sightsView() then 1 else 0, dt, SIGHTS_RATE)
			local back, up = AimRules.modelKick(now - kickStart)
			local kick = CFrame.Angles(0, 0, math.rad(up))
			local shove = CFrame.new(0, 0, back)
			local long = AimRules.longGun(gun)
			-- The cheek on the stock: the sights near the eyes (nearer looking up); lowered, the gun
			-- held on the body (a long gun across it), where both hands reach it.
			local pitch = math.asin(math.clamp(anchor.LookVector.Y, -1, 1))
			local sightsFrame = CFrame.new(0, 0, -FirstPersonRules.sightsDepth(pitch, (FirstPersonBody.nearView(view))))
				* AHEAD
			local hipFrame = HIP_FRAME
			local chest = character:FindFirstChild("UpperTorso")
			if chest and chest:IsA("BasePart") then
				local turn, x, y, z, yaw, gunPitch = FirstPersonRules.lowered(pitch, long)
				hipFrame = anchor:ToObjectSpace(
					levelled(chest.CFrame)
						* CFrame.Angles(turn, 0, 0)
						* CFrame.new(x, y, z)
						* CFrame.Angles(0, yaw, 0)
						* CFrame.Angles(gunPitch, 0, 0)
						* AHEAD
				)
			end
			local hip = ItemModels.firearmPivot(item, size, "hip", shove * hipFrame * kick)
			local sights = ItemModels.firearmPivot(item, size, "sights", shove * sightsFrame * kick, key)
			local pivot = if sightsShare <= 0
				then hip
				elseif sightsShare >= 1 then sights
				else hip:Lerp(sights, sightsShare)
			local depth = -ItemModels.firearmPoint(item, key, size, pivot, "muzzle").Z
			local grip = ItemModels.firearmPoint(item, key, size, pivot, "grip")
			local placed = anchor * wallPush(anchor, depth, grip, dt) * pivot
			local axes = ItemModels.firearmAxes(item, placed)
			rightGrip = CFrame.new(ItemModels.firearmPoint(item, key, size, placed, "grip")) * axes * GUN_GRIP
			if FirstPersonRules.leftHand("firearm", long, false, sightsShare > 0.5) then
				leftGrip = CFrame.new(ItemModels.firearmPoint(item, key, size, placed, "fore")) * axes * FORE_GRIP
			end
			holding.kind = "firearm"
			holding.long = long
			holding.guard = false
			holding.sightsShare = sightsShare
			holding.scoped = AimCamera.scoped()
			return placed
		end
		local dip = dipAt(now)
		holding.long = false
		holding.sightsShare = 0
		holding.scoped = false
		if ItemModels.isHandheld(item) then
			local guarding, charge = false, 0
			if Weapons.melee(item) then
				guarding = localGuard()
				charge = localCharge()
				guardShare = AimRules.ease(guardShare, if guarding then 1 else 0, dt, SIGHTS_RATE)
			else
				guardShare = 0
			end
			local x, y, z, pitch, yaw, roll = FirstPersonRules.handPose("tool", dip, guardShare, charge)
			local at = Vector3.new(x, y, z)
			local wall = wallPush(anchor, -z + FirstPersonRules.TOOL_REACH, at, dt)
			local grip = anchor * wall * CFrame.new(at) * CFrame.Angles(pitch, yaw, roll)
			rightGrip = grip
			if FirstPersonRules.leftHand("tool", false, guarding) then
				leftGrip = grip * CFrame.new(0, GUARD_LEFT, 0)
			end
			holding.kind = "tool"
			holding.guard = guarding
			return ItemModels.holdPivot(item, size, grip)
		end
		local x, y, z, pitch, yaw, roll = FirstPersonRules.handPose("block", dip, 0, 0)
		local at = Vector3.new(x, y, z)
		local wall = wallPush(anchor, -z + FirstPersonRules.BLOCK_REACH, at, dt)
		local grip = anchor * wall * CFrame.new(at) * CFrame.Angles(pitch, yaw, roll)
		rightGrip = grip
		holding.kind = "block"
		holding.guard = false
		return grip * CFrame.new(0, 0, -size * BLOCK_HOLD)
	end

	-- True first person with nothing drawn in hand: a bare fist punches on a swing (none while a
	-- Tool is equipped); the arms otherwise hang as the animation has them.
	local function emptyHands(view: Camera, character: Model, tool: boolean, now: number)
		holding.kind = "empty"
		holding.long = false
		holding.guard = false
		holding.sightsShare = 0
		holding.scoped = false
		pull, lift = 0, 0
		local dip = if tool then 0 else dipAt(now)
		if dip <= 0 then
			FirstPersonBody.release(character)
			return
		end
		local x, y, z, pitch, yaw, roll = FirstPersonRules.handPose("empty", dip, 0, 0)
		local grip = anchorOf(view) * CFrame.new(x, y, z) * CFrame.Angles(pitch, yaw, roll)
		FirstPersonBody.poseArmsWeighted(character, grip, nil, dip, 0, view.CFrame.Position)
	end

	--[[
		True first person: the hands on a gun placed at `where` (its grips `rightGrip`, `leftGrip`).
		Its sight picture is kept: it only slides along the view towards the eyes, until the right
		wrist is comfortably in reach (Player/FirstPersonBody.gripSlide; its grip kept
		FirstPersonRules.GRIP_CLEAR past the near plane), eased; a long gun's left hand takes the
		fore end where it reaches (FirstPersonBody.foreHold: slid back along the barrel towards the
		right hand). A hand that can't reach, or whose arm the camera's near plane would cut
		(FirstPersonBody.armClips), lets go (eased; HOLD_SLACK of hysteresis): the animation has that
		arm, the gun stays in its sights. Returns where the gun goes.
	]]
	local function holdGun(view: Camera, character: Model, where: CFrame, dt: number): CFrame
		local right = rightGrip :: CFrame
		local toEye = -placedAlong
		local depth = (right.Position - placedFrom):Dot(placedAlong)
		local nearDepth = FirstPersonBody.nearView(view)
		-- (A hand holding on keeps holding a little further than it takes hold: no flicker. Only a
		-- gun in its sights slides, and there no arm may be in front of the sight line.)
		local slack = if holdsRight then HOLD_SLACK else 0
		local sightLine = sightsShare > 0.5
		local limit = math.max(depth - nearDepth - FirstPersonRules.GRIP_CLEAR, 0) * sightsShare + slack
		local want = FirstPersonBody.gripSlide(character, right, toEye, limit, FirstPersonRules.COMFORT)
			or FirstPersonBody.gripSlide(character, right, toEye, limit, 1)
		if want and FirstPersonBody.armClips(character, true, right + toEye * want, view, slack, sightLine) then
			want = nil
		end
		holdsRight = want ~= nil
		gunSlide =
			AimRules.ease(gunSlide, want or 0, dt, if (want or 0) > gunSlide then SLIDE_IN_RATE else SLIDE_OUT_RATE)
		local shift = toEye * gunSlide
		right += shift
		rightHold = AimRules.ease(rightHold, if holdsRight then 1 else 0, dt, HOLD_RATE)
		local left: CFrame? = nil
		local fore = leftGrip
		if fore then
			fore += shift
			local leftSlack = if holdsLeft then HOLD_SLACK else 0
			left = nil
			if holdsRight then
				-- (An arm in the way tries a little further back along the barrel.)
				for _, from in FirstPersonRules.FORE_TRIES do
					local at = FirstPersonBody.foreHold(character, fore, right.Position, from)
					if at == nil then
						break
					elseif not FirstPersonBody.armClips(character, false, at, view, leftSlack, sightLine) then
						left = at
						break
					end
				end
			end
			holdsLeft = left ~= nil
			leftHold = AimRules.ease(leftHold, if holdsLeft then 1 else 0, dt, HOLD_RATE)
			if left == nil and leftHold > 0 then
				-- (Letting go: towards the nearest the left hand may hold.)
				local back = right.Position - fore.Position
				left = if back.Magnitude > FirstPersonRules.FORE_MIN
					then fore + back.Unit * (back.Magnitude - FirstPersonRules.FORE_MIN)
					else fore
			end
		else
			holdsLeft, leftHold = false, 0
		end
		FirstPersonBody.poseArmsWeighted(character, right, left, rightHold, leftHold, view.CFrame.Position)
		return where + shift
	end

	local function step(frameDt: number)
		local now = os.clock()
		local dt = math.min(frameDt, 0.1)
		local view = workspace.CurrentCamera
		-- (Measured at Camera + 2 this frame.)
		local trueFirstPerson = FirstPersonBody.trueFirstPerson() and view ~= nil
		local localPlaced = false
		local localGun = false
		if not trueFirstPerson then
			pull, lift = 0, 0
		end
		-- Third person: every character's hand; true first person: the local one at the camera.
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local item = itemOf(player)
			local gun = if item ~= 0 then Weapons.firearm(item) else nil
			local isLocal = player == localPlayer
			local firstPerson = isLocal and trueFirstPerson
			local tool = character ~= nil and character:FindFirstChildOfClass("Tool") ~= nil
			local where: CFrame? = nil
			rightGrip = nil
			if character and firstPerson then
				-- (The arms are FirstPersonBody's: let go of the third-person pose first.)
				WeaponPoses.applyLook(character, 0, 0)
				WeaponPoses.release(character)
				if item ~= 0 and not tool and humanoid and humanoid.Health > 0 then
					local size = if gun then ItemModels.firearmSize(item) else ItemModels.handSize(item)
					where = placeFirstPerson(view, character, item, gun, keyOf(player), size, dt, now)
				end
			elseif character and gun then
				if isLocal then
					FirstPersonBody.release(character)
				end
				local posture: AimRules.Posture, pitch: number = aimOf(player)
				local long = AimRules.longGun(gun)
				WeaponPoses.apply(character, posture, pitch, long)
				local frame = WeaponPoses.gunFrame(character, posture, pitch, long)
				if frame then
					where = ItemModels.firearmPivot(item, ItemModels.firearmSize(item), "hand", frame)
				end
			elseif character and item ~= 0 then
				if isLocal then
					FirstPersonBody.release(character)
				end
				if Weapons.melee(item) then
					local guard, charge = meleeOf(player)
					WeaponPoses.applyMelee(character, guard, charge)
				else
					WeaponPoses.release(character)
				end
				where = ItemModels.handPivot(item, character)
			elseif character and isLocal then
				FirstPersonBody.release(character)
			end
			if character == nil or humanoid == nil or humanoid.Health <= 0 or item == 0 or where == nil or tool then
				if held[player] then
					clear(player)
				elseif character then
					WeaponPoses.release(character)
				end
				if character and firstPerson then
					emptyHands(view, character, tool, now)
					localPlaced = true
				end
			else
				local current = held[player]
				local look = ItemModels.generation()
				local key = if gun then keyOf(player) else ""
				if current == nil or current.item ~= item or current.look ~= look or current.key ~= key then
					if current then
						current.model:Destroy()
						held[player] = nil
					end
					local size = if gun then ItemModels.firearmSize(item) else ItemModels.handSize(item)
					local model = if gun then ItemModels.buildFirearm(item, key, size) else ItemModels.build(item, size)
					model.Parent = folder
					local parts: { BasePart } = {}
					for _, part in model:GetDescendants() do
						if part:IsA("BasePart") then
							table.insert(parts, part)
						elseif part:IsA("SpotLight") and isLocal then
							-- (The local player's weapon light casts shadows; others' don't.)
							part.Shadows = true
						end
					end
					local optic: { BasePart } = {}
					if gun and isLocal then
						opticOf(model, optic)
					end
					-- New parts are visible (LocalTransparencyModifier 0).
					current = {
						item = item,
						model = model,
						parts = parts,
						hidden = false,
						clipped = table.create(#parts, false),
						look = look,
						key = key,
						firearm = gun ~= nil,
						size = size,
						pivot = nil,
						relative = nil,
						optic = optic,
						opticHidden = false,
					}
					held[player] = current
				end
				assert(current and character and where, "held model")
				local hidden: boolean
				current.relative = nil
				if firstPerson then
					-- The hands take it: a gun slides towards the eyes for them, its sight line kept
					-- (`holdGun`); a tool or a block follows the right hand where it can't reach.
					if current.firearm and rightGrip then
						where = holdGun(view, character, where, dt)
						localGun = true
					else
						FirstPersonBody.poseArms(character, rightGrip, leftGrip, view.CFrame.Position)
						local miss = FirstPersonBody.reach()
						if miss.Magnitude > 1e-3 then
							where += miss
						end
					end
					assert(where, "placed")
					if current.firearm then
						current.relative = view.CFrame:ToObjectSpace(where)
					end
					localPlaced = true
					-- (A scope's view: Ui/WeaponHud's overlay instead.)
					hidden = holding.scoped
				else
					-- Hidden with the camera subject's character in first person (Roblox hides the
					-- body there, FirstPersonBody with the setting off): the local player's, or the
					-- one a spectator spectates.
					local head = character:FindFirstChild("Head")
					hidden = head ~= nil and head:IsA("BasePart") and head.LocalTransparencyModifier > 0.5
				end
				current.model:PivotTo(where)
				current.pivot = where
				-- In true first person a part the camera's near plane would cut is hidden too (a
				-- stock reaching back past the eyes).
				local eyes = if firstPerson and not hidden then view.CFrame else nil
				local depth, tx, ty = 0, 0, 0
				if eyes then
					depth, tx, ty = FirstPersonBody.nearView(view)
				end
				local clipped = current.clipped
				local changed = hidden ~= current.hidden
				current.hidden = hidden
				for i, part in current.parts do
					local clip = eyes ~= nil and FirstPersonBody.clipped(eyes, part.CFrame, part.Size, depth, tx, ty)
					if changed or clip ~= clipped[i] then
						clipped[i] = clip
						part.LocalTransparencyModifier = if hidden or clip then 1 else 0
					end
				end
				-- The optic is looked through in true first person's sights.
				local hideOptic = firstPerson and current.firearm and sightsShare > 0.6
				if hideOptic ~= current.opticHidden then
					current.opticHidden = hideOptic
					for _, part in current.optic do
						part.Transparency = if hideOptic then 1 else 0
					end
				end
			end
			-- The local head turns with a freelooking camera in third person.
			if isLocal and character and not firstPerson then
				local yaw, pitch = 0, 0
				if not CameraRig.eyesView() then
					yaw, pitch = CameraRig.freelookOffset()
				end
				WeaponPoses.applyLook(character, yaw, pitch)
			end
		end
		for player in held do
			if player.Parent == nil then
				clear(player)
			end
		end
		if not (trueFirstPerson and localPlaced) then
			-- (Nothing held in true first person: no character, or the first-person view.)
			holding.kind = "empty"
			holding.scoped = false
			holding.sightsShare = 0
			holding.long = false
			holding.guard = false
		end
		if not localGun then
			gunSlide, rightHold, leftHold = 0, 0, 0
			holdsRight, holdsLeft = false, false
		end
		FirstPersonBody.setHeld(holding)
		if trueFirstPerson then
			-- (The arms where they were just posed, with this frame's camera and scope.)
			FirstPersonBody.settleArms(view)
		end

		-- The first-person view (the setting off, an R6 body, Roblox's own first person): the item
		-- in the corner, or the gun across the whole screen.
		local item = itemOf(localPlayer)
		local gun = if item ~= 0 then Weapons.firearm(item) else nil
		local character = localPlayer.Character
		local show = CameraRig.eyesView()
			and not trueFirstPerson
			and item ~= 0
			and not Screens.isOpen()
			and character ~= nil
			and character:FindFirstChildOfClass("Tool") == nil
		handGun = show and gun ~= nil
		local visible = show and not (gun ~= nil and AimCamera.scoped())
		if viewport.Visible ~= visible then
			viewport.Visible = visible
		end
		if not show then
			return
		end
		layout(gun ~= nil)
		local look = ItemModels.generation()
		local key = if gun then localKey else ""
		local size = if gun then ItemModels.firearmSize(item) else 1
		if handItem ~= item or handModel == nil or handLook ~= look or handKey ~= key then
			if handModel then
				handModel:Destroy()
			end
			local model = if gun then ItemModels.buildFirearm(item, key, size) else ItemModels.build(item, 1)
			model.Parent = viewport
			table.clear(opticParts)
			opticHidden = false
			opticOf(model, opticParts)
			handModel = model
			handItem = item
			handLook = look
			handKey = key
		end
		local model = handModel :: Model
		if gun then
			-- The world camera's field of view, so the sight line meets the screen's centre.
			if camera.FieldOfView ~= view.FieldOfView then
				camera.FieldOfView = view.FieldOfView
			end
			sightsShare = AimRules.ease(sightsShare, if AimCamera.sightsView() then 1 else 0, dt, SIGHTS_RATE)
			local back, up = AimRules.modelKick(now - kickStart)
			local kick = CFrame.Angles(0, 0, math.rad(up))
			local shove = CFrame.new(0, 0, back)
			local hip = ItemModels.firearmPivot(item, size, "hip", shove * HIP_FRAME * kick)
			local sights = ItemModels.firearmPivot(item, size, "sights", shove * SIGHTS_FRAME * kick, key)
			local pivot = if sightsShare <= 0
				then hip
				elseif sightsShare >= 1 then sights
				else hip:Lerp(sights, sightsShare)
			model:PivotTo(pivot)
			local hideOptic = sightsShare > 0.6
			if hideOptic ~= opticHidden then
				opticHidden = hideOptic
				for _, part in opticParts do
					part.Transparency = if hideOptic then 1 else 0
				end
			end
			handGunItem, handGunKey, handGunSize, handGunPivot = item, key, size, pivot
			return
		end
		-- Minecraft's swing: the item dips towards the centre and back.
		local dip = dipAt(now)
		if ItemModels.isHandheld(item) then
			local pose = toolPose(dip)
			if Weapons.melee(item) then
				-- The melee rework: across the middle while guarding, drawn back winding up.
				guardShare = AimRules.ease(guardShare, if localGuard() then 1 else 0, dt, SIGHTS_RATE)
				local x, y, z, roll, tip = AimRules.meleeView(guardShare, localCharge())
				pose = CFrame.new(x, y, z) * pose * CFrame.Angles(math.rad(tip), 0, math.rad(roll))
			end
			model:PivotTo(ItemModels.holdPivot(item, 1, pose))
		else
			model:PivotTo(blockPose(dip))
		end
	end

	RunService:BindToRenderStep(RENDER_STEP, RENDER_PRIORITY, step)
	Players.PlayerRemoving:Connect(clear)
end

--[[
	Where the barrel of `player`'s held gun ends (render studs): the local player's gun in the
	first-person view through the world camera, else the gun in their hand (or in true first
	person at the camera) as last placed; nil when no gun of theirs is drawn.
]]
function HeldItems.muzzle(player: Player): Vector3?
	if player == Players.LocalPlayer and handGun then
		local view = workspace.CurrentCamera
		return view.CFrame * ItemModels.firearmPoint(handGunItem, handGunKey, handGunSize, handGunPivot, "muzzle")
	end
	local current = held[player]
	if current == nil or not current.firearm then
		return nil
	end
	-- (True first person: where it is drawn this frame, with this frame's camera.)
	local relative = current.relative
	local pivot = if relative then workspace.CurrentCamera.CFrame * relative else current.pivot
	if pivot then
		return ItemModels.firearmPoint(current.item, current.key, current.size, pivot, "muzzle")
	end
	return nil
end

return HeldItems
