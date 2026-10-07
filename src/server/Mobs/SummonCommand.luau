--!strict
--[[
	The /summon and /kill chat commands for mobs, without the Roblox parts (Mobs/Mobs runs them),
	so the tests can run them. Minecraft's syntax, for the mobs this game has:

	    /summon <kind> [<x> <y> <z>]     a mob at the position (blocks; "~" is the player's own
	                                      coordinate, "~2" two more), else at the player's feet:
	                                      "Summoned new Zombie"
	    /kill @e[type=<kind>]             every mob of that kind: "Killed 3 entities"
	    /kill @e                          every mob (players are left alone here)

	A kind is a MobList name in any case, with or without "minecraft:" ("zombie",
	"minecraft:creeper"). Who may: as /time (Players/TimeCommand.mayUse: Config.Gameplay.Admins,
	the game's owner and Studio sessions); others get "You can't summon or kill mobs here". Killed
	mobs die (drops, death records) as if hurt to death, without a killer.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local MobList = require(Shared.Entities.MobList)

export type Context = {
	mayUse: boolean,
	-- Mobs are on (Config.Mobs.Enabled).
	enabled: boolean,
	-- The player's feet (blocks).
	x: number,
	y: number,
	z: number,
}

export type Result = {
	summon: { kind: number, x: number, y: number, z: number }?,
	-- Kill every mob of `kind` (nil: every mob).
	kill: { kind: number? }?,
	feedback: { string },
}

local SummonCommand = {}

SummonCommand.SUMMON_USAGE =
	"Usage: /summon <cow | sheep | pig | chicken | zombie | skeleton | creeper | spider> [x y z]"
SummonCommand.KILL_USAGE = "Usage: /kill @e[type=<kind>] (or /kill @e: every mob)"
SummonCommand.DENIED = "You can't summon or kill mobs here"
SummonCommand.DISABLED = "Mobs are turned off (Config.Mobs.Enabled)"
-- How far from the player (blocks) a summoned mob may go.
SummonCommand.MAX_DISTANCE = 256

local function words(text: string): { string }
	local list = {}
	for word in string.gmatch(text, "%S+") do
		table.insert(list, word)
	end
	return list
end

-- Is `text` a /summon or /kill command?
function SummonCommand.matches(text: string): boolean
	local first = string.match(text, "^%s*(%S+)")
	if first == nil then
		return false
	end
	first = string.lower(first)
	return first == "/summon" or first == "/kill"
end

-- A coordinate: a number, or "~" / "~n" relative to `base`. nil when it is neither.
function SummonCommand.coordinate(text: string, base: number): number?
	if string.sub(text, 1, 1) == "~" then
		local rest = string.sub(text, 2)
		if rest == "" then
			return base
		end
		local offset = tonumber(rest)
		return if offset and offset == offset and math.abs(offset) < math.huge then base + offset else nil
	end
	local value = tonumber(text)
	return if value and value == value and math.abs(value) < math.huge then value else nil
end

-- The kind a /kill selector names: "@e" (nil kind: all), "@e[type=zombie]"; false when malformed.
local function selector(text: string): (boolean, number?)
	local lowered = string.lower(text)
	if lowered == "@e" then
		return true, nil
	end
	local name = string.match(lowered, "^@e%[type=([%w_:]+)%]$")
	if name == nil then
		return false, nil
	end
	local kind = MobList.find(name)
	if kind == nil then
		return false, nil
	end
	return true, kind
end

--[[
	Runs `text` for a player (`context`): what to summon or kill and the messages for them, or nil
	when it is no /summon or /kill.
]]
function SummonCommand.run(text: string, context: Context): Result?
	if not SummonCommand.matches(text) then
		return nil
	end
	local args = words(text)
	local command = string.lower(args[1])
	local result: Result = { feedback = {} }
	if not context.mayUse then
		table.insert(result.feedback, SummonCommand.DENIED)
		return result
	end
	if not context.enabled then
		table.insert(result.feedback, SummonCommand.DISABLED)
		return result
	end
	if command == "/summon" then
		local kind = if args[2] then MobList.find(args[2]) else nil
		if kind == nil or (#args ~= 2 and #args ~= 5) then
			if args[2] and kind == nil then
				table.insert(result.feedback, `Unknown entity: {args[2]}`)
			end
			table.insert(result.feedback, SummonCommand.SUMMON_USAGE)
			return result
		end
		local x, y, z = context.x, context.y, context.z
		if #args == 5 then
			local cx = SummonCommand.coordinate(args[3], context.x)
			local cy = SummonCommand.coordinate(args[4], context.y)
			local cz = SummonCommand.coordinate(args[5], context.z)
			if cx == nil or cy == nil or cz == nil then
				table.insert(result.feedback, SummonCommand.SUMMON_USAGE)
				return result
			end
			x, y, z = cx, cy, cz
		end
		local dx, dy, dz = x - context.x, y - context.y, z - context.z
		if dx * dx + dy * dy + dz * dz > SummonCommand.MAX_DISTANCE * SummonCommand.MAX_DISTANCE then
			table.insert(result.feedback, `That position is too far away (at most {SummonCommand.MAX_DISTANCE} blocks)`)
			return result
		end
		result.summon = { kind = kind, x = x, y = y, z = z }
		local spec = MobList.get(kind) :: MobList.Kind
		table.insert(result.feedback, `Summoned new {spec.displayName}`)
		return result
	end
	-- /kill
	local ok, kind = false, nil
	if args[2] and #args == 2 then
		ok, kind = selector(args[2])
	end
	if not ok then
		table.insert(result.feedback, SummonCommand.KILL_USAGE)
		return result
	end
	result.kill = { kind = kind }
	return result
end

-- Minecraft's answer to /kill.
function SummonCommand.killed(count: number): string
	if count == 0 then
		return "No entity was found"
	end
	return if count == 1 then "Killed 1 entity" else `Killed {count} entities`
end

return SummonCommand
