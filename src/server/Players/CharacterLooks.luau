--!strict
--[[
	A character's R15 look on Roblox's side (Shared/Characters/Appearance is the look itself): the
	user's own avatar read as a look, a look made into a HumanoidDescription for spawning, and
	the preview rigs the title screen shows (client Ui/CharacterSelect, Ui/AvatarEditor).

	  Snapshot   `snapshot(player)`: Players:GetHumanoidDescriptionFromUserIdAsync(userId) (the
	             Async name, else the older one; under pcall) read as a look, everything worn as
	             the user wears it: the body parts, face, classic clothing and animations
	             (Appearance.KIND 1..18: a property not 0), the accessories (GetAccessories with
	             rigid ones: kind ACCESSORY + Enum.AccessoryType's value, layered, order,
	             puffiness), the six body colours and the scales (clamped to
	             Config.Characters.Scales), at most Config.Characters.MaxAssets things. Read once
	             a session per player (cached). When it fails (Studio's test players have negative
	             ids; the web call can fail) the look is Appearance.default(): a plain blocky R15.
	  Spawning   `description(look)`: a new HumanoidDescription with the look's colours, scales,
	             its worn parts, face, clothing and animations (a body part not worn is 0: the
	             plain blocky part) and its worn accessories (SetAccessories, rigid ones
	             included). Players/WorldMenu spawns with it (Player
	             :LoadCharacterWithHumanoidDescriptionAsync), and with the title screen off
	             Players/CharacterStore applies it once (Humanoid:ApplyDescriptionResetAsync).
	             `fields` / `fromFields` are the same mapping without Roblox (the specs run them).
	  Previews   `preview(player, name, look)`: a rig built on the server with
	             Players:CreateHumanoidModelFromDescriptionAsync(description, R15) (Roblox only
	             builds avatars there), its scripts taken out and its parts anchored, put in a
	             folder "IceVoxelPreviews" in the player's PlayerGui (only that player's client
	             receives it) as "c<id>" (a character in the list) or "editor" (the avatar
	             editor's). The client clones it into its ViewportFrame. A request waits
	             Config.Characters.PreviewDelay seconds for the next (a slider dragged: only the
	             last look is built), one build at a time per player, and a look already built
	             under that name is not built again.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Appearance = require(Shared.Characters.Appearance)
local Config = require(Shared.Config)

type Appearance = Appearance.Appearance

-- An accessory as HumanoidDescription:SetAccessories takes it (AccessoryType as its number).
export type AccessoryField = {
	AssetId: number,
	AccessoryType: number,
	IsLayered: boolean,
	Order: number,
	Puffiness: number,
}

-- A look as HumanoidDescription's properties (colours 0xRRGGBB).
export type Fields = {
	colors: { [string]: number },
	scales: { [string]: number },
	properties: { [string]: number },
	accessories: { AccessoryField },
}

local CharacterLooks = {}

-- The PlayerGui folder holding a player's preview rigs.
CharacterLooks.FOLDER = "IceVoxelPreviews"
-- The avatar editor's rig's name (a listed character's is "c<id>").
CharacterLooks.EDITOR = "editor"

--[[ The mapping (pure) ]]

-- `look` as HumanoidDescription's properties (see the header).
function CharacterLooks.fields(look: Appearance): Fields
	local colors: { [string]: number } = {}
	for i, part in Appearance.PARTS do
		colors[`{part}Color`] = look.colors[i] or 0
	end
	local scales: { [string]: number } = {}
	local clamped = Appearance.clampScales(look.scales) :: any
	for _, name in Appearance.SCALES do
		scales[Appearance.SCALE_PROPERTY[name]] = clamped[name]
	end
	local properties: { [string]: number } = {}
	for kind, name in Appearance.PROPERTY do
		properties[name] = 0
		for _, asset in look.assets do
			if asset.kind == kind and asset.worn then
				properties[name] = asset.id
				break
			end
		end
	end
	local accessories: { AccessoryField } = {}
	for _, asset in look.assets do
		if asset.worn and Appearance.isAccessory(asset.kind) then
			table.insert(accessories, {
				AssetId = asset.id,
				AccessoryType = asset.kind - Appearance.ACCESSORY,
				IsLayered = asset.layered,
				Order = asset.order,
				Puffiness = asset.puffiness,
			})
		end
	end
	return { colors = colors, scales = scales, properties = properties, accessories = accessories }
end

local function wholeId(value: unknown): number?
	if type(value) == "number" and value >= 1 and value <= 2 ^ 53 and value == math.floor(value) then
		return value
	end
	return nil
end

--[[
	The look HumanoidDescription properties describe, everything worn (a user's own avatar), at
	most Config.Characters.MaxAssets things: properties first (parts, face, clothing, animations),
	then accessories.
]]
function CharacterLooks.fromFields(fields: Fields): Appearance
	local look = Appearance.default()
	for i, part in Appearance.PARTS do
		local color = fields.colors[`{part}Color`]
		if type(color) == "number" and color >= 0 and color <= 0xFFFFFF then
			look.colors[i] = math.floor(color)
		end
	end
	local scales: { [string]: number } = {}
	for _, name in Appearance.SCALES do
		scales[name] = fields.scales[Appearance.SCALE_PROPERTY[name]]
	end
	look.scales = Appearance.clampScales(scales)
	local most = math.clamp(math.floor(Config.Characters.MaxAssets), 0, Appearance.MAX_ASSETS)
	for kind = 1, #Appearance.PROPERTY do
		local assetId = wholeId(fields.properties[Appearance.PROPERTY[kind]])
		if assetId and #look.assets < most then
			table.insert(look.assets, {
				kind = kind,
				id = assetId,
				worn = true,
				layered = false,
				order = 0,
				puffiness = 1,
			})
		end
	end
	for _, accessory in fields.accessories do
		local assetId = wholeId(accessory.AssetId)
		local kind = Appearance.ACCESSORY + (tonumber(accessory.AccessoryType) or 0)
		if assetId and Appearance.isAccessory(kind) and #look.assets < most then
			local order = tonumber(accessory.Order) or 0
			local puffiness = tonumber(accessory.Puffiness) or 1
			table.insert(look.assets, {
				kind = kind,
				id = assetId,
				worn = true,
				layered = accessory.IsLayered == true,
				order = math.clamp(math.floor(order), 0, 255),
				puffiness = math.clamp(puffiness, 0, 2.55),
			})
		end
	end
	return look
end

--[[ Roblox ]]

local function toColor3(rgb: number): Color3
	return Color3.fromRGB(bit32.rshift(rgb, 16), bit32.band(bit32.rshift(rgb, 8), 0xFF), bit32.band(rgb, 0xFF))
end

local function fromColor3(color: Color3): number
	local r = math.clamp(math.round(color.R * 255), 0, 255)
	local g = math.clamp(math.round(color.G * 255), 0, 255)
	local b = math.clamp(math.round(color.B * 255), 0, 255)
	return r * 65536 + g * 256 + b
end

-- Enum.AccessoryType by value (made on first use: the specs load this module without Roblox).
local accessoryTypes: { [number]: Enum.AccessoryType }? = nil
local function accessoryType(value: number): Enum.AccessoryType?
	local types = accessoryTypes
	if types == nil then
		local made: { [number]: Enum.AccessoryType } = {}
		for _, item in Enum.AccessoryType:GetEnumItems() do
			made[item.Value] = item
		end
		accessoryTypes = made
		types = made
	end
	return (types :: { [number]: Enum.AccessoryType })[value]
end

-- Calls `object`'s method `name` (else `older`, Roblox's previous name for it) under pcall.
local function callAsync(object: any, name: string, older: string, ...: any): (boolean, any)
	local found, method = pcall(function(): any
		return object[name]
	end)
	if not (found and type(method) == "function") then
		found, method = pcall(function(): any
			return object[older]
		end)
	end
	if not (found and type(method) == "function") then
		return false, `{name} is not available`
	end
	return pcall(method, object, ...)
end

-- The look a HumanoidDescription describes (see `fromFields`).
function CharacterLooks.fromDescription(description: HumanoidDescription): Appearance
	local desc = description :: any
	local colors: { [string]: number } = {}
	for _, part in Appearance.PARTS do
		local ok, color = pcall(function(): any
			return desc[`{part}Color`]
		end)
		if ok and typeof(color) == "Color3" then
			colors[`{part}Color`] = fromColor3(color)
		end
	end
	local scales: { [string]: number } = {}
	for _, property in Appearance.SCALE_PROPERTY do
		local ok, value = pcall(function(): any
			return desc[property]
		end)
		if ok and type(value) == "number" then
			scales[property] = value
		end
	end
	local properties: { [string]: number } = {}
	for _, name in Appearance.PROPERTY do
		local ok, value = pcall(function(): any
			return desc[name]
		end)
		if ok and type(value) == "number" then
			properties[name] = value
		end
	end
	local accessories: { AccessoryField } = {}
	local ok, list = pcall(function(): any
		return description:GetAccessories(true)
	end)
	if ok and type(list) == "table" then
		for _, entry in list do
			local kind = entry.AccessoryType
			table.insert(accessories, {
				AssetId = entry.AssetId,
				AccessoryType = if typeof(kind) == "EnumItem" then kind.Value else 0,
				IsLayered = entry.IsLayered == true,
				Order = tonumber(entry.Order) or 0,
				Puffiness = tonumber(entry.Puffiness) or 1,
			})
		end
	end
	return CharacterLooks.fromFields({
		colors = colors,
		scales = scales,
		properties = properties,
		accessories = accessories,
	})
end

-- A new HumanoidDescription of `look` (see the header).
function CharacterLooks.description(look: Appearance): HumanoidDescription
	local fields = CharacterLooks.fields(look)
	local description = Instance.new("HumanoidDescription")
	local desc = description :: any
	for property, rgb in fields.colors do
		desc[property] = toColor3(rgb)
	end
	for property, value in fields.scales do
		desc[property] = value
	end
	for property, value in fields.properties do
		pcall(function()
			desc[property] = value
		end)
	end
	local accessories = {}
	for _, accessory in fields.accessories do
		local kind = accessoryType(accessory.AccessoryType)
		if kind then
			table.insert(accessories, {
				AssetId = accessory.AssetId,
				AccessoryType = kind,
				IsLayered = accessory.IsLayered,
				Order = accessory.Order,
				Puffiness = accessory.Puffiness,
			})
		end
	end
	local ok, err = pcall(function()
		description:SetAccessories(accessories, true)
	end)
	if not ok then
		warn(`[IceVoxel] a character's accessories could not be set: {err}`)
	end
	return description
end

--[[ Snapshots ]]

local snapshots: { [Player]: Appearance } = {}
local reading: { [Player]: boolean } = {}

--[[
	`player`'s own avatar as a look (see the header): read once a session, the default look when
	it can't be read. Yields the first time.
]]
function CharacterLooks.snapshot(player: Player): Appearance
	local cached = snapshots[player]
	if cached then
		return Appearance.copy(cached)
	end
	while reading[player] do
		task.wait(0.1)
		cached = snapshots[player]
		if cached then
			return Appearance.copy(cached)
		end
	end
	reading[player] = true
	local look = Appearance.default()
	local ok, description =
		callAsync(Players, "GetHumanoidDescriptionFromUserIdAsync", "GetHumanoidDescriptionFromUserId", player.UserId)
	if ok and typeof(description) == "Instance" and description:IsA("HumanoidDescription") then
		look = CharacterLooks.fromDescription(description)
		description:Destroy()
	else
		warn(`[IceVoxel] the avatar of {player.Name} could not be read ({description}): a plain one is used`)
	end
	reading[player] = nil
	if player.Parent then
		snapshots[player] = look
	end
	return Appearance.copy(look)
end

--[[ Preview rigs ]]

type Pending = { name: string, look: Appearance, key: string }
type Previews = {
	-- The latest request per rig name, built after PreviewDelay.
	pending: { [string]: Pending },
	-- The look each rig name was last built with (Appearance bytes as text).
	built: { [string]: string },
	running: boolean,
	-- os.clock of the latest request (a build waits PreviewDelay after it).
	requestedAt: number,
}

local previews: { [Player]: Previews } = {}

local function keyOf(look: Appearance): string
	return buffer.tostring(Appearance.encode(look))
end

local function folderOf(player: Player): Folder?
	local gui = player:FindFirstChildOfClass("PlayerGui")
	if gui == nil then
		return nil
	end
	local folder = gui:FindFirstChild(CharacterLooks.FOLDER)
	if folder and folder:IsA("Folder") then
		return folder
	end
	local made = Instance.new("Folder")
	made.Name = CharacterLooks.FOLDER
	made.Parent = gui
	return made
end

-- Builds one preview rig of `look` as `name` in `player`'s folder (yields).
local function build(player: Player, name: string, look: Appearance): boolean
	local description = CharacterLooks.description(look)
	local ok, model = callAsync(
		Players,
		"CreateHumanoidModelFromDescriptionAsync",
		"CreateHumanoidModelFromDescription",
		description,
		Enum.HumanoidRigType.R15
	)
	description:Destroy()
	if not ok or typeof(model) ~= "Instance" or not model:IsA("Model") then
		warn(`[IceVoxel] a preview of {player.Name}'s character could not be built: {model}`)
		return false
	end
	local rig = model :: Model
	for _, descendant in rig:GetDescendants() do
		if descendant:IsA("BaseScript") or descendant:IsA("Sound") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		elseif descendant:IsA("Humanoid") then
			descendant.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end
	end
	local root = rig:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		rig.PrimaryPart = root
		root.Transparency = 1
	end
	rig.Name = name
	rig.Archivable = true
	local folder = folderOf(player)
	if folder == nil or player.Parent == nil then
		rig:Destroy()
		return false
	end
	local old = folder:FindFirstChild(name)
	if old then
		old:Destroy()
	end
	rig.Parent = folder
	return true
end

local function run(player: Player, state: Previews)
	state.running = true
	while player.Parent and previews[player] == state do
		local wait = state.requestedAt + Config.Characters.PreviewDelay - os.clock()
		if wait > 0 then
			task.wait(wait)
			continue
		end
		local name, request = next(state.pending)
		if name == nil or request == nil then
			break
		end
		state.pending[name] = nil
		if state.built[name] ~= request.key then
			if build(player, name, request.look) then
				state.built[name] = request.key
			end
		end
	end
	state.running = false
end

--[[
	Builds (soon: see the header) `player`'s preview rig `name` ("c<id>" or EDITOR) with `look`,
	unless that look is the one built under that name.
]]
function CharacterLooks.preview(player: Player, name: string, look: Appearance)
	local state = previews[player]
	if state == nil then
		state = { pending = {}, built = {}, running = false, requestedAt = 0 }
		previews[player] = state
	end
	local key = keyOf(look)
	if state.built[name] == key and state.pending[name] == nil then
		return
	end
	state.pending[name] = { name = name, look = Appearance.copy(look), key = key }
	state.requestedAt = os.clock()
	if not state.running then
		task.spawn(run, player, state)
	end
end

-- Takes `player`'s preview rigs away (they entered the world: the title screen is gone).
function CharacterLooks.clear(player: Player)
	previews[player] = nil
	local gui = player:FindFirstChildOfClass("PlayerGui")
	local folder = gui and gui:FindFirstChild(CharacterLooks.FOLDER)
	if folder then
		folder:Destroy()
	end
end

-- Forgets players who leave (call once).
function CharacterLooks.start()
	Players.PlayerRemoving:Connect(function(player: Player)
		snapshots[player] = nil
		reading[player] = nil
		previews[player] = nil
	end)
end

return CharacterLooks
