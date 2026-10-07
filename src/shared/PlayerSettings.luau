--!strict
--[[
	What a player can tune in the Options menu: the schema the client's menu (Ui/SettingsScreen),
	its controller (client Settings/), the server's store (Players/SettingsStore) and the tests
	share. Pure, so all of them use the same rules.

	Every setting is one number (toggles 0 / 1, choices an index), kept by `key` in a Values table
	and sent and saved by `id`: ids are append-only bytes like BlockList's (saved settings and the
	wire use them), so a removed setting leaves its id unused. An entry says:

	  kind      "slider" (min..max by step), "toggle" (0 / 1) or "choice" (min..max, labelled)
	  default   the desktop default (and `mobileDefault` on phones and tablets); for the settings a
	            preset sets (`preset`), the preset decides instead
	  effect    what applying it takes, a key of the client's effect registry (Settings.register):
	            "lod", "caves", "foliage", "fog", "lighting", "lichen", "shadows", "farShadows",
	            "textures", "overlay", "budget", "skipHidden", "swapFrames", "audio", "camera",
	            "controls", "hud", "chat" (`also` names more). The costly ones (EXPENSIVE) wait
	            until a slider has stopped moving (Config.Settings.ApplyDelay).

	Presets (Low, Medium, High, Ultra; priced in parts in the README): High is Config's own view
	(Lod, Caves, Render), Low its Mobile values (view, caves, plants, lichen lights: what phones
	drew before this menu) with shadows off and hidden terrain skipped; lichen lights follow
	Config's LichenLightDistance (every light, today) in all of them, the slider lowers it on slow
	devices. Phones start on Low; other devices by Roblox's saved graphics quality
	(`defaultPreset`: 1-3 Low, 4-6 Medium, 7-10 or Automatic High). Changing a value a preset sets
	makes the preset read "Custom".

	The LOD balance rule (`balance`): LodTree stays 2:1 balanced (no full detail chunk next to a
	level 2 node) while the split distance is at least 2 and full detail (normal and underground)
	reaches at most split + 1 (checked for every slider combination in tests/spec/PlayerSettings):
	full detail is clamped as the falloff slider moves. The underground split comes from the cave
	view: caves only exist in full detail chunks, which reach about 32 x split blocks, so it is
	the cave view / 32 (rounded up to a half), between full detail and split + 1 (`lod`).

	Saved and sent: only what the player chose (`load`, the controller's `chosen`): a profile
	that never changed render distance follows its preset, and Roblox's quality setting, later.
	Wire format (Protocol SaveSettings / Settings): u8 version, u8 profile (1 desktop, 2 touch,
	3 console), u8 count, count x (u8 id, f32 value); `decode` drops unknown ids and NaN and
	clamps every value (touch profiles to the phone limits).
]]

local Config = require(script.Parent.Config)

export type Kind = "slider" | "toggle" | "choice"
export type Values = { [string]: number }

export type Entry = {
	id: number,
	key: string,
	name: string,
	kind: Kind,
	page: string,
	min: number,
	max: number,
	step: number,
	default: number,
	mobileDefault: number?,
	-- Highest value on phones and tablets.
	mobileMax: number?,
	effect: string,
	also: { string }?,
	-- Set by presets.
	preset: boolean,
	-- How the value reads (`text`): "blocks" (a distance, the name says in what), "factor",
	-- "percent", "ms", "seconds", "pixels" (GUI pixels), "plain", "fullDetail" (about 32 x the
	-- value: how far full detail reaches, in blocks); toggles read ON / OFF; `labels` name special
	-- values. Kept short: buttons are 150 GUI pixels wide and the pixel font is 8 pixels a
	-- character.
	format: string,
	labels: { [number]: string }?,
	-- Only offered on touch screens.
	touchOnly: boolean?,
}

local PlayerSettings = {}

PlayerSettings.VERSION = 1

-- Device classes, one saved profile each (a phone never gets a computer's 2048-block view).
PlayerSettings.Profile = table.freeze({ Desktop = 1, Touch = 2, Console = 3 })
PlayerSettings.PROFILE_NAMES = table.freeze({ "desktop", "touch", "console" })

PlayerSettings.PRESET_NAMES = table.freeze({ "Low", "Medium", "High", "Ultra" })
PlayerSettings.LOW, PlayerSettings.MEDIUM, PlayerSettings.HIGH, PlayerSettings.ULTRA = 1, 2, 3, 4

-- The lichen light slider's top value: every light on.
PlayerSettings.ALL_LIGHTS = 144

-- Effects that wait for a slider to stop (remeshing, restyling, rebuilding).
PlayerSettings.EXPENSIVE = table.freeze({
	lod = true,
	caves = true,
	foliage = true,
	shadows = true,
	farShadows = true,
	textures = true,
	overlay = true,
} :: { [string]: boolean })

-- The order effects run in within one frame (the view before the fog that follows it).
PlayerSettings.EFFECT_ORDER = table.freeze({
	"controls",
	"camera",
	"audio",
	"hud",
	"chat",
	"budget",
	"swapFrames",
	"lighting",
	"lichen",
	"lod",
	"caves",
	"foliage",
	"fog",
	"skipHidden",
	"overlay",
	"shadows",
	"farShadows",
	"textures",
})

-- Brightness 100%: Minecraft's "Bright" for caves (Lighting.CaveAmbient; 0% is Config's own).
local BRIGHT = { 90, 90, 100 }

