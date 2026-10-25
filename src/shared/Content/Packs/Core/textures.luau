--!strict
--[[
	Core's texture: the texture pack's fallback (TexturePack.Missing), drawn where a texture is
	missing (TexturePack.ShowMissing) or an id failed to load. It is no block's, so it lives with
	the game's core and is there whatever packs are.
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	-- The sheet does not know its size, and the id is an old, short one: check in Studio that it is
	-- an Image id, not a Decal id.
	["missing texture"] = {
		Color = "rbxassetid://925810526",
		Material = "SmoothPlastic",
		Tint = false,
	},
} :: { [string]: Schema.Texture }
