--!strict
--[[
	The use each player holds the button for (eating a food, drinking a drink), as every client
	sees it: the player attribute Types.USE_ATTRIBUTE, Types.USE_EAT or Types.USE_DRINK while the
	use lasts, nil otherwise. Clients play the use's loop at the player from it (client
	Audio/UseSounds); the user's own client plays theirs from its own hold, at once.

	  begin(player, kind, ticks)  a use the server accepted: Players/Eating (a food that is not
	                              medicine: medicine plays its own sound) and Players/ToughAsNails
	                              (a drink), with its length in ticks
	  finish(player, kind)        it ended: finished, cancelled, or refused (a use of another kind
	                              is left alone)
	A use also ends here when the player's character is dead or gone (checked every frame while
	one lasts), when the player leaves, and on its own LEEWAY ticks after its length: a client that
	never says it stopped (a lost message, a cheat) leaves no sound looping at it for long.

	Pure apart from the attribute and the frame hook (`expired` is the rule; `start` once, on the
	server). Before `start` (and in specs) the attribute is still written; nothing expires.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Types = require(Shared.Inventory.Types)

local UseState = {}

-- Minecraft's tick (seconds).
local TICK = 1 / 20
-- Ticks a use may outlast its length before it ends here (the client's finish is on its way).
UseState.LEEWAY = 20

type Use = { kind: string, started: number, ticks: number }
local uses: { [Player]: Use } = {}
local started = false

-- Has a use of `ticks` begun at `since` (os.clock seconds) run out at `now`?
function UseState.expired(since: number, ticks: number, now: number): boolean
	return now - since > (ticks + UseState.LEEWAY) * TICK
end

local function write(player: Player, kind: string?)
	if player:GetAttribute(Types.USE_ATTRIBUTE) ~= kind then
		player:SetAttribute(Types.USE_ATTRIBUTE, kind)
	end
end

-- `player` began a use of `kind` (Types.USE_EAT, USE_DRINK) lasting `ticks`.
function UseState.begin(player: Player, kind: string, ticks: number)
	assert(kind == Types.USE_EAT or kind == Types.USE_DRINK, `Unknown use {kind}`)
	uses[player] = { kind = kind, started = os.clock(), ticks = ticks }
	write(player, kind)
end

-- `player`'s use of `kind` ended (nil: whatever use it was).
function UseState.finish(player: Player, kind: string?)
	local use = uses[player]
	if use and (kind == nil or use.kind == kind) then
		uses[player] = nil
		write(player, nil)
	end
end

-- The use `player` holds (Types.USE_EAT, USE_DRINK), nil when none.
function UseState.of(player: Player): string?
	local use = uses[player]
	return if use then use.kind else nil
end

local function alive(player: Player): boolean
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	return player.Parent ~= nil and humanoid ~= nil and humanoid.Health > 0
end

function UseState.start()
	if started then
		return
	end
	started = true
	RunService.Heartbeat:Connect(function()
		if next(uses) == nil then
			return
		end
		local now = os.clock()
		for player, use in uses do
			if not alive(player) or UseState.expired(use.started, use.ticks, now) then
				UseState.finish(player)
			end
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		uses[player] = nil
	end)
end

return UseState
