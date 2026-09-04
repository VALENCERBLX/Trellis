-- The generated installer. Runs dist/Adeal.luau against fake Instances and checks it
-- rebuilds the package byte-for-byte, so a stale or mangled dist cannot ship.

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local H = require("./harness")
local T = H.suite("Dist")
local check = T.check

-- ============================================================== fake Instances ===

local created = {}

local Inst = {}
Inst.__index = Inst

function Inst:Destroy()
	self.Destroyed = true
	if self._parent then
		local kids = self._parent._children
		local i = table.find(kids, self)
		if i then
			table.remove(kids, i)
		end
	end
end

function Inst:FindFirstChild(name)
	for _, child in self._children do
		if child.Name == name then
			return child
		end
	end
	return nil
end

function Inst:GetChildren()
	return self._children
end

function Inst:GetFullName()
	local parts, node = {}, self
	while node do
		table.insert(parts, 1, node.Name)
		node = rawget(node, "_parent")
	end
	return table.concat(parts, ".")
end

local function newInstance(className)
	local inst = setmetatable({
		ClassName = className,
		Name = "Instance",
		Source = nil,
		_children = {},
		_parent = nil,
	}, {
		__index = Inst,
		__newindex = function(t, key, value)
			if key == "Parent" then
				rawset(t, "_parent", value)
				if value then
					table.insert(value._children, t)
				end
			else
				rawset(t, key, value)
			end
		end,
	})
	table.insert(created, inst)
	return inst
end

local ReplicatedStorage = setmetatable({ ClassName = "ReplicatedStorage", Name = "ReplicatedStorage", _children = {} }, { __index = Inst })


local printed = {}

local function run()
	created = {}
	printed = {}
	local chunk = luau.load(fs.readFile("../dist/Adeal.luau"), {
		environment = {
			game = {
				GetService = function(_, name)
					assert(name == "ReplicatedStorage", "Adeal asked for " .. name)
					return ReplicatedStorage
				end,
			},
			Instance = { new = newInstance },
			string = string,
			table = table,
			print = function(...)
				local parts = {}
				for i = 1, select("#", ...) do
					table.insert(parts, tostring(select(i, ...)))
				end
				table.insert(printed, table.concat(parts, " "))
			end,
			setmetatable = setmetatable,
			rawset = rawset,
			select = select,
			assert = assert,
			pcall = pcall,
			error = error,
			tostring = tostring,
			type = type,
		},
	})
	return chunk()
end

-- ===================================================================== tests ===

run()

local function at(root, path)
	local node = root
	for segment in string.gmatch(path, "[^%.]+") do
		node = node and node:FindFirstChild(segment)
	end
	return node
end

local package = at(ReplicatedStorage, "Shared.Modules.Packages.Trellis")
check("Adeal parses and runs", package ~= nil)
check("it installs with the other packages", package and package.ClassName == "ModuleScript")
check("...creating the path if it is missing", at(ReplicatedStorage, "Shared.Modules.Packages") ~= nil)
check("...and not at the old root location", ReplicatedStorage:FindFirstChild("Trellis") == nil)

-- every src module must be present, with its source intact
local expected = {}
for _, file in fs.readDir("../src") do
	local name = string.match(file, "^(.+)%.luau$")
	if name and name ~= "init" then
		expected[name] = fs.readFile("../src/" .. file)
	end
end

local count, mismatched = 0, {}
for name, source in expected do
	count += 1
	local child = package:FindFirstChild(name)
	if not child then
		table.insert(mismatched, name .. " missing")
	elseif child.Source ~= source then
		table.insert(mismatched, name .. " source differs")
	end
end