local caves = Config.Caves :: any
local render = Config.Render :: any
local lod = Config.Lod
local mobile = Config.Lod.Mobile :: any

local function bool(value: any): number
	return if value then 1 else 0
end

local function snap(value: number, min: number, step: number): number
	local snapped = min + math.floor((value - min) / step + 0.5) * step
	-- (Whole multiples of 1/16 stay exact; this rounds away float noise from other steps.)
	return math.floor(snapped * 1e6 + 0.5) / 1e6
end

-- Entries, by id. Appending only: never reuse or renumber an id.
local ENTRIES: { Entry } = {
	{
		id = 1,
		key = "preset",
		name = "Graphics",
		kind = "choice",
		page = "main",
		min = 1,
		max = 4,
		step = 1,
		default = 3,
		effect = "preset",
		preset = false,
		format = "plain",
		labels = { [1] = "Low", [2] = "Medium", [3] = "High", [4] = "Ultra" },
	},
	{
		id = 2,
		key = "renderDistance",
		name = "Render Distance",
		kind = "slider",
		page = "video",
		min = 256,
		max = 4096,
		step = 256,
		default = 2048,
		mobileMax = 1024,
		effect = "lod",
		also = { "fog" },
		preset = true,
		format = "blocks",
	},
	{
		id = 3,
		key = "detailFalloff",
		name = "Detail Falloff",
		kind = "slider",
		page = "video",
		min = 2,
		max = 4,
		step = 0.5,
		default = 3,
		effect = "lod",
		preset = true,
		format = "factor",
	},
	{
		id = 4,
		key = "fullDetail",
		name = "Full Detail",
		kind = "slider",
		page = "video",
		min = 1.5,
		max = 5,
		step = 0.5,
		default = 3,
		effect = "lod",
		preset = true,
		format = "fullDetail",
	},
	{
		id = 5,
		key = "caveView",
		name = "Cave View",
		kind = "slider",
		page = "video",
		min = 64,
		max = 176,
		step = 16,
		default = 128,
		effect = "caves",
		also = { "lod" },
		preset = true,
		format = "blocks",
	},
	{
		id = 6,
		key = "plants",
		name = "Plant Distance",
		kind = "slider",
		page = "video",
		min = 0,
		max = 64,
		step = 8,
		default = 40,
		effect = "foliage",
		preset = true,
		format = "blocks",
		labels = { [0] = "OFF" },
	},
	{
		id = 7,
		key = "shadows",
		name = "Shadows",
		kind = "toggle",
		page = "video",
		min = 0,
		max = 1,
		step = 1,
		default = 1,
		effect = "shadows",
		preset = true,
		format = "plain",
	},
	{
		id = 8,
		key = "farShadows",
		name = "Far Shadows",
		kind = "toggle",
		page = "video",
		min = 0,
		max = 1,
		step = 1,
		default = 0,
		effect = "farShadows",
		preset = true,
		format = "plain",
	},
	{
		id = 9,
		key = "fog",
		name = "Fog",
		kind = "toggle",
		page = "video",
		min = 0,
		max = 1,
		step = 1,
		default = bool(Config.Render.Fog),
		effect = "fog",
		preset = false,
		format = "plain",
	},
	{
		id = 10,
		key = "textures",
		name = "Textures",
		kind = "toggle",
		page = "video",
		min = 0,
		max = 1,
		step = 1,
		default = bool(Config.Render.Textures),
		effect = "textures",
		preset = false,
		format = "plain",
	},
	{
		id = 11,
		key = "lichenLights",
		name = "Lichen Lights",
		kind = "slider",
		page = "video",
		min = 16,
		max = 144,
		step = 16,
		default = 144,
		effect = "lichen",
		preset = true,
		format = "blocks",
		labels = { [144] = "All" },
	},
	{
		id = 12,
		key = "brightness",
		name = "Brightness",
		kind = "slider",
		page = "video",
		min = 0,
		max = 100,
		step = 1,
		default = 0,
		effect = "lighting",
		preset = false,
		format = "percent",
		labels = { [0] = "Moody", [100] = "Bright" },
	},
	{
		id = 13,
		key = "preferDistance",
		name = "Prefer",
		kind = "toggle",
		page = "video",
		min = 0,
		max = 1,
		step = 1,
		default = 1,
		effect = "lighting",
		preset = false,
		format = "plain",
		labels = { [0] = "Lighting", [1] = "Distance" },
	},
	{
		id = 14,
		key = "farMeshes",
		name = "Far Meshes",
		kind = "toggle",
		page = "performance",
		min = 0,
		max = 1,
		step = 1,
		default = bool(render.FarMeshes.Enabled),
		mobileDefault = bool(render.FarMeshes.Enabled and render.FarMeshes.Mobile),
		effect = "overlay",
		preset = false,
		format = "plain",
	},
	{
		id = 15,
		key = "buildBudget",
		name = "Build Budget",
		kind = "slider",
		page = "performance",
		min = 0,
		max = 12,
		step = 1,
		default = if render.AutoBudget == false then math.clamp(math.floor(render.BuildBudgetMs + 0.5), 1, 12) else 0,
		effect = "budget",
		preset = false,
		format = "ms",
		labels = { [0] = "Auto" },
	},
	{
		id = 16,
		key = "skipHidden",
		name = "Hidden Terrain",
		kind = "toggle",
		page = "performance",
		min = 0,
		max = 1,
		step = 1,
		default = 0,
		effect = "skipHidden",
		preset = true,
		format = "plain",
		labels = { [0] = "Draw", [1] = "Skip" },
	},
	{
		id = 17,
		key = "swapFrames",
		name = "Swap Frames",
		kind = "slider",
		page = "performance",
		min = 0,
		max = 3,
		step = 1,
		default = math.clamp(math.floor((render.SwapFrames or 2) + 0.5), 0, 3),
		effect = "swapFrames",
		preset = false,
		format = "plain",
	},
	{
		id = 18,
		key = "masterVolume",
		name = "Master Volume",
		kind = "slider",
		page = "sounds",
		min = 0,
		max = 100,
		step = 1,
		default = 100,
		effect = "audio",
		preset = false,
		format = "percent",
		labels = { [0] = "OFF" },
	},
	{
		id = 19,
		key = "blocksVolume",
		name = "Blocks",
		kind = "slider",
		page = "sounds",
		min = 0,
		max = 100,
		step = 1,
		default = 100,
		effect = "audio",
		preset = false,
		format = "percent",
		labels = { [0] = "OFF" },
	},
	{
		id = 20,
		key = "playersVolume",
		name = "Players",
		kind = "slider",
		page = "sounds",
		min = 0,
		max = 100,
		step = 1,
		default = 100,
		effect = "audio",
		preset = false,
		format = "percent",
		labels = { [0] = "OFF" },
	},
	{
		id = 21,
		key = "ambientVolume",
		name = "Ambient",
		kind = "slider",
		page = "sounds",
		min = 0,
		max = 100,
		step = 1,
		default = 100,
		effect = "audio",
		preset = false,
		format = "percent",
		labels = { [0] = "OFF" },
	},
	{
		id = 22,
		key = "uiVolume",
		name = "Interface",
		kind = "slider",
		page = "sounds",
		min = 0,
		max = 100,
		step = 1,
		default = 100,
		effect = "audio",
		preset = false,
		format = "percent",
		labels = { [0] = "OFF" },
	},
	{
		id = 23,
		key = "footsteps",
		name = "Footsteps",
		kind = "toggle",
		page = "sounds",
		min = 0,
		max = 1,
		step = 1,
		default = 1,
		effect = "audio",
		preset = false,
		format = "plain",
	},
	{
		id = 24,
		key = "interfaceClicks",
		name = "Interface Clicks",
		kind = "toggle",
		page = "sounds",
		min = 0,
		max = 1,
		step = 1,
		default = 1,
		effect = "audio",
		preset = false,
		format = "plain",
	},
	{
		id = 25,
		key = "caveRumble",
		name = "Cave Moods",
		kind = "toggle",
		page = "sounds",
		min = 0,
		max = 1,
		step = 1,
		default = 1,
		effect = "audio",
		preset = false,
		format = "plain",
	},
	{
		id = 26,
		key = "fov",
		name = "FOV",
		kind = "slider",
		page = "main",
		min = 30,
		max = 110,
		step = 1,
		default = 70,
		effect = "camera",
		preset = false,
		format = "plain",
		labels = { [70] = "Normal", [110] = "Quake Pro" },
	},
	{
		id = 27,
		key = "fovEffects",
		name = "FOV Effects",
		kind = "slider",
		page = "controls",
		min = 0,
		max = 100,
		step = 1,
		default = 100,
		effect = "camera",
		preset = false,
		format = "percent",
		labels = { [0] = "OFF" },
	},
	{
		id = 28,
		key = "toggleSprint",
		name = "Sprint",
		kind = "toggle",
		page = "controls",
		min = 0,
		max = 1,
		step = 1,
		default = bool(Config.Movement.ToggleSprint),
		effect = "controls",
		preset = false,
		format = "plain",
		labels = { [0] = "Hold", [1] = "Toggle" },
	},
	{
		id = 29,
		key = "scrollHotbar",
		name = "Scroll Wheel",
		kind = "toggle",
		page = "controls",
		min = 0,
		max = 1,
		step = 1,
		default = bool(Config.Interaction.ScrollWheelHotbar),
		effect = "controls",
		preset = false,
		format = "plain",
		labels = { [0] = "Zoom", [1] = "Hotbar" },
	},
	{
		id = 30,
		key = "touchButtons",
		name = "Touch Buttons",
		kind = "toggle",
		page = "controls",
		min = 0,
		max = 1,
		step = 1,
		default = bool(Config.Movement.TouchButtons),
		effect = "controls",
		preset = false,
		format = "plain",
		touchOnly = true,
	},
	{
		id = 31,
		key = "minimap",
		name = "Minimap",
		kind = "toggle",
		page = "hud",
		min = 0,
		max = 1,
		step = 1,
		default = 1,
		effect = "hud",
		preset = false,
		format = "plain",
	},
	{
		id = 32,
		key = "waila",
		name = "WAILA",
		kind = "toggle",
		page = "hud",
		min = 0,
		max = 1,
		step = 1,
		default = 1,
		effect = "hud",
		preset = false,
		format = "plain",
	},
	{
		id = 33,
		key = "guiScale",
		name = "GUI Scale",
		kind = "choice",
		page = "hud",
		min = 0,
		max = 3,
		step = 1,
		default = 0,
		effect = "hud",
		preset = false,
		format = "plain",
		labels = { [0] = "Auto" },
	},
	-- Materials and textures on merged far chunks (far meshes split by look) instead of plain
	-- colours; restyled like Textures. Offered only where far meshes can run (Settings.shown).
	{
		id = 34,
		key = "farMaterials",
		name = "Far Materials",
		kind = "toggle",
		page = "video",
		min = 0,
		max = 1,
		step = 1,
		default = bool(Config.Render.FarMaterials),
		effect = "textures",
		preset = false,
		format = "plain",
	},
	-- Minecraft's Music slider: the background music (Audio/Music).
	{
		id = 35,
		key = "musicVolume",
		name = "Music",
		kind = "slider",
		page = "sounds",
		min = 0,
		max = 100,
		step = 1,
		default = 100,
		effect = "audio",
		preset = false,
		format = "percent",
		labels = { [0] = "OFF" },
	},
	-- The "Now Playing" toast when a track starts (Ui/MusicToast).
	{
		id = 36,
		key = "musicToasts",
		name = "Music Toasts",
		kind = "toggle",
		page = "sounds",
		min = 0,
		max = 1,
		step = 1,
		default = bool(Config.Music.Toast),
		effect = "audio",
		preset = false,
		format = "plain",
	},
	-- Chat Settings (client Ui/Chat), Minecraft's ChatOptionsScreen: chatVisibility, chatOpacity
	-- (shown 10-100%), textBackgroundOpacity ("Text Background": Minecraft's name is too long for
	-- the button), chatScale, chatLineSpacing, chatDelay (in half seconds here: tenths are not
	-- exact in f32), chatWidth (40-320 GUI pixels), chatHeightFocused / Unfocused (20-180) and
	-- autoSuggestions, with Minecraft's defaults.
	{
		id = 37,
		key = "chatVisibility",
		name = "Chat",
		kind = "choice",
		page = "chat",
		min = 1,
		max = 3,
		step = 1,
		default = 1,
		effect = "chat",
		preset = false,
		format = "plain",
		labels = { [1] = "Shown", [2] = "Commands Only", [3] = "Hidden" },
	},
	{
		id = 38,
		key = "chatOpacity",
		name = "Chat Text Opacity",
		kind = "slider",
		page = "chat",
		min = 10,
		max = 100,
		step = 1,
		default = 100,
		effect = "chat",
		preset = false,
		format = "percent",
	},
	{
		id = 39,
		key = "chatBackground",
		name = "Text Background",
		kind = "slider",
		page = "chat",
		min = 0,
		max = 100,
		step = 1,
		default = 50,
		effect = "chat",
		preset = false,
		format = "percent",
	},
	{
		id = 40,
		key = "chatScale",
		name = "Text Size",
		kind = "slider",
		page = "chat",
		min = 0,
		max = 100,
		step = 1,
		default = 100,
		effect = "chat",
		preset = false,
		format = "percent",
		labels = { [0] = "OFF" },
	},
	{
		id = 41,
		key = "chatLineSpacing",
		name = "Line Spacing",
		kind = "slider",
		page = "chat",
		min = 0,
		max = 100,
		step = 1,
		default = 0,
		effect = "chat",
		preset = false,
		format = "percent",
	},
	{
		id = 42,
		key = "chatDelay",
		name = "Chat Delay",
		kind = "slider",
		page = "chat",
		min = 0,
		max = 6,
		step = 0.5,
		default = 0,
		effect = "chat",
		preset = false,
		format = "seconds",
		labels = { [0] = "None" },
	},
	{
		id = 43,
		key = "chatWidth",
		name = "Width",
		kind = "slider",
		page = "chat",
		min = 40,
		max = 320,
		step = 1,
		default = 320,
		effect = "chat",
		preset = false,
		format = "pixels",
	},
	{
		id = 44,
		key = "chatHeightFocused",
		name = "Focused Height",
		kind = "slider",
		page = "chat",
		min = 20,
		max = 180,
		step = 1,
		default = 180,
		effect = "chat",
		preset = false,
		format = "pixels",
	},
	{
		id = 45,
		key = "chatHeightUnfocused",
		name = "Unfocused Height",
		kind = "slider",
		page = "chat",
		min = 20,
		max = 180,
		step = 1,
		default = 90,
		effect = "chat",
		preset = false,
		format = "pixels",
	},
	{
		id = 46,
		key = "commandSuggestions",
		name = "Command Suggestions",
		kind = "toggle",
		page = "chat",
		min = 0,
		max = 1,
		step = 1,
		default = 1,
		effect = "chat",
		preset = false,
		format = "plain",
	},
}

