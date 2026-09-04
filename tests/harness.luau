--!nonstrict
-- Trellis
-- tests/harness.luau
-- Valence
--
-- Shared rig for the Lune suite. Every src module is loaded into one sandboxed
-- environment with a controllable clock and captured warnings, so a test asserts on
-- behaviour instead of rebuilding the plumbing.
--
--   local H = require("./harness")
--   local T = H.suite("Junction")
--   local Junction = H.src("Junction")
--
--   T.check("label", condition, detail)
--   T.throws("label", fn, "fragment of the message")
--   H.clock.set(2.5)          -- the clock every module sees
--   H.warnings.take()         -- and drain what was warned
--   T.done()                  -- prints the tally, exits non-zero on failure

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local harness = {}

-- ===================================================================== clock ===

local now = 0

harness.clock = {
	set = function(value: number)
		now = value
	end,
	advance = function(delta: number)
		now += delta
	end,
	get = function(): number
		return now
	end,
	reset = function()
		now = 0
	end,
}

-- ================================================================== warnings ===

local captured = {}

harness.warnings = {
	-- Drain and return. Draining is the default because a test that reads warnings
	-- without clearing them will pass on the previous test's output.
	take = function(): { string }
		local out = captured
		captured = {}
		return out
	end,
	saw = function(fragment: string): boolean
		for _, w in captured do
			if string.find(w, fragment, 1, true) then
				return true
			end
		end
		return false
	end,
	clear = function()
		captured = {}
	end,
	peek = function(): { string }
		return captured
	end,
}

-- ============================================================ the environment ===

local modules = {}

local function environment()
	return {
		setmetatable = setmetatable,
		getmetatable = getmetatable,
		rawget = rawget,
		rawset = rawset,
		select = select,
		string = string,
		table = table,
		math = math,
		type = type,
		typeof = nil, -- absent outside Roblox; modules fall back to type()
		pcall = pcall,
		xpcall = xpcall,
		error = error,
		assert = assert,
		tostring = tostring,
		tonumber = tonumber,
		print = print,
		next = next,
		ipairs = ipairs,
		pairs = pairs,
		os = {
			clock = function()
				return now
			end,
			time = function()
				return math.floor(now)
			end,
		},
		debug = {
			profilebegin = function() end,
			profileend = function() end,
		},
		task = {
			spawn = function(fn, ...)
				fn(...)
			end,
			delay = function(seconds, fn)
				table.insert(harness.delayed, { At = now + seconds, Fn = fn })
			end,
			wait = function()
				return 0
			end,
		},
		warn = function(message)
			table.insert(captured, tostring(message))
		end,
		require = function(name)
			local found = modules[name]
			if not found then
				error(string.format("harness: %s required %q, which is not loaded yet", "a module", name), 0)
			end
			return found
		end,
		-- `script.Parent.X` resolves to the string "X", which the require above maps
		-- back to the loaded module. That is the whole trick.
		script = setmetatable({}, {
			__index = function(self, key)
				if key == "Parent" then
					return self
				end
				return key
			end,
		}),
		game = {
			GetService = function()
				error("harness: no live Roblox services; pass a stub through opts", 0)
			end,
		},
		Instance = {
			new = function(className: string)
				return harness.live(className)
			end,
		},
	}
end

-- task.delay does not run on its own here: a test fires them when it wants to.
harness.delayed = {}

function harness.fireDelayed()
	local due = harness.delayed
	harness.delayed = {}
	for _, entry in due do
		entry.Fn()
	end
	return #due
end

-- Load order matters: a module's requires must already be loaded.
local ORDER = {
	"Types",
	"Schema",
	"Reaction",
	"Trove",
	"Log",
	"Registry",
	"Junction",
	"Scheduler",
	"Reg",
	"Src",
	"Inspect",
	"Bootstrap",
	"Tenv",
}

local loaded = false

local function loadAll()
	if loaded then
		return
	end
	loaded = true
	for _, name in ORDER do
		local chunk = luau.load(fs.readFile("../src/" .. name .. ".luau"), { environment = environment() })
		modules[name] = chunk()
	end
end

-- A src module, with every dependency wired.
function harness.src(name: string)
	loadAll()
	local found = modules[name]
	if not found then
		error(string.format("harness: no src module %q", name), 0)
	end
	return found
end

-- ============================================================== live Instances ===
-- Fake instances with the parts that replication-shaped code needs: Parent
-- assignment, ChildAdded/ChildRemoved, Clone and Destroy. `Instance.new` in the
-- sandbox is backed by these, so a module under test and a test's own world are the
-- same kind of thing.

local function signal()
	local handlers = {}
	return {
		Connect = function(_, fn)
			table.insert(handlers, fn)
			return { Disconnect = function()
				local i = table.find(handlers, fn)
				if i then
					table.remove(handlers, i)
				end
			end }
		end,
		Fire = function(...)
			for _, fn in table.clone(handlers) do
				fn(...)
			end
		end,
	}
end

harness.signal = signal

