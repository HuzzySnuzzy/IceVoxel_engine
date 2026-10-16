--!strict
--[[
	A touch screen's firearm buttons, in the manner of DayZ's console controls: while a firearm is
	in hand (Interaction/Firearms says `setShown`), three buttons join Roblox's jump button and the
	sprint and sneak buttons around it:

	  AIM     toggles the gun raised or lowered (its title says which comes next: AIM, LOWER)
	  FIRE    held, fires at the screen's centre while the gun is raised (a semi-automatic once a
	          press, an automatic at its rate)
	  RELOAD  reloads (or clears a jam), as R

	They are ContextActionService's touch buttons (bound only while a gun is held), each put in a
	slot of its own round the jump button (Ui/TouchButtons.place, Ui/TouchLayout: FIRE beside the
	sprint button, AIM over it, RELOAD beside AIM), whatever order the buttons were bound in, and
	Ui/UiScale measures them with the rest for the HUD's corner to keep clear of; a press on one
	never reaches the world (no tap, no bash). Elsewhere (a mouse, a gamepad) no button shows.
]]

local ContextActionService = game:GetService("ContextActionService")

local TouchButtons = require(script.Parent.TouchButtons)

export type Handlers = {
	-- FIRE went down (true) or up (false).
	fire: (down: boolean) -> (),
	-- AIM was tapped.
	aim: () -> (),
	-- RELOAD was tapped.
	reload: () -> (),
}

local WeaponButtons = {}

local FIRE = "IceVoxelWeaponFire"
local AIM = "IceVoxelWeaponAim"
local RELOAD = "IceVoxelWeaponReload"

local handlers: Handlers? = nil
local shown = false
local raised = false

local function result(): Enum.ContextActionResult
	return Enum.ContextActionResult.Sink
end

local function bind()
	ContextActionService:BindAction(FIRE, function(_, state: Enum.UserInputState)
		local h = handlers
		if h then
			if state == Enum.UserInputState.Begin then
				h.fire(true)
			elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
				h.fire(false)
			end
		end
		return result()
	end, true)
	ContextActionService:BindAction(AIM, function(_, state: Enum.UserInputState)
		local h = handlers
		if h and state == Enum.UserInputState.Begin then
			h.aim()
		end
		return result()
	end, true)
	ContextActionService:BindAction(RELOAD, function(_, state: Enum.UserInputState)
		local h = handlers
		if h and state == Enum.UserInputState.Begin then
			h.reload()
		end
		return result()
	end, true)
	ContextActionService:SetTitle(FIRE, "FIRE")
	ContextActionService:SetTitle(AIM, if raised then "LOWER" else "AIM")
	ContextActionService:SetTitle(RELOAD, "RELOAD")
	TouchButtons.place(FIRE, "fire")
	TouchButtons.place(AIM, "aim")
	TouchButtons.place(RELOAD, "reload")
end

local function unbind()
	local h = handlers
	if h then
		-- (A FIRE held while the buttons go lets go.)
		h.fire(false)
	end
	ContextActionService:UnbindAction(FIRE)
	ContextActionService:UnbindAction(AIM)
	ContextActionService:UnbindAction(RELOAD)
end

-- What the buttons do (Interaction/Firearms).
function WeaponButtons.start(with: Handlers)
	handlers = with
end

-- Shows the buttons (a firearm in hand) or takes them away.
function WeaponButtons.setShown(show: boolean)
	if show == shown then
		return
	end
	shown = show
	if show then
		bind()
	else
		unbind()
	end
end

-- The gun is raised (AIM's title says LOWER) or not.
function WeaponButtons.setRaised(value: boolean)
	if value == raised then
		return
	end
	raised = value
	if shown then
		ContextActionService:SetTitle(AIM, if value then "LOWER" else "AIM")
	end
end

return WeaponButtons
