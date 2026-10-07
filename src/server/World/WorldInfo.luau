--!strict
--[[
	The world's settings on the server once it exists (Shared/WorldSettings: name, the game mode new
	players get, difficulty, Allow Commands, world type, options, seed), and creating it: for any
	server script to read (`get`), set once by `create`.

	  States   "waiting" (no world: the title screen waits for its operator, Players/WorldMenu),
	           "creating" (the boot's startWorld is running), "ready", or "failed" (startWorld
	           threw: the server needs a restart, half the world's parts may have started).
	  create   runs `start(settings)` (the boot's startWorld) once, from "waiting": the settings
	           go into Config first (`apply`), so the parts starting read them.
	  apply    what the settings change in Config on this server (`Config` is shared, but only
	           the server's copy changes): Gameplay.DefaultGameMode (new players' game mode,
	           Players/GameModes), Server.Fire.Difficulty (fire spreading, Behaviours/Fire),
	           on Peaceful no monsters spawning (Mobs.HostileCap and MaxHostile 0: Minecraft's
	           peaceful spawns none; /summon still makes them), and a world type with
	           `mobs = false` (the void, the debug worlds: Generation/WorldTypes) no natural
	           spawning at all (Mobs.Spawning). Allow Commands goes to Players/Operators (the boot
	           script); a type's `ticks = false` is the boot script's too (its block ticker).
	No Roblox APIs, so the specs run it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local WorldSettings = require(Shared.WorldSettings)
local WorldTypes = require(Shared.Generation.WorldTypes)

export type State = "waiting" | "creating" | "ready" | "failed"

local WorldInfo = {}

local state: State = "waiting"
local current: WorldSettings.Settings? = nil
local problem: string? = nil
local readyCallbacks: { (WorldSettings.Settings) -> () } = {}

function WorldInfo.state(): State
	return state
end

-- The world's settings (nil until it is ready).
function WorldInfo.get(): WorldSettings.Settings?
	return current
end

function WorldInfo.exists(): boolean
	return state == "ready"
end

-- Why creating the world failed (nil unless it did).
function WorldInfo.problem(): string?
	return problem
end

-- Calls `fn(settings)` once the world is ready (at once when it is).
function WorldInfo.onReady(fn: (WorldSettings.Settings) -> ())
	local settings = current
	if state == "ready" and settings then
		fn(settings)
	else
		table.insert(readyCallbacks, fn)
	end
end

--[[
	Why a CreateWorld from a player can't go ahead now (nil: it can): only an operator (`operator`:
	Players/Operators.isOperator, not just Allow Commands), and only while there is no world and
	none being made (`busy`: a request under way, its name still at the filter).
]]
function WorldInfo.refusal(operator: boolean, busy: boolean): string?
	if not operator then
		return "Only the operator can create the world"
	elseif state == "ready" then
		return "The world already exists"
	elseif state == "failed" then
		return "The world could not be created"
	elseif busy or state == "creating" then
		return "The world is being created"
	end
	return nil
end

-- What `settings` change in `config` (see the header).
function WorldInfo.apply(config: typeof(Config), settings: WorldSettings.Settings)
	config.Gameplay.DefaultGameMode = settings.gameMode
	config.Server.Fire.Difficulty = settings.difficulty
	if settings.difficulty == 0 then
		config.Mobs.HostileCap = 0
		config.Mobs.MaxHostile = 0
	end
	local worldType = WorldTypes.get(settings.worldType)
	if worldType and worldType.mobs == false then
		config.Mobs.Spawning = false
	end
end

--[[
	Creates the world: from "waiting", applies `settings` to Config and runs `start(settings)`.
	Returns whether the world is ready, or why not ("The world already exists", startWorld's
	error: then the state is "failed" for good).
]]
function WorldInfo.create(settings: WorldSettings.Settings, start: (WorldSettings.Settings) -> ()): (boolean, string?)
	if state ~= "waiting" then
		return false, if state == "failed" then "The world could not be created" else "The world already exists"
	end
	state = "creating"
	WorldInfo.apply(Config, settings)
	local ok, err = pcall(function()
		start(settings)
	end)
	if not ok then
		state = "failed"
		problem = tostring(err)
		return false, problem
	end
	current = settings
	state = "ready"
	local callbacks = readyCallbacks
	readyCallbacks = {}
	for _, fn in callbacks do
		fn(settings)
	end
	return true, nil
end

-- Back to no world (the specs only: a real world can't be taken away).
function WorldInfo._reset()
	state = "waiting"
	current = nil
	problem = nil
	readyCallbacks = {}
end

return WorldInfo
