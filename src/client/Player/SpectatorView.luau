--!strict
--[[
	Spectators as this player sees them (Player/SpectatorRules): every frame, after the camera,
	every spectator's character is made invisible for a player who is not spectating, or shown as a
	translucent floating head (what is worn on the head too) for one who is; their name and health
	display (Humanoid.DisplayDistanceType) is hidden while they are invisible. Not only parts: the
	decals on them (the face) and effects (SpectatorRules.HIDDEN_CLASSES), which go with the part
	they are on. The local spectator sees their own head the same way in third person, and nothing
	of themselves while spectating someone (their body is inside the other player's).

	Only LocalTransparencyModifier is changed (this client alone), never Transparency, and never
	below what something else set: the camera's first person fade sets the local character's own
	value, which is kept as the object's own and only ever raised. Objects and names are put back
	as soon as their player stops spectating (or this player starts).

	This is the one writer of other characters' visibility on this client. With the server's own
	positions (Config.Players.ServerPositions) the characters of players it doesn't send this
	client (Player/RemotePlayers: beyond Config.Interest.PlayerDistance, a spectator for a player
	who isn't one) stand parked far above the world: they are hidden whole, their name and health
	too, and their Highlight (the Glowing effect's outline, drawn through everything) is off. So
	is a dead body once its death tilt is over (RemotePlayers.shown; the local player's own:
	MovementController.deathTime), as Minecraft removes it at deathTime 20.

	What is hidden of a character (SpectatorRules.HIDDEN_CLASSES, the head and what is worn on it)
	is listed once and again only when its descendants change, so many hidden characters cost a
	walk of a list a frame, not GetDescendants.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local GameMode = require(Shared.GameMode)

local MovementController = require(script.Parent.MovementController)
local RemotePlayers = require(script.Parent.RemotePlayers)
local SpectatorRules = require(script.Parent.SpectatorRules)

-- After the camera (and its first person fade, which sets the local character's transparency).
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 2
-- LocalTransparencyModifier is stored as a float: values read back this close are the same.
local EPSILON = 1e-3

local SpectatorView = {}

-- An object made more transparent: its own value (as the camera or nothing left it) and what was
-- set.
type Tracked = { original: number, written: number }

-- What can be hidden of a character: its hideable objects, whether each is the head or worn on it,
-- and its Highlights; listed again when `dirty` (a descendant came or went).
type Cover = {
	objects: { Instance },
	heads: { boolean },
	highlights: { Highlight },
	dirty: boolean,
	connections: { RBXScriptConnection },
}

-- Whether objects of a class are hidden with their character (SpectatorRules.hidden), by ClassName.
local hiddenClasses: { [string]: boolean } = {}

local function hideable(object: Instance): boolean
	local known = hiddenClasses[object.ClassName]
	if known == nil then
		known = SpectatorRules.hidden(function(class: string): boolean
			return object:IsA(class)
		end)
		hiddenClasses[object.ClassName] = known
	end
	return known == true
end

-- (Every hideable class has a LocalTransparencyModifier; the types know it per class only.)
local function transparencyOf(object: Instance): number
	return (object :: any).LocalTransparencyModifier
end

local function setTransparency(object: Instance, value: number)
	(object :: any).LocalTransparencyModifier = value
end

-- The part an object is drawn with: itself, or the part it is on (a decal, an effect).
local function partOf(object: Instance): BasePart?
	if object:IsA("BasePart") then
		return object
	end
	return object:FindFirstAncestorWhichIsA("BasePart")
end

-- Is `part` the head, or worn on it (an accessory welded to the head)?
local function onHead(part: BasePart?, head: BasePart?): boolean
	if head == nil or part == nil then
		return false
	elseif part == head then
		return true
	end
	local accessory = part.Parent
	if accessory == nil or not accessory:IsA("Accessory") then
		return false
	end
	local weld = part:FindFirstChild("AccessoryWeld")
	if weld and weld:IsA("Weld") then
		return weld.Part0 == head or weld.Part1 == head
	elseif weld and weld:IsA("WeldConstraint") then
		return weld.Part0 == head or weld.Part1 == head
	end
	return false
end

function SpectatorView.start()
	local localPlayer = Players.LocalPlayer
	local tracked: { [Instance]: Tracked } = {}
	-- Humanoids whose name display is hidden, with how it was shown before.
	local hiddenNames: { [Humanoid]: Enum.HumanoidDisplayDistanceType } = {}
	local seen: { [Instance]: boolean } = {}
	local shownNames: { [Humanoid]: boolean } = {}

	local function apply(object: Instance, least: number)
		local current = transparencyOf(object)
		local record = tracked[object]
		if record == nil then
			record = { original = current, written = current }
			tracked[object] = record
		elseif math.abs(current - record.written) > EPSILON then
			-- Something else (the camera's fade) changed it: that is the object's own value now.
			record.original = current
		end
		local wanted = math.max(record.original, least)
		if math.abs(current - wanted) > EPSILON then
			setTransparency(object, wanted)
		end
		record.written = wanted
		seen[object] = true
	end

	-- The characters listed (Cover), and those used this frame; Highlights turned off here, and
	-- those still to be off this frame.
	local covers: { [Model]: Cover } = {}
	local usedCovers: { [Model]: boolean } = {}
	local disabled: { [Highlight]: boolean } = {}
	local stillOff: { [Highlight]: boolean } = {}

	local function coverOf(character: Model): Cover
		local cover = covers[character]
		if cover == nil then
			local made: Cover = { objects = {}, heads = {}, highlights = {}, dirty = true, connections = {} }
			local function changed()
				made.dirty = true
			end
			table.insert(made.connections, character.DescendantAdded:Connect(changed))
			table.insert(made.connections, character.DescendantRemoving:Connect(changed))
			covers[character] = made
			cover = made
		end
		assert(cover, "cover")
		if cover.dirty then
			cover.dirty = false
			table.clear(cover.objects)
			table.clear(cover.heads)
			table.clear(cover.highlights)
			local head = character:FindFirstChild("Head")
			local headPart = if head and head:IsA("BasePart") then head else nil
			for _, object in character:GetDescendants() do
				if hideable(object) then
					table.insert(cover.objects, object)
					table.insert(cover.heads, onHead(partOf(object), headPart))
				elseif object:IsA("Highlight") then
					table.insert(cover.highlights, object)
				end
			end
		end
		usedCovers[character] = true
		return cover
	end

	RunService:BindToRenderStep("IceVoxelSpectators", RENDER_PRIORITY, function()
		local viewer = GameMode.of(localPlayer)
		local spectatingSomeone = MovementController.spectating() ~= nil
		-- (The local body after its death tilt, with the server's own positions.)
		local died = MovementController.deathTime()
		local selfGone = died ~= nil and died >= MovementController.DEATH_SECONDS
		table.clear(seen)
		table.clear(shownNames)
		table.clear(usedCovers)
		table.clear(stillOff)
		for _, other in Players:GetPlayers() do
			local character = other.Character
			if character then
				local target = GameMode.of(other)
				local isLocal = other == localPlayer
				-- Not drawn at all: another player this client isn't sent (or a body gone after its
				-- death), this player's own inside the player spectated or gone after its death.
				local gone = if isLocal then spectatingSomeone or selfGone else not RemotePlayers.shown(other)
				if gone or GameMode.isSpectator(target) then
					local cover = coverOf(character)
					for i, object in cover.objects do
						apply(object, if gone then 1 else SpectatorRules.transparency(viewer, target, cover.heads[i]))
					end
					if gone and not isLocal then
						for _, highlight in cover.highlights do
							stillOff[highlight] = true
							if not disabled[highlight] and highlight.Enabled then
								disabled[highlight] = true
								highlight.Enabled = false
							end
						end
					end
				end
				-- Names and health bars of players this one can't see.
				local humanoid = character:FindFirstChildOfClass("Humanoid")
				if humanoid and not isLocal and (gone or not SpectatorRules.sees(viewer, target)) then
					shownNames[humanoid] = true
					if hiddenNames[humanoid] == nil then
						hiddenNames[humanoid] = humanoid.DisplayDistanceType
						humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
					end
				end
			end
		end
		-- Characters no longer hidden (or gone) let go of their lists.
		for character, cover in covers do
			if not usedCovers[character] then
				covers[character] = nil
				for _, connection in cover.connections do
					connection:Disconnect()
				end
			end
		end
		-- Highlights of players seen again come back on.
		for highlight in disabled do
			if not stillOff[highlight] then
				disabled[highlight] = nil
				if highlight.Parent ~= nil then
					highlight.Enabled = true
				end
			end
		end
		-- Objects of players who stopped spectating (or left) get their own transparency back.
		for object, record in tracked do
			if not seen[object] then
				tracked[object] = nil
				if math.abs(transparencyOf(object) - record.written) <= EPSILON then
					setTransparency(object, record.original)
				end
			end
		end
		for humanoid, before in hiddenNames do
			if not shownNames[humanoid] then
				hiddenNames[humanoid] = nil
				if humanoid.DisplayDistanceType == Enum.HumanoidDisplayDistanceType.None then
					humanoid.DisplayDistanceType = before
				end
			end
		end
	end)
end

return SpectatorView
