-- The heartbeat scheduler: throttling, accumulated dt, phase staggering, timers.

local H = require("./harness")
local T = H.suite("Scheduler")
local Scheduler = H.src("Scheduler")

local check = T.check

local function fakeModule()
	local m = { Calls = 0, Total = 0, Frames = {} }
	function m:Heartbeat(dt)
		self.Calls += 1
		self.Total += dt
	end
	return m
end

local FRAME = 1 / 60
local SECONDS = 2
local FRAMES = 60 * SECONDS

-- throttling + accumulated dt ------------------------------------------------
do
	local sched = Scheduler.new("Server")
	local fast, slow, every = fakeModule(), fakeModule(), fakeModule()

	sched:Add("Fast", fast, 30)
	sched:Add("Slow", slow, 10)
	sched:Add("Every", every, nil)

	for _ = 1, FRAMES do
		sched:Step("Heart", FRAME)
	end

	check("Hz=30 over 2s fires ~60x", fast.Calls == 60, fast.Calls)
	check("Hz=10 over 2s fires ~20x", slow.Calls == 20, slow.Calls)
	check("no Hz fires every frame", every.Calls == FRAMES, every.Calls)

	-- the point of accumulating: elapsed time is preserved regardless of rate
	check("Hz=30 accumulated dt == wall clock", math.abs(fast.Total - SECONDS) < 0.02, fast.Total)
	check("Hz=10 accumulated dt == wall clock", math.abs(slow.Total - SECONDS) < 0.06, slow.Total)
	check("unthrottled dt == wall clock", math.abs(every.Total - SECONDS) < 0.001, every.Total)
end

-- phase staggering -----------------------------------------------------------
do
	local sched = Scheduler.new("Server")
	local mods = {}

	-- 12 modules all at the same rate: the worst case for clustering
	for i = 1, 12 do
		local m = fakeModule()
		local id = i
		function m:Heartbeat(dt)
			self.Calls += 1
			self.Total += dt
			table.insert(self.Frames, id)
		end
		mods[i] = m
		sched:Add("Mod" .. i, m, 10)
	end

	-- count how many of the 12 fire on each frame
	local perFrame = {}
	local seen = {}
	for i = 1, 12 do
		seen[i] = 0
	end

	for frame = 1, 60 do
		local before = {}
		for i = 1, 12 do
			before[i] = mods[i].Calls
		end
		sched:Step("Heart", FRAME)
		local fired = 0
		for i = 1, 12 do
			if mods[i].Calls > before[i] then
				fired += 1
			end
		end
		perFrame[frame] = fired
	end

	local busiest = 0
	local framesWithWork = 0
	for _, n in perFrame do
		busiest = math.max(busiest, n)
		if n > 0 then
			framesWithWork += 1
		end
	end

	check("all 12 ran at the right rate", mods[1].Calls == mods[12].Calls, mods[1].Calls)
	check("no frame carries all 12 (staggered)", busiest < 12, "busiest frame: " .. busiest)
	check("work spread over many frames", framesWithWork >= 10, framesWithWork .. " frames had work")
	print(string.format("       busiest frame: %d of 12 · work landed on %d of 60 frames", busiest, framesWithWork))
end

-- drivers --------------------------------------------------------------------
do
	local sched = Scheduler.new("Client")
	sched:Add("Cam", fakeModule(), "Render")
	sched:Add("Phys", fakeModule(), "Step")
	sched:Add("Vfx", fakeModule(), nil)

	check("drivers are separate lists", table.concat(sched:Drivers(), ",") == "Heart,Render,Step")
	check("one task per driver", sched:Count("Render") == 1 and sched:Count("Heart") == 1)

	local cam = fakeModule()
	sched:Add("Cam2", cam, "Render")
	sched:Step("Heart", FRAME)
	check("stepping one driver doesn't run another", cam.Calls == 0, cam.Calls)
	sched:Step("Render", FRAME)
	check("stepping Render runs Render tasks", cam.Calls == 1, cam.Calls)
end

-- validation -----------------------------------------------------------------
do
	local sched = Scheduler.new("Server")

	local ok, err = pcall(function()
		sched:Add("Cam", fakeModule(), "Render")
	end)
	check('Hz="Render" rejected on the server', not ok and string.find(tostring(err), "client-only", 1, true) ~= nil, err)

	local ok2, err2 = pcall(function()
		sched:Add("Broken", { Start = function() end }, 10)
	end)
	check("Req Heart without :Heartbeat is an error", not ok2 and string.find(tostring(err2), "defines no :Heartbeat", 1, true) ~= nil, err2)

	local ok3 = pcall(function()
		sched:Add("Bad", fakeModule(), -5)
	end)
	check("Hz <= 0 rejected", not ok3)
end

-- an erroring module must not take the frame down ----------------------------
do
	local sched = Scheduler.new("Server")
	local bad = { Heartbeat = function() error("boom") end }
	local good = fakeModule()
	sched:Add("Bad", bad, nil)
	sched:Add("Good", good, nil)

	sched:Step("Heart", FRAME)
	sched:Step("Heart", FRAME)

	check("an erroring :Heartbeat is isolated", good.Calls == 2, good.Calls)
	check("the error is reported once per frame", #H.warnings.peek() == 2, #H.warnings.peek())
end

T.done()
