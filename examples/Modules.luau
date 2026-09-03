--!nonstrict
-- Example: one of each role, and every capability in use.
-- In a real game each of these is its own ModuleScript in the matching folder.

-- ================================= ServerScriptService/Server/Managers/... ===

local CombatManager = {}
CombatManager.Req = { "Heart", "Fence", "Trove" }

function CombatManager:Start(Src)
	-- The domain is always named: Src has no Domain field, so nothing is implicit.
	local Combat = Src:Network("Combat")

	Combat:Subscribe("Swing", function(payload, from)
		-- `from` is nil for internal traffic and a Player for a client's. The
		-- Schema already guaranteed the shape, and the Fence below already ran.
		if not from then
			return
		end
		Combat:PostAll("Hit", { Target = payload.Target, Combo = payload.Combo })
	end)

	self.Trove:Add(workspace.ChildAdded:Connect(function() end))
end

-- Runs on the RECEIVING side, before any handler. Many modules may fence one
-- Fence and all must pass. Usually the domain owner fences its own domain.
function CombatManager:Fence(event, payload, from)
	if not from then
		return true -- internal, trusted
	end
	return self:InRange(from, payload.Target), "range"
end

function CombatManager:Heartbeat(dt)
	-- dt is the ACCUMULATED time since this module's last call, so integration
	-- stays correct at the Hz BootOrder gave it.
end

function CombatManager:InRange()
	return true
end

local SessionManager = {}
SessionManager.Req = { "Player", "Timer" }

function SessionManager:Start(Src)
	Src:Network("Session"):Respond("Get", function(_, from)
		return Src:Reg("Session", from):Access("Stats")
	end)

	-- Bound to this module's lifetime: cancelled on :Stop, so it can never fire
	-- into a torn-down module.
	self:Every(30, function()
		Src:Network("Session"):PostAll("Sync", { at = os.time() })
	end)
end

-- Players who joined BEFORE this module booted are replayed through here, so a
-- late-booting module cannot miss them.
function SessionManager:PlayerAdded(player)
	local reg = self:Reg("Session", player)
	-- A persisted register may already hold this player's data, so seed defaults
	-- only where there is nothing. New on a hydrated key is (correctly) an error.
	if reg:Access("Stats.Health") == nil then
		reg:New("Stats.Health", 100)
	end
end

function SessionManager:PlayerRemoving(player)
	-- Nothing to do: the framework flushes and releases persisted registers.
end

-- ============================ StarterPlayerScripts/Client/Controllers/... ===

local HudController = {}

function HudController:Start(Src)
	self.Session = Src:Reg("Session") -- on the client, implicitly yours

	-- Bubble fires for descendants too, so one watcher covers the subtree.
	self.Session:Bubble("Stats", function(value, path, op)
		self:Refresh(path, value)
	end)

	Src:Network("Combat"):Subscribe("Hit", function(payload)
		self:Flash(payload.Combo)
	end)
end

-- No Req needed: :Ready costs nothing when absent, and runs once EVERY module on
-- this side has started.
function HudController:Ready()
	self:Refresh("Stats.Health", self.Session:Access("Stats.Health"))
end

function HudController:Refresh() end
function HudController:Flash() end

-- ============================================ a double-sided Service ========
-- Lives in a REPLICATED container. __Serve is a factory the CLIENT runs in its own
-- VM -- not a table the server sends -- so it must be self-contained, and the
-- server half's source is readable by exploiters. Keep secrets in a Manager.

local AnimationService = {}

function AnimationService:Start(Src) -- the SERVER half
	Src:Local("Animation"):Respond("Check", function(payload)
		return payload ~= nil
	end)
end

function AnimationService:__Serve() -- the CLIENT half
	local Client = {}

	function Client:Start(Src)
		Src:Local("Animation"):Subscribe("Play", function(payload)
			self:Play(payload)
		end)
	end

	function Client:Play() end

	return Client
end

return {
	CombatManager = CombatManager,
	SessionManager = SessionManager,
	HudController = HudController,
	AnimationService = AnimationService,
}
