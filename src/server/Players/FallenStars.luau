--!strict
--[[
	Terraria's Fallen Stars (Config.Mana.Stars; the rules are Shared/Mana/StarFall, pure and
	tested): stars fall at night near every player, and the ones left lying about vanish at dawn.

	  Falling    once a second while it is night (time of day NightStart..NightEnd, World/
	             TimeOfDay), every player in survival, adventure or creative (not spectators)
	             rolls StarFall.chance (PerNight 5 a night on average, whatever the day's length):
	             a Fallen Star item (Entities.spawnItem: ordinary item physics, picked up as any
	             item) appears FallHeight 40 blocks over the top block of a random column 16..48
	             blocks away (StarFall.pick, StarFall.topY on `world:peekBlock`: a column the
	             server hasn't generated gets none), falling from StarFall.START_SPEED 1 block a
	             tick, and entity.fallen_star.fall plays ten blocks over where it will land (the
	             clients near hear it come; they draw it glowing: client Entities/EntityRenderer).
	             Weather doesn't matter (Terraria's).
	  Dawn       when the night ends (the clock passing NightEnd, or /time setting day), every
	             Fallen Star item on the ground vanishes, the ones a player dropped too (Terraria's
	             rule); those in inventories and chests stay.
	  Off        nothing falls with Config.Mana.Enabled or Config.Mana.Stars.Enabled false.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local StarFall = require(Shared.Mana.StarFall)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local TimeOfDay = require(script.Parent.Parent.World.TimeOfDay)
local Sounds = require(script.Parent.Parent.Audio.Sounds)
local Entities = require(script.Parent.Parent.Entities.Entities)
local PlayerPositions = require(script.Parent.PlayerPositions)

local FallenStars = {}

local STAR = Items.id.FallenStar
local FALL = "entity.fallen_star.fall"
-- Blocks over the landing spot the fall's sound plays.
local SOUND_HEIGHT = 10

local random = Random.new()
local roll = function(): number
	return random:NextNumber()
end

-- Does `player` see stars fall (survival, adventure, creative)?
local function seesStars(player: Player): boolean
	local mode = GameMode.of(player)
	return GameMode.isSurvivalLike(mode) or GameMode.instabuild(mode)
end

-- A star near the player at (x, z), if its column is generated.
local function drop(world: WorldServer.World, x: number, z: number)
	local sx, sz = StarFall.pick(roll, x, z)
	local top = StarFall.topY(function(bx: number, by: number, bz: number): number?
		return world:peekBlock(bx, by, bz)
	end, sx, sz, Config.WorldHeight - 1)
	if top == nil then
		return
	end
	local y = StarFall.spawnY(top)
	if Entities.spawnItem({ item = STAR, count = 1 }, sx, y, sz, 0, -StarFall.START_SPEED, 0) ~= 0 then
		Sounds.play(FALL, sx, top + 1 + SOUND_HEIGHT, sz)
	end
end

-- Every Fallen Star item in the world vanishes (dawn). How many.
local function vanish(): number
	local entities = Entities.world()
	if entities == nil then
		return 0
	end
	local count = 0
	for _, entity in entities:each() do
		if entity.item == STAR then
			entities:remove(entity.id)
			count += 1
		end
	end
	return count
end

-- Starts the stars (see the header).
function FallenStars.start(_net: any, world: WorldServer.World)
	if not (Config.Mana.Enabled and Config.Mana.Stars.Enabled) then
		return
	end
	local last = TimeOfDay.get()
	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt: number)
		elapsed += dt
		if elapsed < 1 then
			return
		end
		elapsed = math.min(elapsed - 1, 1)
		local now = TimeOfDay.get()
		if StarFall.dawned(last, now) then
			vanish()
		end
		last = now
		if not StarFall.isNight(now) then
			return
		end
		local chance = StarFall.chance(Config.Time.DayLength)
		for _, player in Players:GetPlayers() do
			if random:NextNumber() < chance and seesStars(player) then
				local x, _, z = PlayerPositions.feet(player)
				if x then
					drop(world, x, z)
				end
			end
		end
	end)
end

return FallenStars
