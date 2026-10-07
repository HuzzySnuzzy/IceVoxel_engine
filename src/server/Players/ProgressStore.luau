--!strict
--[[
	Where each player's progression is kept between visits: the DataStore "IceVoxelProgress_v1",
	key player_<UserId>, one record (Shared/Progression.toRecord: { v = 1, points, age, skills,
	found }), tied to the user (SetAsync's user ids). The safety rules of Players/SettingsStore and
	WaypointStore:

	  * `load` tries LOAD_ATTEMPTS times with growing waits. When every try fails it says so, and
	    the caller never saves that player this session: an outage can't overwrite saved progress
	    with a fresh start. A player with nothing saved loads fine (nil record).
	  * `save` tries twice (2 s apart).
	  * Without DataStore access (Studio without API services, Config.Progression.Save off) there
	    is no store: progress lasts for the session only.

	When to save is the caller's (server Players/Progression: on leave, on shutdown and every
	Config.Progression.SaveInterval seconds while something changed).
]]

local DataStoreService = game:GetService("DataStoreService")

local STORE_NAME = "IceVoxelProgress_v1"
local LOAD_ATTEMPTS = 3

export type Store = {
	load: (self: Store, player: Player) -> (boolean, unknown),
	save: (self: Store, player: Player, record: unknown) -> boolean,
}

local ProgressStore = {}

ProgressStore.NAME = STORE_NAME

local function key(player: Player): string
	return `player_{player.UserId}`
end

-- The store, or nil when there is none (saving off, or no DataStore access).
function ProgressStore.open(enabled: boolean): Store?
	if not enabled then
		return nil
	end
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if not ok then
		warn(`[IceVoxel] progress will not be saved: {result}`)
		return nil
	end
	local dataStore = result :: DataStore

	local store = {}

	--[[
		The player's saved record (nil: nothing saved yet). Yields. false when it could not be read
		(then never save this player this session).
	]]
	function store.load(_self: Store, player: Player): (boolean, unknown)
		for attempt = 1, LOAD_ATTEMPTS do
			local okLoad, value = pcall(function()
				return dataStore:GetAsync(key(player))
			end)
			if okLoad then
				return true, value
			end
			warn(`[IceVoxel] could not load the progress of {player.Name} (attempt {attempt}): {value}`)
			if attempt < LOAD_ATTEMPTS then
				task.wait(2 ^ attempt)
			end
		end
		warn(`[IceVoxel] the progress of {player.Name} is session-only this time`)
		return false, nil
	end

	-- Saves `record` for the player. Yields. Whether it was saved.
	function store.save(_self: Store, player: Player, record: unknown): boolean
		for attempt = 1, 2 do
			local okSave, err = pcall(function()
				dataStore:SetAsync(key(player), record, { player.UserId })
			end)
			if okSave then
				return true
			end
			warn(`[IceVoxel] could not save the progress of {player.Name} (attempt {attempt}): {err}`)
			if attempt == 1 then
				task.wait(2)
			end
		end
		return false
	end

	return (store :: any) :: Store
end

return ProgressStore
