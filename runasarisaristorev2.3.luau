-- Sari-Sari Store Auto Farm v3.1 | Rayfield | Plot-scoped
-- v3.1: thief detection now uses the game's real flags (SariShoplifter / SariCrook / SlapThief) and swings the Tsinelas
--       like the game does; open-store uses the prompt first, remote as fallback; delivery pickup waits for the whole
--       truck to unload, then grabs every box in ONE burst (single stand point). Live register-anchored HOME, teleport governor.
-- getgenv().SSAF_DEBUG = true BEFORE running to see decisions in the console.
if getgenv().SSAF_STOP then pcall(getgenv().SSAF_STOP) end

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local CS = game:GetService("CollectionService")
local lp = Players.LocalPlayer
local R = RS.SariSariStore.Remotes
local DC = require(RS.SariSariStore.Modules.DataConfig)

local S = {Grab=true, Checkout=true, KashG=true, Utang=true, Load=true, Clean=true, Restock=true,
    Pickup=true, Trash=true, Bill=true, Continue=true, Tasks=true, Buy=true, Slap=true, AntiAFK=true, Unstick=true,
    HideUI=true, SkipOut=true, Stay=true, Racks=true, AutoOpen=true, Thief=true, Beggar=true, BeggarAmt=20, BuyBelow=60, Buffer=1, StandTop=false, NeedsFirst=true,
    BuyMode="Smart", Delay=0.05, Pct=100, Reserve=1000,
    WaitStock=8, MaxItems=12, MaxBoxes=5, BuyPct=60, Reach=25, HomeRadius=12, RackPct=60, ShopReach=30}
local alive = true
local conns = {}
local stats = {served=0, change=0, kashOk=0, kashNo=0, loads=0, loadFail=0, utang=0, cleaned=0, restocked=0, picks=0,
    picked=0, trashed=0, claimed=0, bought=0, bills=0, continued=0, slapped=0, afk=0, hops=0, homes=0, racked=0,
    opened=0, caught=0, donated=0}
local X = {thiefNext=0, lastOpen=0, lastToggle=0, pickupBackoff=0, pickupAdded=0}

local nextBuyAt, nextChore, serveUntil = 0, 0, 0
local moveBusy = false
local wanted = {}
local demandNow = {}
local bad, fail = {}, {}
local HOME = nil
local pickLockUntil, pressBackoff, lastPress = 0, 0, 0

