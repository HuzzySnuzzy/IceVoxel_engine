--!strict
--[[
	The player's settings on this device (pure; the client's Settings controller wraps it).

	  values    every setting (PlayerSettings keys), one table for the whole session: Rendering/
	            ViewSettings and the effects read it, so it is changed in place, never replaced.
	  chosen    the settings the player picked (only those are saved: the rest follow the preset
	            and Roblox's quality level, PlayerSettings.load). Picking a preset chooses
	            `preset` and lets every setting it sets follow it again; "Reset" does the same
	            for the current preset; "Defaults" forgets every choice (key bindings too), and
	            `unset` forgets some (the Key Binds screen's Reset and Reset Keys: a key on its
	            default is not saved, as any other setting).
	  revision  bumps with every change of what is saved, so the controller knows when to send.
	  received  the server's saved profile arrived (`receive`: merged under the choices the
	            player made this session before it came).
	  limits    this screen's highest value of a setting the screen decides (`setLimit`: GUI Scale
	            goes up to Ui/GuiScale.maxChoice for the window): `cycle` wraps after it, as
	            Minecraft's GUI Scale button offers Auto, 1 .. the largest scale that fits. A value
	            above it (chosen on a bigger screen) is kept, not clamped.

	Every operation returns the keys whose values changed (for the effects, Settings/Schedule).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local PlayerSettings = require(Shared.PlayerSettings)

type Values = PlayerSettings.Values

export type State = {
	values: Values,
	chosen: { [string]: boolean },
	profile: number,
	mobile: boolean,
	quality: number,
	revision: number,
	sent: number,
	received: boolean,
	-- "Defaults" was pressed this session (saved choices arriving later don't apply).
	cleared: boolean,
	limits: { [string]: number? },
}

local State = {}

function State.new(profile: number, mobile: boolean, quality: number): State
	return {
		values = PlayerSettings.defaults(mobile, quality),
		chosen = {},
		profile = profile,
		mobile = mobile,
		quality = quality,
		revision = 0,
		sent = 0,
		received = false,
		cleared = false,
		limits = {},
	}
end

-- Copies `new` into the session's values table; returns the keys that changed.
local function assign(self: State, new: Values): { string }
	local changed = {}
	for _, entry in PlayerSettings.ENTRIES do
		local key = entry.key
		local value = new[key]
		if value ~= nil and self.values[key] ~= value then
			self.values[key] = value
			table.insert(changed, key)
		end
	end
	return changed
end

-- Sets preset `index` (its settings follow it again).
function State.setPreset(self: State, index: number): { string }
	local changed = PlayerSettings.applyPreset(self.values, index, self.mobile)
	self.chosen.preset = true
	for _, key in PlayerSettings.PRESET_KEYS do
		self.chosen[key] = nil
	end
	self.revision += 1
	return changed
end

-- Sets `key` to `value` (clamped; full detail follows the balance rule).
function State.set(self: State, key: string, value: number): { string }
	if key == "preset" then
		return State.setPreset(self, value)
	end
	local clamped = PlayerSettings.clamp(key, value, self.mobile)
	if self.values[key] == clamped then
		return {}
	end
	self.values[key] = clamped
	self.chosen[key] = true
	local changed = { key }
	for _, other in PlayerSettings.balance(self.values) do
		self.chosen[other] = true
		table.insert(changed, other)
	end
	self.revision += 1
	return changed
end

-- The next value of a toggle or choice (`delta` steps, wrapping), or of a slider (clamped).
function State.cycle(self: State, key: string, delta: number?): { string }
	local entry = PlayerSettings.entry(key)
	local step = delta or 1
	local value = self.values[key] + step * entry.step
	if entry.kind ~= "slider" then
		local max = PlayerSettings.maxOf(entry, self.mobile)
		local limit = self.limits[key]
		if limit then
			max = math.clamp(limit, entry.min, max)
		end
		if value > max then
			value = entry.min
		elseif value < entry.min then
			value = max
		end
	end
	return State.set(self, key, value)
end

-- This screen's highest value of `key` for `cycle` (nil: the setting's own; see the header).
function State.setLimit(self: State, key: string, limit: number?)
	self.limits[key] = limit
end

-- "Reset": the current preset's values again.
function State.reset(self: State): { string }
	return State.setPreset(self, self.values.preset)
end

--[[
	Forgets the choice of each of `keys` (not presets' settings): back to the device's default,
	no longer saved. The Key Binds screen's Reset (one key) and Reset Keys (all of them).
]]
function State.unset(self: State, keys: { string }): { string }
	local defaults = PlayerSettings.defaults(self.mobile, self.quality)
	local changed = {}
	local forgot = false
	for _, key in keys do
		local entry = PlayerSettings.entry(key)
		assert(not entry.preset and key ~= "preset", `State.unset: {key} follows the preset`)
		if self.chosen[key] then
			self.chosen[key] = nil
			forgot = true
		end
		local value = defaults[key]
		if self.values[key] ~= value then
			self.values[key] = value
			table.insert(changed, key)
		end
	end
	if forgot or #changed > 0 then
		self.revision += 1
	end
	return changed
end

-- "Defaults": every setting back to the device's default (its preset by the quality level).
function State.restoreDefaults(self: State): { string }
	local changed = assign(self, PlayerSettings.defaults(self.mobile, self.quality))
	table.clear(self.chosen)
	self.cleared = true
	self.revision += 1
	return changed
end

--[[
	The server's saved profile (only the chosen settings), once. Choices the player already made
	this session win: saved settings they did not touch still apply, except that a preset picked
	this session drops the saved settings that presets set, and "Defaults" drops all of them. The
	merged choices are then saved.
]]
function State.receive(self: State, saved: Values): { string }
	if self.received then
		return {}
	end
	self.received = true
	local session: Values = if self.revision > 0 then State.payload(self) else {}
	local merged: Values = {}
	if not self.cleared then
		for key, value in saved do
			local entry = PlayerSettings.byKey[key]
			if entry and not (session.preset ~= nil and entry.preset) then
				merged[key] = value
			end
		end
	end
	for key, value in session do
		merged[key] = value
	end
	local values, chosen = PlayerSettings.load(merged, self.mobile, self.quality)
	local changed = assign(self, values)
	table.clear(self.chosen)
	for key in chosen do
		self.chosen[key] = true
	end
	if self.revision > 0 then
		self.revision += 1
	end
	return changed
end

-- What is saved: the chosen settings.
function State.payload(self: State): Values
	local out: Values = {}
	for key in self.chosen do
		local value = self.values[key]
		if value ~= nil then
			out[key] = value
		end
	end
	return out
end

-- Does the server lack the latest choices?
function State.unsent(self: State): boolean
	return self.sent ~= self.revision
end

function State.markSent(self: State)
	self.sent = self.revision
end

-- The preset the values match ("Custom" when none).
function State.presetName(self: State): string
	local index = PlayerSettings.presetOf(self.values, self.mobile)
	return if index then PlayerSettings.PRESET_NAMES[index] else "Custom"
end

return State
