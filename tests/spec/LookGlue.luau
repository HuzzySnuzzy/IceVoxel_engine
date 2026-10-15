--[[
	The survival look's Roblox glue where it has rules of its own, run with fake instances
	(property bags that count every write):

	  * the item tooltip (client Ui/ItemTooltip): its key holds what the box shows but not the
	    stack's count, so a count that changes under the pointer (a furnace's output, fuel burning
	    down, a stack filling from pickups) never restarts the mouse's hover delay (Ui/Screens'
	    rule, replayed here frame by frame); the header's count is written in place instead, once
	    per change and never when unchanged; the box keeps its width as the count changes, and
	    only a count past its most's digits asks for a new box;
	  * the backdrop (client Ui/Backdrop): its layer by kind and screen, the vignette only on a
	    mouse, the world's blur whenever an inventory kind is open on a screen that is not touch
	    (with or without the vignette's image), off for panels, on touch and when closed, never
	    with InventoryBlur 0, and nothing written when nothing changed.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

-- Arguments every loaded module gets (as locals, like tests/lib/Loader).
local GLOBALS = "script, require, game, workspace, Instance, Vector2, UDim2, UDim, Color3, Enum, NumberSequence"

local function withHeader(source: string): string
	local lines = string.split(source, "\n")
	local i = 1
	while lines[i] and string.sub(lines[i], 1, 3) == "--!" do
		i += 1
	end
	lines[i] = `local {GLOBALS} = ...; ` .. (lines[i] or "")
	return table.concat(lines, "\n")
end

-- What a new instance of a class reads before anything is written (Roblox's defaults).
local DEFAULTS: { [string]: { [string]: any } } = {
	BlurEffect = { Enabled = true, Size = 24 },
	Frame = { Visible = true },
	ImageLabel = { Visible = true },
	TextLabel = { Visible = true, Text = "Label" },
	UIGradient = { Enabled = true },
}

--[[
	A fake client: `world.new(class)` makes a property bag (`world.writes` counts every property
	written, `world.created` lists them); `world.load(path)` loads a client module (Ui/Theme,
	Ui/MenuLayout and Ui/Masks the real ones, through the suite's require), with stand-ins for
	Ui/Style (the look's colours from the real Theme, a fixed-advance measure), Ui/ItemIcon,
	Ui/UiScale (`world.touch`), Player/ProgressionState (no locks) and Config.Ui
	(`world.blurSize`); Style.Dayz.maskContent gives an image only while `world.vignette`.
]]
local function fakeClient(shared: any, sharedRequire: (any) -> any, client: any): any
	local world: any = {
		writes = 0,
		created = {},
		touch = false,
		vignette = true,
		blurSize = 8,
		masks = 0,
	}
	function world.new(class: string): any
		local props: { [string]: any } = { ClassName = class }
		for key, value in DEFAULTS[class] or {} do
			props[key] = value
		end
		local object = setmetatable({}, {
			__index = function(_, key: string): any
				if key == "Destroy" then
					return function()
						props.Parent = nil
						props.destroyed = true
					end
				end
				return props[key]
			end,
			__newindex = function(_, key: string, value: any)
				world.writes += 1
				props[key] = value
			end,
		})
		table.insert(world.created, object)
		return object
	end
	local Instance = { new = world.new }
	world.camera = world.new("Camera")
	local services: { [string]: any } = {
		ReplicatedStorage = {
			WaitForChild = function(_, name: string): any
				assert(name == "IceVoxel")
				return shared
			end,
		},
		Workspace = { CurrentCamera = world.camera },
	}
	local game = {
		GetService = function(_, name: string): any
			return assert(services[name], `no fake service {name}`)
		end,
	}

	local Theme = sharedRequire(client.Ui.Theme)
	local colours, alphas, conditions = {}, {}, {}
	for key, c in Theme.Colour do
		colours[key] = roblox.Color3.fromRGB(c.r, c.g, c.b)
		alphas[key] = c.t
	end
	for _, level in Theme.CONDITIONS do
		conditions[level.name] = roblox.Color3.fromRGB(level.rgb[1], level.rgb[2], level.rgb[3])
	end
	-- (Strict, as Style makes them: a key that is not a token is an error.)
	for kind, values in { Colour = colours, Alpha = alphas, Condition = conditions } do
		setmetatable(values, {
			__index = function(_, key: any)
				error(`Style.Dayz.{kind} has no {tostring(key)}`, 2)
			end,
		})
	end
	local UDim2 = roblox.UDim2
	local function frame(parent: any, x: number, y: number, w: number, h: number, colour: any, z: number?): any
		local made = world.new("Frame")
		made.Position = UDim2.fromOffset(x, y)
		made.Size = UDim2.fromOffset(w, h)
		made.BackgroundColor3 = colour
		made.ZIndex = z or 1
		made.Parent = parent
		return made
	end
	local Color3 = roblox.Color3
	local Style = {
		ITEM = 16,
		-- (Minecraft's palette: what the extra lines' colours are mapped from.)
		Colour = {
			Text = Color3.fromRGB(255, 255, 255),
			Gray = Color3.fromRGB(170, 170, 170),
			Blue = Color3.fromRGB(85, 85, 255),
			Red = Color3.fromRGB(255, 85, 85),
			TextDisabled = Color3.fromRGB(160, 160, 160),
			Missing = Color3.fromRGB(255, 0, 0),
			DarkGreen = Color3.fromRGB(0, 170, 0),
			Lore = Color3.fromRGB(170, 0, 170),
		},
		frame = frame,
		Dayz = {
			Colour = colours,
			Alpha = alphas,
			Condition = conditions,
			-- (Theme's spec's measure: 5 GUI pixels a character at the body size, 4 at the small.)
			measure = function(text: string, size: number): number
				return #text * (size - 3)
			end,
			label = function(
				parent: any,
				text: string,
				x: number,
				y: number,
				w: number,
				h: number,
				role: string,
				colour: any,
				z: number?,
				align: any,
				_scaled: any
			): any
				local label = world.new("TextLabel")
				label.Position = UDim2.fromOffset(x, y)
				label.Size = UDim2.fromOffset(w, h)
				label.TextSize = Theme.Text[role]
				label.TextColor3 = colour
				label.TextXAlignment = align
				label.Text = text
				label.ZIndex = z or 5
				label.Parent = parent
				return label
			end,
			dot = function(parent: any, x: number, y: number, size: number, z: number?): any
				return frame(parent, x, y, size, size, colours.Text, z)
			end,
			scaled = function(): any
				return {
					scale = 1,
					setScale = function(self: any, scale: number)
						self.scale = scale
					end,
				}
			end,
			maskContent = function(_name: string, mask: () -> any): any
				world.masks += 1
				if not world.vignette then
					return nil
				end
				local drawn = mask()
				assert(drawn.w > 0 and drawn.h > 0, "a vignette drawn")
				return { content = "vignette" }
			end,
		},
	}
	local ItemIcon = {
		new = function(_parent: any, _x: number, _y: number, _scale: number?, _look: string?): any
			return {
				set = function(self: any, item: number?, count: number?)
					self.item, self.count = item, count
				end,
			}
		end,
	}
	local UiScale = {
		touch = function(): boolean
			return world.touch
		end,
	}
	local ProgressionState = {
		gate = function(): any
			return nil
		end,
		lockText = function(_item: number): string?
			return nil
		end,
	}
	local stubs: { [string]: any } = {
		["src/client/Ui/Style"] = Style,
		["src/client/Ui/ItemIcon"] = ItemIcon,
		["src/client/Ui/UiScale"] = UiScale,
		["src/client/Player/ProgressionState"] = ProgressionState,
	}
	local real: { [string]: any } = {
		["src/client/Ui/Theme"] = client.Ui.Theme,
		["src/client/Ui/MenuLayout"] = client.Ui.MenuLayout,
		["src/client/Ui/Masks"] = client.Ui.Masks,
	}
	local config = { Ui = { InventoryBlur = 0 } }

	local function node(path: string, parent: any): any
		return setmetatable({ __fake = true, path = path, Parent = parent }, {
			__index = function(self: any, name: string): any
				local child = node(`{path}/{name}`, self)
				rawset(self, name, child)
				return child
			end,
		})
	end
	local cache: { [string]: any } = {}
	local function req(n: any): any
		if type(n) ~= "table" or not rawget(n, "__fake") then
			if n == shared.Config then
				config.Ui.InventoryBlur = world.blurSize
				return config
			end
			return sharedRequire(n)
		end
		local path = n.path
		if stubs[path] then
			return stubs[path]
		elseif real[path] then
			return sharedRequire(real[path])
		end
		if cache[path] == nil then
			local file = `{path}.luau`
			local chunk = luau.load(withHeader(fs.readFile(file)), { debugName = file })
			cache[path] = chunk(
				n,
				req,
				game,
				services.Workspace,
				Instance,
				roblox.Vector2,
				roblox.UDim2,
				roblox.UDim,
				roblox.Color3,
				roblox.Enum,
				roblox.NumberSequence
			)
		end
		return cache[path]
	end
	local root = node("src/client", nil)
	function world.load(name: string): any
		return req(root.Ui[name])
	end
	-- The blur on the camera config sets (nil: none made).
	function world.blur(): any
		for _, made in world.created do
			if made.ClassName == "BlurEffect" then
				return made
			end
		end
		return nil
	end
	world.colours, world.alphas = colours, alphas
	return world
end

return function(t, shared, require, _server, client)
	local Items = require(shared.Items)
	local I = Items.id

	-- The labels under `parent` (a box): its texts.
	local function labelsOf(world: any, parent: any): { any }
		local found = {}
		for _, made in world.created do
			if made.ClassName == "TextLabel" and made.Parent == parent and not made.destroyed then
				table.insert(found, made)
			end
		end
		return found
	end

	-- The tooltip's count label (right-aligned in the header), or nil.
	local function countLabel(world: any, tooltip: any): any
		for _, label in labelsOf(world, tooltip.box) do
			if label.TextXAlignment == roblox.Enum.TextXAlignment.Right then
				return label
			end
		end
		return nil
	end

	t.test("item tooltip: a count that changes keeps the key and is written in place", function()
		local world = fakeClient(shared, require, client)
		local ItemTooltip = world.load("ItemTooltip")
		local tooltip = ItemTooltip.new(world.new("ScreenGui"))
		local cobble = I.Cobblestone
		local most = Items.maxStack(cobble)
		t.eq(most, 64)
		local stack = { item = cobble, count = 32 }
		local key = tooltip:key(cobble, stack, nil)
		local size = tooltip:build(cobble, stack, nil)
		local label = countLabel(world, tooltip)
		t.ok(label ~= nil, "the header's count")
		t.eq(label.Text, "32 / 64")
		-- Another count of the same stack: the same key (nothing rebuilt), the count rewritten.
		for _, count in { 33, 5, 64, 1, 40 } do
			local now = { item = cobble, count = count }
			t.eq(tooltip:key(cobble, now, nil), key, `{count}: the same key`)
			t.eq(label.Text, `{count} / 64`, `{count}: shown in place`)
			t.eq(countLabel(world, tooltip), label, "the same label")
		end
		-- Unchanged: nothing written.
		local before = world.writes
		for _ = 1, 10 do
			tooltip:key(cobble, { item = cobble, count = 40 }, nil)
		end
		t.eq(world.writes, before, "an unchanged count writes nothing")
		-- A new box for another count is the same size (room kept for its digits: Theme's spec
		-- checks the rule with a measure where the count sets the width).
		local one = tooltip:build(cobble, { item = cobble, count = 1 }, nil)
		local full = tooltip:build(cobble, { item = cobble, count = 64 }, nil)
		t.eq(one, size, "1: the same size")
		t.eq(full, size, "64: the same size")
		-- What else the tooltip shows still makes a new key: another item, wear, extra lines, no stack.
		t.ok(tooltip:key(I.Stone, { item = I.Stone, count = 32 }, nil) ~= key, "another item")
		t.ok(tooltip:key(cobble, nil, nil) ~= key, "the item without its stack (JEI's)")
		local extra = { { text = "Locked", colour = roblox.Color3.fromRGB(255, 85, 85) } }
		t.ok(tooltip:key(cobble, stack, extra) ~= key, "extra lines")
		-- (An extra line in Minecraft's red is drawn in the look's Warning.)
		tooltip:build(cobble, stack, extra)
		local warned = false
		for _, label in labelsOf(world, tooltip.box) do
			if label.Text == "Locked" then
				warned = label.TextColor3 == world.colours.Warning
			end
		end
		t.ok(warned, "the extra line in Warning")
		local pick = I.IronPickaxe
		local worn = tooltip:key(pick, { item = pick, count = 1, damage = 10 }, nil)
		t.ok(worn ~= tooltip:key(pick, { item = pick, count = 1, damage = 20 }, nil), "wear")
		-- Past its most's digits (a container that holds more): a new key, a box with room for it.
		local big = tooltip:key(cobble, { item = cobble, count = 100 }, nil)
		t.ok(big ~= key, "three digits: a new key")
		t.eq(tooltip:key(cobble, { item = cobble, count = 150 }, nil), big, "still three")
	end)

	t.test("item tooltip: the count's in-place text goes only to the stack it was built for", function()
		local world = fakeClient(shared, require, client)
		local ItemTooltip = world.load("ItemTooltip")
		local tooltip = ItemTooltip.new(world.new("ScreenGui"))
		local cobble = I.Cobblestone
		tooltip:build(cobble, { item = cobble, count = 32 }, nil)
		local label = countLabel(world, tooltip)
		-- Another thing's key leaves the drawn count alone (its owner builds that one).
		tooltip:key(I.Stone, { item = I.Stone, count = 7 }, nil)
		t.eq(label.Text, "32 / 64", "not another item's count")
		tooltip:key(cobble, { item = cobble, count = 9 }, { { text = "x", colour = roblox.Color3.new(1, 1, 1) } })
		t.eq(label.Text, "32 / 64", "not with other lines")
		-- A stack that shows no count (one to a stack) has no label to write.
		local pick = I.IronPickaxe
		local stack = { item = pick, count = 1, damage = 3 }
		tooltip:build(pick, stack, nil)
		t.eq(countLabel(world, tooltip), nil, "no count for a tool")
		local key = tooltip:key(pick, stack, nil)
		t.eq(tooltip:key(pick, { item = pick, count = 2, damage = 3 }, nil), key, "a tool's count is not its key")
		-- A new box for the stack again: its own label, kept current.
		tooltip:build(cobble, { item = cobble, count = 12 }, nil)
		local again = countLabel(world, tooltip)
		t.ok(again ~= label, "a new label")
		t.ok(label.destroyed or label.Parent == nil or label.Parent.destroyed, "the old box went")
		tooltip:key(cobble, { item = cobble, count = 13 }, nil)
		t.eq(again.Text, "13 / 64")
	end)

	t.test("item tooltip: on a mouse it shows 0.25 s after the pointer stops, whatever the count does", function()
		local world = fakeClient(shared, require, client)
		local ItemTooltip = world.load("ItemTooltip")
		local Theme = require(client.Ui.Theme)
		local tooltip = ItemTooltip.new(world.new("ScreenGui"))
		local cobble = I.Cobblestone
		-- Ui/Screens' rule each frame: a new key restarts the delay and builds; shown after the delay.
		local hoverKey, hoverSince, tooltipKey, builds = "", 0, "", 0
		local shownAt: number? = nil
		local count = 1
		local frames = 120
		for frame = 1, frames do
			local now = frame / 60
			-- (A furnace's output growing every 0.1 s.)
			if frame % 6 == 0 then
				count += 1
			end
			local stack = { item = cobble, count = count }
			local key = tooltip:key(cobble, stack, nil)
			if key ~= hoverKey then
				hoverKey, hoverSince = key, now
			end
			if key ~= tooltipKey then
				tooltipKey = key
				builds += 1
				tooltip:build(cobble, stack, nil)
			end
			if shownAt == nil and now - hoverSince >= Theme.Time.TOOLTIP_DELAY then
				shownAt = now
			end
			t.eq(countLabel(world, tooltip).Text, `{count} / 64`, `frame {frame}: the count shown`)
		end
		t.eq(builds, 1, "built once")
		t.ok(shownAt ~= nil and shownAt <= Theme.Time.TOOLTIP_DELAY + 1 / 60 + 1e-9, `shown at {shownAt}`)
	end)

	t.test("backdrop: its layer and the world's blur by kind and screen, with or without the vignette", function()
		local function open(touch: boolean, vignette: boolean, kind: string): (any, any)
			local world = fakeClient(shared, require, client)
			world.touch, world.vignette = touch, vignette
			local Backdrop = world.load("Backdrop")
			local backdrop = Backdrop.new(world.new("ScreenGui"))
			backdrop:setOpen(true, kind)
			return world, backdrop
		end
		local function blurOn(world: any): boolean
			local blur = world.blur()
			return blur ~= nil and blur.Enabled == true and blur.Parent == world.camera
		end
		local function vignetteShown(world: any): boolean
			for _, made in world.created do
				if made.ClassName == "ImageLabel" and made.Name == "Vignette" then
					return made.Visible == true
				end
			end
			return false
		end
		-- A mouse with the vignette: the light layer, the vignette and the blur.
		local world, backdrop = open(false, true, "inventory")
		local root = backdrop.root
		t.eq(root.Visible, true)
		t.eq(root.BackgroundColor3, world.colours.Backdrop)
		t.eq(root.BackgroundTransparency, world.alphas.Backdrop)
		t.ok(vignetteShown(world), "the vignette")
		t.ok(blurOn(world), "the blur on the camera")
		t.eq(world.blur().Size, 8, "InventoryBlur's size")
		-- A mouse without the vignette's image: the darker layer, and the blur all the same.
		world, backdrop = open(false, false, "creative")
		t.eq(world.masks, 1, "the vignette was tried")
		t.eq(backdrop.root.BackgroundTransparency, world.alphas.BackdropTouch, "the darker layer")
		t.ok(not vignetteShown(world), "no vignette")
		t.ok(blurOn(world), "still blurred: the blur goes with the mouse, not the vignette")
		-- Tried once: opening again does not draw it again.
		backdrop:setOpen(false, "creative")
		backdrop:setOpen(true, "inventory")
		t.eq(world.masks, 1, "not tried again")
		t.ok(blurOn(world), "blurred again")
		-- Touch: the darker layer, no vignette (never drawn), no blur.
		world, backdrop = open(true, true, "inventory")
		t.eq(backdrop.root.BackgroundTransparency, world.alphas.BackdropTouch)
		t.eq(world.masks, 0, "no vignette drawn on touch")
		t.ok(not blurOn(world), "no blur on touch")
		-- A panel: Minecraft's layer and no blur, whatever the screen.
		world, backdrop = open(false, true, "panel")
		t.eq(backdrop.root.BackgroundTransparency, 0, "Minecraft's layer (its gradient carries the alpha)")
		t.ok(not blurOn(world), "no blur behind a panel")
		-- InventoryBlur 0: no blur is made at all.
		world = fakeClient(shared, require, client)
		world.blurSize = 0
		local Backdrop = world.load("Backdrop")
		Backdrop.new(world.new("ScreenGui")):setOpen(true, "inventory")
		t.eq(world.blur(), nil, "InventoryBlur 0: none")
	end)

	t.test("backdrop: a kind change or a close turns the blur off; nothing written twice", function()
		for _, vignette in { true, false } do
			local world = fakeClient(shared, require, client)
			world.vignette = vignette
			local Backdrop = world.load("Backdrop")
			local backdrop = Backdrop.new(world.new("ScreenGui"))
			backdrop:setOpen(true, "inventory")
			local blur = world.blur()
			t.ok(blur ~= nil and blur.Enabled, `vignette {vignette}: blurred`)
			-- The same again: nothing written.
			local before = world.writes
			backdrop:setOpen(true, "inventory")
			backdrop:setOpen(true, "creative")
			t.eq(world.writes, before, `vignette {vignette}: the same look writes nothing`)
			-- To a panel and back, then closed.
			backdrop:setOpen(true, "panel")
			t.eq(blur.Enabled, false, "off behind a panel")
			backdrop:setOpen(true, "inventory")
			t.eq(blur.Enabled, true, "on again")
			t.eq(world.blur(), blur, "the same blur kept")
			backdrop:setOpen(false, "inventory")
			t.eq(blur.Enabled, false, "off when closed")
			t.eq(backdrop.root.Visible, false)
			before = world.writes
			backdrop:setOpen(false, "inventory")
			t.eq(world.writes, before, "closed twice: nothing written")
		end
	end)
end
