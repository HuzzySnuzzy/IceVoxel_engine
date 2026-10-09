--!strict
--[[
	What every character wears, drawn on their body: armor and Terraria's vanity armor and
	accessories (Inventory/Types' equipment; the rules of what shows are Items/Accessories.looks).

	  Source     the server sets the player attribute Types.LOOKS_ATTRIBUTE on every snapshot that
	             changes it ("head,chest,legs,feet,accessories...": vanity over armor, hidden slots
	             left out, only accessories with a `worn` place); every client draws the pieces
	             itself (anchored, inert, moved with the body each frame), so nothing extra
	             replicates. The local player's comes from the predicted inventory (Inventory/
	             ClientInventory), so a piece put on shows at once.
	  Armor      Minecraft's armor layers: a box a little larger than each body part it covers, in
	             the item's colour and material (ItemList `color`, `material`): a helmet over the
	             Head; a chestplate over the UpperTorso, LowerTorso and both arms; leggings over
	             the LowerTorso and both legs; boots over both feet and lower legs (R6 rigs:
	             Torso, the arms, the legs, the bottom of the legs). Each layer is a little larger
	             than the one under it (boots over leggings), so they never fight. A vanity item
	             that is no armor (the Top Hat) is its own model (Rendering/ItemModels) sitting on
	             the head; vanity chest and leg pieces are boxes like armor.
	  Accessories  their ItemModels models at their `worn` place: Feet on both feet, Hand on the
	             left hand (the right one holds the held item: Player/HeldItems), Back behind the
	             upper torso, Waist at the right hip, Face over the face, Head on top, Neck at the
	             throat. A second one at the same place moves a step along (up the leg, round the
	             waist...), so two never sit in each other.
	  Frames     one render step after the characters are placed (RemotePlayers' and the local
	             controller's run before the camera; this runs after it, RENDER_STEP) moves every
	             piece with one workspace:BulkMoveTo: no allocation but the CFrames. Pieces are
	             built again when the looks change, the character is a new one, a body part's size
	             changes (an avatar scaled after loading) or item looks change
	             (ItemModels.generation).
	  Hidden     for spectators (invisible or a floating head: Player/SpectatorRules), dead bodies,
	             players this client doesn't show (Player/RemotePlayers.shown), and, with the
	             character's head faded out by the camera, the local player in first person (and the
	             player a spectator spectates): LocalTransparencyModifier, as Player/HeldItems.
	  Air jumps  `airJump(x, y, z)` puffs a little cloud at the feet and plays
	             entity.player.double_jump (the local player's Player/MovementController calls it
	             on PlayerPhysics' `airJumped`); other players' are told from their poses
	             (Player/AirJumps).
	  Preview    `dress(model, looks)` puts the pieces on a still copy of a character (the
	             inventory's preview, Ui/InventoryScreen), inside it so they turn with it.

	The pieces are in a Folder under the camera, in the render frame the characters are placed in,
	so a move of the render origin needs nothing here (they follow the body parts every frame).
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Accessories = require(Shared.Items.Accessories)
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Origin = require(Shared.World.Origin)
local Types = require(Shared.Inventory.Types)

local ItemModels = require(script.Parent.Parent.Rendering.ItemModels)
local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
local AirJumps = require(script.Parent.AirJumps)
local RemotePlayers = require(script.Parent.RemotePlayers)

local BLOCK = Config.BlockSize
-- After the camera (the characters are placed before it).
local RENDER_STEP = "IceVoxelEquipmentLooks"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1
-- Studs each armor layer stands off its body part (head, chest, legs, feet), boots over leggings.
local LAYER_PAD = { 0.22, 0.16, 0.12, 0.2 }
-- Model sizes are rounded to this (studs), so ItemModels' prototype cache stays small.
local SIZE_STEP = 0.05
-- The puff of an air jump: balls, their size and the seconds it lasts.
local PUFF_BALLS = 6
local PUFF_SIZE = 0.35 * BLOCK
local PUFF_SECONDS = 0.35

-- Body parts by role, R15 name first, then R6's.
local PARTS: { [string]: { string } } = {
	Head = { "Head" },
	UpperTorso = { "UpperTorso", "Torso" },
	LowerTorso = { "LowerTorso" },
	LeftUpperArm = { "LeftUpperArm", "Left Arm" },
	RightUpperArm = { "RightUpperArm", "Right Arm" },
	LeftLowerArm = { "LeftLowerArm" },
	RightLowerArm = { "RightLowerArm" },
	LeftHand = { "LeftHand", "Left Arm" },
	LeftUpperLeg = { "LeftUpperLeg", "Left Leg" },
	RightUpperLeg = { "RightUpperLeg", "Right Leg" },
	LeftLowerLeg = { "LeftLowerLeg" },
	RightLowerLeg = { "RightLowerLeg" },
	LeftFoot = { "LeftFoot", "Left Leg" },
	RightFoot = { "RightFoot", "Right Leg" },
}

-- The body parts each armor slot covers (head, chest, legs, feet).
local LAYERS: { { string } } = {
	{ "Head" },
	{ "UpperTorso", "LowerTorso", "LeftUpperArm", "RightUpperArm", "LeftLowerArm", "RightLowerArm" },
	{ "LowerTorso", "LeftUpperLeg", "RightUpperLeg", "LeftLowerLeg", "RightLowerLeg" },
	{ "LeftFoot", "RightFoot", "LeftLowerLeg", "RightLowerLeg" },
}

-- One drawn piece: its parts, each at `offsets[i]` from the anchor part's CFrame times `at`.
type Piece = {
	anchor: BasePart,
	-- The anchor's size when built (rebuilt when it changes).
	size: Vector3,
	parts: { BasePart },
	offsets: { CFrame },
}

-- A character's pieces: what they show (`looks` text), on which body, built with which item
-- looks, and whether they are faded out (first person).
type Dressed = {
	looks: string,
	character: Model,
	pieces: { Piece },
	folder: Folder,
	look: number,
	hidden: boolean,
}

local EquipmentLooks = {}

local localPlayer = Players.LocalPlayer
local folder: Folder? = nil
local dressed: { [Player]: Dressed } = {}
local watches: { [Player]: AirJumps.Watch } = {}
-- The local player's looks from the predicted inventory (on ClientInventory.changed).
local localLooks = "0,0,0,0"
-- Reused every frame by the BulkMoveTo.
local moveParts: { BasePart } = {}
local moveFrames: { CFrame } = {}

local function inert(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
end

local function material(name: string): Enum.Material
	local ok, value = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	return if ok and value then value else Enum.Material.SmoothPlastic
end

-- The body part playing `role` (R15 first, then R6), if the character has it.
local function partOf(character: Model, role: string): BasePart?
	local names = PARTS[role]
	if names == nil then
		return nil
	end
	for _, name in names do
		local part = character:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			return part
		end
	end
	return nil
end

local function round(size: number): number
	return math.max(SIZE_STEP, math.floor(size / SIZE_STEP + 0.5) * SIZE_STEP)
end

-- A piece made of `model` (an ItemModels model) at `at` from `anchor`.
local function modelPiece(model: Model, anchor: BasePart, at: CFrame, parent: Instance): Piece
	local parts: { BasePart } = {}
	local offsets: { CFrame } = {}
	local pivot = model:GetPivot()
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			inert(part)
			table.insert(parts, part)
			table.insert(offsets, at * pivot:ToObjectSpace(part.CFrame))
		end
	end
	model.Parent = parent
	return { anchor = anchor, size = anchor.Size, parts = parts, offsets = offsets }
end

--[[
	An armor layer's box over `anchor` (`fraction` of its height from the bottom: an R6 leg's
	boot; nil the whole part), `pad` studs off it, in `item`'s colour and material.
]]
local function layerPiece(item: number, anchor: BasePart, pad: number, parent: Instance, fraction: number?): Piece
	local def = Items.get(item)
	local rgb = if def then def.color else { 128, 128, 128 }
	local box = Instance.new("Part")
	inert(box)
	box.Name = "Layer"
	box.TopSurface, box.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
	box.Color = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
	box.Material = material(if def then def.material else "SmoothPlastic")
	local size = anchor.Size
	local share = fraction or 1
	box.Size = Vector3.new(size.X + pad, size.Y * share + pad, size.Z + pad)
	box.Parent = parent
	local at = CFrame.new(0, -size.Y * (1 - share) / 2, 0)
	return { anchor = anchor, size = anchor.Size, parts = { box }, offsets = { at } }
end

-- Where accessory number `k` (0 first) at `place` sits on `character`: its anchor, offset, size.
local function placeOf(character: Model, place: string, k: number, side: number): (BasePart?, CFrame, number)
	if place == "Feet" then
		-- (Both feet: `side` -1 left, 1 right; more go up the legs.)
		local foot = partOf(character, if side < 0 then "LeftFoot" else "RightFoot")
		if foot == nil then
			return nil, CFrame.identity, 0
		end
		local size = math.max(foot.Size.X, foot.Size.Z) * 1.05
		return foot, CFrame.new(0, k * size * 0.55, 0), size
	elseif place == "Hand" then
		local hand = partOf(character, "LeftHand")
		if hand == nil then
			return nil, CFrame.identity, 0
		end
		local size = math.max(hand.Size.X, hand.Size.Z) * 1.4
		-- (An R6 arm's hand is its bottom.)
		local low = if hand.Name == "Left Arm" then -hand.Size.Y * 0.4 else 0
		return hand, CFrame.new(-hand.Size.X * 0.3, low + k * size * 0.6, 0), size
	elseif place == "Back" then
		local torso = partOf(character, "UpperTorso")
		if torso == nil then
			return nil, CFrame.identity, 0
		end
		local size = torso.Size.X * 0.7
		local x = if k == 0 then 0 else (if k % 2 == 1 then -1 else 1) * size * 0.6
		return torso, CFrame.new(x, torso.Size.Y * 0.35, torso.Size.Z / 2 + size * 0.45), size
	elseif place == "Waist" then
		local hips = partOf(character, "LowerTorso") or partOf(character, "UpperTorso")
		if hips == nil then
			return nil, CFrame.identity, 0
		end
		local size = hips.Size.X * 0.45
		local y = if hips.Name == "Torso" then -hips.Size.Y * 0.35 else 0
		-- (Round the waist: right hip, left hip, back.)
		local spots =
			{ CFrame.new(hips.Size.X / 2 + size * 0.3, y, 0), CFrame.new(-hips.Size.X / 2 - size * 0.3, y, 0) }
		return hips, spots[k % 2 + 1] * CFrame.new(0, 0, (k // 2) * size * 0.8), size
	elseif place == "Face" then
		local head = partOf(character, "Head")
		if head == nil then
			return nil, CFrame.identity, 0
		end
		local size = head.Size.X * 0.95
		return head, CFrame.new(0, 0, -head.Size.Z / 2 - size * 0.1 - k * size * 0.3), size
	elseif place == "Head" then
		local head = partOf(character, "Head")
		if head == nil then
			return nil, CFrame.identity, 0
		end
		local size = head.Size.X
		return head, CFrame.new(0, head.Size.Y / 2 + size * (0.3 + 0.5 * k), 0), size
	elseif place == "Neck" then
		local torso = partOf(character, "UpperTorso")
		if torso == nil then
			return nil, CFrame.identity, 0
		end
		local size = torso.Size.X * 0.35
		return torso, CFrame.new(0, torso.Size.Y / 2 - size * (0.3 + 0.6 * k), -torso.Size.Z / 2 - size * 0.2), size
	end
	return nil, CFrame.identity, 0
end

-- The pieces `ids` (Accessories.parseLooks) put on `character`, their parts parented to `parent`.
local function build(character: Model, ids: { number }, parent: Instance): { Piece }
	local pieces: { Piece } = {}
	for slot = 1, Types.ARMOR_SIZE do
		local item = ids[slot]
		if item and item ~= 0 then
			if slot == 1 and Items.armorSlot(item) == nil then
				-- A vanity hat: its own model on the head.
				local head = partOf(character, "Head")
				if head then
					local size = round(head.Size.X * 1.15)
					local model = ItemModels.build(item, size)
					table.insert(pieces, modelPiece(model, head, CFrame.new(0, head.Size.Y * 0.45, 0), parent))
				end
			else
				local seen: { [BasePart]: boolean } = {}
				for _, role in LAYERS[slot] do
					local part = partOf(character, role)
					if part and not seen[part] then
						seen[part] = true
						-- (An R6 leg wears boots on its lower third.)
						local fraction = if slot == 4 and (part.Name == "Left Leg" or part.Name == "Right Leg")
							then 0.3
							else nil
						table.insert(pieces, layerPiece(item, part, LAYER_PAD[slot], parent, fraction))
					end
				end
			end
		end
	end
	local count: { [string]: number } = {}
	for index = Types.ARMOR_SIZE + 1, #ids do
		local item = ids[index]
		local accessory = Items.accessory(item)
		local place = accessory and accessory.worn
		if place then
			local k = count[place] or 0
			count[place] = k + 1
			for _, side in (if place == "Feet" then { -1, 1 } else { 1 }) :: { number } do
				local anchor, at, size = placeOf(character, place, k, side)
				if anchor and size > 0 then
					local model = ItemModels.build(item, round(size))
					table.insert(pieces, modelPiece(model, anchor, at, parent))
				end
			end
		end
	end
	return pieces
end

-- Takes `player`'s pieces off.
local function clear(player: Player)
	local current = dressed[player]
	if current then
		current.folder:Destroy()
		dressed[player] = nil
	end
end

-- The looks text `player` wears now ("" draws nothing).
local function looksOf(player: Player): string
	if GameMode.isSpectator(GameMode.of(player)) then
		return ""
	end
	if player == localPlayer then
		return localLooks
	end
	if not RemotePlayers.shown(player) then
		return ""
	end
	local looks = player:GetAttribute(Types.LOOKS_ATTRIBUTE)
	return if type(looks) == "string" then looks else ""
end

-- Has any anchor's size changed since its piece was built (an avatar scaled after loading)?
local function resized(current: Dressed): boolean
	for _, piece in current.pieces do
		if piece.anchor.Size ~= piece.size or piece.anchor.Parent == nil then
			return true
		end
	end
	return false
end

-- The pieces of one character, (re)built when needed; adds its parts and CFrames to the move.
local function update(player: Player, root: Folder)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local looks = looksOf(player)
	if character == nil or humanoid == nil or humanoid.Health <= 0 or looks == "" or looks == "0,0,0,0" then
		clear(player)
		return
	end
	local look = ItemModels.generation()
	local current = dressed[player]
	if
		current == nil
		or current.looks ~= looks
		or current.character ~= character
		or current.look ~= look
		or resized(current)
	then
		clear(player)
		local holder = Instance.new("Folder")
		holder.Name = player.Name
		holder.Parent = root
		current = {
			looks = looks,
			character = character,
			pieces = build(character, Accessories.parseLooks(looks), holder),
			folder = holder,
			look = look,
			hidden = false,
		}
		dressed[player] = current
	end
	assert(current, "dressed")
	-- (Faded with the head in first person, as Player/HeldItems.)
	local head = character:FindFirstChild("Head")
	local hidden = head ~= nil and head:IsA("BasePart") and head.LocalTransparencyModifier > 0.5
	if hidden ~= current.hidden then
		current.hidden = hidden
		for _, piece in current.pieces do
			for _, part in piece.parts do
				part.LocalTransparencyModifier = if hidden then 1 else 0
			end
		end
	end
	for _, piece in current.pieces do
		local at = piece.anchor.CFrame
		local offsets = piece.offsets
		for i, part in piece.parts do
			table.insert(moveParts, part)
			table.insert(moveFrames, at * offsets[i])
		end
	end
end

-- A little cloud at (x, y, z) (feet, blocks): an air jump.
local function puff(x: number, y: number, z: number)
	local root = folder
	if root == nil then
		return
	end
	local centre = Origin.blocksToRender(x, y, z)
	for i = 1, PUFF_BALLS do
		local angle = i / PUFF_BALLS * math.pi * 2
		local ball = Instance.new("Part")
		inert(ball)
		ball.Shape = Enum.PartType.Ball
		ball.Material = Enum.Material.SmoothPlastic
		ball.Color = Color3.new(1, 1, 1)
		ball.Transparency = 0.2
		ball.Size = Vector3.one * PUFF_SIZE
		ball.CFrame = CFrame.new(centre + Vector3.new(math.cos(angle), 0, math.sin(angle)) * PUFF_SIZE * 0.6)
		ball.Parent = root
		local out = Vector3.new(math.cos(angle), -0.3, math.sin(angle)) * PUFF_SIZE * 1.6
		TweenService:Create(ball, TweenInfo.new(PUFF_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			CFrame = ball.CFrame + out,
			Size = Vector3.one * PUFF_SIZE * 1.8,
			Transparency = 1,
		}):Play()
		Debris:AddItem(ball, PUFF_SECONDS + 0.05)
	end
end

--[[
	An air jump at (x, y, z) (feet, blocks): Terraria's puff of cloud and its sound
	(entity.player.double_jump), heard by this player only (every client plays others' itself).
]]
function EquipmentLooks.airJump(x: number, y: number, z: number)
	SoundPlayer.play("entity.player.double_jump", x, y, z)
	puff(x, y, z)
end

--[[
	Puts the pieces of `looks` (Types.LOOKS_ATTRIBUTE's text, Accessories.looks) on `model`, a
	still copy of a character (the inventory's preview): parented inside it, so they turn with it.
	Returns the Folder holding them (destroy it to take them off).
]]
function EquipmentLooks.dress(model: Model, looks: string): Folder
	local holder = Instance.new("Folder")
	holder.Name = "IceVoxelLooks"
	for _, piece in build(model, Accessories.parseLooks(looks), holder) do
		local at = piece.anchor.CFrame
		for i, part in piece.parts do
			part.CFrame = at * piece.offsets[i]
		end
	end
	holder.Parent = model
	return holder
end

function EquipmentLooks.start()
	if folder then
		return
	end
	local root = Instance.new("Folder")
	root.Name = "IceVoxelEquipmentLooks"
	root.Parent = workspace.CurrentCamera
	folder = root

	local function refreshLocal()
		localLooks = Accessories.looks(ClientInventory.inventory())
	end
	refreshLocal()
	ClientInventory.changed:Connect(refreshLocal)

	RunService:BindToRenderStep(RENDER_STEP, RENDER_PRIORITY, function()
		table.clear(moveParts)
		table.clear(moveFrames)
		local now = os.clock()
		for _, player in Players:GetPlayers() do
			update(player, root)
			-- Other players' air jumps, from their poses.
			if player ~= localPlayer then
				local remote = RemotePlayers.get(player)
				if remote and RemotePlayers.shown(player) then
					local watch = watches[player]
					if watch == nil then
						watch = AirJumps.new()
						watches[player] = watch
					end
					if AirJumps.step(watch, remote.flags, remote.y, now) then
						EquipmentLooks.airJump(remote.x, remote.y, remote.z)
					end
				elseif watches[player] then
					watches[player] = nil
				end
			end
		end
		if #moveParts > 0 then
			workspace:BulkMoveTo(moveParts, moveFrames, Enum.BulkMoveMode.FireCFrameChanged)
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		clear(player)
		watches[player] = nil
	end)
end

return EquipmentLooks
