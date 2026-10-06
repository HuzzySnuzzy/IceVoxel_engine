--!strict
--[[
	Plays the game's sounds on this client: Minecraft's sound events (Shared/Sounds) at a position
	in the world, or flat for the interface.

	  From       the server's Sound messages (what other players and the world do near the player;
	             Protocol `Sound`, routed here by Net/ClientNet) and this client's own actions,
	             played at once: BlockInteraction (mining hits, breaking, placing),
	             Audio/MovementSounds (footsteps, swimming, splashes, hurting landings), the screens'
	             buttons and tabs, Audio/Ambience (a lit furnace, caves). Events whose `side` is
	             "server" only ever come from the server.
	  3D         a pool of POSITIONED_VOICES Sounds, each in an Attachment of one anchored,
	             invisible Part (workspace.IceVoxelAudio.Emitter) moved to the sound: full volume
	             within Config.Sounds.MinDistance blocks, fading out linearly to the event's
	             maxDistance. Sounds out of hearing never take a voice.
	  Listener   the camera, as in Minecraft, but never more than SoundRules.LISTENER_REACH blocks
	             from the eyes it looks at (Camera.Focus): Roblox's camera zooms out to 128 studs,
	             where the world near the player would fall silent (SoundService:SetListener, every
	             frame after the camera; a Scriptable camera is left as it is).
	  2D         interface events (`ui`) play on FLAT_VOICES Sounds in SoundService.IceVoxelAudio.
	  Voices     a voice is free again once its sound ends, or when it is cut at the event's
	             `duration`; when all are busy the oldest is taken, and a kind of sound never has
	             more than a few at once (overlapping mining hits, many footsteps:
	             SoundRules.CAPS). At most MAX_PER_FRAME sounds start per frame. Nothing is created
	             per sound.
	  Volume     the event's Volume (or the replacement's) x the cue's x Config.Sounds.Volume x
	             Config.Sounds.Sources[event.source], each of those two times the player's Music &
	             Sounds setting (`setPlayerSettings`); the pitch varies randomly by the event's
	             pitchVariance (SoundRules.playback). The player's footsteps, interface clicks and
	             cave rumble switches can only turn off what Config.Sounds has on (`allows`).
	  Files      every file the catalogue uses is preloaded (ContentProvider). One whose Sound has
	             not loaded after SoundRules.LOAD_TIMEOUT seconds (FAILED_GRACE once the preload
	             reported it failed) is replaced by its events' `fallback` from then on, with a
	             warning in the output (SoundRules.loadFailed).
	  Overrides  a developer's Sounds in a Folder named Config.Sounds.OverrideFolder in SoundService
	             (else ReplicatedStorage), named like an event or its category, replace it
	             (SoundRules.chooseOverride; several with one name are picked from at random).
	             Their SoundId, Volume, PlaybackSpeed and SoundGroup are used, heard as far as the
	             event. The folder is watched: Sounds added or removed during the game count.
	  Defaults   Roblox's own character sounds (PlayerScripts.RbxCharacterSounds: running,
	             landing, dying...) would double these, so that script is disabled and the sounds
	             it made are removed.

	Config.Sounds.Enabled = false plays nothing (and leaves Roblox's character sounds alone).
	Positions are in blocks.
]]

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Protocol = require(Shared.Net.Protocol)
local Sounds = require(Shared.Sounds)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local SoundRules = require(script.Parent.SoundRules)

local BLOCK = Config.BlockSize
local POSITIONED_VOICES = 32
local FLAT_VOICES = 4
-- Most sounds started in one frame (a burst of server cues; the rest are dropped).
local MAX_PER_FRAME = 32
-- A voice whose Sound is not playing this long (seconds) after it started is free: its sound
-- ended, or its file never loaded.
local START_GRACE = 0.5
-- Sounds out of hearing by more than this (studs) are not played.
local CULL_SLACK = 2
local FOLDER = "IceVoxelAudio"
-- The Sounds RbxCharacterSounds puts in characters' root parts.
local DEFAULT_SOUNDS: { [string]: boolean } = {
	Climbing = true,
	Died = true,
	FreeFalling = true,
	GettingUp = true,
	Jumping = true,
	Landing = true,
	Running = true,
	Splash = true,
	Swimming = true,
}

