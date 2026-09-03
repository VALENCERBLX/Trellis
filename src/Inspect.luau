--!nonstrict
-- Trellis
-- Inspect.luau
-- Valence
--
-- A framework that makes you declare the topology owes you a picture of it.
--
--   app:Inspect()            -- the snapshot, as data
--   print(Inspect.Render(s)) -- the same thing as text, for the console
--   Configure({ Panel = true }) -- a live on-screen panel (client, dev builds)
--
-- The snapshot answers the questions the declared design makes answerable:
-- every route and who listens to it, which events are fenced and by whom, what is
-- rate limited, which modules tick and how fast, and what the registers hold.

local Inspect = {}

local function count(t): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

-- ================================================================= the snapshot ===

function Inspect.Snapshot(runtime, modules, order): any
	local junction = runtime.Junction
	local registry = runtime.Registry
	local scheduler = runtime.Scheduler

	local snapshot = {
		Side = runtime.Side,
		Modules = {},
		Routes = {},
		Fences = {},
		Drivers = {},
		Registers = if runtime.Reg then runtime.Reg:Census() else {},
		Log = if runtime.Log then runtime.Log:Stats() else {},
		Bins = registry and registry:Bins() or {},
	}

	for _, name in order or {} do
		local entry = modules[name]
		local asked = {}
		for capability in entry.Asked or {} do
			table.insert(asked, capability)
		end
		table.sort(asked)

		table.insert(snapshot.Modules, {
			Name = name,
			Role = entry.Role,
			Req = asked,
			Hz = entry.Hz,
			Timers = entry.Src and entry.Src.Delay ~= nil,
		})
	end

	-- Every route, with the subscribers actually attached to it. A route with no
	-- listeners is usually a leftover; a route whose only listener is not its
	-- Destination never fires at all.
	for _, path in junction and junction:Paths() or {} do
		local entry = junction:Entry(path)
		local signal = junction:Signal(path)

		local listeners = {}
		for _, sub in (signal and signal.Handlers) or {} do
			table.insert(listeners, sub.Owner)
		end

		table.insert(snapshot.Routes, {
			Path = path,
			Kind = entry.Kind,
			Class = entry.Class,
			Destination = entry.Destination,
			Side = entry.Side,
			Schema = entry.Schema ~= nil,
			Listeners = listeners,
			Responder = signal ~= nil and signal.Responder ~= nil,
			Fences = junction:FencesFor(path),
		})
	end

	table.sort(snapshot.Routes, function(a, b)
		return a.Path < b.Path
	end)

	for name, paths in (junction and junction._fences) or {} do
		local spec = junction:FenceSpec(name)
		local fencers = {}
		for _, module in (junction._fencers[name] or {}) do
			table.insert(fencers, module.Name or "?")
		end
		table.insert(snapshot.Fences, {
			Name = name,
			Events = #paths,
			Rate = spec and spec.Rate,
			Per = spec and spec.Per,
			Fencers = fencers,
		})
	end

	table.sort(snapshot.Fences, function(a, b)
		return a.Name < b.Name
	end)

	for _, driver in (scheduler and scheduler:Drivers()) or {} do
		table.insert(snapshot.Drivers, { Driver = driver, Tasks = scheduler:Count(driver) })
	end

	snapshot.Timers = scheduler and scheduler:TimerCount() or 0

	return snapshot
end

-- ==================================================================== as text ===