local byKey: { [string]: Entry } = {}
local byId: { [number]: Entry } = {}
for i, entry in ENTRIES do
	assert(entry.id == i, `PlayerSettings: entry {entry.key} must have id {i}`)
	assert(byKey[entry.key] == nil, `PlayerSettings: duplicate key {entry.key}`)
	byKey[entry.key] = entry
	byId[entry.id] = entry
	table.freeze(entry)
end

PlayerSettings.ENTRIES = table.freeze(ENTRIES)
PlayerSettings.byKey = table.freeze(byKey)
PlayerSettings.byId = table.freeze(byId)

--[[ Values ]]

-- The entry of `key` (errors on unknown keys: a typo should not be silent).
function PlayerSettings.entry(key: string): Entry
	local entry = byKey[key]
	assert(entry, `PlayerSettings: unknown setting {key}`)
	return entry
end

-- Highest value of `entry` on this device.
function PlayerSettings.maxOf(entry: Entry, isMobile: boolean?): number
	local max = entry.max
	if isMobile and entry.mobileMax then
		max = math.min(max, entry.mobileMax)
	end
	return max
end

--[[
	`value` snapped to the setting's step and clamped to its range (on phones and tablets also to
	`mobileMax`). NaN and infinities give the default.
]]
function PlayerSettings.clamp(key: string, value: number, isMobile: boolean?): number
	local entry = PlayerSettings.entry(key)
	local max = PlayerSettings.maxOf(entry, isMobile)
	if value ~= value or value == math.huge or value == -math.huge then
		value = if isMobile and entry.mobileDefault ~= nil then entry.mobileDefault else entry.default
	end
	return math.clamp(snap(value, entry.min, entry.step), entry.min, max)