type Event = Sounds.Event

type Voice = { sound: Sound, attachment: Attachment?, stopAt: number }
type Bank = { pool: SoundRules.Pool, voices: { Voice } }

local SoundPlayer = {}

local started = false
local enabled = false
local positioned: Bank? = nil
local flat: Bank? = nil
local playedThisFrame = 0
-- Files that failed to load (their events play their fallback).
local failed: { [string]: boolean } = {}
-- Where the player hears from (studs; SoundRules.listenerAt), nil before the first frame.
local listenerPosition: Vector3? = nil
-- The player's settings (Settings/: Music & Sounds), on top of Config.Sounds.
local playerVolume = 1
local playerSources: { [string]: number } = {}
local playerToggles: { [string]: boolean } = {}
-- Config.Sounds with the player's volumes multiplied in (refilled for every sound).
local mixed: SoundRules.Settings = { Volume = 1, Sources = {} }
-- Replacement Sounds by name; nil when they need indexing again.
local overrideIndex: { [string]: { Sound } }? = nil
local preloadedOverrides: { [Sound]: boolean } = setmetatable({}, { __mode = "k" }) :: any

--[[ Files ]]

local function markFailed(id: string)
	if failed[id] then
		return
	end
	failed[id] = true
	warn(`[IceVoxel] Sound file {id} did not load; the events using it play their fallback, if any.`)
end

-- Preloads every file the catalogue uses and notes the ones that do not load.
local function preload(holder: Instance)
	local probes: { [string]: Sound } = {}
	local list: { Sound } = {}
	for _, id in Sounds.contentIds() do
		local probe = Instance.new("Sound")
		probe.Name = "Preload"
		probe.SoundId = id
		probe.Volume = 0
		probe.Parent = holder
		probes[id] = probe
		table.insert(list, probe)
	end
	-- What PreloadAsync reported per file ("ok" or "failed"). Local rbxasset:// files may report
	-- nothing, or a failure although they load: a probe that loaded always counts as loaded.
	local reported: { [string]: SoundRules.LoadReport } = {}
	pcall(function()
		ContentProvider:PreloadAsync(list, function(contentId: string, status: Enum.AssetFetchStatus)
			if status == Enum.AssetFetchStatus.Success then
				reported[contentId] = "ok"
			elseif status == Enum.AssetFetchStatus.Failure or status == Enum.AssetFetchStatus.TimedOut then
				reported[contentId] = "failed"
			end
		end)
	end)
	local since = os.clock()
	while true do
		local waiting = false
		for id, probe in probes do
			if SoundRules.loadPending(probe.IsLoaded, reported[id], os.clock() - since) then
				waiting = true
				break
			end
		end
		if not waiting then
			break
		end
		task.wait(0.25)
	end
	for id, probe in probes do
		if SoundRules.loadFailed(probe.IsLoaded, reported[id]) then
			markFailed(id)
		end
		probe:Destroy()
	end
end

--[[ Overrides ]]

local overrideConnections: { RBXScriptConnection } = {}
local watchedFolder: Instance? = nil

local function invalidate()
	overrideIndex = nil
end

local function overrideFolder(): Instance?
	local name = Config.Sounds.OverrideFolder
	return SoundService:FindFirstChild(name) or ReplicatedStorage:FindFirstChild(name)
end

-- Replacement Sounds by name (indexed again after the folder changes).
local function overrides(): { [string]: { Sound } }
	local index = overrideIndex
	if index then
		return index
	end
	local built: { [string]: { Sound } } = {}
	local folder = overrideFolder()
	if folder ~= watchedFolder then
		for _, connection in overrideConnections do
			connection:Disconnect()
		end
		table.clear(overrideConnections)
		watchedFolder = folder
		if folder then
			table.insert(overrideConnections, folder.DescendantAdded:Connect(invalidate))
			table.insert(overrideConnections, folder.DescendantRemoving:Connect(invalidate))
		end
	end
	local fresh: { Sound } = {}
	if folder then
		for _, descendant in folder:GetDescendants() do
			if descendant:IsA("Sound") and descendant.SoundId ~= "" then
				local list = built[descendant.Name]
				if list == nil then
					list = {}
					built[descendant.Name] = list
				end
				table.insert(list, descendant)
				if not preloadedOverrides[descendant] then
					preloadedOverrides[descendant] = true
					table.insert(fresh, descendant)
				end
			end
		end
	end
	if #fresh > 0 then
		task.spawn(function()
			pcall(function()
				ContentProvider:PreloadAsync(fresh)
			end)
		end)
	end
	overrideIndex = built
	return built
