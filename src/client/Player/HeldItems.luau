--!strict
--[[
	The item each player holds (their selected hotbar slot), as Minecraft shows it:

	  third person  a small model of the item in every character's right hand. The server sets the
	                player attribute Types.HELD_ATTRIBUTE; every client draws the models itself
	                (anchored, inert, moved with the hand each frame), so nothing extra replicates.
	                The local player's comes from the predicted inventory, so it changes at once.
	  first person  the local player's item in the bottom right corner of the screen, in a
	                ViewportFrame, dipping in a short swing when breaking or placing (`swing`).

	Blocks and most items are held turned like a block. Tools and sticks are held like Minecraft's
	"handheld" items (ItemModels.handPivot / holdPivot): at the handle, upright rather than lying
	diagonally as in their icon. In third person they point forward and up from the fist; in first
	person they rise from the bottom right corner towards the middle, leaning left, their face to
	the camera, and chop forward when swinging. A melee weapon of the melee rework (Shared/Weapons
	.melee) is also held across the chest while guarding and drawn back over the shoulder as a heavy
	attack winds up (Interaction/MeleeInput.guarding and .charge: Player/WeaponPoses.applyMelee in
	third person, other players' guard from Types.AIM_ATTRIBUTE; AimRules.meleeView in first
	person).

	Firearms (Shared/Weapons), in the manner of DayZ:
	  third person  the gun dressed as it is (ItemModels.buildFirearm: magazine, optic, muzzle
	                device, light; the look key from the predicted inventory for the local player,
	                the player attribute Types.HELD_LOOK_ATTRIBUTE for the others), built at
	                ItemModels.firearmSize, held at the grip in the right hand, which Player/
	                WeaponPoses posed first (lowered across the body or raised along the look: the
	                local player's posture from Player/AimCamera at once, the others' from
	                Types.AIM_ATTRIBUTE; the pitch from Player/MovementController or Player/
	                RemotePlayers). Its weapon light shines from the model (the local player's with
	                shadows, Roblox's lights shine through a hidden model too, so in first person it
	                lights where the raised gun points).
	  first person  the viewport covers the whole screen and its camera takes the world camera's
	                field of view every frame, so a point posed in front of it lands where the same
	                point in front of the world camera would: the gun low on the right, its barrel
	                towards the screen's centre (AimRules.hipPose), or in the sights (Player/
	                AimCamera.sightsView: first person raised, or V in third person, where the view
	                is the eyes' too) with its sight line on the view axis, eased between the two
	                (through a mounted optic's middle, the optic itself hidden there: Ui/WeaponHud
	                draws a red dot's dot); a shot kicks it back and up (`kick`, AimRules
	                .modelKick). A scope's zoom (AimCamera.scoped) hides it: Ui/WeaponHud draws the
	                scope.
	  muzzle        `muzzle(player)`: where a held gun's barrel ends in the world (render studs; the
	                local player's in first person through the viewport's pose, by the world
	                camera), for Rendering/ShotView's flashes and tracers.

	Models are built again when item looks change (ItemModels.generation: the Textures setting,
	texture averages measured a few seconds after joining).

	Nothing is drawn for an empty hand or while a Tool is equipped, nor for spectators (Shared/
	GameMode): their body is invisible or a floating head (Player/SpectatorRules), and in first
	person they have no hand. Nor for a player whose character isn't shown on this client (Player/
	RemotePlayers.shown: with the server's own positions, one it doesn't send this client, parked
	far away, or a body gone after its death). A third person model hides with its character's
	head when the camera fades that out: the local player's in first person, and the player a
	spectator spectates, whose eyes the camera is in (Roblox fades the camera subject's
	character). The models follow the hands every frame (PivotTo, in the render frame the
	characters are placed in), so a move of the render origin needs nothing here.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local GameMode = require(Shared.GameMode)
local Types = require(Shared.Inventory.Types)
local WeaponState = require(Shared.Weapons.WeaponState)
local Weapons = require(Shared.Weapons)

local ItemModels = require(script.Parent.Parent.Rendering.ItemModels)
local MeleeInput = require(script.Parent.Parent.Interaction.MeleeInput)
local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local Screens = require(script.Parent.Parent.Ui.Screens)
local UiScale = require(script.Parent.Parent.Ui.UiScale)
local AimCamera = require(script.Parent.AimCamera)
local AimRules = require(script.Parent.AimRules)
local MovementController = require(script.Parent.MovementController)
local RemotePlayers = require(script.Parent.RemotePlayers)
local WeaponPoses = require(script.Parent.WeaponPoses)

-- Minecraft's arm swing lasts 6 ticks.
local SWING_TIME = 0.3
-- The camera counts as first person this close (studs) to its focus.
local FIRST_PERSON_DISTANCE = 1
-- The corner view's field of view (non-firearms).
local CORNER_FOV = 40
-- How fast the first-person gun moves between the hip and the sights (per second).
local SIGHTS_RATE = 14

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
	`parts` and `hidden` let the first person hiding write only when it changes; `look`: the item
	look generation the model was built with; a firearm's look key, its size and the pivot it was
	last placed at (for its muzzle).
]]
type Held = {
	item: number,
	model: Model,
	parts: { BasePart },
	hidden: boolean,
	look: number,
	key: string,
	firearm: boolean,
	size: number,
	pivot: CFrame?,
}