local function pad(text: string, width: number): string
	text = tostring(text)
	if #text >= width then
		return text
	end
	return text .. string.rep(" ", width - #text)
end

function Inspect.Render(s): string
	local out = { string.format("[Trellis] %s", s.Side) }

	table.insert(out, "")
	table.insert(out, string.format("MODULES (%d)", #s.Modules))
	for _, m in s.Modules do
		table.insert(
			out,
			string.format(
				"  %s %s %s",
				pad(m.Name, 26),
				pad(m.Role, 11),
				if #m.Req > 0 then "Req " .. table.concat(m.Req, ",") else ""
			)
		)
	end

	table.insert(out, "")
	table.insert(out, string.format("ROUTES (%d)", #s.Routes))
	for _, r in s.Routes do
		local flags = {}
		if r.Schema then
			table.insert(flags, "schema")
		end
		if #r.Fences > 0 then
			table.insert(flags, "fenced:" .. table.concat(r.Fences, "/"))
		end
		if r.Destination then
			table.insert(flags, "->" .. r.Destination)
		end

		local who = if r.Kind == "Resolve"
			then (if r.Responder then "responder" else "NO RESPONDER")
			else (if #r.Listeners > 0 then table.concat(r.Listeners, ",") else "no listeners")

		table.insert(out, string.format("  %s %s %s", pad(r.Path, 40), pad(who, 30), table.concat(flags, " ")))
	end

	if #s.Fences > 0 then
		table.insert(out, "")
		table.insert(out, string.format("FENCES (%d)", #s.Fences))
		for _, f in s.Fences do
			table.insert(
				out,
				string.format(
					"  %s %d events  %s  by %s",
					pad(f.Name, 18),
					f.Events,
					if f.Rate then string.format("rate %d/%gs", f.Rate, f.Per) else "no rate",
					if #f.Fencers > 0 then table.concat(f.Fencers, ",") else "nobody"
				)
			)
		end
	end

	if #s.Drivers > 0 or s.Timers > 0 then
		table.insert(out, "")
		table.insert(out, "TICKING")
		for _, d in s.Drivers do
			table.insert(out, string.format("  %s %d modules", pad(d.Driver, 18), d.Tasks))
		end
		if s.Timers > 0 then
			table.insert(out, string.format("  %s %d live", pad("timers", 18), s.Timers))
		end
	end

	if #s.Registers > 0 then
		table.insert(out, "")
		table.insert(out, string.format("REGISTERS (%d)", #s.Registers))
		for _, r in s.Registers do
			table.insert(
				out,
				string.format(
					"  %s %s  %d values / %d cats%s%s",
					pad(r.Key, 26),
					pad(tostring(r.Replicate), 8),
					r.Values,
					r.Cats,
					if r.Persist then "  persist" else "",
					if r.Dirty then " (dirty)" else ""
				)
			)
		end
	end

	if #s.Log > 0 then
		table.insert(out, "")
		table.insert(out, "TRAFFIC")
		for i, row in s.Log do
			if i > 12 then
				break
			end
			table.insert(
				out,
				string.format(
					"  %s %6d  %5.1f/s%s",
					pad(row.Path, 40),
					row.Count,
					row.Rate,
					if row.Refused > 0 then string.format("  %d refused", row.Refused) else ""
				)
			)
		end
	end

	return table.concat(out, "\n")
end

-- =============================================================== the live panel ===

-- A dev-only overlay. Deliberately plain: monospace text in a scrolling frame,
-- refreshed on a timer, toggled with F4. It exists to be read, not admired.
function Inspect.Panel(app, runtime, opts)
	if runtime.Side ~= "Client" then
		return nil
	end

	local ok, gui = pcall(function()
		local Players = (opts and opts.Players) or game:GetService("Players")
		local UserInput = (opts and opts.UserInputService) or game:GetService("UserInputService")

		local screen = Instance.new("ScreenGui")
		screen.Name = "TrellisPanel"
		screen.ResetOnSpawn = false
		screen.IgnoreGuiInset = true
		screen.DisplayOrder = 10000
		screen.Enabled = false

		local frame = Instance.new("Frame")
		frame.Size = UDim2.new(0, 620, 1, -80)
		frame.Position = UDim2.new(0, 20, 0, 40)
		frame.BackgroundColor3 = Color3.fromRGB(12, 12, 16)
		frame.BackgroundTransparency = 0.08
		frame.BorderSizePixel = 0
		frame.Parent = screen

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = frame

		local scroll = Instance.new("ScrollingFrame")
		scroll.Size = UDim2.new(1, -16, 1, -16)
		scroll.Position = UDim2.new(0, 8, 0, 8)
		scroll.BackgroundTransparency = 1
		scroll.BorderSizePixel = 0
		scroll.ScrollBarThickness = 4
		scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
		scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
		scroll.Parent = frame

		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, 0, 0, 0)
		label.AutomaticSize = Enum.AutomaticSize.Y
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.Code
		label.TextSize = 12
		label.TextColor3 = Color3.fromRGB(214, 220, 230)
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Top
		label.Text = "..."
		label.Parent = scroll

		screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

		local function refresh()
			label.Text = Inspect.Render(app:Inspect())
		end

		UserInput.InputBegan:Connect(function(input, processed)
			if processed then
				return
			end
			if input.KeyCode == Enum.KeyCode.F4 then
				screen.Enabled = not screen.Enabled
				if screen.Enabled then
					refresh()
				end
			end
		end)

		return { Gui = screen, Refresh = refresh }
	end)

	if not ok then
		warn("[Trellis] panel could not be built: " .. tostring(gui))
		return nil
	end
	return gui
end

return Inspect
