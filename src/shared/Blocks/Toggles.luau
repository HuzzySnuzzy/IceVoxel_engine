--!strict
--[[
	Blocks a use swaps for another (BlockList `toggle`, `menu` "Toggle": the bunker hatch, shut on
	the floor and open against the wall), pure: what a use turns a block into and the sound it
	makes. The server's Players/ToggleUse applies it; nothing on the client predicts it (unlike a
	door), so everyone, the user too, hears the server's sound.
]]

local Blocks = require(script.Parent)

local Toggles = {}

-- What using `block` turns it into and the sound it makes; nil for a block that doesn't toggle.
function Toggles.use(block: number): (number?, string?)
	if not Blocks.isValid(block) then
		return nil, nil
	end
	return Blocks.toggleOf(block)
end

return Toggles