end

-- Is toggle `key` on?
function PlayerSettings.on(values: Values, key: string): boolean
	return (values[key] or 0) >= 0.5
end

--[[
	The LOD balance rule: full detail reaches at most split + 1 (the falloff's own range keeps it
	at least 2). Returns the keys it changed.
]]
function PlayerSettings.balance(values: Values): { string }
	local changed = {}
	local limit = values.detailFalloff + 1
	if values.fullDetail > limit then
		values.fullDetail = limit
		table.insert(changed, "fullDetail")
	end
	return changed
end

--[[ Presets ]]

local function lichenValue(distance: number): number
	return if distance >= PlayerSettings.ALL_LIGHTS then PlayerSettings.ALL_LIGHTS else distance
end

-- Config's cave view: the largest reveal radius (how far big caverns are seen; tunnels from it:
-- revealReach).
local function configReach(table_: any): number
	return math.max(table_.RevealRadius or 0, table_.RevealRadiusMax or 0)
end

-- Values each preset sets (only `preset` entries), before device limits.
local PRESETS: { Values } = {
	-- Low: Config's phone values (view, caves, plants, lights), shadows off, hidden terrain skipped.
	{
		renderDistance = mobile.ViewDistance,
		detailFalloff = mobile.SplitDistance,
		fullDetail = mobile.SplitDistanceL1 or mobile.SplitDistance,
		caveView = configReach(caves.Mobile),
		plants = if render.Foliage then mobile.FoliageDistance else 0,
		shadows = 0,
		farShadows = 0,
		lichenLights = lichenValue(caves.Mobile.LichenLightDistance),
		skipHidden = 1,
	},
	{
		renderDistance = 1024,
		detailFalloff = 2,
		fullDetail = 3,
		caveView = configReach(caves.Mobile),
		plants = 24,
		shadows = 1,
		farShadows = 0,
		lichenLights = lichenValue(caves.LichenLightDistance),
		skipHidden = 0,
	},
	-- High: Config's own view.
	{
		renderDistance = lod.ViewDistance,
		detailFalloff = lod.SplitDistance,
		fullDetail = lod.SplitDistanceL1 or lod.SplitDistance,
		caveView = configReach(caves),
		plants = if render.Foliage then lod.FoliageDistance else 0,
		shadows = bool(render.Shadows),
		farShadows = bool(render.FarShadows),
		lichenLights = lichenValue(caves.LichenLightDistance),
		skipHidden = 0,
	},
	{
		renderDistance = 4096,
		detailFalloff = 3,
		fullDetail = 3,
		caveView = math.max(144, configReach(caves)),
		plants = 64,
		shadows = 1,
		farShadows = 1,
		lichenLights = PlayerSettings.ALL_LIGHTS,
		skipHidden = 0,
	},
}
for _, preset in PRESETS do
	-- (A preset breaking the balance rule would read "Custom" right after being picked.)
	for key, value in preset do
		preset[key] = PlayerSettings.clamp(key, value)
	end
	PlayerSettings.balance(preset)
	table.freeze(preset)
