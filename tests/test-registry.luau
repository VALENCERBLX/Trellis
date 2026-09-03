-- Lune harness for Registry.luau — stubs Instance + require, then exercises the
-- derived getters, collision detection, suffix aliasing and lazy loading.

local fs = require("@lune/fs")
local process = require("@lune/process")
local luau = require("@lune/luau")

-- ============================================================ Instance stubs ===

local MODULE_VALUES = {}

local Instance_mt = {}
Instance_mt.__index = Instance_mt

function Instance_mt:GetChildren()
	return self._children
end

function Instance_mt:IsA(className)
	return self.ClassName == className
end

function Instance_mt:GetFullName()
	local parts, node = {}, self
	while node do
		table.insert(parts, 1, node.Name)
		node = node._parent
	end
	return table.concat(parts, ".")
end

local function make(className, name, children)
	local inst = setmetatable({
		ClassName = className,
		Name = name,
		_children = {},
		_parent = nil,
	}, Instance_mt)
	for _, child in children or {} do
		child._parent = inst
		table.insert(inst._children, child)
	end
	return inst
end

local function folder(name, children)
	return make("Folder", name, children)
end

-- a ModuleScript stub whose "source" is just the value it returns
local function module(name, value)
	local m = make("ModuleScript", name, {})
	MODULE_VALUES[m] = value
	return m
end

-- ================================================================ load target ===

local requireCount = 0

local function stubRequire(target)
	if target == "TYPES" then
		return {}
	end
	if MODULE_VALUES[target] ~= nil then
		requireCount += 1
		return MODULE_VALUES[target]
	end
	error("stub require: unknown target " .. tostring(target))
end

local source = fs.readFile("../src/Registry.luau")
-- the only real require in the module is the sibling Types module
source = source:gsub("require%(script%.Parent%.Types%)", 'require("TYPES")')

local chunk = luau.load(source, {
	environment = {
		require = stubRequire,
		string = string,
		table = table,
		type = type,
		setmetatable = setmetatable,
		pcall = pcall,
		error = error,
		tostring = tostring,
		print = print,
		script = nil,
	},
})

local Registry = chunk()

-- ===================================================================== tests ===

local passed, failed = 0, 0

local function check(label, ok, detail)
	if ok then
		passed += 1
		print(string.format("  ok   %s", label))
	else
		failed += 1
		print(string.format("  FAIL %s%s", label, detail and ("  -> " .. tostring(detail)) or ""))
	end
end

local function expectError(label, fn, fragment)
	local ok, err = pcall(fn)
	if ok then
		check(label, false, "expected an error, got none")
		return
	end
	check(label, string.find(tostring(err), fragment, 1, true) ~= nil, err)
end

print("\nRegistry\n")

-- a hierarchy shaped like the real thing
local shared = folder("Shared", {
	folder("Packages", {
		module("Lume", { id = "Lume" }),
		-- a package with its own nested Packages folder: must be invisible to us
		(function()
			local icon = module("Icon", { id = "Icon" })
			local nested = folder("Packages", { module("Lume", { id = "IconLume" }) })
			nested._parent = icon
			table.insert(icon._children, nested)
			return icon
		end)(),
	}),
	folder("Utilities", {
		module("Maid", { id = "Maid" }),
	}),
	folder("Config", {
		module("Junction", { id = "Junction" }),
	}),
})

local server = folder("ServerStorage", {
	folder("Managers", {
		module("CombatManager", { id = "CombatManager" }),
	}),
	folder("Services", {
		module("CombatService", { id = "CombatService" }),
	}),
})

local before = requireCount
local reg = Registry.new({ shared, server }, {
	Inject = { Package = { Profiles = { id = "Profiles" } } },
})

check("nothing required at construction (lazy)", requireCount == before, requireCount)

-- derived getters ------------------------------------------------------------
check("Packages  -> GetPackage", reg:GetPackage("Lume").id == "Lume")
check("Utilities -> GetUtility", reg:GetUtility("Maid").id == "Maid")
check("Config    -> GetConfig (already singular)", reg:GetConfig("Junction").id == "Junction")
check("Managers  -> GetManager", reg:GetManager("CombatManager").id == "CombatManager")
check("Services  -> GetService", reg:GetService("CombatService").id == "CombatService")

check("requires happened on access", requireCount == before + 5, requireCount)
reg:GetPackage("Lume")
check("second access is cached", requireCount == before + 5, requireCount)

