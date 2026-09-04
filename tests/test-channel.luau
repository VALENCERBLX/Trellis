-- Service to Service, directly, with REST verbs and nothing else.

local H = require("./harness")
local T = H.suite("Channel")

local Src = H.src("Src")
local Junction = H.src("Junction")

local check, throws = T.check, T.throws

local MAP = { Local = { Ping = { Send = {} } } }

-- A runtime with a few modules already booted, which is all a channel needs.
local function world()
	local junction = Junction.new(MAP, "Server")
	junction:Materialize({ New = function()
		return {}
	end, Wait = function()
		return {}
	end })

	local modules = {}
	local runtime = { Side = "Server", Junction = junction, Modules = modules, Latches = {} }

	local function add(name, role, module)
		local entry = { Name = name, Role = role, Module = module }
		entry.Src = Src.new(entry, runtime)
		modules[name] = entry
		return entry
	end

	return add, modules
end

-- ===================================================================== the calls ===

do
	local add = world()

	local log = {}
	local memory = {
		profiles = { [1] = { Coins = 10, Name = "Ada" } },
	}
	function memory:GET(route, payload, from)
		table.insert(log, string.format("GET %s from %s", route, from))
		if route == "profile" then
			return self.profiles[payload.UserId]
		end
		return nil
	end
	function memory:PATCH(route, payload)
		local profile = self.profiles[payload.UserId]
		for key, value in payload.Changes do
			profile[key] = value
		end
		return profile
	end
	function memory:DELETE(route, payload)
		self.profiles[payload.UserId] = nil
		return true
	end

	local combat = {}
	add("MemoryService", "Service", memory)
	local caller = add("CombatService", "Service", combat)

	local channel = caller.Src:Channel("MemoryService")

	local profile = channel:GET("profile", { UserId = 1 })
	check("Get reaches the other Service", profile ~= nil and profile.Name == "Ada")
	check("...and the handler is told who called", log[1] == "GET profile from CombatService", log[1])

	local patched = channel:PATCH("profile", { UserId = 1, Changes = { Coins = 99 } })
	T.equal("Patch runs on the same live module", patched.Coins, 99)
	T.equal("...the target's own state changed", memory.profiles[1].Coins, 99)

	check("Delete works", channel:DELETE("profile", { UserId = 1 }) == true)
	check("...and it really deleted", memory.profiles[1] == nil)

	check("the channel is cached", caller.Src:Channel("MemoryService") == channel)
end

-- ================================================================ the vocabulary ===

do
	local add = world()

	local target = {}
	function target:GET() end
	function target:POST() end

	add("DataService", "Service", target)
	local caller = add("UserService", "Service", {})
	local channel = caller.Src:Channel("DataService")

	check("every REST verb exists on the channel", (function()
		for _, verb in { "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS" } do
			if type(channel[verb]) ~= "function" then
				return false
			end
		end
		return true
	end)())

	check("...and nothing else does", channel.Fetch == nil and channel.Send == nil and channel.Invoke == nil)

	T.equal(
		"Options answers without the Service implementing it",
		table.concat(channel:OPTIONS(), ","),
		"GET,POST"
	)

	throws("a verb the target does not answer says what it does", function()
		channel:PUT("thing", {})
	end, "DataService answers no :PUT. it implements: GET, POST")
end

-- ==================================================================== the rules ===

do
	local add = world()
	add("RealService", "Service", { GET = function() end })
	add("SomeManager", "Manager", {})
	local controller = add("HudController", "Controller", {})
	local service = add("MineService", "Service", {})

	throws("a Controller cannot open a channel", function()
		controller.Src:Channel("RealService")
	end, "HudController is a Controller, and channels are between Services")

	throws("a channel to a Manager is refused", function()
		service.Src:Channel("SomeManager")
	end, 'opened a channel to "SomeManager", which is a Manager')

	throws("a channel to nothing lists the Services", function()
		service.Src:Channel("GhostService")
	end, 'opened a channel to "GhostService", which is not on the Server. Services here: RealService')

	throws("a channel to itself is refused", function()
		service.Src:Channel("MineService")
	end, "MineService opened a channel to itself")
end

-- ================================================================== both sides ===

do
	-- channels are same-side by construction: they reach the Modules table of the
	-- side you are on, so a client channel finds the client's half
	local add = world()
	local clientish = { GET = function()
		return "server side"
	end }
	add("SplitService", "Service", clientish)
	local caller = add("OtherService", "Service", {})

	T.equal("it reaches the module on this side", caller.Src:Channel("SplitService"):GET("x"), "server side")
end

T.done()
