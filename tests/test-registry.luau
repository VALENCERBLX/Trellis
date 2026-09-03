-- Dependency injection derived from the hierarchy: bin derivation, Main, no descent,
-- collisions, suffix aliasing, lazy loading, reconciliation.

local H = require("./harness")
local T = H.suite("Registry")
local Registry = H.src("Registry")

local check, expectError = T.check, T.throws
local folder, module = H.folder, H.module

-- Every construction goes through here so laziness can be measured: the registry
-- must not resolve anything until something asks.
local requireCount = 0
local function newRegistry(roots, config)
	config = config or {}
	config.Loader = function(source)
		requireCount += 1
		return H.loader(source)
	end
	return Registry.new(roots, config)
end


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
local reg = newRegistry({ shared, server }, {
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
	local dup = newRegistry({ shared, other })

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
local reg2 = newRegistry({ shared }, {
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

T.done()