local liveValues = {}

function harness.live(className: string, name: string?, value: any?)
	local added, removed = signal(), signal()
	local inst = {
		ClassName = className,
		Name = name or "Instance",
		_children = {},
		_added = added,
		_removed = removed,
		ChildAdded = { Connect = function(_, fn)
			return added.Connect(nil, fn)
		end },
		ChildRemoved = { Connect = function(_, fn)
			return removed.Connect(nil, fn)
		end },
	}

	function inst:IsA(c)
		return self.ClassName == c
	end
	function inst:GetChildren()
		return self._children
	end
	function inst:FindFirstChild(n)
		for _, c in self._children do
			if c.Name == n then
				return c
			end
		end
		return nil
	end
	function inst:GetFullName()
		local parts, node = {}, self
		while node do
			table.insert(parts, 1, node.Name)
			node = rawget(node, "_parent")
		end
		return table.concat(parts, ".")
	end
	function inst:Clone()
		return harness.live(self.ClassName, self.Name, liveValues[self])
	end
	function inst:Destroy()
		local parent = rawget(self, "_parent")
		if parent then
			local i = table.find(parent._children, self)
			if i then
				table.remove(parent._children, i)
			end
			parent._removed.Fire(self)
		end
		rawset(self, "_parent", nil)
	end

	setmetatable(inst, {
		__newindex = function(t, key, v)
			if key == "Parent" then
				rawset(t, "_parent", v)
				if v then
					table.insert(v._children, t)
					v._added.Fire(t)
				end
			else
				rawset(t, key, v)
			end
		end,
	})

	if value ~= nil then
		liveValues[inst] = value
	end
	return inst
end

-- =============================================================== fake Instances ===

local Node = {}
Node.__index = Node

function Node:GetChildren()
	return self._children
end

function Node:IsA(className: string): boolean
	return self.ClassName == className
end

function Node:GetFullName(): string
	local parts, node = {}, self
	while node do
		table.insert(parts, 1, node.Name)
		node = node._parent
	end
	return table.concat(parts, ".")
end

function Node:FindFirstChild(name: string)
	for _, child in self._children do
		if child.Name == name then
			return child
		end
	end
	return nil
end

function Node:Add(child)
	child._parent = self
	table.insert(self._children, child)
	return child
end

local sources = {}

function harness.folder(name: string, children: { any }?)
	local f = setmetatable({ ClassName = "Folder", Name = name, _children = {} }, Node)
	for _, child in children or {} do
		f:Add(child)
	end
	return f
end

-- A ModuleScript carrying a value. The loader below hands the value straight back,
-- so a test never has to write Luau source into a string.
function harness.module(name: string, value: any)
	assert(value ~= nil, "harness.module(" .. name .. ") was given nil -- declared after use?")
	local m = setmetatable({ ClassName = "ModuleScript", Name = name, _children = {} }, Node)
	sources[m] = value
	return m
end

-- What a live instance carries, for asserting on WHICH module was delivered.
function harness.valueOf(instance)
	return liveValues[instance]
end

-- Pass to Registry or Bootstrap as `Loader`.
function harness.loader(source)
	local value = sources[source]
	if value == nil then
		value = liveValues[source]
	end
	if value == nil then
		error("harness: nothing mounted for " .. tostring(source and source.Name), 0)
	end
	return value
end

-- ==================================================================== the suite ===

function harness.suite(name: string)
	local passed, failed = 0, 0

	print(string.format("\n%s\n", name))

	local T = {}

	function T.check(label: string, ok: any, detail: any?): boolean
		if ok then
			passed += 1
			print(string.format("  ok   %s", label))
		else
			failed += 1
			print(string.format("  FAIL %s%s", label, detail ~= nil and ("  -> " .. tostring(detail)) or ""))
		end
		return ok == true
	end

	function T.equal(label: string, actual: any, expected: any): boolean
		return T.check(label, actual == expected, string.format("got %s, expected %s", tostring(actual), tostring(expected)))
	end

	-- Within `tolerance`, for anything the frame clock touches. Timing assertions
	-- that demand exactness fail on floating-point drift rather than on real bugs.
	function T.near(label: string, actual: number, expected: number, tolerance: number): boolean
		return T.check(
			label,
			math.abs(actual - expected) <= tolerance,
			string.format("got %s, expected %s ± %s", tostring(actual), tostring(expected), tostring(tolerance))
		)
	end

	function T.throws(label: string, fn, fragment: string): boolean
		local ok, err = pcall(fn)
		if ok then
			return T.check(label, false, "expected an error, got none")
		end
		return T.check(label, string.find(tostring(err), fragment, 1, true) ~= nil, err)
	end

	function T.warned(label: string, fragment: string): boolean
		return T.check(label, harness.warnings.saw(fragment), table.concat(harness.warnings.peek(), " | "))
	end

	function T.done()
		print(string.format("\n%d passed, %d failed\n", passed, failed))
		if failed > 0 then
			process.exit(1)
		end
	end

	return T
end

return harness