end
PlayerSettings.PRESETS = table.freeze(PRESETS)

-- The keys presets set, in id order.
local PRESET_KEYS: { string } = {}
for _, entry in ENTRIES do
	if entry.preset then
		table.insert(PRESET_KEYS, entry.key)
	end
end
PlayerSettings.PRESET_KEYS = table.freeze(PRESET_KEYS)

--[[
	The preset a device starts on: phones and tablets Low; otherwise by Roblox's saved graphics
	quality (UserGameSettings.SavedQualityLevel: 0 Automatic, 1..10): 1-3 Low (the engine drops
	shadows below 4 anyway), 4-6 Medium, 7-10 or Automatic High.
]]
function PlayerSettings.defaultPreset(quality: number?, isMobile: boolean?): number
	if isMobile then
		return PlayerSettings.LOW
	end
	local level = quality or 0
	if level >= 1 and level <= 3 then
		return PlayerSettings.LOW
	elseif level >= 4 and level <= 6 then
		return PlayerSettings.MEDIUM
	end
	return PlayerSettings.HIGH
end

-- Sets preset `index`'s values (and `preset` itself). Returns the keys that changed.
function PlayerSettings.applyPreset(values: Values, index: number, isMobile: boolean?): { string }
	local changed = {}
	local preset = PRESETS[math.clamp(math.floor(index), 1, #PRESETS)]
	local chosen = PlayerSettings.clamp("preset", index)
	if values.preset ~= chosen then
		values.preset = chosen
		table.insert(changed, "preset")
	end
	for _, key in PRESET_KEYS do
		local value = PlayerSettings.clamp(key, preset[key], isMobile)
		if values[key] ~= value then
			values[key] = value
			table.insert(changed, key)
		end
	end
	for _, key in PlayerSettings.balance(values) do
		table.insert(changed, key)
	end
	return changed
end

-- Do `values` hold preset `index`'s values (as this device clamps them)?
function PlayerSettings.matchesPreset(values: Values, index: number, isMobile: boolean?): boolean
	local preset = PRESETS[index]
	if preset == nil then
		return false
	end
	for _, key in PRESET_KEYS do
		if values[key] ~= PlayerSettings.clamp(key, preset[key], isMobile) then
			return false
		end
	end
	return true
end

-- The preset `values` match (the chosen one first), nil when the player changed one: "Custom".
function PlayerSettings.presetOf(values: Values, isMobile: boolean?): number?
	local base = values.preset
	if base and PlayerSettings.matchesPreset(values, base, isMobile) then
		return base
	end
	for index in PRESETS do
		if PlayerSettings.matchesPreset(values, index, isMobile) then
			return index
		end
	end
	return nil
end

-- Every setting's default for the device, on preset `preset` (default: `defaultPreset`).
function PlayerSettings.defaults(isMobile: boolean?, quality: number?, preset: number?): Values
	local values: Values = {}
	for _, entry in ENTRIES do
		local value = if isMobile and entry.mobileDefault ~= nil then entry.mobileDefault else entry.default
		values[entry.key] = PlayerSettings.clamp(entry.key, value, isMobile)
	end
	PlayerSettings.applyPreset(values, preset or PlayerSettings.defaultPreset(quality, isMobile), isMobile)
	return values
end

--[[
	The values of a profile from what was saved (`saved`: only the keys the player chose): the
	device's defaults, the saved preset's values, then the saved values on top. Returns the
	values and the chosen keys.
]]
function PlayerSettings.load(saved: Values, isMobile: boolean?, quality: number?): (Values, { [string]: boolean })
	local chosen: { [string]: boolean } = {}
	local preset = saved.preset
	if preset ~= nil then
		chosen.preset = true
	end
	local values = PlayerSettings.defaults(isMobile, quality, preset)
	for key, value in saved do
		if byKey[key] and key ~= "preset" then
			values[key] = PlayerSettings.clamp(key, value, isMobile)
			chosen[key] = true
		end
	end
	PlayerSettings.balance(values)
	return values, chosen
end

--[[ What the values mean ]]

--[[
	LodTree's four distances: view distance (blocks), split distance, full detail's split
	distance and full detail's while the camera is underground (all in node sizes), with the
	balance rule applied.
]]
function PlayerSettings.lod(values: Values): (number, number, number, number)
	local split = values.detailFalloff
	local l1 = math.min(values.fullDetail, split + 1)
	local underground = math.clamp(math.ceil(values.caveView / 16) / 2, l1, split + 1)
	return values.renderDistance, split, l1, underground
end

-- How far plants are drawn (blocks; 0: no plants).
function PlayerSettings.foliageDistance(values: Values): number
	return values.plants
end

--[[
	How far the cave view's search reveals tunnels (blocks to section centres; CaveReach): Config's
	Caves.RevealReach at Config's cave view (RevealRadiusMax), in proportion to the slider, in
	whole 8-block bands (SectionGraph.BAND). High: 88, Low and Medium (96): 64, Ultra (144): 96.
]]
function PlayerSettings.revealReach(values: Values): number
	local scaled = Config.Caves.RevealReach * values.caveView / configReach(Config.Caves)
	return math.max(16, math.floor(scaled / 8 + 0.5) * 8)
end

--[[
	The open-space radii of the cave view (Streaming/CaveReach's tracker: in tunnels, at most in big
	caverns, where the search reaches the radius plus a section) for a cave view: the view is the
	largest; tunnels get half of it, at most Config's RevealRadius (High: 64 / 128, Low: 48 / 96,
	as Config and Config.Caves.Mobile have them).
]]
function PlayerSettings.revealRadii(values: Values): (number, number)
	local reach = values.caveView
	return math.min(Config.Caves.RevealRadius, reach / 2), reach
end

-- How far from the camera glow lichen's lights are on (blocks; math.huge: all).
function PlayerSettings.lichenLightDistance(values: Values): number
	local value = values.lichenLights
	return if value >= PlayerSettings.ALL_LIGHTS then math.huge else value
end

-- The fixed build budget (ms), nil for the adaptive one ("Auto").
function PlayerSettings.buildBudget(values: Values): number?
	local value = values.buildBudget
	return if value <= 0 then nil else value
end

-- Lighting.CaveAmbient for the brightness slider: `base` (Config's, "Moody") towards Bright.
function PlayerSettings.caveAmbient(values: Values, base: { number }): { number }
	local t = values.brightness / 100
	local out = {}
	for i = 1, 3 do
		local from = base[i] or 0
		local to = math.max(from, BRIGHT[i])
		out[i] = math.floor(from + (to - from) * t + 0.5)
	end
	return out
end

-- Minecraft's FOV effects: a field of view modifier (x 1.1 flying, x 1.15 sprinting) scaled
-- towards 1 by the FOV Effects slider.
function PlayerSettings.fovModifier(modifier: number, values: Values): number
	return 1 + (modifier - 1) * values.fovEffects / 100
end

-- A volume slider as a multiplier (0..1).
function PlayerSettings.volume(values: Values, key: string): number
	return values[key] / 100
end

-- The effects a change of `key` needs: its own and `also`.
function PlayerSettings.effectsOf(key: string): { string }
	local entry = PlayerSettings.entry(key)
	local list = { entry.effect }
	if entry.also then
		for _, effect in entry.also do
			table.insert(list, effect)
		end
	end
	return list
end

-- How a value reads on its button: "Render Distance: 2048", "Shadows: ON".
function PlayerSettings.valueText(key: string, value: number): string
	local entry = PlayerSettings.entry(key)
	local label = entry.labels and entry.labels[value]
	if label then
		return label
	end
	if entry.kind == "toggle" then
		return if value >= 0.5 then "ON" else "OFF"
	end
	local format = entry.format
	if format == "fullDetail" then
		return tostring(math.floor(value * 32 + 0.5))
	elseif format == "factor" then
		return string.format("%.1f", value)
	elseif format == "percent" then
		return `{value}%`
	elseif format == "ms" then
		return `{value} ms`
	elseif format == "seconds" then
		return string.format("%.1f s", value)
	elseif format == "pixels" then
		return `{value} px`
	end
	return if value == math.floor(value) then tostring(math.floor(value)) else tostring(value)
end

function PlayerSettings.text(key: string, value: number): string
	return `{PlayerSettings.entry(key).name}: {PlayerSettings.valueText(key, value)}`
end

--[[ Encoding ]]

-- The bytes of a profile's values (keys unknown to the schema are left out), in id order.
function PlayerSettings.encode(profile: number, values: Values): buffer
	local entries: { Entry } = {}
	for _, entry in ENTRIES do
		local value = values[entry.key]
		if value ~= nil and value == value then
			table.insert(entries, entry)
		end
	end
	local count = math.min(#entries, 255)
	local b = buffer.create(3 + count * 5)
	buffer.writeu8(b, 0, PlayerSettings.VERSION)
	buffer.writeu8(b, 1, profile)
	buffer.writeu8(b, 2, count)
	for i = 1, count do
		local entry = entries[i]
		local offset = 3 + (i - 1) * 5
		buffer.writeu8(b, offset, entry.id)
		buffer.writef32(b, offset + 1, values[entry.key])
	end
	return b
end

--[[
	A profile and its values from `encode`'s bytes, nil when malformed (another version, a
	profile out of range, a length that does not match). Unknown ids and NaN are dropped; values
	are clamped (a touch profile to the phone limits).
]]
function PlayerSettings.decode(b: buffer): (number?, Values?)
	local length = buffer.len(b)
	if length < 3 then
		return nil, nil
	end
	local version, profile, count = buffer.readu8(b, 0), buffer.readu8(b, 1), buffer.readu8(b, 2)
	if version ~= PlayerSettings.VERSION or PlayerSettings.PROFILE_NAMES[profile] == nil or length ~= 3 + count * 5 then
		return nil, nil
	end
	local isMobile = profile == PlayerSettings.Profile.Touch
	local values: Values = {}
	for i = 1, count do
		local offset = 3 + (i - 1) * 5
		local entry = byId[buffer.readu8(b, offset)]
		local value = buffer.readf32(b, offset + 1)
		if entry and value == value then
			values[entry.key] = PlayerSettings.clamp(entry.key, value, isMobile)
		end
	end
	return profile, values
end

--[[ Saving (DataStore) ]]

-- A profile's values for a DataStore: { [tostring(id)] = value } (JSON keys are strings).
function PlayerSettings.toStored(values: Values): { [string]: number }
	local out: { [string]: number } = {}
	for key, value in values do
		local entry = byKey[key]
		if entry and value == value then
			out[tostring(entry.id)] = value
		end
	end
	return out
end

-- A profile's values back from `toStored` (anything malformed or unknown is dropped).
function PlayerSettings.fromStored(stored: unknown, profile: number): Values
	local values: Values = {}
	if type(stored) ~= "table" then
		return values
	end
	local isMobile = profile == PlayerSettings.Profile.Touch
	for id, value in stored :: { [any]: any } do
		local entry = byId[tonumber(id) or -1]
		if entry and type(value) == "number" and value == value then
			values[entry.key] = PlayerSettings.clamp(entry.key, value, isMobile)
		end
	end
	return values
end

-- The record a player's profiles are saved as: { v = 1, desktop = {...}, touch = {...}, ... }.
function PlayerSettings.toRecord(profiles: { [number]: Values }): { [string]: any }
	local record: { [string]: any } = { v = PlayerSettings.VERSION }
	for profile, name in PlayerSettings.PROFILE_NAMES do
		local values = profiles[profile]
		if values and next(values) ~= nil then
			record[name] = PlayerSettings.toStored(values)
		end
	end
	return record
end

-- A player's profiles from a saved record (anything malformed or unknown is dropped).
function PlayerSettings.fromRecord(record: unknown): { [number]: Values }
	local profiles: { [number]: Values } = {}
	if type(record) ~= "table" then
		return profiles
	end
	for profile, name in PlayerSettings.PROFILE_NAMES do
		local stored = (record :: { [any]: any })[name]
		if stored ~= nil then
			profiles[profile] = PlayerSettings.fromStored(stored, profile)
		end
	end
	return profiles
end

return PlayerSettings
