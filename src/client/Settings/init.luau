--!strict
--[[
	The player's settings on this client: the values (Shared/PlayerSettings), what changing them
	takes, and keeping them on the server.

	  Values    one table for the session (Settings/State), on the device's defaults: phones and
	            tablets Low, others by Roblox's saved graphics quality (UserGameSettings.
	            SavedQualityLevel). Rendering/ViewSettings reads the same table.
	  Profiles  one per kind of device (desktop, touch: ViewSettings.isMobile, console: GuiService:
	            IsTenFootInterface); the server sends its saved one (Players/SettingsStore) when
	            the player joins, and the client start-up waits for it up to Config.Settings.
	            LoadWait seconds (`waitForSaved`) so the first terrain is already the player's.
	            Arriving later, it applies then (merged under choices already made).
	  Effects   what a change takes is registered by the client script, one function per effect
	            key (`register("lod", fn)`; the keys are PlayerSettings' `effect`s). A change
	            marks its effects (Settings/Schedule); every frame the due ones run once each (a
	            function registered under several keys runs once), in PlayerSettings.EFFECT_ORDER.
	            Cheap ones run at the next frame; costly ones (view, caves, plants, shadows,
	            textures, far meshes) Config.Settings.ApplyDelay seconds after the last change, so
	            a dragged slider rebuilds once. `flush` runs everything waiting at once (the menu
	            closing). Effects nobody registered are skipped (`missing` lists them).
	  Saving    the chosen settings go to the server (Protocol SaveSettings) Config.Settings.
	            SaveDelay seconds after the last change, and at once on `flush` and when the saved
	            profile arrives after choices were made (the merged result).
	  Status    the menu's status lines come from providers the client script sets (`setStatus`:
	            "terrain" -> "Updating terrain: N queued, M building", "farMeshes", "controls",
	            "mouse").
	  Keys      the key bindings are settings too ("key.<action>", Shared/KeyBindings), read by
	            every input site through Settings/Keybinds; `unset` forgets some choices (the Key
	            Binds screen's Reset and Reset Keys).
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local PlayerSettings = require(Shared.PlayerSettings)
local Protocol = require(Shared.Net.Protocol)

local ClientNet = require(script.Parent.Net.ClientNet)
local ViewSettings = require(script.Parent.Rendering.ViewSettings)
local Schedule = require(script.Schedule)
local State = require(script.State)

export type Values = PlayerSettings.Values
-- An effect: applies what the values say now.
export type Effect = (values: Values) -> ()

local Settings = {}

-- The device class's profile, and whether it is a phone or tablet.
local function deviceProfile(): (number, boolean)
	local mobile = ViewSettings.isMobile()
	local ok, console = pcall(function()
		return GuiService:IsTenFootInterface()
	end)
	if ok and console then
		return PlayerSettings.Profile.Console, mobile
	elseif mobile then
		return PlayerSettings.Profile.Touch, true
	end
	return PlayerSettings.Profile.Desktop, false
end

-- Roblox's saved graphics quality: 0 Automatic, 1..10 (0 when it can't be read).
local function savedQuality(): number
	local ok, level = pcall(function()
		local settings = (UserSettings() :: any):GetService("UserGameSettings")
		return settings.SavedQualityLevel.Value
	end)
	return if ok and type(level) == "number" then level else 0
end

local profile, mobile = deviceProfile()
local state = State.new(profile, mobile, savedQuality())
local schedule = Schedule.new(Config.Settings.ApplyDelay)
local effects: { [string]: Effect } = {}
local statuses: { [string]: () -> string? } = {}
local saveAt: number? = nil
local started = false

local changedEvent = Instance.new("BindableEvent")
-- Fires with the keys whose values changed (the menu redraws).
Settings.changed = changedEvent.Event

-- The session's values (changed in place).
Settings.values = state.values
ViewSettings.bind(state.values)

-- Does any block draw a texture of the pack (TexturePack)? Else the Textures button is hidden.
local texturesUsed = false
for _, appearance in Blocks.appearances do
	if appearance.textured then
		texturesUsed = true
		break
	end
end

-- Can far meshes run on this device (as MeshOverlay decides)? Else Far Materials changes nothing:
-- far chunks are parts in their full look already.
local farMeshes = Config.Render.FarMeshes
local farMeshesRun = farMeshes.Enabled and (farMeshes.Mobile or not mobile)

--[[ Applying ]]

local function run(list: { string })
	local ran: { [Effect]: boolean } = {}
	for _, effect in list do
		local fn = effects[effect]
		if fn and not ran[fn] then
			ran[fn] = true
			local ok, err = pcall(function()
				fn(state.values)
			end)
			if not ok then
				warn(`[IceVoxel] settings effect {effect} failed: {err}`)
			end
		end
	end
end

local function changed(keys: { string })
	if #keys == 0 then
		return
	end
	local now = os.clock()
	Schedule.markKeys(schedule, keys, now)
	if State.unsent(state) then
		saveAt = now + Config.Settings.SaveDelay
	end
	changedEvent:Fire(keys)
end

-- Sends the chosen settings to the server if it lacks the latest.
local function save()
	saveAt = nil
	if State.unsent(state) then
		State.markSent(state)
		ClientNet.send(
			Protocol.ClientMessage.SaveSettings,
			Protocol.encodeSettings(state.profile, State.payload(state))
		)
	end
end

--[[ Public ]]

-- Starts listening for the saved settings and applying changes every frame. Call first.
function Settings.start()
	if started then
		return
	end
	started = true
	ClientNet.on(Protocol.ServerMessage.Settings, function(payload: buffer)
		local from, values = Protocol.decodeSettings(payload)
		if from == state.profile and values then
			changed(State.receive(state, values))
			-- The merged choices go back at once, even when no value changed: what the server
			-- holds was sent before it had the saved ones (Defaults or a preset may have dropped
			-- some of those).
			if State.unsent(state) then
				save()
			end
		end
	end)
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if next(schedule.dueAt) ~= nil then
			run(Schedule.due(schedule, now))
		end
		local at = saveAt
		if at and now >= at then
			save()
		end
	end)
