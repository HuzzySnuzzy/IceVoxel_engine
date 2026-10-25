--!strict
--[[
	Turret parts and the Laser Sight (Shared/Turrets): a turret is built from its type's barrel, a
	receiver, a belt feeder, a servo motor and a targeting module (the pack's recipes), each named
	for its job in the gun: the barrel its calibre (the SMG's short and thick, the rifle's long with
	a handguard, the sniper's longest with a muzzle brake), the receiver its action, the belt feeder
	the transporter's feed, the servo its turning, the targeting module its sensor and fire control.
	The Laser Sight (one to a stack, as attachments) mounts on a turret's optic slot only: no
	hand-held gun takes it. Box models in their colours until their icons are made (each one's
	`icon`, blank), barrels to the right as the guns lie, and a lore line each saying what it is
	for. They are always there, whatever the turrets' Config switch; they are the Electric Age's
	while it is on (the Servo Motor while the turrets or the Ammo Press are), no Age's while off,
	as their recipes are left out.
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)
local models = require(script.Parent._models)

local BARREL_STEEL = { 150, 152, 156 }
local DARK_STEEL = { 70, 74, 80 }
local GUNMETAL = { 58, 60, 64 }
local BRASS = { 196, 160, 70 }
local BELT = { 92, 70, 48 }
local COPPER = { 190, 120, 60 }
local OSMIUM_BLUE = { 172, 192, 216 }
local LENS = { 90, 170, 230 }
local LASER = { 230, 40, 40 }

local box = models.box

return function(define: Define.Context): { Schema.ItemSpec }
	local Config = define.Config
	-- The Electric Age, while the turrets are on (as their recipes); the Servo Motor's while the
	-- turrets or the Ammo Press are (the press takes servos too).
	local electric = if Config.Turrets.Enabled then "electric" else nil
	local servoElectric = if Config.Turrets.Enabled or Config.AmmoPress.Enabled then "electric" else nil
	return {
		{
			name = "SmgBarrel",
			displayName = "SMG Barrel",
			color = BARREL_STEEL,
			material = "Metal",
			model = {
				box({ 12, 3.2, 3.2 }, { 0, 0, 0 }, BARREL_STEEL),
				box({ 4, 4.2, 4.2 }, { -5, 0, 0 }, DARK_STEEL),
				box({ 1, 3.6, 3.6 }, { 6, 0, 0 }, GUNMETAL),
			},
			tilt = 30,
			icon = "",
			lore = "A turret part: an SMG turret's 9mm barrel.",
			age = electric,
		},
		{
			name = "RifleBarrel",
			color = BARREL_STEEL,
			material = "Metal",
			model = {
				box({ 16, 2, 2 }, { 0, 0, 0 }, BARREL_STEEL),
				box({ 7, 3.4, 3.4 }, { -4, 0, 0 }, DARK_STEEL),
				box({ 1, 2.6, 2.6 }, { 8, 0, 0 }, GUNMETAL),
			},
			tilt = 30,
			icon = "",
			lore = "A turret part: a rifle turret's 5.56 barrel.",
			age = electric,
		},
		{
			name = "SniperBarrel",
			color = BARREL_STEEL,
			material = "Metal",
			model = {
				box({ 17, 2.2, 2.2 }, { -0.5, 0, 0 }, BARREL_STEEL),
				box({ 3, 3.6, 3.6 }, { -7, 0, 0 }, DARK_STEEL),
				box({ 2.4, 3.2, 3.2 }, { 7.6, 0, 0 }, GUNMETAL),
				box({ 0.6, 3.4, 1 }, { 7.6, 0, 1.4 }, OSMIUM_BLUE),
			},
			tilt = 30,
			icon = "",
			lore = "A turret part: a sniper turret's .308 barrel.",
			age = electric,
		},
		{
			name = "BeltFeeder",
			color = DARK_STEEL,
			material = "Metal",
			model = {
				box({ 8, 7, 5 }, { 1, 0, 0 }, DARK_STEEL),
				box({ 6, 1, 5.2 }, { 1, 3, 0 }, BARREL_STEEL),
				box({ 5, 2, 3 }, { -5.5, -1, 0 }, BELT, "Fabric"),
				box({ 1.4, 3, 1.4 }, { -6.5, 1, 0 }, BRASS),
				box({ 1.4, 3, 1.4 }, { -4.5, 1, 0 }, BRASS),
			},
			icon = "",
			lore = "A turret part: takes the rounds a transporter brings into the gun.",
			age = electric,
		},
		{
			name = "Receiver",
			color = GUNMETAL,
			material = "Metal",
			model = {
				box({ 12, 6, 5 }, { 0, 0, 0 }, GUNMETAL),
				box({ 4, 2, 0.4 }, { 1, 1, 2.6 }, BRASS),
				box({ 10, 1, 5.2 }, { 0, 3.2, 0 }, BARREL_STEEL),
				box({ 2, 3, 3 }, { 6.5, 0.5, 0 }, DARK_STEEL),
			},
			icon = "",
			lore = "A turret part: the action that chambers and fires each round.",
			age = electric,
		},
		{
			name = "ServoMotor",
			color = DARK_STEEL,
			material = "Metal",
			model = {
				box({ 8, 8, 6 }, { -1, 0, 0 }, DARK_STEEL, nil, "Cylinder"),
				box({ 7, 7, 6.4 }, { -1, 0, 0 }, COPPER, nil, "Cylinder"),
				box({ 6, 6, 6.8 }, { -1, 0, 0 }, DARK_STEEL, nil, "Cylinder"),
				box({ 5, 1.6, 1.6 }, { 5, 0, 0 }, BARREL_STEEL),
			},
			icon = "",
			lore = "A turret part: turns the gun towards its target.",
			age = servoElectric,
		},
		{
			name = "TargetingModule",
			color = GUNMETAL,
			material = "Metal",
			model = {
				box({ 10, 8, 5 }, { 0, -1, 0 }, GUNMETAL),
				box({ 5, 5, 0.6 }, { 0, -1, 2.7 }, LENS, "Glass", "Cylinder"),
				box({ 8, 1.4, 5.2 }, { 0, 3.6, 0 }, OSMIUM_BLUE),
				box({ 1, 1, 0.4 }, { 3.6, 2, 2.6 }, { 90, 210, 100 }, "Neon"),
			},
			icon = "",
			lore = "A turret part: finds targets and tells the gun when to fire.",
			age = electric,
		},
		{
			name = "LaserSight",
			maxStack = 1,
			color = GUNMETAL,
			material = "SmoothPlastic",
			model = {
				box({ 8, 3, 3 }, { 0, 0, 0 }, GUNMETAL),
				box({ 3, 1.4, 3.2 }, { -1, 2, 0 }, DARK_STEEL),
				box({ 0.4, 2, 2 }, { 4.2, 0, 0 }, LASER, "Neon"),
			},
			icon = "",
			lore = "Mount it on a turret: tighter shots, quicker to find a target.",
			age = electric,
		},
	}
end
