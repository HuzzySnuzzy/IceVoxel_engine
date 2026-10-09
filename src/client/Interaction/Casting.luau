--!strict
--[[
	Magic on this player's client, for Interaction/BlockInteraction: using a magic weapon or a Mana
	Crystal without a block (Shared/Magic/Casting; the server's checks are server Players/Magic).
	It comes after a block's own use (a chest still opens with a wand in hand) and after drinking
	and eating, in survival, adventure and creative, never for spectators.

	  weapon   while the use button is held (BlockInteraction calls `use` on the press and every
	           frame while it stays down), it casts every `useTicks` of the weapon (ItemList
	           `magic`) along the aim: HeldUse (Net/MagicSync: a numbered seq, the hotbar slot,
	           the item, the unit direction), the projectile flying at once
	           (Rendering/ProjectileView.predict, adopted when the server's spawn comes),
	           item.magic.cast at once (predicted: the server plays it for the others) and the
	           mana taken here (Player/ManaState.spend) until the server says. Without the
	           mana (as far as this client knows) nothing is cast, as Terraria (creative: free),
	           and the HUD's stars blink (ManaState.noteRefused).
	  aim      from the eyes (the local hull: feet + PlayerPhysics.eyeHeight, 1.62 standing, 1.27
	           sneaking, as the server's spawn) towards what the camera's ray points at: the block
	           it hits, else AIM_DISTANCE blocks along it, so third person's camera aims where its
	           crosshair is; a point not in front of the eyes falls back to the ray's direction.
	  crystal  a Mana Crystal: one HeldUse a press (BlockInteraction spends the press); the server
	           uses it up while fewer than nine were used, and plays its chime for everyone.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Casting = require(Shared.Magic.Casting)
local Projectiles = require(Shared.Magic.Projectiles)
local MagicSync = require(Shared.Net.MagicSync)
local Protocol = require(Shared.Net.Protocol)
local PlayerPhysics = require(Shared.Movement.PlayerPhysics)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local MovementController = require(script.Parent.Parent.Player.MovementController)
local ManaState = require(script.Parent.Parent.Player.ManaState)
local ProjectileView = require(script.Parent.Parent.Rendering.ProjectileView)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)

-- The aim: where the camera's ray starts (world blocks), its unit direction, and the block it hit
-- (its distance along the ray; nil: none in reach).
export type Aim = { x: number, y: number, z: number, direction: Vector3 }

local ClientCasting = {}

local CAST = "item.magic.cast"
-- Blocks along the camera's ray aimed at when it hits no block.
local AIM_DISTANCE = 32
-- The aim is used when its direction is at least this much in front (cosine) of the camera's.
local FRONT = 0.2

local seq = 0
-- os.clock() of this client's last cast (its cadence: a whole use time, no slack).
local lastCast: number? = nil

-- Is `stack` used through HeldUse (a magic weapon, a Mana Crystal)?
function ClientCasting.handles(stack: Items.Stack?): boolean
	return stack ~= nil and Casting.handles(stack.item)
end

-- The eyes (world blocks) and the unit direction towards what `aim` points at, `hitDistance` along it.
local function aimFrom(aim: Aim, hitDistance: number?): (number?, number, number, number, number, number)
	local view = MovementController.current
	if view == nil then
		return nil, 0, 0, 0, 0, 0
	end
	local state = view.state
	local ex, ey, ez = state.x, state.y + PlayerPhysics.eyeHeight(state), state.z
	local d = aim.direction
	local reach = hitDistance or AIM_DISTANCE
	local tx, ty, tz = aim.x + d.X * reach - ex, aim.y + d.Y * reach - ey, aim.z + d.Z * reach - ez
	local length = math.sqrt(tx * tx + ty * ty + tz * tz)
	if length > 1e-6 then
		tx, ty, tz = tx / length, ty / length, tz / length
		if tx * d.X + ty * d.Y + tz * d.Z >= FRONT then
			return ex, ey, ez, tx, ty, tz
		end
	end
	return ex, ey, ez, d.X, d.Y, d.Z
end

local function send(item: number, dx: number, dy: number, dz: number): number
	seq = (seq + 1) % 65536
	ClientNet.send(
		Protocol.ClientMessage.HeldUse,
		MagicSync.encodeHeldUse({
			seq = seq,
			slot = ClientInventory.selected(),
			item = item,
			dx = dx,
			dy = dy,
			dz = dz,
		})
	)
	return seq
end

--[[
	Uses `stack` (see the header) in game `mode` along `aim` (`hitDistance`: the block the camera's
	ray hit, nil when none). Returns "cast" or "crystal" when something went to the server, nil
	when nothing did (not its time yet, no mana, a spectator).
]]
function ClientCasting.use(stack: Items.Stack, mode: string, aim: Aim, hitDistance: number?): Casting.Use?
	if GameMode.isSpectator(mode) or not Casting.handles(stack.item) then
		return nil
	end
	local ex, ey, ez, dx, dy, dz = aimFrom(aim, hitDistance)
	if ex == nil then
		return nil
	end
	if stack.item == Casting.CRYSTAL then
		send(stack.item, dx, dy, dz)
		return "crystal"
	end
	local magic = Items.magic(stack.item) :: Items.MagicSpec
	local now = os.clock()
	local last = lastCast
	if last and now - last < magic.useTicks * Casting.TICK then
		return nil
	end
	local free = Casting.free(mode)
	if not free and not ManaState.has(magic.mana) then
		-- (The stars blink: Ui/ManaHud.)
		ManaState.noteRefused()
		return nil
	end
	lastCast = now
	local number = send(stack.item, dx, dy, dz)
	local kind = Projectiles.kind(magic.projectile)
	if kind then
		ProjectileView.predict(kind, number, ex, ey, ez, dx, dy, dz)
	end
	if not free then
		ManaState.spend(magic.mana)
	end
	SoundPlayer.play(CAST, ex, ey, ez)
	return "cast"
end

return ClientCasting