end

-- Waits until the saved settings arrived, at most `timeout` seconds (Config.Settings.LoadWait).
function Settings.waitForSaved(timeout: number?)
	local deadline = os.clock() + (timeout or Config.Settings.LoadWait)
	while not state.received and os.clock() < deadline do
		task.wait()
	end
end

-- Did the saved settings arrive?
function Settings.loaded(): boolean
	return state.received
end

--[[
	Registers what effect `effect` takes (PlayerSettings effect keys: "lod", "caves", "foliage",
	"fog", "lighting", "lichen", "shadows", "farShadows", "textures", "overlay", "budget",
	"skipHidden", "swapFrames", "audio", "camera", "controls", "hud", "keys", "mouse") and runs it
	once now, so
	the current values apply (unless the same function was registered under another key before).
	A later registration replaces an earlier one.
]]
function Settings.register(effect: string, fn: Effect)
	local already = false
	for _, other in effects do
		if other == fn then
			already = true
		end
	end
	effects[effect] = fn
	if not already then
		run({ effect })
	end
end

-- Is an effect registered for `effect`?
function Settings.has(effect: string): boolean
	return effects[effect] ~= nil
end

-- The effect keys settings use that nobody registered (for the F3 overlay and tests).
function Settings.missing(): { string }
	local list = {}
	for _, effect in PlayerSettings.EFFECT_ORDER do
		if effects[effect] == nil then
			table.insert(list, effect)
		end
	end
	return list
end

function Settings.get(key: string): number
	return state.values[key]
end

function Settings.on(key: string): boolean
	return PlayerSettings.on(state.values, key)
end

-- Sets `key` (clamped, with the balance rule; "preset" picks a preset).
function Settings.set(key: string, value: number)
	changed(State.set(state, key, value))
end

-- The next value of a toggle or choice (wrapping), or a slider's next step.
function Settings.cycle(key: string, delta: number?)
	changed(State.cycle(state, key, delta))
end

function Settings.setPreset(index: number)
	changed(State.setPreset(state, index))
end

-- "Reset": the current preset's values again.
function Settings.reset()
	changed(State.reset(state))
end

-- "Defaults": every setting back to the device's default.
function Settings.restoreDefaults()
	changed(State.restoreDefaults(state))
end

-- Forgets the choice of `keys` (back to the device's defaults; the Key Binds screen's Reset and
-- Reset Keys).
function Settings.unset(keys: { string })
	changed(State.unset(state, keys))
end

-- The preset the values match, or "Custom".
function Settings.presetName(): string
	return State.presetName(state)
end

-- Runs every waiting effect now and sends the settings (the menu closing).
function Settings.flush()
	run(Schedule.due(schedule, os.clock(), true))
	save()
end

-- How many effects are waiting to run.
function Settings.waiting(): number
	return Schedule.waiting(schedule)
end

function Settings.profile(): number
	return state.profile
end

function Settings.isMobile(): boolean
	return state.mobile
end

--[[
	Is setting `key` offered on this device (touch buttons on touch screens, textures when some
	block has one, far materials where far meshes can run)?
]]
function Settings.shown(key: string): boolean
	local entry = PlayerSettings.entry(key)
	if entry.touchOnly and not UserInputService.TouchEnabled then
		return false
	end
	if key == "textures" then
		return texturesUsed
	elseif key == "farMaterials" then
		return farMeshesRun
	end
	return true
end

--[[
	Is page `id` offered on this device: Key Binds with a keyboard, Mouse Settings with a mouse
	(touch screens and consoles keep their own controls)?
]]
function Settings.pageShown(id: string): boolean
	if id == "keybinds" then
		return UserInputService.KeyboardEnabled
	elseif id == "mouse" then
		return UserInputService.MouseEnabled
	end
	return true
end

-- A status line's provider (kinds: "terrain", "farMeshes", "controls", "mouse").
function Settings.setStatus(kind: string, fn: () -> string?)
	statuses[kind] = fn
end

function Settings.status(kind: string): string?
	local fn = statuses[kind]
	if fn == nil then
		return nil
	end
	local ok, text = pcall(fn)
	return if ok then text else nil
end

return Settings
