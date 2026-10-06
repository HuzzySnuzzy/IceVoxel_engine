--!strict
--[[
	Background music, as Minecraft's (Audio/MusicRules decides when and which; the tracks are in
	Shared/Sounds/MusicList).

	  Places   surface tracks above ground, cave tracks in caves: the sky light reaching the camera
	           (Rendering/LightingController.skyExposure) decides, with MusicRules' thresholds and
	           delay. A track of the other kind fades out over Config.Music.FadeSeconds when the
	           player goes underground or comes back up, and one of the new kind follows.
	  Timing   the first track about FirstDelay seconds after joining, then one every MinDelay to
	           MaxDelay seconds after the last ends (Minecraft's 10 to 20 minutes).
	  Playing  one Sound (SoundService.IceVoxelMusic), flat, never looped. Its file is preloaded
	           first (ContentProvider); one that fails to load or takes longer than LoadTimeout
	           seconds is skipped from then on, with a warning, and another plays soon after.
	  Volume   Config.Music.Volume x the master and music volumes (Config.Sounds and the player's
	           Music & Sounds settings: SoundPlayer.sourceVolume("music")), x the fade. Nothing new
	           starts while that is 0, and nothing at all without sound (Config.Sounds.Enabled) or
	           with Config.Music.Enabled false.
	  Toast    when a track starts, the "Now Playing" toast (Ui/MusicToast) shows its title: the
	           MusicList's Title, else the audio's name on Roblox (MarketplaceService, looked up
	           once per track), else "Unknown Track".
]]

local ContentProvider = game:GetService("ContentProvider")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local MusicList = require(Shared.Sounds.MusicList)

local LightingController = require(script.Parent.Parent.Rendering.LightingController)
local MusicToast = require(script.Parent.Parent.Ui.MusicToast)
local MusicRules = require(script.Parent.MusicRules)
local SoundPlayer = require(script.Parent.SoundPlayer)

type Place = MusicRules.Place
type Track = MusicList.Track

-- The track playing or loading.
type Current = { place: Place, index: number, track: Track, playing: boolean, title: string? }

local Music = {}

local started = false
local sound: Sound? = nil
local state: MusicRules.State? = nil
local current: Current? = nil
-- 1 while a track plays, down to 0 while it fades out.
local fade = 1
-- Titles looked up on Roblox, by id.
local titles: { [string]: string } = {}
local toasts = true

local function tracksOf(place: Place): { Track }
	return if place == "cave" then MusicList.Cave else MusicList.Surface
end

local COUNTS: { [Place]: number } = { surface = #MusicList.Surface, cave = #MusicList.Cave }

local function random(): number
	return math.random()
end

-- The title the toast shows for `track` (may yield the first time, to ask Roblox).
local function titleOf(track: Track): string
	if track.Title ~= "" then
		return track.Title
	end
	local known = titles[track.Id]
	if known then
		return known
	end
	local name = "Unknown Track"
	local number = tonumber(string.match(track.Id, "^rbxassetid://(%d+)$"))
	if number then
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(number, Enum.InfoType.Asset)
		end)
		if ok and type(info) == "table" and type(info.Name) == "string" and info.Name ~= "" then
			name = info.Name
		end
	end
	titles[track.Id] = name
	return name
end

-- The track stopped (`ending`, MusicRules.Ending).
local function stopped(ending: MusicRules.Ending, failedIndex: number?)
	current = nil
	fade = 1
	local music = state
	if music then
		MusicRules.ended(music, Config.Music, ending, random, failedIndex)
	end
end

-- Loads track `index` of `place` and plays it, unless something else happened meanwhile.
local function begin(place: Place, index: number)
	local track = tracksOf(place)[index]
	local player = sound
	if track == nil or player == nil then
		stopped("failed", index)
		return
	end
	local mine: Current = { place = place, index = index, track = track, playing = false }
	current = mine
	fade = 1
	player:Stop()
	player.SoundId = track.Id
	task.spawn(function()
		local status: Enum.AssetFetchStatus? = nil
		pcall(function()
			ContentProvider:PreloadAsync({ track.Id }, function(_, fetched: Enum.AssetFetchStatus)
				status = fetched
			end)
		end)
		local deadline = os.clock() + Config.Music.LoadTimeout
		while status ~= Enum.AssetFetchStatus.Failure and not player.IsLoaded and os.clock() < deadline do
			if current ~= mine then
				return
			end
			task.wait(0.1)
		end
		local title = titleOf(track)
		if current ~= mine then
			return
		end
		local music = state
		if music and music.fading then
			-- (The player changed place while it loaded: it never starts.)
			stopped("faded")
			return
		end
		if not player.IsLoaded then
			warn(`[IceVoxel] Music track {track.Id} ({place}) did not load; it is skipped from now on.`)
			stopped("failed", index)
			return
		end
		mine.title = title
		mine.playing = true
		player.TimePosition = 0
		player:Play()
		if toasts and Config.Music.Toast then
			MusicToast.show(title)
		end
	end)
end

local function step(dt: number)
	local music = state
	local player = sound
	if music == nil or player == nil then
		return
	end
	local settings = Config.Music
	local level = if settings.Enabled then SoundPlayer.sourceVolume("music") else 0
	-- (Muted with nothing playing: the music waits, nothing is downloaded.)
	if level > 0 or music.playing then
		for _, action in MusicRules.step(music, settings, dt, LightingController.skyExposure(), COUNTS, random) do
			if action.kind == "play" then
				begin(action.place, action.track)
			end
		end
	end
	if music.fading then
		local playing = current
		if playing == nil or not playing.playing then
			-- (A track still loading is dropped by its loader.)
		else
			fade -= dt / math.max(settings.FadeSeconds, 1e-3)
			if fade <= 0 then
				player:Stop()
				stopped("faded")
			end
		end
	end
	player.Volume = settings.Volume * level * math.clamp(fade, 0, 1)
end

function Music.start()
	if started then
		return
	end
	started = true
	local player = Instance.new("Sound")
	player.Name = "IceVoxelMusic"
	player.Looped = false
	player.Volume = 0
	player.Parent = SoundService
	sound = player
	local exposure = LightingController.skyExposure()
	state = MusicRules.new(Config.Music, MusicRules.placeOf(Config.Music, exposure))
	player.Ended:Connect(function()
		local playing = current
		if playing and playing.playing then
			stopped("finished")
		end
	end)
	RunService.Heartbeat:Connect(step)
end

-- The player's Music Toasts setting.
function Music.setToasts(value: boolean)
	toasts = value
	MusicToast.setEnabled(value)
end

-- For F3: where the player is for the music, what plays (its title) and the seconds until the next.
function Music.status(): (string, string?, number)
	local music = state
	local playing = current
	if music == nil then
		return "surface", nil, 0
	end
	local title = if playing and playing.playing then playing.title else nil
	return music.place, title, math.max(music.wait, 0)
end

return Music