end

-- Rebuilds the index when a folder with the override name comes or goes.
local function watchService(service: Instance)
	local function check(child: Instance)
		if child.Name == Config.Sounds.OverrideFolder then
			invalidate()
		end
	end
	service.ChildAdded:Connect(check)
	service.ChildRemoved:Connect(check)
end

--[[ Roblox's character sounds ]]

local function removeDefaultSounds()
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		if root then
			for _, child in root:GetChildren() do
				if
					child:IsA("Sound")
					and DEFAULT_SOUNDS[child.Name]
					and string.find(child.SoundId, "^rbxasset://sounds/") ~= nil
				then
					child:Stop()
					child:Destroy()
				end
			end
		end
	end
end

local function silenceDefaults()
	local player = Players.LocalPlayer
	local scripts = player:FindFirstChildOfClass("PlayerScripts") or player:WaitForChild("PlayerScripts", 10)
	if scripts == nil then
		return
	end
	local function disable(child: Instance)
		-- (BaseScript: a LocalScript, or a Script with a client RunContext.)
		if child.Name == "RbxCharacterSounds" and child:IsA("BaseScript") and child.Enabled then
			child.Enabled = false
			removeDefaultSounds()
		end
	end
	for _, child in scripts:GetChildren() do
		disable(child)
	end
	scripts.ChildAdded:Connect(disable)
end

--[[ Listener ]]

-- Where the player hears from (studs): the listener set last frame, else the camera.
local function hearingPoint(): Vector3?
	if listenerPosition then
		return listenerPosition
	end
	local camera = workspace.CurrentCamera
	return if camera then camera.CFrame.Position else nil
end

-- Puts Roblox's listener where the player hears from (after the camera moved this frame).
local function updateListener()
	local camera = workspace.CurrentCamera
	if camera == nil or camera.CameraType == Enum.CameraType.Scriptable then
		-- (A scripted camera, a cutscene say, hears from where it is.)
		if listenerPosition then
			listenerPosition = nil
			SoundService:SetListener(Enum.ListenerType.Camera)
		end
		return
	end
	local cframe = camera.CFrame
	local eye, focus = cframe.Position / BLOCK, camera.Focus.Position / BLOCK
	local x, y, z = SoundRules.listenerAt(eye.X, eye.Y, eye.Z, focus.X, focus.Y, focus.Z, SoundRules.LISTENER_REACH)
	local position = Vector3.new(x, y, z) * BLOCK
	listenerPosition = position
	SoundService:SetListener(Enum.ListenerType.CFrame, cframe.Rotation + position)
end

--[[ Voices ]]

local function newBank(size: number, parent: Instance, positionedVoices: boolean): Bank
	local voices: { Voice } = table.create(size)
	for i = 1, size do
		local sound = Instance.new("Sound")
		sound.Name = `Voice{i}`
		local attachment: Attachment? = nil
		if positionedVoices then
			sound.RollOffMode = Enum.RollOffMode.Linear
			local holder = Instance.new("Attachment")
			holder.Name = `Voice{i}`
			holder.Parent = parent
			sound.Parent = holder
			attachment = holder
		else
			sound.Parent = parent
		end
		voices[i] = { sound = sound, attachment = attachment, stopAt = math.huge }
	end
	return { pool = SoundRules.newPool(size), voices = voices }
end

-- Frees voices whose sound ended, stopping those cut at their duration.
local function sweep(bank: Bank, now: number)
	for i, voice in bank.voices do
		local state = bank.pool.voices[i]
		if state.busy then
			if now >= voice.stopAt then
				voice.sound:Stop()
				SoundRules.release(bank.pool, i)
			elseif now - state.startedAt > START_GRACE and not voice.sound.IsPlaying then
				SoundRules.release(bank.pool, i)
			end
		end
	end
end

local function overrideOf(sound: Sound?): SoundRules.Override?
	if sound == nil then
		return nil
	end
	return { id = sound.SoundId, volume = sound.Volume, speed = sound.PlaybackSpeed }
end

--[[
	Starts `event` on a voice of `bank`, at `position` (studs; nil: flat). Returns whether it
	plays.
]]
local function start(bank: Bank, event: Event, position: Vector3?, cueVolume: number, cuePitch: number): boolean
	if playedThisFrame >= MAX_PER_FRAME then
		return false
	end
	local replacement = SoundRules.chooseOverride(overrides(), Sounds.lookupNames(event.index), math.random())
	-- (Config.Sounds is read live: a developer may change it during the game.)
	local settings = Config.Sounds :: any
	mixed.Volume = settings.Volume * playerVolume
	local source = event.source
	mixed.Sources[source] = (settings.Sources[source] or 1) * (playerSources[source] or 1)
	local playback =
		SoundRules.playback(event, overrideOf(replacement), failed, cueVolume, cuePitch, math.random(), mixed)
	if playback.volume <= 0 then
		return false
	end
	local range = playback.range * BLOCK
	if position then
		local listener = hearingPoint()
		if listener and (listener - position).Magnitude > range + CULL_SLACK then
			return false
		end
	end
	playedThisFrame += 1
	local now = os.clock()
	local key = SoundRules.voiceKey(event)
	local index = SoundRules.acquire(bank.pool, key, SoundRules.capOf(key), now)
	local voice = bank.voices[index]
	local sound = voice.sound
	if sound.Playing then
		sound:Stop()
	end
	sound.SoundId = playback.id
	sound.Volume = playback.volume
	sound.PlaybackSpeed = playback.pitch
	sound.SoundGroup = if replacement then replacement.SoundGroup else nil
	local attachment = voice.attachment
	if position and attachment then
		sound.RollOffMaxDistance = range
		sound.RollOffMinDistance = math.min(Config.Sounds.MinDistance * BLOCK, range)
		attachment.Position = position
	end
	sound.TimePosition = 0
	sound:Play()
	voice.stopAt = if playback.length then now + playback.length else math.huge
	return true
end

local function resolve(sound: (number | string)?): Event?
	if sound == nil then
		return nil
	end
	if type(sound) == "string" then
		-- (Errors on unknown names, so a typo is not just silent.)
		return Sounds.get(Sounds.id[sound])
	end
	return Sounds.get(sound)
end

local function playEvent(event: Event, position: Vector3?, volume: number?, pitch: number?): boolean
	local bank = if event.ui or position == nil then flat else positioned
	if bank == nil or not enabled then
		return false
	end
	return start(bank, event, if event.ui then nil else position, volume or 1, pitch or 1)
end

--[[ API ]]

--[[
	The player's Music & Sounds settings: the master volume and one per source (blocks, players,
	ambient, ui; 0..1, multiplying Config.Sounds' own), and the switches "footsteps", "interface"
	and "ambient" (the cave rumble).
]]
function SoundPlayer.setPlayerSettings(volume: number, sources: { [string]: number }, toggles: { [string]: boolean })
	playerVolume = volume
	playerSources = table.clone(sources)
	playerToggles = table.clone(toggles)
end

--[[
	Do footsteps ("footsteps"), interface clicks ("interface") or the cave rumble ("ambient")
	play: on in Config.Sounds (Footsteps, Interface, Ambient) and not switched off by the player.
]]
function SoundPlayer.allows(kind: string): boolean
	local configured = if kind == "footsteps"
		then Config.Sounds.Footsteps
		elseif kind == "interface" then Config.Sounds.Interface
		elseif kind == "ambient" then Config.Sounds.Ambient
		else true
	return configured and playerToggles[kind] ~= false
end

-- Whether sounds play (started, and Config.Sounds.Enabled).
function SoundPlayer.isEnabled(): boolean
	return enabled
end

-- Where the player hears from (blocks): the camera, at most SoundRules.LISTENER_REACH blocks
-- from the eyes. nil without a camera.
function SoundPlayer.listener(): Vector3?
	local point = hearingPoint()
	return if point then point / BLOCK else nil
end

--[[
	Plays event `sound` (a number or name of Shared/Sounds; nil plays nothing, an unknown name
	errors) at (x, y, z) in blocks, for this player only. Interface events play flat. `volume` and
	`pitch` multiply the event's own. Returns whether it plays (not before `start`, when sounds
	are off, out of hearing, or past this frame's limit).
]]
function SoundPlayer.play(
	sound: (number | string)?,
	x: number,
	y: number,
	z: number,
	volume: number?,
	pitch: number?
): boolean
	local event = resolve(sound)
	if event == nil then
		return false
	end
	return playEvent(event, Vector3.new(x, y, z) * BLOCK, volume, pitch)
end

-- Plays the sound `block` makes for `action` ("break", "place", "hit", "step", "fall"; its sound
-- type's) at the centre of block (x, y, z). Silent blocks play nothing.
function SoundPlayer.playBlock(
	block: number,
	action: string,
	x: number,
	y: number,
	z: number,
	volume: number?,
	pitch: number?
): boolean
	return SoundPlayer.play(Sounds.block(block, action), x + 0.5, y + 0.5, z + 0.5, volume, pitch)
end

-- Plays event `sound` flat (no position), for this player only.
function SoundPlayer.playFlat(sound: (number | string)?, volume: number?, pitch: number?): boolean
	local event = resolve(sound)
	if event == nil then
		return false
	end
	return playEvent(event, nil, volume, pitch)
end

-- An interface button or tab was clicked (ui.button.click; Config.Sounds.Interface).
function SoundPlayer.click()
	if SoundPlayer.allows("interface") then
		SoundPlayer.playFlat("ui.button.click")
	end
end

-- A sound the server sent (Protocol `Sound`).
local function playCue(cue: Protocol.SoundCue)
	local event = Sounds.get(cue.sound)
	if event then
		playEvent(event, Vector3.new(cue.x, cue.y, cue.z) * BLOCK, cue.volume, cue.pitch)
	end
end

--[[
	Creates the voices, routes the server's Sound messages here, preloads the files and silences
	Roblox's character sounds. With Config.Sounds.Enabled false only the messages are taken (and
	dropped).
]]
function SoundPlayer.start()
	if started then
		return
	end
	started = true
	ClientNet.on(Protocol.ServerMessage.Sound, function(payload: buffer)
		if not enabled then
			return
		end
		local cues = Protocol.decodeSounds(payload)
		if cues then
			for _, cue in cues do
				playCue(cue)
			end
		end
	end)
	if not Config.Sounds.Enabled then
		return
	end

	local world = Instance.new("Folder")
	world.Name = FOLDER
	local emitter = Instance.new("Part")
	emitter.Name = "Emitter"
	emitter.Anchored = true
	emitter.CanCollide = false
	emitter.CanQuery = false
	emitter.CanTouch = false
	emitter.CastShadow = false
	emitter.Transparency = 1
	emitter.Size = Vector3.one
	emitter.CFrame = CFrame.identity
	emitter.Parent = world
	local positionedBank = newBank(POSITIONED_VOICES, emitter, true)
	world.Parent = workspace

	local interface = Instance.new("Folder")
	interface.Name = FOLDER
	local flatBank = newBank(FLAT_VOICES, interface, false)
	interface.Parent = SoundService
	positioned, flat = positionedBank, flatBank
	enabled = true

	watchService(SoundService)
	watchService(ReplicatedStorage)

	RunService:BindToRenderStep("IceVoxelSoundListener", Enum.RenderPriority.Camera.Value + 1, updateListener)
	RunService.Heartbeat:Connect(function()
		playedThisFrame = 0
		local now = os.clock()
		sweep(positionedBank, now)
		sweep(flatBank, now)
	end)

	task.spawn(preload, interface)
	task.spawn(silenceDefaults)
end

return SoundPlayer