T.equal("every src module is carried", #package:GetChildren(), count)
check("...with sources byte-for-byte identical", #mismatched == 0, table.concat(mismatched, ", "))
check("the root module is init.luau", package.Source == fs.readFile("../src/init.luau"))

-- The dist is generated, so it goes stale silently unless something checks. This is
-- that something: if it fails, run `lune run scripts/build-dist`.
check("dist is not stale (rerun scripts/build-dist if this fails)", #mismatched == 0 and #package:GetChildren() == count)

check("it reports where it landed", string.find(printed[1] or "", "ReplicatedStorage.Shared.Modules.Packages.Trellis", 1, true) ~= nil, printed[1])

-- rerunning replaces rather than duplicating
-- a place upgraded from a version that installed at the root
local legacy = newInstance("ModuleScript")
legacy.Name = "Trellis"
legacy.Parent = ReplicatedStorage

run()

local Packages = at(ReplicatedStorage, "Shared.Modules.Packages")
local after = 0
for _, child in Packages._children do
	if child.Name == "Trellis" and not child.Destroyed then
		after += 1
	end
end
T.equal("rerunning leaves exactly one package", after, 1)
check("...and clears a copy left at the old location", ReplicatedStorage:FindFirstChild("Trellis") == nil)
check("...saying so", (function()
	for _, line in printed do
		if string.find(line, "removed the old copy", 1, true) then
			return true
		end
	end
	return false
end)(), table.concat(printed, " | "))
check("...and says it replaced", string.find(printed[1] or "", "replaced", 1, true) ~= nil, printed[1])

-- ============================================================ dist/Setup.luau ===
-- Setup is hand-written rather than generated, so this is the only thing standing
-- between a typo and a broken paste-in script.

do
	local roots = {}
	local function service(name)
		local svc = setmetatable({ ClassName = name, Name = name, _children = {} }, { __index = Inst })
		function svc:GetFullName()
			return self.Name
		end
		roots[name] = svc
		return svc
	end

	local RS = service("ReplicatedStorage")
	local SSS = service("ServerScriptService")
	local SS = service("ServerStorage")
	local SP = service("StarterPlayer")

	-- StarterPlayerScripts is a child, as it is in a real place
	local sps = setmetatable({ ClassName = "StarterPlayerScripts", Name = "StarterPlayerScripts", _children = {}, _parent = SP }, { __index = Inst })
	function sps:GetFullName()
		return "StarterPlayer.StarterPlayerScripts"
	end
	table.insert(SP._children, sps)

	local instances = {}
	local function makeInstance(className)
		local inst
		inst = setmetatable({ ClassName = className, Name = "Instance", _children = {} }, {
			__index = Inst,
			__newindex = function(t, key, value)
				if key == "Parent" then
					rawset(t, "_parent", value)
					if value then
						table.insert(value._children, t)
					end
				else
					rawset(t, key, value)
				end
			end,
		})
		table.insert(instances, inst)
		return inst
	end

	local out, warns = {}, {}
	local function runSetup()
		local chunk = luau.load(fs.readFile("../dist/Setup.luau"), {
			environment = {
				game = { GetService = function(_, name)
					return roots[name] or error("Setup asked for " .. name)
				end },
				Instance = { new = makeInstance },
				string = string,
				table = table,
				rawget = rawget,
				rawset = rawset,
				setmetatable = setmetatable,
				error = error,
				print = function(...)
					local parts = {}
					for i = 1, select("#", ...) do
						table.insert(parts, tostring(select(i, ...)))
					end
					table.insert(out, table.concat(parts, " "))
				end,
				warn = function(m)
					table.insert(warns, tostring(m))
				end,
				select = select,
				tostring = tostring,
			},
		})
		return chunk()
	end

	runSetup()

	local function at2(path)
		local node = roots[string.match(path, "^[^%.]+")]
		for segment in string.gmatch(string.gsub(path, "^[^%.]+%.?", ""), "[^%.]+") do
			node = node and node:FindFirstChild(segment)
		end
		return node
	end
	local at = at2

	check("Setup.luau parses and runs", #out > 0)
	check("it warns when the package is missing", #warns == 1 and string.find(warns[1], "Run dist/Adeal.luau first", 1, true) ~= nil, warns[1])
	check("Packages is part of the layout", at2("ReplicatedStorage.Shared.Modules.Packages") ~= nil)

	check("Shared module folders", at("ReplicatedStorage.Shared.Modules.Packages") ~= nil and at("ReplicatedStorage.Shared.Modules.Services") ~= nil)
	check("content trees", at("ReplicatedStorage.Shared.Assets.Interface") ~= nil and at("ReplicatedStorage.Shared.Classes.__NameOfClassFolder__.__NameOfClass__") ~= nil)
	check("client module folders", at("ReplicatedStorage.Client.Modules.Controllers") ~= nil)
	check("server module folders", at("ServerStorage.Modules.Managers") ~= nil)

	local bootstrap = at("ReplicatedStorage.Shared.Modules.Utilities.Bootstrap")
	check("the shared Bootstrap", bootstrap ~= nil and bootstrap.ClassName == "ModuleScript")

	local config = at("ReplicatedStorage.Shared.Modules.Utilities.Config")
	check("Config is a ModuleScript", config ~= nil and config.ClassName == "ModuleScript")
	check("...with its four children", config
		and config:FindFirstChild("Junction")
		and config:FindFirstChild("BootOrder")
		and config:FindFirstChild("Registers")
		and config:FindFirstChild("Manifests") ~= nil)

	local serverInit = at("ServerScriptService.ServerInit")
	check("ServerInit is a Script", serverInit ~= nil and serverInit.ClassName == "Script")
	local clientInit = sps:FindFirstChild("Init")
	check("Init is a LocalScript", clientInit ~= nil and clientInit.ClassName == "LocalScript")

	-- every generated source must itself be valid Luau
	local bad = {}
	local function parses(node, label)
		if not node or not node.Source then
			table.insert(bad, label .. " has no source")
			return
		end
		local ok, err = pcall(luau.load, node.Source)
		if not ok then
			table.insert(bad, label .. ": " .. tostring(err))
		end
	end
	parses(bootstrap, "Bootstrap")
	parses(config, "Config")
	for _, name in { "Junction", "BootOrder", "Registers", "Manifests" } do
		parses(config:FindFirstChild(name), name)
	end
	parses(serverInit, "ServerInit")
	parses(clientInit, "Init")
	check("every generated source is valid Luau", #bad == 0, table.concat(bad, " | "))

	-- and it must be safe to run twice
	local before = #instances
	out = {}
	runSetup()
	T.equal("re-running creates nothing new", #instances, before)
	check("...and says so", string.find(out[1] or "", "created 0, kept", 1, true) ~= nil, out[1])
end

T.done()