local function dbg(...) if getgenv().SSAF_DEBUG then print("[SSAF]", ...) end end
local function bind(sig, fn) conns[#conns+1] = sig:Connect(fn) end
local function digits(v) return tostring(v or ""):match("%d+") end

local REAL = digits(DC.KASHG_SCREEN_REAL)
local FAKE = digits(DC.KASHG_SCREEN_FAKE)

local name2id = {}
for _, p in pairs(DC.PRODUCTS) do
    name2id[(p.name:lower():gsub("[^%w]", ""))] = p.id
end

---------------------------------------------------------------- helpers
local plotCache
local function myPlot()
    if plotCache and plotCache.Parent and plotCache:GetAttribute("OwnerUserId") == lp.UserId then return plotCache end
    for _, p in ipairs(workspace.Plots:GetChildren()) do
        if p:GetAttribute("OwnerUserId") == lp.UserId then plotCache = p return p end
    end
end

local function myHRP()
    local ch = lp.Character
    return ch and ch:FindFirstChild("HumanoidRootPart")
end

local function money()
    local ls = lp:FindFirstChild("leaderstats")
    local p = ls and ls:FindFirstChild("Pesos")
    return p and p.Value or 0
end

local function posOf(inst)
    if typeof(inst) == "Vector3" then return inst end
    if typeof(inst) ~= "Instance" then return nil end
    if inst:IsA("BasePart") then return inst.Position end
    if inst:IsA("Attachment") then return inst.WorldPosition end
    local ok, pos = pcall(function() return inst:GetPivot().Position end)
    return ok and pos or nil
end

local function promptPos(pr) return pr.Parent and posOf(pr.Parent) or nil end

local function counterPos(plot)
    return plot and posOf(plot:FindFirstChild("CashRegister"))
end

local function hiddenUp(plot, x)
    while x and x ~= plot do
        if x:GetAttribute("Hidden") == true then return true end
        x = x.Parent
    end
    return false
end

local function inactive(plot, m)
    if hiddenUp(plot, m) then return true end
    if m:GetAttribute("Locked") == true then return true end
    for _, d in ipairs(m:GetDescendants()) do
        if d:IsA("BasePart") and d:GetAttribute("RemodelHidden") == true then return true end
    end
    return false
end

local shelfCache, rackCache, scanT = {}, {}, 0
local function scan(plot)
    if tick() - scanT < 6 then return end
    scanT = tick()
    table.clear(shelfCache)
    table.clear(rackCache)
    for _, m in ipairs(plot:GetDescendants()) do
        if m:IsA("Model") then
            if m:GetAttribute("ShelfId") and not inactive(plot, m) then shelfCache[#shelfCache+1] = m end
        elseif m:IsA("ProximityPrompt") and m.Name == "BoxPrompt" then
            if not hiddenUp(plot, m) then rackCache[#rackCache+1] = m end
        end
    end
end
local function shelves(plot) scan(plot) return shelfCache end
local function racks(plot) scan(plot) return rackCache end

local function stockFor(plot, id, ref, ignoreBad)
    local best, bd
    for _, m in ipairs(shelves(plot)) do
        if m.Parent and m:GetAttribute("ProductId") == id and (m:GetAttribute("Stock") or 0) > 0
            and (ignoreBad or not (bad[m] and tick() - bad[m] < 5)) then
            local p = posOf(m)
            local d = (ref and p) and (p - ref).Magnitude or 0
            if not bd or d < bd then best, bd = m, d end
        end
    end
    return best
end

local function getRows(c)
    local rows = {}
    local od = c:FindFirstChild("Head") and c.Head:FindFirstChild("OrderDialogue")
    if not od then return rows end
    for _, t in ipairs(od:GetDescendants()) do
        if t:IsA("TextLabel") then
            local q, n, h, w = t.Text:match("^(%d+)x%s+(.-)%s*%((%d+)/(%d+)%)$")
            if q then
                rows[#rows+1] = {id=name2id[(n:lower():gsub("[^%w]", ""))], have=tonumber(h), need=tonumber(w)}
            end
        end
    end
    return rows
end

local function orderCustomer(plot)
    local reg = counterPos(plot)
    if not reg then return end
    local best, bd, brows, bscore
    for _, c in ipairs(workspace:GetChildren()) do
        if c:IsA("Model") and c:GetAttribute("SukiOwnerId") == lp.UserId and c:FindFirstChild("HumanoidRootPart") then
            local d = (c.HumanoidRootPart.Position - reg).Magnitude
            local atCounter = c:GetAttribute("BubbleOn") == true or d <= 12
            if atCounter then
                local rows = getRows(c)
                if #rows > 0 then
                    local score = (c:GetAttribute("BubbleOn") == true) and 0 or 1
                    if not bscore or score < bscore or (score == bscore and d < bd) then
                        best, bd, brows, bscore = c, d, rows, score
                    end
                end
            end
        end
    end
    return best, brows, bd
end

---------------------------------------------------------------- movement helpers (shared)
local function failed(k) return fail[k] and tick() - fail[k] < 10 end

local function holdingTool()
    local ch = lp.Character
    return ch and ch:FindFirstChildOfClass("Tool")
end

local function ensureFree()
    if not holdingTool() then return end
    local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
    if hum then hum:UnequipTools() end
    local t = tick()
    while holdingTool() and tick() - t < 0.5 do task.wait(0.03) end
end

local function equip(tool)
    local char = lp.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum or not tool or not tool.Parent then return false end
    if tool.Parent ~= char then hum:EquipTool(tool) end
    local t = tick()
    while tool.Parent ~= char and tick() - t < 1 do task.wait(0.05) end
    return tool.Parent == char
end

local function getTool(name)
    return lp.Backpack:FindFirstChild(name) or (lp.Character and lp.Character:FindFirstChild(name))
end

local function toolsWhere(pred)
    local out = {}
    for _, holder in ipairs({lp.Backpack, lp.Character}) do
        if holder then
            for _, t in ipairs(holder:GetChildren()) do
                if t:IsA("Tool") and pred(t) then out[#out+1] = t end
            end
        end
    end
    return out
end

local function collectBoxes()
    return toolsWhere(function(t) return t:GetAttribute("IsRestockBox") and (t:GetAttribute("Count") or 0) > 0 end)
end

local function handUnits(pid)
    local n = 0
    for _, t in ipairs(toolsWhere(function(t) return t:GetAttribute("IsRestockBox") and t:GetAttribute("ProductId") == pid end)) do
        n = n + (t:GetAttribute("Count") or 0)
    end
    return n
end

local function rackUnits(plot, pid)
    local n = 0
    for _, pr in ipairs(racks(plot)) do
        local p = pr.Parent
        if p and p:GetAttribute("Occupied") == true and p:GetAttribute("ProductId") == pid then
            n = n + (p:GetAttribute("Count") or 0)
        end
    end
    return n
end
local function ownedUnits(plot, pid) return handUnits(pid) + rackUnits(plot, pid) end

-- THE ONLY place that teleports the character. Rate limited so nothing can ever spam-teleport.
local tpLog, lastTp = {}, 0
local function tp(cf)
    local hrp = myHRP()
    if not hrp then return false end
    local now = tick()
    while #tpLog > 0 and now - tpLog[1] > 3 do table.remove(tpLog, 1) end
    if #tpLog >= 10 then
        -- throttle instead of failing: wait until the oldest teleport leaves the 3s window
        task.wait(math.max(0.05, tpLog[1] + 3 - now))
        hrp = myHRP()
        if not hrp then return false end
        now = tick()
        while #tpLog > 0 and now - tpLog[1] > 3 do table.remove(tpLog, 1) end
    end
    if now - lastTp < 0.12 then task.wait(0.12 - (now - lastTp)) end
    lastTp = tick()
    tpLog[#tpLog+1] = lastTp
    hrp.CFrame = cf
    hrp.AssemblyLinearVelocity = Vector3.zero
    stats.hops = stats.hops + 1
    return true
end

local function standAt(hrp, pos)
    return tp(CFrame.new(pos + Vector3.new(0, 3, 0)))
end

local baseWalk = 16
pcall(function() baseWalk = lp.Character:FindFirstChildOfClass("Humanoid").WalkSpeed end)
local function settle()
    local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
    local hrp = myHRP()
    if hrp then hrp.AssemblyLinearVelocity = Vector3.zero end
    if hum then
        hum.PlatformStand = false
        hum.Sit = false
        if hum:GetState() == Enum.HumanoidStateType.Climbing then hum:ChangeState(Enum.HumanoidStateType.Freefall) end
        if hum.WalkSpeed <= 0 then hum.WalkSpeed = baseWalk end
    end
end

local function stream(pos)
    if not pos then return end
    task.spawn(function() pcall(function() lp:RequestStreamAroundAsync(pos, 0.4) end) end)
end

---------------------------------------------------------------- HOME = LIVE position next to / on top of the CashRegister
local homeOffset = getgenv().SSAF_HOMEOFF
local function ensureHome(plot)
    local reg = plot and plot:FindFirstChild("CashRegister")
    if not reg then return end
    if not reg:IsA("BasePart") then
        local rp = posOf(reg)
        if rp then HOME = CFrame.new(rp + Vector3.new(0, 3, 3)) end
        return
    end
    local topOff = CFrame.new(0, reg.Size.Y / 2 + 3, 0)
    if S.StandTop then
        HOME = reg.CFrame * topOff
        return
    end
    if typeof(homeOffset) ~= "CFrame" then
        local hrp = myHRP()
        if hrp and (hrp.Position - reg.Position).Magnitude <= 14 then
            homeOffset = reg.CFrame:ToObjectSpace(hrp.CFrame)
        else
            homeOffset = topOff
        end
        getgenv().SSAF_HOMEOFF = homeOffset
    end
    HOME = reg.CFrame * homeOffset
end

local function setHome()
    local plot = myPlot()
    local reg = plot and plot:FindFirstChild("CashRegister")
    local hrp = myHRP()
    if reg and reg:IsA("BasePart") and hrp then
        homeOffset = reg.CFrame:ToObjectSpace(hrp.CFrame)
        getgenv().SSAF_HOMEOFF = homeOffset
        S.StandTop = false
        ensureHome(plot)
    end
end

local function goHome(force)
    local hrp = myHRP()
    if not hrp or not HOME then return false end
    if not force and (hrp.Position - HOME.Position).Magnitude <= S.HomeRadius then return false end
    stream(HOME.Position)
    if tp(HOME) then
        stats.homes = stats.homes + 1
        return true
    end
    return false
end

local function approach(pos, reach)
    local hrp = myHRP()
    if not hrp or not pos then return false end
    if (hrp.Position - pos).Magnitude <= reach then return false end
    local stand = pos
    if HOME then
        local dir = HOME.Position - pos
        if dir.Magnitude > 1 then
            stand = pos + dir.Unit * math.min(reach * 0.6, dir.Magnitude)
        end
        stand = Vector3.new(stand.X, HOME.Position.Y, stand.Z)
    else
        stand = pos + Vector3.new(0, 3, 0)
    end
    stream(stand)
    tp(CFrame.new(stand))
    task.wait(0.1)
    return true
end

local function nearPrompt(pr, tight)
    local pos = promptPos(pr)
    if not pos then return false end
    local maxd = pr.MaxActivationDistance or 10
    local reach = tight and 4 or math.max(4, math.min(maxd - 6, S.Reach))
    if reach <= 8 then
        local hrp = myHRP()
        if not hrp then return false end
        if (hrp.Position - pos).Magnitude <= reach then return false end
        stream(pos)
        standAt(hrp, pos)
        task.wait(0.1)
        return true
    end
    return approach(pos, reach)
end

local function withMove(fn, ...)
    if moveBusy then return false end
    moveBusy = true
    local ok, res = pcall(fn, ...)
    if S.Stay then
        pcall(function() if goHome() then settle() end end)
    end
    moveBusy = false
    if not ok then dbg("error:", res) return false end
    return res
end

---------------------------------------------------------------- shop deliveries (TruckBay)
local pickups, trackedPlot = {}, nil
local function trackPickups(plot)
    if trackedPlot == plot then return end
    trackedPlot = plot
    for _, d in ipairs(plot:GetDescendants()) do
        if d:IsA("ProximityPrompt") and d.Name == "PickupPrompt" then pickups[d] = {t=tick(), n=0} end
    end
    bind(plot.DescendantAdded, function(d)
        if d:IsA("ProximityPrompt") and d.Name == "PickupPrompt" then
            pickups[d] = {t=tick(), n=0}
            X.pickupBackoff = 0
            X.pickupAdded = tick()
        end
    end)
end

local function alivePrompt(d) return d.Parent and d:IsDescendantOf(workspace) end

local function hasPickup()
    if tick() < X.pickupBackoff then return false end
    for d, e in pairs(pickups) do
        if not alivePrompt(d) then
            pickups[d] = nil
        elseif tick() - e.t < 25 and e.n < 4 then
            return true
        end
    end
    return false
end

local function abortChore()
    return tick() < serveUntil or (S.Pickup and hasPickup())
end

---------------------------------------------------------------- register
local function pressRegister(plot)
    if tick() < pressBackoff or tick() - lastPress < 0.4 then return end
    lastPress = tick()
    local reg = plot and plot:FindFirstChild("CashRegister")
    if reg then R.RegisterPress:FireServer(reg) end
end

bind(R.ShowWarning.OnClientEvent, function(msg)
    if typeof(msg) ~= "string" then return end
    if msg:find("No customer at the register", 1, true) then
        pressBackoff = tick() + 1.5
    elseif msg:find("No customer is asking for this", 1, true) then
        pickLockUntil = tick() + 0.8
    end
end)

---------------------------------------------------------------- hide the game's popups
local function gameConns(remote, scriptName)
    local out = {}
    local ok, list = pcall(getconnections, remote.OnClientEvent)
    if not ok then return out end
    for _, c in ipairs(list) do
        local ok2, src = pcall(function() return debug.info(c.Function, "s") end)
        if ok2 and typeof(src) == "string" and src:find(scriptName, 1, true) then out[#out+1] = c end
    end
    return out
end

local function suppress(remote, scriptName, on)
    for _, c in ipairs(gameConns(remote, scriptName)) do
        pcall(function() if on then c:Disable() else c:Enable() end end)
    end
end

local function applyUI()
    suppress(R.KashGAsk, "KashGClient", S.HideUI and S.KashG)
    suppress(R.CheckoutData, "RegisterClient", S.HideUI and S.Checkout)
    suppress(R.UtangAsk, "UtangClient", S.HideUI and S.Utang)
end

local pg = lp:WaitForChild("PlayerGui")
for gui, flag in pairs({KashGGui="KashG", UtangGui="Utang", CashierGui="Checkout", BeggarGui="Beggar"}) do
    local g = pg:FindFirstChild(gui)
    if g then
        bind(g:GetPropertyChangedSignal("Enabled"), function()
            if g.Enabled and S.HideUI and S[flag] then g.Enabled = false end
        end)
    end
end

---------------------------------------------------------------- demand
local lastDemand = 0
local function scanDemand(plot)
    local ids = {}
    for _, c in ipairs(workspace:GetChildren()) do
        if c:IsA("Model") and c:GetAttribute("SukiOwnerId") == lp.UserId then
            local need = c:GetAttribute("OrderNeed")
            if typeof(need) == "string" then
                for id in need:gmatch("[^,]+") do ids[id] = true end
            end
        end
    end
    demandNow = ids
    local ref = HOME and HOME.Position
    for id in pairs(ids) do
        if DC.getProduct(id) and not stockFor(plot, id, ref, true) then
            if not (wanted[id] and tick() - wanted[id] < 60) and ownedUnits(plot, id) <= 0 then
                nextBuyAt = math.min(nextBuyAt, tick() + 0.5)
            end
            wanted[id] = tick()
        end
    end
end

---------------------------------------------------------------- grab + register loop
local function pickShelf(shelf, tight)
    local pr = shelf:FindFirstChild("PickPrompt", true)
    if not pr then
        local piv = posOf(shelf)
        if piv then
            approach(piv, 12)
            local t = tick()
            repeat
                task.wait(0.05)
                pr = shelf:FindFirstChild("PickPrompt", true)
            until pr or tick() - t > 0.8
        end
    end
    if pr then
        nearPrompt(pr, tight)
        local pp, hh = promptPos(pr), myHRP()
        if pp and hh and (hh.Position - pp).Magnitude > (pr.MaxActivationDistance or 10) - 3 then
            dbg("too far to pick", shelf.Name)
            return false
        end
        fireproximityprompt(pr)
    else
        R.ShelfActivate:FireServer(shelf, "pick")
    end
end

local pend, holdMiss, settleUntil, lastStay = {}, {}, 0, 0
local function step()
    local plot = myPlot()
    if not plot then return end
    ensureHome(plot)
    local c, rows, regDist = orderCustomer(plot)
    if not c then
        if S.Stay and tick() - lastStay > 2 then
            lastStay = tick()
            stream(HOME and HOME.Position or counterPos(plot))
        end
        return
    end
    local hrp = myHRP()
    if not hrp then return end
    local ref = HOME and HOME.Position or hrp.Position

    local plan, missIds, missing = {}, {}, false
    for _, r in ipairs(rows) do
        if r.have < r.need then
            local shelf = r.id and (stockFor(plot, r.id, ref) or stockFor(plot, r.id, ref, true))
            if shelf then
                plan[#plan+1] = {r=r, shelf=shelf}
            else
                missing = true
                if r.id then
                    missIds[#missIds+1] = r.id
                    if not (wanted[r.id] and tick() - wanted[r.id] < 60) and ownedUnits(plot, r.id) <= 0 then
                        nextBuyAt = math.min(nextBuyAt, tick() + 0.5)
                    end
                    wanted[r.id] = tick()
                end
            end
        end
    end
    if #plan > 0 then serveUntil = tick() + 1.5 end
    if moveBusy or tick() < settleUntil then return end

    local function act()
        local fired = false
        if S.Grab and #plan > 0 and tick() >= pickLockUntil then
            ensureFree()
            for _, it in ipairs(plan) do
                local r, shelf = it.r, it.shelf
                if not (alive and shelf.Parent) then break end
                local key = c.Name .. "|" .. tostring(r.id)
                local p = pend[key]
                if p and p.have ~= r.have then p = nil pend[key] = nil end
                local waiting = p and tick() - p.t < 0.9
                if not waiting then
                    local tries = p and (p.tries + 1) or 0
                    if tries >= 4 then
                        bad[shelf] = tick()
                        pend[key] = nil
                        dbg("pick had no effect on", shelf.Name)
                    else
                        pend[key] = {have=r.have, t=tick(), tries=tries}
                        local n = math.min(r.need - r.have, 12)
                        for _ = 1, n do
                            if not alive or tick() < pickLockUntil then break end
                            pickShelf(shelf, tries >= 2)
                            stats.picks = stats.picks + 1
                            fired = true
                            task.wait(math.max(S.Delay, 0.06))
                        end
                    end
                end
            end
            if fired then settleUntil = tick() + 0.4 end
        end

        local hold = false
        if missing then
            local first = holdMiss[c.Name]
            if not first then first = tick() holdMiss[c.Name] = first end
            local haveBox = false
            for _, id in ipairs(missIds) do
                if ownedUnits(plot, id) > 0 then haveBox = true break end
            end
            hold = haveBox and tick() - first < S.WaitStock
        else
            holdMiss[c.Name] = nil
        end

        if S.Checkout and #plan == 0 and not hold and (not missing or S.SkipOut) and regDist and regDist <= 12 then
            local hr, rp = myHRP(), counterPos(plot)
            if hr and rp and (hr.Position - rp).Magnitude > 30 then goHome(true) end
            pressRegister(plot)
            serveUntil = tick() + 0.8
        end
    end
    withMove(act)
end

task.spawn(function()
    while alive do
        task.wait(S.Delay)
        if S.Grab or S.Checkout then pcall(step) end
    end
end)

bind(R.OrderStatus.OnClientEvent, function(d)
    if typeof(d) == "table" and d.fulfilled == true then
        table.clear(pend)
        table.clear(holdMiss)
        pickLockUntil = tick() + 0.7
        if S.Checkout then
            task.spawn(function()
                local plot = myPlot()
                pressRegister(plot)
            end)
        end
    end
end)

---------------------------------------------------------------- exact change (no UI)
bind(R.CheckoutData.OnClientEvent, function(d)
    if S.Checkout and typeof(d) == "table" and typeof(d.change) == "number" then
        stats.change = stats.change + d.change
        R.SubmitChange:FireServer(d.change)
        dbg("change", d.change, "for", d.customerName)
    end
end)
bind(R.CheckoutResult.OnClientEvent, function(ok)
    if ok then stats.served = stats.served + 1 end
end)

---------------------------------------------------------------- KashG
bind(R.KashGAsk.OnClientEvent, function(d)
    if not S.KashG or typeof(d) ~= "table" then return end
    local img = digits(d.image)
    local accept = (img == REAL)
    R.KashGDecide:FireServer(accept)
    if accept then stats.kashOk = stats.kashOk + 1 else stats.kashNo = stats.kashNo + 1 end
    dbg("KashG", d.name, d.total, img, accept and "ACCEPT" or "DECLINE", (img ~= REAL and img ~= FAKE) and "(unknown screen)" or "")
    local g = pg:FindFirstChild("KashGGui")
    if g and S.HideUI then task.defer(function() g.Enabled = false end) end
end)

---------------------------------------------------------------- Utang
bind(R.UtangAsk.OnClientEvent, function(d)
    if S.Utang and typeof(d) == "table" then
        R.UtangDecide:FireServer(true)
        stats.utang = stats.utang + 1
    end
end)

---------------------------------------------------------------- E-Load
local loadBusy = false
bind(R.PhoneLoadResult.OnClientEvent, function(ok, msg)
    loadBusy = false
    if ok then stats.loads = stats.loads + 1 else stats.loadFail = stats.loadFail + 1 end
    dbg("LoadResult", ok, msg)
end)

task.spawn(function()
    while alive do
        task.wait(0.25)
        if not S.Load or loadBusy then continue end
        local ok, info = pcall(function() return R.GetPhoneLoadInfo:InvokeServer() end)
        if ok and typeof(info) == "table" and typeof(info.cellphone) == "string" and info.amount ~= nil then
            loadBusy = true
            dbg("Load request", info.cellphone, info.amount)
            pcall(function()
                R.PhoneLoadFocus:FireServer(true)
                R.PhoneLoadProgress:FireServer(info.cellphone, info.amount)
                R.PhoneLoadSubmit:FireServer({cellphone=info.cellphone, amount=info.amount})
            end)
            local t = tick()
            while loadBusy and alive and tick() - t < 2 do task.wait(0.05) end
            loadBusy = false
            pcall(function() R.PhoneLoadFocus:FireServer(false) end)
        end
    end
end)

---------------------------------------------------------------- popups
local function press(btn)
    pcall(function() firesignal(btn.Activated) end)
    pcall(function() firesignal(btn.MouseButton1Click) end)
end

task.spawn(function()
    local lastDS, lastEB = 0, 0
    while alive do
        task.wait(0.4)
        pcall(function()
            local ds = pg:FindFirstChild("DaySummaryGui")
            if S.Continue and ds and ds.Enabled and tick() - lastDS > 2 then
                lastDS = tick()
                local b = ds:FindFirstChild("ContinueButton", true)
                if b then
                    task.wait(0.8)
                    press(b)
                    stats.continued = stats.continued + 1
                    dbg("Day summary: Continue")
                end
            end
            local eb = pg:FindFirstChild("ElectricityBillGui")
            if S.Bill and eb and eb.Enabled and tick() - lastEB > 3 then
                lastEB = tick()
                local b = eb:FindFirstChild("PayButton", true)
                if b then press(b) end
                task.wait(0.8)
                if eb.Enabled then R.ElectricityChoice:FireServer("pay") end
                stats.bills = stats.bills + 1
                dbg("Electric bill: PAY NOW")
            end
        end)
    end
end)

---------------------------------------------------------------- daily tasks
task.spawn(function()
    while alive do
        if S.Tasks then
            pcall(function()
                local res = R.GetDailyTasks:InvokeServer()
                if typeof(res) == "table" and typeof(res.tasks) == "table" then
                    for _, t in ipairs(res.tasks) do
                        if t.done and not t.claimed then
                            R.ClaimTask:FireServer(t.kind)
                            stats.claimed = stats.claimed + 1
                            dbg("Claimed daily task", t.kind, t.peso)
                            task.wait(0.5)
                        end
                    end
                end
            end)
        end
        for _ = 1, 20 do if not alive then break end task.wait(1) end
    end
end)

---------------------------------------------------------------- FAST delivery pickup
-- Waits (max ~0.9s) until the truck has finished unloading, then stands ONCE at the centre of all boxes and fires every
-- prompt in one burst. Anything left behind triggers a short backoff instead of teleport ping-pong.
local function pickupPass()
    local t0 = tick()
    while tick() - X.pickupAdded < 0.22 and tick() - t0 < 0.9 do task.wait(0.03) end
    local live = {}
    for d, e in pairs(pickups) do
        if alivePrompt(d) and tick() - e.t < 25 and e.n < 4 then live[#live+1] = d end
    end
    if #live == 0 then return false end
    ensureFree()
    for _ = 1, 8 do
        local pts = {}
        for _, d in ipairs(live) do
            if alivePrompt(d) then
                local p = promptPos(d)
                if p then pts[#pts+1] = {d=d, p=p} end
            end
        end
        if #pts == 0 then break end
        local sum = Vector3.zero
        for _, e in ipairs(pts) do sum = sum + e.p end
        local c = sum / #pts
        local spread = 0
        for _, e in ipairs(pts) do spread = math.max(spread, (e.p - c).Magnitude) end
        local hrp = myHRP()
        if not hrp then break end
        if spread <= 9 then
            if (hrp.Position - c).Magnitude > 4 then
                stream(c)
                standAt(hrp, c)
                task.wait(0.08)
            end
            for _, e in ipairs(pts) do
                pcall(function() e.d.HoldDuration = 0 end)
                fireproximityprompt(e.d)
            end
        else
            table.sort(pts, function(a, b)
                return (a.p - hrp.Position).Magnitude < (b.p - hrp.Position).Magnitude
            end)
            for _, e in ipairs(pts) do
                hrp = myHRP()
                if not hrp then break end
                if (hrp.Position - e.p).Magnitude > 8 then
                    stream(e.p)
                    standAt(hrp, e.p)
                    task.wait(0.08)
                end
                pcall(function() e.d.HoldDuration = 0 end)
                fireproximityprompt(e.d)
            end
        end
        local left, t = 1, tick()
        repeat
            task.wait(0.05)
            left = 0
            for _, e in ipairs(pts) do if alivePrompt(e.d) then left = left + 1 end end
        until left == 0 or tick() - t > 0.45
        if left == 0 then break end
    end
    local did, remaining = false, 0
    for _, d in ipairs(live) do
        if alivePrompt(d) then
            remaining = remaining + 1
            if pickups[d] then pickups[d].n = pickups[d].n + 1 end
        else
            stats.picked = stats.picked + 1
            did = true
            pickups[d] = nil
        end
    end
    if did then
        nextBuyAt = math.min(nextBuyAt, tick() + 1)
        nextChore = 0
        dbg("Picked up delivery:", #live - remaining, "boxes")
    end
    if remaining > 0 then X.pickupBackoff = tick() + 2.5 end
    return did
end

---------------------------------------------------------------- trash
bind(R.TrashConfirm.OnClientEvent, function()
    if not S.Trash then return end
    task.delay(0.25, function()
        local g = pg:FindFirstChild("TrashConfirmGui")
        local b = g and g:FindFirstChild("ThrowButton", true)
        if b then press(b) end
    end)
end)

local trashCache
local function trashPrompt(plot)
    if trashCache and trashCache.Parent then return trashCache end
    local ref = HOME and HOME.Position
    local best, bd
    for _, d in ipairs(plot:GetDescendants()) do
        if d:IsA("ProximityPrompt") and d.Name == "TrashPrompt" then
            local p = promptPos(d)
            local dist = (ref and p) and (p - ref).Magnitude or 0
            if not bd or dist < bd then best, bd = d, dist end
        end
    end
    trashCache = best
    return best
end

local function trashPass(plot)
    local pr = trashPrompt(plot)
    local hrp = myHRP()
    if not pr or not hrp then return false end
    local function empties() return toolsWhere(function(t) return t:GetAttribute("IsEmptyBox") end) end
    if #empties() == 0 then return false end
    local did = false
    nearPrompt(pr)
    for _ = 1, 40 do
        if not (alive and S.Trash) or abortChore() then break end
        local box = empties()[1]
        if not box then break end
        if not equip(box) then break end
        nearPrompt(pr)
        fireproximityprompt(pr)
        local t = tick()
        while box.Parent and tick() - t < 2 do task.wait(0.05) end
        if not box.Parent then
            stats.trashed = stats.trashed + 1
            did = true
        else
            dbg("trash did not take", box.Name)
            break
        end
    end
    return did
end

---------------------------------------------------------------- smart restock
local function targetShelf(plot, box, pid, ref)
    local prod = DC.getProduct(pid)
    local cat = box:GetAttribute("ShelfCategory") or (prod and prod.category) or "general"
    local exclusive = DC.isExclusiveBox and DC.isExclusiveBox(pid)
    local claimed, mine, empties = 0, {}, {}
    for _, m in ipairs(shelves(plot)) do
        if (m:GetAttribute("Category") or "general") == cat then
            local sp = m:GetAttribute("ProductId") or ""
            local stock = m:GetAttribute("Stock") or 0
            local cap = m:GetAttribute("Capacity") or 0
            local usable = cap > 0 and not failed(m)
            if sp == pid then
                claimed = claimed + 1
                if usable and stock < cap and stock <= cap * (S.Pct / 100) then mine[#mine+1] = m end
            elseif usable and (sp == "" or (stock <= 0 and not exclusive)) then
                empties[#empties+1] = m
            end
        end
    end
    local function nearest(list)
        local best, bd
        for _, m in ipairs(list) do
            local p = posOf(m)
            local d = (p and ref) and (p - ref).Magnitude or 0
            if not bd or d < bd then best, bd = m, d end
        end
        return best
    end
    if #mine > 0 then
        table.sort(mine, function(a, b) return (a:GetAttribute("Stock") or 0) < (b:GetAttribute("Stock") or 0) end)
        return mine[1]
    end
    if claimed < (cat == "rice" and 1 or 2) and #empties > 0 then
        local clean = {}
        for _, m in ipairs(empties) do if (m:GetAttribute("ProductId") or "") == "" then clean[#clean+1] = m end end
        return nearest(#clean > 0 and clean or empties)
    end
end

local function urgency(plot, pid)
    local worst
    for _, m in ipairs(shelves(plot)) do
        if m:GetAttribute("ProductId") == pid then
            local cap = m:GetAttribute("Capacity") or 0
            if cap > 0 then
                local r = (m:GetAttribute("Stock") or 0) / cap
                if not worst or r < worst then worst = r end
            end
        end
    end
    return worst or -1
end

local function needUnits(plot, pid)
    local need, hasShelf = 0, false
    for _, m in ipairs(shelves(plot)) do
        if m:GetAttribute("ProductId") == pid then
            hasShelf = true
            need = need + math.max((m:GetAttribute("Capacity") or 0) - (m:GetAttribute("Stock") or 0), 0)
        end
    end
    if not hasShelf then
        local prod = DC.getProduct(pid)
        need = (prod and prod.shelfCap) or 8
    end
    return need
end

local function takeFromRack(plot, pid)
    local hrp = myHRP()
    if not hrp then return false end
    local list = {}
    for _, pr in ipairs(racks(plot)) do
        local p = pr.Parent
        if p and p:GetAttribute("Occupied") == true and p:GetAttribute("ProductId") == pid
            and (p:GetAttribute("Count") or 0) > 0 and not failed(pr) then
            list[#list+1] = pr
        end
    end
    if #list == 0 then return false end
    local ref = HOME and HOME.Position or hrp.Position
    table.sort(list, function(a, b)
        local pa, pb = promptPos(a), promptPos(b)
        return (pa and (pa - ref).Magnitude or 1e9) < (pb and (pb - ref).Magnitude or 1e9)
    end)
    local pr = list[1]
    local part = pr.Parent
    ensureFree()
    nearPrompt(pr)
    local before = part:GetAttribute("Count") or 0
    fireproximityprompt(pr)
    local t = tick()
    while tick() - t < 1.3 and part:GetAttribute("Occupied") == true and (part:GetAttribute("Count") or 0) >= before do
        task.wait(0.05)
    end
    if part:GetAttribute("Occupied") ~= true or (part:GetAttribute("Count") or 0) < before then
        stats.racked = stats.racked + 1
        dbg("Took a box from the rack:", pid)
        return true
    end
    fail[pr] = tick() + 20
    dbg("Rack take failed", pid)
    return false
end

local dummyBox = {GetAttribute = function() return nil end}
local function rackPass(plot)
    if not S.Racks then return false end
    local want = {}
    for _, m in ipairs(shelves(plot)) do
        local id, cap = m:GetAttribute("ProductId"), m:GetAttribute("Capacity") or 0
        if id and id ~= "" and cap > 0 then
            local ratio = (m:GetAttribute("Stock") or 0) / cap
            if ratio <= S.RackPct / 100 then want[id] = math.min(want[id] or 9, ratio) end
        end
    end
    for id in pairs(demandNow) do want[id] = -1 end
    for id, t in pairs(wanted) do if tick() - t < 30 then want[id] = -1 end end
    local order = {}
    for id, r in pairs(want) do order[#order+1] = {id=id, r=r} end
    table.sort(order, function(a, b) return a.r < b.r end)
    local did, handled = false, 0
    for _, o in ipairs(order) do
        if handled >= 5 or not alive or not S.Restock or abortChore() then break end
        local id = o.id
        if DC.getProduct(id) and rackUnits(plot, id) > 0 then
            local ref = HOME and HOME.Position
            if targetShelf(plot, dummyBox, id, ref) then
                handled = handled + 1
                local taken = 0
                while taken < 3 and alive and not abortChore() and handUnits(id) < needUnits(plot, id)
                    and rackUnits(plot, id) > 0 do
                    if not takeFromRack(plot, id) then break end
                    taken = taken + 1
                    did = true
                end
            end
        end
    end
    return did
end

local function restockPass(plot)
    local hrp = myHRP()
    if not hrp then return false end
    local did = rackPass(plot)
    local boxes = collectBoxes()
    if #boxes == 0 then return did end
    local rank = {}
    for _, b in ipairs(boxes) do
        local pid = b:GetAttribute("ProductId")
        local r = urgency(plot, pid)
        if demandNow[pid] then r = r - 3 end
        if wanted[pid] and tick() - wanted[pid] < 30 then r = r - 2 end
        rank[b] = r
    end
    table.sort(boxes, function(a, b) return rank[a] < rank[b] end)
    for _, box in ipairs(boxes) do
        local pid = box:GetAttribute("ProductId")
        for _ = 1, 30 do
            if not alive or not S.Restock or abortChore() then break end
            if not box.Parent or (box:GetAttribute("Count") or 0) <= 0 then break end
            hrp = myHRP()
            if not hrp then break end
            local ref = HOME and HOME.Position or hrp.Position
            local shelf = targetShelf(plot, box, pid, ref)
            if not shelf then break end
            local pr = shelf:FindFirstChild("RestockPrompt", true)
            if not pr then
                local piv = posOf(shelf)
                if piv then approach(piv, 12) end
                local t = tick()
                repeat
                    task.wait(0.05)
                    pr = shelf:FindFirstChild("RestockPrompt", true)
                until pr or tick() - t > 0.8
            end
            if not pr then
                fail[shelf] = tick() + 20
                dbg("No RestockPrompt on", shelf.Name)
                continue
            end
            nearPrompt(pr)
            do
                local pp, hh = promptPos(pr), myHRP()
                if pp and hh and (hh.Position - pp).Magnitude > (pr.MaxActivationDistance or 10) - 3 then
                    fail[shelf] = tick()
                    dbg("restock: shelf out of reach", shelf.Name)
                    continue
                end
            end
            if not equip(box) then break end
            local before = shelf:GetAttribute("Stock") or 0
            fireproximityprompt(pr)
            local t = tick()
            while tick() - t < 1.6 and (shelf:GetAttribute("Stock") or 0) == before do task.wait(0.05) end
            local after = shelf:GetAttribute("Stock") or 0
            if after ~= before then
                stats.restocked = stats.restocked + math.max(0, after - before)
                did = true
                wanted[pid] = nil
                dbg("Restocked", pid, "->", shelf.Name, before, "=>", after)
            else
                nearPrompt(pr, true)
                fireproximityprompt(pr)
                t = tick()
                while tick() - t < 1.2 and (shelf:GetAttribute("Stock") or 0) == before do task.wait(0.05) end
                after = shelf:GetAttribute("Stock") or 0
                if after ~= before then
                    stats.restocked = stats.restocked + math.max(0, after - before)
                    did = true
                    wanted[pid] = nil
                else
                    fail[shelf] = tick()
                    dbg("Restock failed", pid, shelf.Name)
                end
            end
        end
    end
    return did
end

---------------------------------------------------------------- cleaning
local pileCache, pileT = {}, 0
local function piles(plot)
    if tick() - pileT > 3 then
        pileT = tick()
        table.clear(pileCache)
        for _, d in ipairs(plot:GetDescendants()) do
            if d:IsA("ProximityPrompt") and d.Name == "CleanPilePrompt" then pileCache[#pileCache+1] = d end
        end
    end
    return pileCache
end

local function holdPrompt(pr)
    if pr.HoldDuration > 0 then
        pcall(function() pr:InputHoldBegin() end)
        task.wait(pr.HoldDuration + 0.35)
        pcall(function() pr:InputHoldEnd() end)
    else
        fireproximityprompt(pr)
    end
end

local function cleanPass(plot)
    local hrp = myHRP()
    if not hrp then return false end
    local todo = {}
    for _, pr in ipairs(piles(plot)) do
        local part = pr.Parent
        if part and part:GetAttribute("Active") == true and part:GetAttribute("Cleaning") ~= true and not failed(pr) then
            todo[#todo+1] = pr
        end
    end
    if #todo == 0 then return false end
    for _, pr in ipairs(todo) do
        if not (alive and S.Clean) or abortChore() then break end
        hrp = myHRP()
        if not hrp then break end
        local part = pr.Parent
        local pos = posOf(part)
        local toolName = (pr:GetAttribute("CleanArea") == "outdoor") and "BroomStick" or "Broom"
        local tool = getTool(toolName)
        if not tool then
            local holder = plot:FindFirstChild(toolName == "Broom" and "BroomModel" or "BroomStickModel")
            local gp = holder and holder:FindFirstChild("CleaningPrompt", true)
            local gpos = gp and promptPos(gp)
            if gpos then
                standAt(hrp, gpos)
                task.wait(0.25)
                holdPrompt(gp)
                task.wait(0.5)
                tool = getTool(toolName)
            end
        end
        if tool and pos and equip(tool) then
            local t = tick()
            while not pr.Enabled and tick() - t < 1 do task.wait(0.05) end
            standAt(hrp, pos)
            task.wait(0.25)
            holdPrompt(pr)
            t = tick()
            while part:GetAttribute("Active") == true and tick() - t < 1.5 do task.wait(0.05) end
            if part:GetAttribute("Active") ~= true then
                stats.cleaned = stats.cleaned + 1
                dbg("Cleaned", part.Name)
            else
                fail[pr] = tick()
                dbg("Clean failed", part.Name)
            end
        else
            fail[pr] = tick()
            dbg("No tool for", toolName)
        end
    end
    return true
end

---------------------------------------------------------------- Tsinelas: wake workers + catch thieves
local HIT_TOOL = DC.HIT_TOOL_NAME or "Tsinelas"
local slapT = {}
local function slapPass()
    local asleep = {}
    for _, w in ipairs(CS:GetTagged("SariWorkerNPC")) do
        if w:GetAttribute("SariWorkerOwner") == lp.UserId and w:GetAttribute("Asleep") == true
            and not (slapT[w] and tick() - slapT[w] < 4) and w:FindFirstChild("HumanoidRootPart") then
            asleep[#asleep+1] = w
        end
    end
    if #asleep == 0 then return false end
    local tool = getTool(HIT_TOOL)
    local hrp = myHRP()
    if not tool or not hrp then return false end
    local did = false
    if not equip(tool) then return false end
    for _, w in ipairs(asleep) do
        slapT[w] = tick()
        hrp = myHRP()
        if not hrp then break end
        local wr = w:FindFirstChild("HumanoidRootPart")
        if wr and (hrp.Position - wr.Position).Magnitude > 6 then
            tp(wr.CFrame * CFrame.new(0, 0, 3))
            task.wait(0.25)
        end
        for _ = 1, 2 do
            R.HitNPC:FireServer(w)
            local t = tick()
            while w:GetAttribute("Asleep") == true and tick() - t < 1.2 do task.wait(0.05) end
            if w:GetAttribute("Asleep") ~= true then break end
            pcall(function() tool:Activate() end)
        end
        if w:GetAttribute("Asleep") ~= true then
            stats.slapped = stats.slapped + 1
            did = true
            dbg("Woke up", w.Name)
        end
    end
    local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
    if hum then hum:UnequipTools() end
    return did
end

-- the game's own thief flags (from HitClient / ShopliftAlertClient): SariShoplifter == true, SariCrook == true, tag SlapThief.
-- Only thieves near YOUR register are chased.
local function isThief(m, regPos)
    if not m.Parent or m == lp.Character then return false end
    local root = m:FindFirstChild("HumanoidRootPart")
    if not root then return false end
    if m:GetAttribute("SariWorkerOwner") then return false end
    if regPos and (root.Position - regPos).Magnitude > 160 then return false end
    local owner = m:GetAttribute("SukiOwnerId")
    if owner ~= nil and owner ~= lp.UserId then return false end
    return m:GetAttribute("SariShoplifter") == true or m:GetAttribute("SariCrook") == true or CS:HasTag(m, "SlapThief")
end

local function thiefList()
    local out, seen = {}, {}
    local plot = myPlot()
    local regPos = plot and counterPos(plot)
    local function consider(m)
        if typeof(m) ~= "Instance" then return end
        if not m:IsA("Model") then m = m:FindFirstAncestorOfClass("Model") end
        if not m or seen[m] then return end
        seen[m] = true
        if isThief(m, regPos) then out[#out+1] = m end
    end
    for _, m in ipairs(CS:GetTagged("SlapThief")) do consider(m) end
    for _, c in ipairs(workspace:GetChildren()) do
        if c:IsA("Model") and c:FindFirstChild("Humanoid") then consider(c) end
    end
    return out
end

bind(R.ShopliftAlert.OnClientEvent, function(...) X.thiefNext = 0 dbg("ShopliftAlert", ...) end)
bind(R.ThiefStatus.OnClientEvent, function(...) X.thiefNext = 0 dbg("ThiefStatus", ...) end)

local function thiefPass()
    local list = thiefList()
    if #list == 0 then return false end
    local tool = getTool(HIT_TOOL)
    if not tool then dbg("No Tsinelas for the thief") return false end
    if not equip(tool) then return false end
    local t0, hit = tick(), false
    while alive and tick() - t0 < 16 do
        if S.Pickup and hasPickup() then break end
        list = thiefList()
        if #list == 0 then break end
        local th = list[1]
        local tr = th:FindFirstChild("HumanoidRootPart")
        local hrp = myHRP()
        if not (tr and hrp) then break end
        if (hrp.Position - tr.Position).Magnitude > 9 then
            tp(tr.CFrame * CFrame.new(0, 0, 4))
            task.wait(0.05)
            hrp = myHRP()
            if not hrp then break end
        end
        -- face the thief (the server checks facing), swing like the game does, then report the hit
        hrp.CFrame = CFrame.lookAt(hrp.Position, Vector3.new(tr.Position.X, hrp.Position.Y, tr.Position.Z))
        pcall(function() tool:Activate() end)
        task.wait(0.06)
        R.HitNPC:FireServer(th)
        hit = true
        task.wait(0.3)
    end
    if hit and #thiefList() == 0 then
        stats.caught = stats.caught + 1
        dbg("Thief down")
    end
    local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
    if hum then hum:UnequipTools() end
    return hit
end

---------------------------------------------------------------- keep the store open 24/7
local function openStorePass(plot)
    if not S.AutoOpen then return false end
    if plot:GetAttribute("StoreOpen") ~= false then return false end
    if tick() - X.lastOpen < 3 then return false end
    X.lastOpen = tick()
    local pr = plot:FindFirstChild("OpenClosePrompt", true)
    if pr then
        local pos, hrp = promptPos(pr), myHRP()
        if pos and hrp and (hrp.Position - pos).Magnitude > (pr.MaxActivationDistance or 25) - 8 then
            approach(pos, 14)
        end
        fireproximityprompt(pr)
        local t = tick()
        while plot:GetAttribute("StoreOpen") == false and tick() - t < 0.8 do task.wait(0.05) end
    end
    if plot:GetAttribute("StoreOpen") == false and tick() - X.lastToggle > 3 then
        X.lastToggle = tick()
        pcall(function() R.ToggleStoreOpen:FireServer() end)
        local t = tick()
        while plot:GetAttribute("StoreOpen") == false and tick() - t < 1.2 do task.wait(0.05) end
    end
    if plot:GetAttribute("StoreOpen") ~= false then
        stats.opened = stats.opened + 1
        dbg("Store re-opened")
        return true
    end
    return false
end

---------------------------------------------------------------- beggar: always donate (ignoring beggars costs honor)
local BEGGAR_AMTS = {1, 5, 10, 20, 50, 100, 500, 1000}
bind(R.BeggarRequest.OnClientEvent, function(...)
    if not S.Beggar then return end
    local info = {...}
    task.delay(0.35, function()
        local cash, amt = money(), 0
        for i = #BEGGAR_AMTS, 1, -1 do
            local a = BEGGAR_AMTS[i]
            if a <= S.BeggarAmt and a <= cash then amt = a break end
        end
        R.BeggarGive:FireServer(amt)
        if amt > 0 then stats.donated = stats.donated + 1 end
        dbg("Beggar: gave", amt, #info)
        local g = pg:FindFirstChild("BeggarGui")
        if g and S.HideUI then g.Enabled = false end
    end)
end)

---------------------------------------------------------------- anti-AFK + unstick
local VU = game:GetService("VirtualUser")
local idleOff = {}
for _, c in ipairs(getconnections(lp.Idled)) do
    pcall(function() c:Disable() idleOff[#idleOff+1] = c end)
end
local function antiAfk()
    pcall(function()
        VU:CaptureController()
        VU:ClickButton2(Vector2.new(0, 0))
    end)
    stats.afk = stats.afk + 1
end
bind(lp.Idled, function() if S.AntiAFK then antiAfk() end end)

task.spawn(function()
    local climbSince, n = nil, 0
    while alive do
        task.wait(1)
        n = n + 1
        if S.AntiAFK and n % 50 == 0 then antiAfk() end
        local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
        if S.Unstick and hum then
            if hum:GetState() == Enum.HumanoidStateType.Climbing then
                climbSince = climbSince or tick()
                if tick() - climbSince > 3 then
                    hum:ChangeState(Enum.HumanoidStateType.Freefall)
                    climbSince = nil
                    dbg("Unstuck from Climbing")
                end
            else
                climbSince = nil
            end
        end
    end
end)

---------------------------------------------------------------- scheduler
task.spawn(function()
    local lastHomeFix, lastStream = 0, 0
    while alive do
        task.wait(0.1)
        pcall(function()
            local plot = myPlot()
            if not plot or not lp.Character or not myHRP() then return end
            ensureHome(plot)
            if S.Pickup then trackPickups(plot) end
            if tick() - lastDemand > 1 then
                lastDemand = tick()
                scanDemand(plot)
            end
            if S.Stay and HOME and tick() - lastStream > 3 then
                lastStream = tick()
                stream(HOME.Position)
            end
            if moveBusy then return end
            if S.Pickup and hasPickup() then withMove(pickupPass) return end
            if S.Thief and tick() >= X.thiefNext then
                if #thiefList() > 0 then
                    withMove(thiefPass)
                    X.thiefNext = tick() + 0.2
                    return
                end
                X.thiefNext = tick() + 0.35
            end
            if S.AutoOpen and plot:GetAttribute("StoreOpen") == false then
                if withMove(openStorePass, plot) then return end
            end
            if S.Stay and HOME and tick() - lastHomeFix > 2 then
                local hrp = myHRP()
                if hrp and (hrp.Position - HOME.Position).Magnitude > S.HomeRadius + 6 then
                    lastHomeFix = tick()
                    withMove(function() end)
                    dbg("Watchdog: back to the register")
                    return
                end
            end
            if S.Slap and tick() >= serveUntil then withMove(slapPass) end
            if tick() < serveUntil or tick() < nextChore then return end
            nextChore = tick() + 0.5
            local did = false
            if S.Restock then did = withMove(restockPass, plot) or did end
            if S.Trash then did = withMove(trashPass, plot) or did end
            if S.Clean then did = withMove(cleanPass, plot) or did end
            if did or holdingTool() then
                local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
                if hum and not moveBusy then hum:UnequipTools() end
            end
        end)
    end
end)

---------------------------------------------------------------- smart buying from the shop
local buyFail, lastRes = {}, nil
bind(R.PurchaseResult.OnClientEvent, function(ok, msg) lastRes = {ok, msg} end)

local shopCache, shopT = nil, 0
local function laptopPrompt(plot)
    if shopCache and shopCache.Parent and tick() - shopT < 30 then return shopCache end
    shopT = tick()
    local ref = HOME and HOME.Position or counterPos(plot)
    local best, bd
    local function consider(d)
        local p = promptPos(d)
        if p then
            local dist = ref and (p - ref).Magnitude or 0
            if not bd or dist < bd then best, bd = d, dist end
        end
    end
    for _, d in ipairs(plot:GetDescendants()) do
        if d:IsA("ProximityPrompt") and d.Name == "LaptopPrompt" then consider(d) end
    end
    if not best then
        local plots = workspace:FindFirstChild("Plots")
        for _, d in ipairs(workspace:GetDescendants()) do
            if d:IsA("ProximityPrompt") and d.Name == "LaptopPrompt" and not (plots and d:IsDescendantOf(plots)) then consider(d) end
        end
    end
    shopCache = best
    return best
end

local function goShop(plot, tight)
    local pr = laptopPrompt(plot)
    local pos = posOf(getgenv().SSAF_SHOP) or (pr and promptPos(pr))
    local hrp = myHRP()
    if not pos or not hrp then return false end
    local reach = tight and 5 or S.ShopReach
    if (hrp.Position - pos).Magnitude > reach then
        stream(pos)
        if reach <= 8 then standAt(hrp, pos) else approach(pos, reach) end
        task.wait(0.3)
        settle()
    end
    return true
end

local DIST_WORDS = {"near", "far", "close", "distance", "range", "reach", "approach", "within"}
local function distMsg(msg)
    msg = tostring(msg or ""):lower()
    if msg:find("on its way", 1, true) then return false end
    for _, w in ipairs(DIST_WORDS) do if msg:find(w, 1, true) then return true end end
    return false
end

local function placeOrder(items)
    lastRes = nil
    R.PurchaseOrder:FireServer(items)
    local t = tick()
    while not lastRes and tick() - t < 3 do task.wait(0.1) end
    return lastRes and lastRes[1] == true, lastRes and lastRes[2]
end

local BUY_MODES = {"Smart", "Highest value", "Lowest value", "Best profit", "Best ROI"}

local function planOrder(rep)
    local dem, now = {}, tick()
    local function bump(id, need, prio, boxes)
        if not id or id == "" then return end
        local d = dem[id]
        if not d then d = {id=id, need=0, prio=0, box=0} dem[id] = d end
        if need > d.need then d.need = need end
        if prio > d.prio then d.prio = prio end
        if boxes and boxes > d.box then d.box = boxes end
    end
    for _, group in ipairs({{rep.outOfStock, true}, {rep.lowStock, false}}) do
        for _, e in ipairs(group[1] or {}) do
            local prod = DC.getProduct(e.id)
            if prod then
                local full = (prod.shelfCap or 8) * ((prod.category == "rice") and 1 or 2)
                bump(e.id, group[2] and full or math.max(full - (e.stock or 0), 0), group[2] and 2 or 1, e.box or 0)
            end
        end
    end
    local plot = myPlot()
    if plot then
        local need, capSum, anyEmpty, minR = {}, {}, {}, {}
        for _, m in ipairs(shelves(plot)) do
            local id, cap = m:GetAttribute("ProductId"), m:GetAttribute("Capacity") or 0
            if id and id ~= "" and cap > 0 then
                local st = m:GetAttribute("Stock") or 0
                need[id] = (need[id] or 0) + (cap - st)
                capSum[id] = (capSum[id] or 0) + cap
                if st <= 0 then anyEmpty[id] = true end
                local rr = st / cap
                if not minR[id] or rr < minR[id] then minR[id] = rr end
            end
        end
        for id, n in pairs(need) do
            if DC.getProduct(id) and (anyEmpty[id] or (minR[id] or 1) <= S.BuyBelow / 100 or n >= capSum[id] * 0.5) then
                bump(id, n, anyEmpty[id] and 2 or 1)
            end
        end
    end
    for id, t in pairs(wanted) do
        if now - t < 60 then
            local prod = DC.getProduct(id)
            if prod then bump(id, (prod.shelfCap or 8) * ((prod.category == "rice") and 1 or 2), 3) end
        else
            wanted[id] = nil
        end
    end

    local inv = {}
    pcall(function() inv = R.GetInventoryCounts:InvokeServer() or {} end)
    if typeof(inv) ~= "table" then inv = {} end

    local cash = money()
    local mode = S.BuyMode
    local list = {}
    for _, d in pairs(dem) do
        local prod = DC.getProduct(d.id)
        local size = prod and (DC.getBoxSize(prod) or 10) or 10
        local buy, sell = prod and prod.buy or 0, prod and (prod.sell or prod.buy) or 0
        d.cost = math.max(buy * size, 1)
        d.profit = (sell - buy) * size
        d.roi = (sell - buy) / math.max(buy, 0.5)
        d.urg = plot and urgency(plot, d.id) or -1
        d.hot = lp:GetAttribute("HotItem") == d.id
        d.tier = S.NeedsFirst and ((d.prio >= 3 and 2) or (d.prio >= 2 and 1) or 0) or 0
        if mode == "Highest value" then
            d.score = d.tier * 1e6 + d.cost
        elseif mode == "Lowest value" then
            d.score = d.tier * 1e6 - d.cost
        elseif mode == "Best profit" then
            d.score = d.tier * 1e6 + d.profit
        elseif mode == "Best ROI" then
            d.score = d.tier * 1e6 + d.roi * 1000
        else
            local base = (cash < 4000) and (d.roi * 600) or math.min(d.profit, 3000)
            d.score = d.tier * 1e6 + (1 - math.min(d.urg, 1)) * 2500 + base + (d.hot and 800 or 0)
        end
        list[#list+1] = d
    end
    table.sort(list, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.need > b.need
    end)

    local pctNow = S.BuyPct
    if mode == "Smart" then pctNow = (cash < 3000 and 40) or (cash < 15000 and 60) or 80 end
    local avail = cash - S.Reserve
    local urgent = cash - S.Reserve * 0.3
    local budget = math.max(avail, 0) * (pctNow / 100)
    local items, total = {}, 0
    for _, d in ipairs(list) do
        if #items >= S.MaxItems or urgent <= 0 then break end
        local prod = DC.getProduct(d.id)
        if prod and not (buyFail[d.id] and now - buyFail[d.id] < 120) then
            local size = DC.getBoxSize(prod) or 10
            local shelfStock = 0
            if plot then
                for _, m in ipairs(shelves(plot)) do
                    if m:GetAttribute("ProductId") == d.id then shelfStock = shelfStock + (m:GetAttribute("Stock") or 0) end
                end
            end
            local spare = math.max((tonumber(inv[d.id]) or 0) - shelfStock, handUnits(d.id) + (plot and rackUnits(plot, d.id) or 0), 0)
            local owned = spare
            local deficit = d.need - owned
            if deficit > 0 then
                local limitOk, lim = pcall(DC.marketStockLimit, d.id)
                local want = math.ceil(deficit / size)
                if S.Buffer > 0 and cash > S.Reserve * 4 + 5000 then want = want + S.Buffer end
                local boxes = math.min(want, (limitOk and tonumber(lim)) or 3, S.MaxBoxes)
                local unit = (prod.buy or 0) * (d.hot and 1.2 or 1)
                local cost = math.max(unit * size, 1)
                local cap = (d.prio >= 2) and urgent or math.min(budget, avail)
                boxes = math.min(boxes, math.floor(cap / cost))
                if boxes >= 1 then
                    items[#items+1] = {id=d.id, qty=boxes}
                    urgent = urgent - cost * boxes
                    avail = avail - cost * boxes
                    budget = budget - cost * boxes
                    total = total + boxes
                end
            end
        end
    end
    return items, total
end

local function orderItems(items, total)
    local success, msg = placeOrder(items)
    if not success and msg == nil then return "far", "no answer from the server", items, 0 end
    if not success and distMsg(msg) then return "far", msg, items, 0 end
    local soldName = (not success) and tostring(msg):match("^(.-) is sold out")
    if soldName then
        local sid = name2id[(soldName:lower():gsub("[^%w]", ""))]
        if sid then buyFail[sid] = tick() end
        dbg("Sold out in the market:", soldName)
        return "sold", msg, items, 0
    end
    if not success and not tostring(msg):find("on its way", 1, true) then
        for _, item in ipairs(items) do
            local s2, m2 = placeOrder({item})
            if s2 then return "ok", m2, {item}, item.qty end
            if tostring(m2):find("on its way", 1, true) then return "wait", m2, items, 0 end
            if m2 == nil or distMsg(m2) then return "far", m2, items, 0 end
            buyFail[item.id] = tick()
            dbg("Order refused for", item.id, tostring(m2))
        end
        return "fail", msg, items, 0
    end
    if success then return "ok", msg, items, total end
    return "wait", msg, items, 0
end

local function smartBuy()
    if tick() < nextBuyAt or moveBusy or hasPickup() then return end
    local plot = myPlot()
    if not plot then return end
    ensureHome(plot)
    local ok, rep = pcall(function() return R.GetStockReport:InvokeServer() end)
    if not ok or typeof(rep) ~= "table" then nextBuyAt = tick() + 5 return end
    local items, total = planOrder(rep)
    if #items == 0 then nextBuyAt = tick() + 5 return end

    local st, msg, placed, n = "busy", nil, items, 0
    for attempt = 1, 2 do
        local entered = false
        withMove(function()
            entered = true
            goShop(plot, attempt == 2)
            st, msg, placed, n = orderItems(items, total)
        end)
        if not entered then st = "busy" break end
        if st ~= "far" then break end
    end

    if st == "busy" then
        nextBuyAt = tick() + 2
    elseif st == "ok" then
        stats.bought = stats.bought + n
        nextBuyAt = tick() + 15
        local names = {}
        for _, i in ipairs(placed) do names[#names+1] = i.id .. "x" .. i.qty end
        dbg("Ordered:", table.concat(names, ", "))
    elseif st == "sold" then
        nextBuyAt = tick() + 1
    elseif st == "wait" then
        nextBuyAt = tick() + 8
    elseif st == "far" then
        nextBuyAt = tick() + 10
        dbg("Could not buy:", tostring(msg), "(try getgenv().SSAF_SHOP = <Vector3> next to the computer)")
    else
        nextBuyAt = tick() + 15
        dbg("Order failed:", tostring(msg))
    end
end

task.spawn(function()
    task.wait(5)
    while alive do
        if S.Buy then pcall(smartBuy) end
        for _ = 1, 4 do if not alive then break end task.wait(0.5) end
    end
end)

---------------------------------------------------------------- UI
local Win = Rayfield:CreateWindow({Name="Sari-Sari Auto v3.3", LoadingTitle="Sari-Sari Auto v3.1", ConfigurationSaving={Enabled=false}})
local T = Win:CreateTab("Main")
local function tog(name, key)
    T:CreateToggle({Name=name, CurrentValue=S[key], Callback=function(v) S[key]=v applyUI() end})
end
tog("Auto Grab (skips out-of-stock)", "Grab")
tog("Auto Register + Exact Change", "Checkout")
tog("Stay at the register (live position)", "Stay")
tog("Stand ON TOP of the register", "StandTop")
tog("Auto Open store 24/7", "AutoOpen")
tog("Auto Catch Thief (Tsinelas strike)", "Thief")
tog("Auto Donate to Beggar", "Beggar")
tog("Auto KashG (accept real / decline fake)", "KashG")
tog("Auto Accept Utang", "Utang")
tog("Auto E-Load (no phone UI)", "Load")
tog("Auto Clean Dust / Leaves", "Clean")
tog("Auto Restock shelves from backpack", "Restock")
tog("Take boxes from racks when shelves run low", "Racks")
tog("Auto Throw Away empty boxes", "Trash")
tog("Auto Pick Up shop deliveries (fast)", "Pickup")
tog("Smart Buy (shop computer)", "Buy")
tog("Buy: customer-wanted / empty items first", "NeedsFirst")
tog("Auto Pay Electric Bill", "Bill")
tog("Auto Continue (day summary)", "Continue")
tog("Auto Claim Daily Tasks", "Tasks")
tog("Auto Wake Sleeping Workers (Tsinelas)", "Slap")
tog("Anti-AFK", "AntiAFK")
tog("Auto Unstick (Climbing freeze)", "Unstick")
tog("Hide game popups (register / KashG / Utang)", "HideUI")
tog("Checkout even if an item is out of stock", "SkipOut")
T:CreateDropdown({Name="Buy priority", Options=BUY_MODES, CurrentOption={S.BuyMode}, MultipleOptions=false,
    Callback=function(o)
        local v = typeof(o) == "table" and o[1] or o
        if typeof(v) == "string" then S.BuyMode = v nextBuyAt = 0 end
    end})
T:CreateDropdown({Name="Beggar donation (P)", Options={"1","5","10","20","50","100","500","1000"}, CurrentOption={tostring(S.BeggarAmt)}, MultipleOptions=false,
    Callback=function(o)
        local v = tonumber(typeof(o) == "table" and o[1] or o)
        if v then S.BeggarAmt = v end
    end})
T:CreateSlider({Name="Buy when a shelf is at or below (%)", Range={10,100}, Increment=5, Suffix="%", CurrentValue=S.BuyBelow, Callback=function(v) S.BuyBelow=v nextBuyAt=0 end})
T:CreateSlider({Name="Extra buffer boxes when cash is high", Range={0,3}, Increment=1, CurrentValue=S.Buffer, Callback=function(v) S.Buffer=v end})
T:CreateButton({Name="Set stand spot here (relative to register)", Callback=function() setHome() end})
T:CreateButton({Name="Go to register now", Callback=function() withMove(function() goHome(true) settle() end) end})
T:CreateButton({Name="Buy now", Callback=function() nextBuyAt = 0 end})
T:CreateSlider({Name="Keep this much cash when buying (P)", Range={0,10000}, Increment=250, CurrentValue=S.Reserve, Callback=function(v) S.Reserve=v end})
T:CreateSlider({Name="Spend this % of spare cash per order (non-Smart)", Range={10,100}, Increment=5, Suffix="%", CurrentValue=S.BuyPct, Callback=function(v) S.BuyPct=v end})
T:CreateSlider({Name="Max different items per order", Range={1,12}, Increment=1, CurrentValue=S.MaxItems, Callback=function(v) S.MaxItems=v end})
T:CreateSlider({Name="Max boxes per item", Range={1,10}, Increment=1, CurrentValue=S.MaxBoxes, Callback=function(v) S.MaxBoxes=v end})
T:CreateSlider({Name="Refill shelf when below (%)", Range={10,100}, Increment=5, Suffix="%", CurrentValue=S.Pct, Callback=function(v) S.Pct=v end})
T:CreateSlider({Name="Fetch rack boxes when shelf below (%)", Range={10,100}, Increment=5, Suffix="%", CurrentValue=S.RackPct, Callback=function(v) S.RackPct=v end})
T:CreateSlider({Name="Reach: move only if farther than (studs)", Range={8,36}, Increment=1, CurrentValue=S.Reach, Callback=function(v) S.Reach=v end})
T:CreateSlider({Name="Register radius (studs before returning)", Range={3,30}, Increment=1, CurrentValue=S.HomeRadius, Callback=function(v) S.HomeRadius=v end})
T:CreateSlider({Name="Customer waits for restock (seconds)", Range={0,20}, Increment=1, CurrentValue=S.WaitStock, Callback=function(v) S.WaitStock=v end})
T:CreateSlider({Name="Action Delay", Range={0.03,1}, Increment=0.01, CurrentValue=S.Delay, Callback=function(v) S.Delay=v end})
local lbl1 = T:CreateLabel("Starting...")
local lbl2 = T:CreateLabel("")
local lbl3 = T:CreateLabel("")

task.spawn(function()
    while alive do
        pcall(function()
            lbl1:Set(string.format("Served %d | Picks %d | Change P%d | KashG +%d/-%d | Load %d (fail %d) | Utang %d",
                stats.served, stats.picks, stats.change, stats.kashOk, stats.kashNo, stats.loads, stats.loadFail, stats.utang))
            lbl2:Set(string.format("Restocked %d | Racked %d | Bought %d | Picked up %d | Trashed %d | Cleaned %d | Tasks %d | Bills %d | Days %d | Woke %d | Thieves %d | Opened %d",
                stats.restocked, stats.racked, stats.bought, stats.picked, stats.trashed, stats.cleaned, stats.claimed, stats.bills, stats.continued, stats.slapped, stats.caught, stats.opened))
            local plot = myPlot()
            local empty, wantedN = 0, 0
            if plot then
                for _, m in ipairs(shelves(plot)) do
                    if (m:GetAttribute("ProductId") or "") ~= "" and (m:GetAttribute("Stock") or 0) <= 0 then empty = empty + 1 end
                end
            end
            for _, t in pairs(wanted) do if tick() - t < 60 then wantedN = wantedN + 1 end end
            local hrp = myHRP()
            local hd = (hrp and HOME) and math.floor((hrp.Position - HOME.Position).Magnitude) or -1
            lbl3:Set(string.format("Empty shelves %d | Wanted %d | Teleports %d | Returns %d | From register %d studs | Boxes %d | Store %s",
                empty, wantedN, stats.hops, stats.homes, hd, #collectBoxes(), tostring(plot and plot:GetAttribute("StoreOpen"))))
        end)
        task.wait(1)
    end
end)

applyUI()

getgenv().SSAF_STOP = function()
    alive = false
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    suppress(R.KashGAsk, "KashGClient", false)
    suppress(R.CheckoutData, "RegisterClient", false)
    suppress(R.UtangAsk, "UtangClient", false)
    for _, c in ipairs(idleOff) do pcall(function() c:Enable() end) end
    pcall(function() Rayfield:Destroy() end)
end
print("[SSAF] v3.3 loaded")
