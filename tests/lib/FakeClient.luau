--[[
	A fake Roblox client for loading the inventory family's glue (Ui/InventoryScreen, Ui/Style,
	Ui/HoverTip...) under Lune: table instances with properties, parenting, IsA, attributes and
	events (signals with Connect, Once and Fire; `Destroy` fires Destroying on the object and each
	descendant first, as Roblox does), and AbsolutePosition / AbsoluteSize worked out from Position,
	Size, AnchorPoint and UIScale (Roblox's rules: a UIScale scales its object around its anchor
	point and every descendant's offsets) on a VIEW-sized screen. `loader` loads src/client modules
	with given stand-ins (by path) and services; everything else is the real module. Roblox's own
	data types (UDim2, Color3, Vector2, Enum...) are Lune's; Roblox's `task` is a stand-in whose
	delayed functions run when a test calls `runTasks`.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local UDim2, UDim, Vector2, Color3, Enum, Font =
	roblox.UDim2, roblox.UDim, roblox.Vector2, roblox.Color3, roblox.Enum, roblox.Font

local FakeClient = {}

local GLOBALS =
	"script, require, game, Instance, Color3, UDim2, UDim, Vector2, Enum, Font, ColorSequence, NumberSequence, ColorSequenceKeypoint, NumberSequenceKeypoint, Rect, Content, Vector3, CFrame, task"

local function withHeader(source: string): string
	local lines = string.split(source, "\n")
	local i = 1
	while lines[i] and string.sub(lines[i], 1, 3) == "--!" do
		i += 1
	end
	lines[i] = `local {GLOBALS} = ...; ` .. (lines[i] or "")
	return table.concat(lines, "\n")
end

local function newSignal(): any
	local fns = {}
	local s = {}
	function s.Connect(_, fn)
		table.insert(fns, fn)
		return {
			Connected = true,
			Disconnect = function()
				for i, f in fns do
					if f == fn then
						table.remove(fns, i)
						break
					end
				end
			end,
		}
	end
	function s.Once(self, fn)
		local c
		c = self:Connect(function(...)
			c.Disconnect()
			fn(...)
		end)
		return c
	end
	function s.Fire(_, ...)
		for _, fn in table.clone(fns) do
			fn(...)
		end
	end
	s.Event = s
	return s
end
FakeClient.signal = newSignal

--[[
	Roblox's task library for the loaded modules: `delay` and `defer` queue their function until
	`runTasks` (a test's way of letting the time pass), `spawn` runs it at once, `wait` returns at
	once.
]]
type Job = { fn: (...any) -> ...any, args: { n: number, [number]: any } }
local queued: { Job } = {}
FakeClient.task = {
	delay = function(_seconds: number?, fn: (...any) -> ...any, ...: any)
		table.insert(queued, { fn = fn, args = table.pack(...) })
	end,
	defer = function(fn: (...any) -> ...any, ...: any)
		table.insert(queued, { fn = fn, args = table.pack(...) })
	end,
	spawn = function(fn: (...any) -> ...any, ...: any)
		fn(...)
	end,
	wait = function(): number
		return 0
	end,
}
-- Runs every queued `delay` and `defer` (and those they queue); returns how many ran.
function FakeClient.runTasks(): number
	local ran = 0
	while #queued > 0 do
		local jobs = queued
		queued = {}
		for _, job in jobs do
			job.fn(table.unpack(job.args, 1, job.args.n))
			ran += 1
		end
	end
	return ran
end

local GUI_OBJECT = {
	Frame = true,
	TextButton = true,
	TextLabel = true,
	TextBox = true,
	ImageLabel = true,
	ImageButton = true,
	ViewportFrame = true,
	ScrollingFrame = true,
	CanvasGroup = true,
}
local BUTTON = { TextButton = true, ImageButton = true }

local EVENTS = {
	Activated = true,
	MouseEnter = true,
	MouseLeave = true,
	SelectionGained = true,
	SelectionLost = true,
	InputBegan = true,
	InputEnded = true,
	InputChanged = true,
	Focused = true,
	FocusLost = true,
	Changed = true,
	MouseButton1Click = true,
	MouseButton1Down = true,
	MouseButton1Up = true,
	MouseButton2Click = true,
	ChildAdded = true,
	ChildRemoved = true,
	Destroying = true,
	AncestryChanged = true,
	MouseMoved = true,
	Event = true,
}

local function isA(class: string, want: string): boolean
	if want == class or want == "Instance" then
		return true
	end
	if want == "GuiObject" then
		return GUI_OBJECT[class] == true
	elseif want == "GuiButton" then
		return BUTTON[class] == true
	elseif want == "GuiBase2d" then
		return GUI_OBJECT[class] == true or class == "ScreenGui"
	elseif want == "LayerCollector" then
		return class == "ScreenGui"
	elseif want == "UIComponent" then
		return string.sub(class, 1, 2) == "UI"
	end
	return false
end

FakeClient.VIEW = { w = 1920, h = 1080 }
local VIEW = FakeClient.VIEW

local propsOf: { [any]: any } = setmetatable({}, { __mode = "k" }) :: any
local childrenOf: { [any]: { any } } = setmetatable({}, { __mode = "k" }) :: any
local signalsOf: { [any]: { [string]: any } } = setmetatable({}, { __mode = "k" }) :: any

local function defaults(class: string): { [string]: any }
	local p: { [string]: any } = { ClassName = class, Name = class, Archivable = true }
	if GUI_OBJECT[class] then
		p.Visible = true
		p.Position = UDim2.new()
		p.Size = UDim2.new()
		p.AnchorPoint = Vector2.zero
		p.ZIndex = 1
		p.BackgroundTransparency = 0
		p.BackgroundColor3 = Color3.new(1, 1, 1)
		p.BorderSizePixel = 1
		p.Active = BUTTON[class] == true
		p.Selectable = BUTTON[class] == true or class == "TextBox"
		p.ClipsDescendants = false
		p.Rotation = 0
		p.LayoutOrder = 0
		if class == "TextButton" or class == "TextLabel" or class == "TextBox" then
			p.Text = if class == "TextLabel" then "Label" elseif class == "TextButton" then "Button" else ""
			p.TextSize = 8
			p.TextTransparency = 0
			p.TextColor3 = Color3.new()
			p.TextStrokeTransparency = 1
		end
		if class == "ImageLabel" or class == "ImageButton" then
			p.Image = ""
			p.ImageColor3 = Color3.new(1, 1, 1)
			p.ImageTransparency = 0
		end
	elseif class == "ScreenGui" then
		p.Enabled = true
	elseif class == "UIScale" then
		p.Scale = 1
	elseif class == "UIGradient" or class == "UIStroke" then
		p.Enabled = true
		p.Thickness = 1
		p.Transparency = 0
		p.Color = Color3.new()
	end
	return p
end

local Instance = {}
local meta: any = {}

local function absRect(object: any): (number, number, number, number, number)
	local p = propsOf[object]
	local parent = p.Parent
	local px, py, pw, ph, pk
	if parent ~= nil and GUI_OBJECT[propsOf[parent].ClassName] then
		px, py, pw, ph, pk = absRect(parent)
	else
		px, py, pw, ph, pk = 0, 0, VIEW.w, VIEW.h, 1
	end
	local own = 1
	for _, child in childrenOf[object] do
		if propsOf[child].ClassName == "UIScale" then
			own = propsOf[child].Scale
			break
		end
	end
	local size, pos, anchor = p.Size, p.Position, p.AnchorPoint
	local w = (size.X.Scale * pw + size.X.Offset * pk) * own
	local h = (size.Y.Scale * ph + size.Y.Offset * pk) * own
	local ax = px + pos.X.Scale * pw + pos.X.Offset * pk
	local ay = py + pos.Y.Scale * ph + pos.Y.Offset * pk
	return ax - anchor.X * w, ay - anchor.Y * h, w, h, pk * own
end
FakeClient.absRect = absRect

local methods: { [string]: any } = {}
function methods.IsA(self, class: string): boolean
	return isA(propsOf[self].ClassName, class)
end
function methods.FindFirstChild(self, name: string, recursive: boolean?): any
	for _, child in childrenOf[self] do
		if propsOf[child].Name == name then
			return child
		end
	end
	if recursive then
		for _, child in childrenOf[self] do
			local found = methods.FindFirstChild(child, name, true)
			if found then
				return found
			end
		end
	end
	return nil
end
function methods.WaitForChild(self, name: string): any
	return methods.FindFirstChild(self, name)
end
function methods.FindFirstChildOfClass(self, class: string): any
	for _, child in childrenOf[self] do
		if propsOf[child].ClassName == class then
			return child
		end
	end
	return nil
end
function methods.FindFirstChildWhichIsA(self, class: string): any
	for _, child in childrenOf[self] do
		if isA(propsOf[child].ClassName, class) then
			return child
		end
	end
	return nil
end
function methods.GetChildren(self): { any }
	return table.clone(childrenOf[self])
end
function methods.GetDescendants(self): { any }
	local list = {}
	local function walk(o)
		for _, child in childrenOf[o] do
			table.insert(list, child)
			walk(child)
		end
	end
	walk(self)
	return list
end
function methods.IsDescendantOf(self, other): boolean
	local at = propsOf[self].Parent
	while at do
		if at == other then
			return true
		end
		at = propsOf[at].Parent
	end
	return false
end
function methods.Destroy(self)
	-- (Destroying fires first, on the object and then on each descendant, as in Roblox.)
	local signal = signalsOf[self].Destroying
	if signal then
		signal:Fire()
	end
	for _, child in table.clone(childrenOf[self]) do
		methods.Destroy(child)
	end
	self.Parent = nil
	propsOf[self].destroyed = true
	table.clear(signalsOf[self])
end
function methods.ClearAllChildren(self)
	for _, child in table.clone(childrenOf[self]) do
		methods.Destroy(child)
	end
end
function methods.GetPropertyChangedSignal(self, prop: string): any
	local signals = signalsOf[self]
	local key = "prop:" .. prop
	signals[key] = signals[key] or newSignal()
	return signals[key]
end
function methods.IsFocused(): boolean
	return false
end
function methods.ReleaseFocus() end
function methods.CaptureFocus() end
function methods.GetFullName(self): string
	return propsOf[self].Name
end
function methods.GetAttribute(self, name)
	return (propsOf[self].attributes or {})[name]
end
function methods.SetAttribute(self, name, value)
	local p = propsOf[self]
	p.attributes = p.attributes or {}
	p.attributes[name] = value
end
function methods.TweenSize() end
function methods.TweenPosition() end
-- A BindableEvent's Fire: its Event's listeners, at once.
function methods.Fire(self, ...: any)
	(self :: any).Event:Fire(...)
end

meta.__index = function(self, key: string): any
	local m = methods[key]
	if m then
		return m
	end
	local p = propsOf[self]
	if key == "AbsolutePosition" or key == "AbsoluteSize" then
		if p.ClassName == "ScreenGui" then
			return if key == "AbsolutePosition" then Vector2.zero else Vector2.new(VIEW.w, VIEW.h)
		end
		local x, y, w, h = absRect(self)
		return if key == "AbsolutePosition" then Vector2.new(x, y) else Vector2.new(w, h)
	end
	if EVENTS[key] then
		local signals = signalsOf[self]
		signals[key] = signals[key] or newSignal()
		return signals[key]
	end
	local value = p[key]
	if value ~= nil then
		return value
	end
	for _, child in childrenOf[self] do
		if propsOf[child].Name == key then
			return child
		end
	end
	return nil
end
meta.__newindex = function(self, key: string, value: any)
	local p = propsOf[self]
	if key == "Parent" then
		local old = p.Parent
		if old ~= nil then
			local list = childrenOf[old]
			for i, c in list do
				if c == self then
					table.remove(list, i)
					break
				end
			end
		end
		p.Parent = value
		if value ~= nil then
			table.insert(childrenOf[value], self)
		end
		return
	end
	p[key] = value
end
meta.__tostring = function(self)
	return `{propsOf[self].ClassName}({propsOf[self].Name})`
end

function Instance.new(class: string, parent: any?): any
	local object = setmetatable({}, meta)
	propsOf[object] = defaults(class)
	childrenOf[object] = {}
	signalsOf[object] = {}
	if parent then
		object.Parent = parent
	end
	return object
end
FakeClient.Instance = Instance
FakeClient.props = function(object)
	return propsOf[object]
end

-- Is `object` (and every GuiObject above it, up to its ScreenGui) visible?
function FakeClient.shown(object: any): boolean
	local at = object
	while at do
		local p = propsOf[at]
		if GUI_OBJECT[p.ClassName] and not p.Visible then
			return false
		end
		at = p.Parent
	end
	return true
end

function FakeClient.centre(object: any): Vector2
	local x, y, w, h = absRect(object)
	return Vector2.new(x + w / 2, y + h / 2)
end

--[[
	Loads client modules from src/client with `stubs` (path -> table) and `services`.
]]
function FakeClient.loader(
	shared: any,
	sharedRequire: (any) -> any,
	stubs: { [string]: any },
	services: { [string]: any }
)
	local game = {
		GetService = function(_, name: string): any
			if name == "ReplicatedStorage" then
				return {
					WaitForChild = function(_, child: string)
						assert(child == "IceVoxel", child)
						return shared
					end,
				}
			end
			local service = services[name]
			if service == nil then
				error(`no stand-in service {name}`)
			end
			return service
		end,
	}
	local kinds: { [string]: "file" | "dir" } = {}
	local function scan(dir: string)
		for _, entry in fs.readDir(dir) do
			local full = `{dir}/{entry}`
			if fs.isDir(full) then
				kinds[full] = "dir"
				scan(full)
			elseif string.sub(entry, -5) == ".luau" then
				kinds[string.sub(full, 1, -6)] = "file"
			end
		end
	end
	scan("src/client")
	local nodes: { [string]: any } = {}
	local function node(path: string, file: boolean): any
		local found = nodes[path]
		if found then
			return found
		end
		local made = setmetatable({ __fake = true, path = path, file = file }, {
			__index = function(self, key: string): any
				local own = rawget(self, "path")
				if key == "Parent" then
					local base = if rawget(self, "file") then string.sub(own, 1, -6) else own
					local up = string.match(base, "^(.*)/[^/]+$") :: string
					if kinds[up .. "/init"] == "file" then
						return node(up .. "/init.luau", true)
					end
					return node(up, false)
				end
				local dirpath = if rawget(self, "file") then string.sub(own, 1, -6) else own
				if rawget(self, "file") then
					-- (An init.luau module's children are its folder's.)
					local folder = string.match(own, "^(.*)/init%.luau$")
					assert(folder, `{own} has no child {key}`)
					dirpath = folder :: string
				end
				local child = `{dirpath}/{key}`
				local kind = kinds[child]
				assert(kind ~= nil, `{dirpath} has no child {key}`)
				if kind == "dir" and kinds[child .. "/init"] == "file" then
					return node(child .. "/init.luau", true)
				end
				return if kind == "file" then node(child .. ".luau", true) else node(child, false)
			end,
		})
		nodes[path] = made
		return made
	end

	local cache: { [string]: any } = {}
	local function req(target: any): any
		if type(target) ~= "table" or rawget(target, "__fake") == nil then
			return sharedRequire(target)
		end
		local path = rawget(target, "path")
		if stubs[path] ~= nil then
			local stub = stubs[path]
			if type(stub) == "function" then
				stub = stub(req, node)
				stubs[path] = stub
			end
			return stub
		end
		if cache[path] ~= nil then
			return cache[path]
		end
		local chunk = luau.load(withHeader(fs.readFile(path)), { debugName = path })
		local result = chunk(
			target,
			req,
			game,
			Instance,
			Color3,
			UDim2,
			UDim,
			Vector2,
			Enum,
			Font,
			roblox.ColorSequence,
			roblox.NumberSequence,
			roblox.ColorSequenceKeypoint,
			roblox.NumberSequenceKeypoint,
			roblox.Rect,
			nil,
			roblox.Vector3,
			roblox.CFrame,
			FakeClient.task
		)
		cache[path] = result
		return result
	end
	return function(path: string): any
		return req(node(path, true))
	end, req, node
end

return FakeClient
