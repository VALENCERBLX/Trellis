--!strict
-- Trellis
-- Scheduler.luau
-- Valence
--
-- The engine behind Req "Heart". Owns ONE connection per driver for the whole app
-- and dispatches to every module that asked for a heartbeat. Forty modules cost
-- one Connect, not forty.
--
-- Two things a module cannot do for itself, and so the scheduler does:
--
--   1. THROTTLING. BootOrder gives a module an Hz; the scheduler accumulates frame
--      time and calls :Heartbeat only when that module's period has elapsed, passing
--      the ACCUMULATED dt. Integration stays correct at any rate.
--
--   2. PHASE STAGGERING. Forty modules at Hz = 10 would otherwise all fire on the
--      same frame, giving a six-frame spike cycle. Each module's accumulator starts
--      at a different fraction of its period, spreading the work across frames. Only
--      something that can see all forty can do this.
--
-- Drivers map to RunService signals; "Render" is client-only and rejected on the
-- server at install time, not at first frame.

local Scheduler = {}
Scheduler.__index = Scheduler

-- Golden-ratio low-discrepancy offsets: spreads any number of modules evenly
-- without needing to know the count up front.
local PHI = 0.6180339887498949

export type Driver = "Heart" | "Render" | "Step"

type Task = {
	Name: string,
	Module: any,
	Driver: Driver,
	Period: number, -- 0 = every frame
	Accumulator: number,
	Since: number,
	Calls: number,
}

function Scheduler.new(side: string)
	return setmetatable({
		_side = side,
		_tasks = {} :: { [Driver]: { Task } },
		_timers = {},
		_added = 0,
	}, Scheduler)
end

-- Timers ride the same clock as heartbeats rather than task.delay, so they are
-- deterministic under test, cancel synchronously, and cannot fire into a module the
-- app already tore down.
function Scheduler:Timer(seconds: number, fn, repeating: boolean, owner: string?)
	if type(seconds) ~= "number" or seconds < 0 then
		error(string.format("[Trellis] %s: timer needs a non-negative delay", owner or "?"), 0)
	end

	local handle = {
		Owner = owner,
		Period = seconds,
		Remaining = seconds,
		Repeating = repeating,
		Fn = fn,
		Cancelled = false,
	}
	table.insert(self._timers, handle)
	return handle
end

function Scheduler:CancelTimer(handle)
	if type(handle) == "table" then
		handle.Cancelled = true
	end
end

-- Cancel every timer a module owns. Called on teardown, which is what makes the
-- classic "task.delay fires into a dead module" leak impossible.
function Scheduler:CancelOwned(owner: string)
	for _, handle in self._timers do
		if handle.Owner == owner then
			handle.Cancelled = true
		end
	end
end

function Scheduler:_stepTimers(dt: number)
	local live = {}

	for _, handle in self._timers do
		if handle.Cancelled then
			continue
		end

		handle.Remaining -= dt
		if handle.Remaining <= 0 then
			local ok, err = pcall(handle.Fn)
			if not ok then
				warn(string.format("[Trellis] %s timer errored: %s", handle.Owner or "?", tostring(err)))
			end
			if handle.Repeating and not handle.Cancelled then
				-- Carry the overshoot so a repeating timer keeps its average period.
				handle.Remaining += handle.Period
				table.insert(live, handle)
			end
		else
			table.insert(live, handle)
		end
	end

	self._timers = live
end

function Scheduler:TimerCount(): number
	return #self._timers
end

local function driverOf(hz: any): Driver
	if hz == "Render" then
		return "Render"
	elseif hz == "Step" then
		return "Step"
	end
	return "Heart"
end

-- `hz` comes from BootOrder: a number (throttle), "Render"/"Step" (retarget), or
-- nil (every heartbeat).
function Scheduler:Add(name: string, module: any, hz: any)
	if type(module.Heartbeat) ~= "function" then
		error(
			string.format("[Trellis] %s declares Req \"Heart\" but defines no :Heartbeat", name),
			0
		)
	end

	local driver = driverOf(hz)
	if driver == "Render" and self._side ~= "Client" then
		error(
			string.format("[Trellis] %s: Hz = \"Render\" is client-only (this is the %s)", name, self._side),
			0
		)
	end

	local period = 0
	if type(hz) == "number" then
		if hz <= 0 then
			error(string.format("[Trellis] %s: Hz must be > 0, got %d", name, hz), 0)
		end
		period = 1 / hz
	end

	local list = self._tasks[driver]
	if not list then
		list = {}
		self._tasks[driver] = list
	end

	-- Stagger: start this task partway through its own period so it doesn't land on
	-- the same frame as everything else at the same rate.
	self._added += 1
	local phase = (self._added * PHI) % 1

	table.insert(list, {
		Name = name,
		Module = module,
		Driver = driver,
		Period = period,
		Accumulator = period * phase,
		Since = 0,
		Calls = 0,
	})
end

-- Called once per frame per driver by the single RunService connection.
function Scheduler:Step(driver: Driver, dt: number)
	if driver == "Heart" then
		self:_stepTimers(dt)
	end

	local list = self._tasks[driver]
	if not list then
		return
	end

	for _, task in list do
		if task.Period == 0 then
			task.Calls += 1
			local ok, err = pcall(task.Module.Heartbeat, task.Module, dt)
			if not ok then
				warn(string.format("[Trellis] %s:Heartbeat errored: %s", task.Name, tostring(err)))
			end
			continue
		end

		-- Two counters, because exact RATE and exact DT are different requirements.
		-- Accumulator schedules and carries its remainder, so the average rate is
		-- exact. Since measures wall time and is zeroed on every call, so each dt
		-- counts once and integration stays correct under irregular frames.
		task.Accumulator += dt
		task.Since += dt

		if task.Accumulator < task.Period then
			continue
		end

		task.Accumulator -= task.Period
		if task.Accumulator >= task.Period then
			-- A lag spike banked several periods. Fire once and drop the backlog
			-- rather than rapid-firing to catch up, which only deepens the spike.
			task.Accumulator %= task.Period
		end

		local elapsed = task.Since
		task.Since = 0
		task.Calls += 1

		local ok, err = pcall(task.Module.Heartbeat, task.Module, elapsed)
		if not ok then
			warn(string.format("[Trellis] %s:Heartbeat errored: %s", task.Name, tostring(err)))
		end
	end
end

-- A retired module must stop ticking, or a recalled Worker keeps running forever.
function Scheduler:Remove(name: string)
	for driver, list in self._tasks do
		for i = #list, 1, -1 do
			if list[i].Name == name then
				table.remove(list, i)
			end
		end
		local _ = driver
	end
	self:CancelOwned(name)
end

function Scheduler:Drivers(): { Driver }
	local names = {}
	for driver in self._tasks do
		table.insert(names, driver)
	end
	table.sort(names)
	return names
end

function Scheduler:Count(driver: Driver): number
	local list = self._tasks[driver]
	return if list then #list else 0
end

return Scheduler