local held: { [Player]: Held } = {}
-- The first-person gun: shown, its item, look key, size and pivot (the viewport camera's space).
local handGun = false
local handGunItem = 0
local handGunKey = ""
local handGunSize = 1
local handGunPivot = CFrame.identity

-- First person pose of a block (or any item but tools): `dip` is the swing, 0..1..0.
local function blockPose(dip: number): CFrame
	return CFrame.new(0.35 - 0.25 * dip, -0.45 - 0.2 * dip, -2.4)
		* CFrame.Angles(math.rad(-15 - 40 * dip), math.rad(40), math.rad(5))
end

--[[
	First person pose of a tool's upright view space, at its grip: low in the bottom right corner
	(the handle runs off the bottom), leaning left towards the middle, tipped away a little and
	turned so its face shows. Swinging chops it forward and down towards the middle.
]]
local function toolPose(dip: number): CFrame
	return CFrame.new(0.5 - 0.2 * dip, -0.62 - 0.1 * dip, -2.2)
		* CFrame.Angles(math.rad(-25 - 55 * dip), math.rad(-20), 0)
		* CFrame.Angles(0, 0, math.rad(30))
end

-- A gun's frame looking down the view axis: its barrel ahead (-Z), its top up.
local AHEAD = CFrame.fromMatrix(Vector3.zero, Vector3.new(0, 0, -1), Vector3.yAxis)
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

function HeldItems.start()
	local localPlayer = Players.LocalPlayer
	local folder = Instance.new("Folder")
	folder.Name = "IceVoxelHeldItems"
	folder.Parent = workspace.CurrentCamera

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
	local lastFrame = os.clock()

	RunService.RenderStepped:Connect(function()
		local now = os.clock()
		local dt = math.min(now - lastFrame, 0.1)
		lastFrame = now
		-- Third person: every character's hand.
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local item = itemOf(player)
			local gun = if item ~= 0 then Weapons.firearm(item) else nil
			local where: CFrame? = nil
			if character and gun then
				local posture: AimRules.Posture, pitch: number = aimOf(player)
				local long = AimRules.longGun(gun)
				WeaponPoses.apply(character, posture, pitch, long)
				local frame = WeaponPoses.gunFrame(character, posture, pitch, long)
				if frame then
					where = ItemModels.firearmPivot(item, ItemModels.firearmSize(item), "hand", frame)
				end
			elseif character and item ~= 0 then
				if Weapons.melee(item) then
					local guard, charge = meleeOf(player)
					WeaponPoses.applyMelee(character, guard, charge)
				else
					WeaponPoses.release(character)
				end
				where = ItemModels.handPivot(item, character)
			end
			if
				character == nil
				or humanoid == nil
				or humanoid.Health <= 0
				or item == 0
				or where == nil
				or character:FindFirstChildOfClass("Tool") ~= nil
			then
				if held[player] then
					clear(player)
				elseif character then
					WeaponPoses.release(character)
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
						elseif part:IsA("SpotLight") and player == localPlayer then
							-- (The local player's weapon light casts shadows; others' don't.)
							part.Shadows = true
						end
					end
					-- New parts are visible (LocalTransparencyModifier 0).
					current = {
						item = item,
						model = model,
						parts = parts,
						hidden = false,
						look = look,
						key = key,
						firearm = gun ~= nil,
						size = size,
						pivot = nil,
					}
					held[player] = current
				end
				assert(current and where, "held model")
				current.model:PivotTo(where)
				current.pivot = where
				-- Hidden with the camera subject's character in first person (Roblox hides the body
				-- there): the local player's, or the one a spectator spectates.
				local head = character:FindFirstChild("Head")
				local hidden = head ~= nil and head:IsA("BasePart") and head.LocalTransparencyModifier > 0.5
				if hidden ~= current.hidden then
					current.hidden = hidden
					for _, part in current.parts do
						part.LocalTransparencyModifier = if hidden then 1 else 0
					end
				end
			end
		end
		for player in held do
			if player.Parent == nil then
				clear(player)
			end
		end

		-- First person: the item in the corner, or the gun across the whole screen.
		local view = workspace.CurrentCamera
		local item = itemOf(localPlayer)
		local gun = if item ~= 0 then Weapons.firearm(item) else nil
		local firstPerson = if gun
			then AimCamera.eyesView()
			else (view.CFrame.Position - view.Focus.Position).Magnitude < FIRST_PERSON_DISTANCE
		local character = localPlayer.Character
		local show = firstPerson
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
			for _, part in model:GetChildren() do
				if part.Name == "Optic" and part:IsA("BasePart") then
					table.insert(opticParts, part)
				end
			end
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
		local t = math.clamp((now - swingStart) / SWING_TIME, 0, 1)
		local dip = math.sin(t * math.pi)
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
	end)

	Players.PlayerRemoving:Connect(clear)
end

--[[
	Where the barrel of `player`'s held gun ends (render studs): the local player's first-person
	gun through the world camera, else the gun in their hand as last placed; nil when no gun of
	theirs is drawn.
]]
function HeldItems.muzzle(player: Player): Vector3?
	if player == Players.LocalPlayer and handGun then
		local view = workspace.CurrentCamera
		return view.CFrame * ItemModels.firearmPoint(handGunItem, handGunKey, handGunSize, handGunPivot, "muzzle")
	end
	local current = held[player]
	local pivot = if current and current.firearm then current.pivot else nil
	if current and pivot then
		return ItemModels.firearmPoint(current.item, current.key, current.size, pivot, "muzzle")
	end
	return nil
end

return HeldItems
