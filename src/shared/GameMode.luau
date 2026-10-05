--!strict
--[[
	Game modes, as Minecraft 1.20.1 has them (GameType, and the abilities
	GameType.updatePlayerAbilities gives each one):

	  Survival   blocks take time to mine and drop as items, placing uses items up, falls hurt.
	  Creative   every item from the creative inventory, instant breaking, flying (double tap
	             jump), can't be hurt.
	  Adventure  plays like survival (health, falls, drops, pickups, the inventory), but can't break
	             blocks or use items on them (no placing, buckets, Configurator or shears on
	             blocks: Minecraft's mayBuild is false). Blocks with a menu still open.
	  Spectator  always flies, through everything (no collision, untouched by fluids), can't be
	             hurt, is invisible to players who don't spectate, breaks, places, uses and picks up
	             nothing, and opens menus read only. No hotbar, hearts or armour.

	What each mode allows (the ability helpers below):

	                  survival  creative  adventure  spectator
	  mayFly                       x                     x       Abilities.mayfly
	  alwaysFlying                                       x       isAlwaysFlying
	  noClip                                             x       Player.noPhysics
	  instabuild                   x                             Abilities.instabuild
	  invulnerable                 x                     x       Abilities.invulnerable
	  mayBuild           x         x                             Abilities.mayBuild
	  isSurvivalLike     x                   x                   GameType.isSurvival
	  isSpectator                                        x
	  canPickUp          x         x         x
	  canInteract        x         x         x                   (spectators: menus read only)
	  showsHud           x         x         x                   hotbar, item name

	Code asks what a mode allows through these helpers, never `mode == CREATIVE`: `helper(mode)`,
	or `helperOf(player)` for a player's current mode.

	Player attributes, set by the server (Players/GameModes), so every client sees them:
	  ATTRIBUTE             the mode;
	  PREVIOUS_ATTRIBUTE    the mode before the last change (none until it changes once), for
	                        F3 + N and the game mode switcher (ServerPlayerGameMode's previous mode);
	  PERMISSION_ATTRIBUTE  true when the player may change their own mode (Players/GameModeCommand
	                        rules), so the client can refuse F3 + N / F3 + F4 itself.
]]

local Config = require(script.Parent.Config)

local GameMode = {}

GameMode.SURVIVAL = "Survival"
GameMode.CREATIVE = "Creative"
GameMode.ADVENTURE = "Adventure"
GameMode.SPECTATOR = "Spectator"

GameMode.ATTRIBUTE = "IceVoxelGameMode"
GameMode.PREVIOUS_ATTRIBUTE = "IceVoxelPreviousGameMode"
GameMode.PERMISSION_ATTRIBUTE = "IceVoxelGameModePermission"

-- Every mode, by Minecraft's GameType id + 1 (survival 0, creative 1, adventure 2, spectator 3).
GameMode.ALL = table.freeze({ GameMode.SURVIVAL, GameMode.CREATIVE, GameMode.ADVENTURE, GameMode.SPECTATOR })
-- The game mode switcher's order (GameModeSwitcherScreen.GameModeIcon).
GameMode.ORDER = table.freeze({ GameMode.CREATIVE, GameMode.SURVIVAL, GameMode.ADVENTURE, GameMode.SPECTATOR })

-- Is `value` one of the modes?
function GameMode.isValid(value: unknown): boolean
	return type(value) == "string" and table.find(GameMode.ALL, value) ~= nil
end

-- Minecraft's GameType id of a mode (0..3); the wire format of Protocol SetGameMode.
function GameMode.id(mode: string): number
	local index = table.find(GameMode.ALL, mode)
	assert(index, `Unknown game mode {mode}`)
	return index - 1
end

-- The mode with GameType id `id`, or nil.
function GameMode.fromId(id: number): string?
	return GameMode.ALL[id + 1]
end

--[[
	"survival" / "s" / "0", "creative" / "c" / "1", "adventure" / "a" / "2" and "spectator" /
	"sp" / "3" (any case) -> the mode, else nil.
]]
local WORDS: { [string]: string } = {
	survival = GameMode.SURVIVAL,
	s = GameMode.SURVIVAL,
	["0"] = GameMode.SURVIVAL,
	creative = GameMode.CREATIVE,
	c = GameMode.CREATIVE,
	["1"] = GameMode.CREATIVE,
	adventure = GameMode.ADVENTURE,
	a = GameMode.ADVENTURE,
	["2"] = GameMode.ADVENTURE,
	spectator = GameMode.SPECTATOR,
	sp = GameMode.SPECTATOR,
	["3"] = GameMode.SPECTATOR,
}

function GameMode.parse(text: string): string?
	return WORDS[string.lower(text)]
end

-- "Creative" -> "Creative Mode" (Minecraft's gameMode.* names).
function GameMode.displayName(mode: string): string
	return `{mode} Mode`
end

-- The mode new players get (Config.Gameplay.DefaultGameMode, else survival).
function GameMode.default(): string
	return GameMode.parse(Config.Gameplay.DefaultGameMode) or GameMode.SURVIVAL
end

-- A player's mode (the default until the server has set it).
function GameMode.of(player: Instance): string
	local mode = player:GetAttribute(GameMode.ATTRIBUTE)
	if GameMode.isValid(mode) then
		return mode :: string
	end
	return GameMode.default()
end

-- A player's previous mode (nil until their mode has changed once).
function GameMode.previousOf(player: Instance): string?
	local mode = player:GetAttribute(GameMode.PREVIOUS_ATTRIBUTE)
	return if GameMode.isValid(mode) then mode :: string else nil
end

-- May the player change their own mode (/gamemode, F3 + N, F3 + F4)? The server decides; this is
-- what it told the clients.
function GameMode.mayChangeOwn(player: Instance): boolean
	return player:GetAttribute(GameMode.PERMISSION_ATTRIBUTE) == true
end

--[[ Abilities ]]

-- May fly (creative: double tap jump; spectator: always).
function GameMode.mayFly(mode: string): boolean
	return mode == GameMode.CREATIVE or mode == GameMode.SPECTATOR
end

-- Always flying, never on the ground (spectator).
function GameMode.alwaysFlying(mode: string): boolean
	return mode == GameMode.SPECTATOR
end

-- Moves through blocks, untouched by fluids (spectator).
function GameMode.noClip(mode: string): boolean
	return mode == GameMode.SPECTATOR
end

-- Breaks at once, places and uses without using items up, tools never wear, nothing drops, the
-- creative inventory, creative only blocks (creative).
function GameMode.instabuild(mode: string): boolean
	return mode == GameMode.CREATIVE
end

-- Can't be hurt: no fall damage or any other damage (creative, spectator).
function GameMode.invulnerable(mode: string): boolean
	return mode == GameMode.CREATIVE or mode == GameMode.SPECTATOR
end

-- May break blocks, place them and use items on them (survival, creative).
function GameMode.mayBuild(mode: string): boolean
	return mode == GameMode.SURVIVAL or mode == GameMode.CREATIVE
end

-- Health counts: hearts and armour show (survival, adventure: GameType.isSurvival).
function GameMode.isSurvivalLike(mode: string): boolean
	return mode == GameMode.SURVIVAL or mode == GameMode.ADVENTURE
end

function GameMode.isSpectator(mode: string): boolean
	return mode == GameMode.SPECTATOR
end

-- Picks up item entities (everyone but spectators).
function GameMode.canPickUp(mode: string): boolean
	return mode ~= GameMode.SPECTATOR
end

--[[
	Changes things through menus and the world: slot clicks, drags, dropping items, attacking, using
	blocks and items (everyone but spectators). Spectators still open menus, read only.
]]
function GameMode.canInteract(mode: string): boolean
	return mode ~= GameMode.SPECTATOR
end

-- Has the hotbar and the held item's name (everyone but spectators, who get the spectator menu).
-- Hearts and armour show for isSurvivalLike modes only.
function GameMode.showsHud(mode: string): boolean
	return mode ~= GameMode.SPECTATOR
end

--[[ The same for a player's current mode ]]

function GameMode.mayFlyOf(player: Instance): boolean
	return GameMode.mayFly(GameMode.of(player))
end

function GameMode.alwaysFlyingOf(player: Instance): boolean
	return GameMode.alwaysFlying(GameMode.of(player))
end

function GameMode.noClipOf(player: Instance): boolean
	return GameMode.noClip(GameMode.of(player))
end

function GameMode.instabuildOf(player: Instance): boolean
	return GameMode.instabuild(GameMode.of(player))
end

function GameMode.invulnerableOf(player: Instance): boolean
	return GameMode.invulnerable(GameMode.of(player))
end

function GameMode.mayBuildOf(player: Instance): boolean
	return GameMode.mayBuild(GameMode.of(player))
end

function GameMode.isSurvivalLikeOf(player: Instance): boolean
	return GameMode.isSurvivalLike(GameMode.of(player))
end

function GameMode.isSpectatorOf(player: Instance): boolean
	return GameMode.isSpectator(GameMode.of(player))
end

function GameMode.canPickUpOf(player: Instance): boolean
	return GameMode.canPickUp(GameMode.of(player))
end

function GameMode.canInteractOf(player: Instance): boolean
	return GameMode.canInteract(GameMode.of(player))
end

function GameMode.showsHudOf(player: Instance): boolean
	return GameMode.showsHud(GameMode.of(player))
end

--[[
	Is the player in creative mode itself? Kept for older callers: an ability check should use the
	helper it means (usually instabuildOf, which is the same thing today).
]]
function GameMode.isCreative(player: Instance): boolean
	return GameMode.of(player) == GameMode.CREATIVE
end

return GameMode