-- suffix stripping -----------------------------------------------------------
check("suffix alias: GetService('Combat')", reg:GetService("Combat").id == "CombatService")
check("suffix alias: GetManager('Combat')", reg:GetManager("Combat").id == "CombatManager")
check("no bogus alias for GetPackage('Lume')", reg:HasPackage("Lume"))

-- injection ------------------------------------------------------------------
check("Inject extends the Package bin", reg:GetPackage("Profiles").id == "Profiles")

-- no descent -----------------------------------------------------------------
check("nested Packages/Icon/Packages ignored", reg:GetPackage("Lume").id == "Lume")
check("Icon itself is mounted", reg:GetPackage("Icon").id == "Icon")

-- listing --------------------------------------------------------------------
local bins = table.concat(reg:Bins(), ",")
check("bins derived from the tree", bins == "Config,Manager,Package,Service,Utility", bins)
local pkgs = table.concat(reg:ListPackage(), ",")
check("ListPackage dedupes aliases", pkgs == "Icon,Lume,Profiles", pkgs)

-- errors ---------------------------------------------------------------------
expectError("missing bin names the bins that exist", function()
	return reg:Resolve("Widget", "Thing")
end, "bins on this side: Config, Manager, Package, Service, Utility")

expectError("missing entry lists known names", function()
	return reg:GetUtility("Maidd")
end, 'no Utility named "Maidd". known: Maid')

check("HasX is a soft miss", reg:HasUtility("Maidd") == false)

-- collision ------------------------------------------------------------------
-- A duplicate is recorded at mount and thrown on ACCESS, so Bootstrap gets one
-- chance to reconcile it (a double-sided Service) before it becomes fatal.
do
	local other = folder("Client", { folder("Packages", { module("Lume", { id = "OldLume" }) }) })
	local dup = Registry.new({ shared, other })

	check("a duplicate is recorded, not thrown at mount", #dup:Claims("Package", "Lume") == 2)
	check("...and listed", table.concat(dup:ClaimedNames("Package"), ",") == "Lume")

	expectError("an unreconciled duplicate throws on access", function()
		return dup:GetPackage("Lume")
	end, 'duplicate Package "Lume", mounted from:')

	expectError("...naming every origin", function()
		return dup:GetPackage("Lume")
	end, "Client.Packages.Lume")

	dup:Reconcile("Package", "Lume", { id = "Paired" })
	check("Reconcile collapses it to one value", dup:GetPackage("Lume").id == "Paired")
	check("...and clears the claim", dup:Claims("Package", "Lume") == nil)
end

-- resolver bin ---------------------------------------------------------------
local reg2 = Registry.new({ shared }, {
	Inject = {
		Region = function(name)
			return { id = "region:" .. name }
		end,
	},
})
check("resolver bin generates GetRegion", reg2:GetRegion("Arena").id == "region:Arena")

-- Main: the hierarchy exactly as written -------------------------------------
check("Main.Packages.Lume == GetPackage('Lume')", reg.Main.Packages.Lume == reg:GetPackage("Lume"))
check("Main uses the CONTAINER name (plural)", reg.Main.Utilities.Maid.id == "Maid")
check("Main.Config (already singular)", reg.Main.Config.Junction.id == "Junction")
check("Main.Managers.CombatManager", reg.Main.Managers.CombatManager.id == "CombatManager")
check("Main suffix alias works too", reg.Main.Services.Combat.id == "CombatService")
check("Inject shows up in Main", reg.Main.Packages.Profiles.id == "Profiles")
expectError("Main containers can't be replaced", function()
	reg.Main.Packages = {}
end, "readonly")
expectError("Main entries can't be written", function()
	reg.Main.Packages.Lume = {}
end, "read-only")
expectError("a miss through Main errors like the getter", function()
	return reg.Main.Utilities.Maidd
end, 'no Utility named "Maidd"')
local iterated = {}
for name in reg.Main.Utilities do
	table.insert(iterated, name)
end
check("Main containers are iterable", table.concat(iterated, ",") == "Maid", table.concat(iterated, ","))

-- preload --------------------------------------------------------------------
local loaded = reg:Preload("Service")
check("Preload returns every entry once", loaded.CombatService.id == "CombatService")

print(string.format("\n%d passed, %d failed\n", passed, failed))
if failed > 0 then
	process.exit(1)
end
