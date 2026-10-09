if getgenv().SSAF_STOP then pcall(getgenv().SSAF_STOP) end

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local lp = Players.LocalPlayer
local R = RS.SariSariStore.Remotes
local DC = require(RS.SariSariStore.Modules.DataConfig)

local S = {Grab=true, Checkout=true, KashG=true, Utang=true, Load=true, Clean=true, Restock=true,
    Pickup=true, Trash=true, Bill=true, Continue=true, Tasks=true, Buy=true, Slap=true, AntiAFK=true, Unstick=true,
    HideUI=true, SkipOut=true, Stay=true, Racks=true, Delay=0.05, Pct=100, Reserve=1000,
    WaitStock=8, MaxItems=8, MaxBoxes=5, BuyPct=60, Reach=25, HomeRadius=8, RackPct=60, ShopReach=14}
local alive = true
local conns = {}
local stats = {served=0, change=0, kashOk=0, kashNo=0, loads=0, loadFail=0, utang=0, cleaned=0, restocked=0, picks=0,
    picked=0, trashed=0, claimed=0, bought=0, bills=0, continued=0, slapped=0, afk=0, hops=0, homes=0, racked=0}


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
    if tick() - scanT < 3 then return end
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

local function standAt(hrp, pos)
    ******** = CFrame.new(pos + Vector3.new(0, 3, 0))
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


local function ensureHome(plot)
    if HOME then return end
    local reg = counterPos(plot)
    if not reg then return end
    local saved = getgenv().SSAF_HOMECF
    if typeof(saved) == "CFrame" and (saved.Position - reg).Magnitude < 40 then HOME = saved return end
    local hrp = myHRP()
    if hrp and (hrp.Position - reg).Magnitude <= 30 then
        HOME = ********
    else
        HOME = ********
    end
    getgenv().SSAF_HOMECF = HOME
end

local function setHome()
    local hrp = myHRP()
    if hrp then
        HOME = ********
        getgenv().SSAF_HOMECF = HOME
    end
end

local function goHome(force)
    local hrp = myHRP()
    if not hrp or not HOME then return false end
    if not force and (hrp.Position - HOME.Position).Magnitude <= S.HomeRadius then return false end
    stream(HOME.Position)
    ******** = HOME
    hrp.AssemblyLinearVelocity = Vector3.zero
    stats.homes = stats.homes + 1
    return true
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
    ******** = CFrame.new(stand)
    hrp.AssemblyLinearVelocity = Vector3.zero
    stats.hops = stats.hops + 1
    task.wait(0.12)
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
        stats.hops = stats.hops + 1
        task.wait(0.12)
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




local pickups, trackedPlot = {}, nil
local function trackPickups(plot)
    if trackedPlot == plot then return end
    trackedPlot = plot
    for _, d in ipairs(plot:GetDescendants()) do
        if d:IsA("ProximityPrompt") and d.Name == "PickupPrompt" then pickups[d] = {t=tick(), n=0} end
    end
    bind(plot.DescendantAdded, function(d)
        if d:IsA("ProximityPrompt") and d.Name == "PickupPrompt" then pickups[d] = {t=tick(), n=0} end
    end)
end

local function hasPickup()
    for d, e in pairs(pickups) do
        if d.Parent and d:IsDescendantOf(workspace) and tick() - e.t < 30 and e.n < 3 then return true end
        pickups[d] = nil
    end
    return false
end


local function abortChore()
    return tick() < serveUntil or (S.Pickup and hasPickup())
end


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
for gui, flag in pairs({KashGGui="KashG", UtangGui="Utang", CashierGui="Checkout"}) do
    local g = pg:FindFirstChild(gui)
    if g then
        bind(g:GetPropertyChangedSignal("Enabled"), function()
            if g.Enabled and S.HideUI and S[flag] then g.Enabled = false end
        end)
    end
end


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
                            pickShelf(shelf, tries >= 1)   
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
            goHome()
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
                if not moveBusy then pcall(goHome) end
                pressRegister(plot)
            end)
        end
    end
end)


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


bind(R.UtangAsk.OnClientEvent, function(d)
    if S.Utang and typeof(d) == "table" then
        R.UtangDecide:FireServer(true)
        stats.utang = stats.utang + 1
    end
end)


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


local function pickupPass()
    local hrp = myHRP()
    if not hrp then return false end
    local did = false
    for d, e in pairs(pickups) do
        if d.Parent and d:IsDescendantOf(workspace) then
            e.n = e.n + 1
            local pos = promptPos(d)
            if pos then
                for _ = 1, 5 do
                    if not (d.Parent and d:IsDescendantOf(workspace)) then break end
                    hrp = myHRP()
                    if not hrp then break end
                    standAt(hrp, pos)
                    task.wait(0.12)
                    fireproximityprompt(d)
                    local t = tick()
                    while d.Parent and d:IsDescendantOf(workspace) and tick() - t < 0.7 do task.wait(0.05) end
                end
            end
            if not (d.Parent and d:IsDescendantOf(workspace)) then
                stats.picked = stats.picked + 1
                did = true
                pickups[d] = nil
                nextBuyAt = math.min(nextBuyAt, tick() + 1)   
                nextChore = 0                                  
                dbg("Picked up delivery", d.ObjectText)
            end
        else
            pickups[d] = nil
        end
    end
    return did
end



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


local CS = game:GetService("CollectionService")
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
    local tool = getTool("Tsinelas")
    local hrp = myHRP()
    if not tool or not hrp then return false end
    local did = false
    if not equip(tool) then return false end
    for _, w in ipairs(asleep) do
        slapT[w] = tick()
        hrp = myHRP()
        if not hrp then break end
        local wr = w:FindFirstChild("HumanoidRootPart")
        if wr and (hrp.Position - wr.Position).Magnitude > 8 then
            ******** = wr.CFrame * CFrame.new(0, 0, 3)
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


task.spawn(function()
    local lastHomeFix, lastStream = 0, 0
    while alive do
        task.wait(0.2)
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
            
            if S.Stay and HOME and tick() - lastHomeFix > 1 then
                local hrp = myHRP()
                if hrp and (hrp.Position - HOME.Position).Magnitude > S.HomeRadius + 4 then
                    lastHomeFix = tick()
                    withMove(function() end)
                    dbg("Watchdog: back to the counter")
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
    stream(pos)
    local reach = tight and 5 or S.ShopReach
    if (hrp.Position - pos).Magnitude > reach then
        if reach <= 8 then standAt(hrp, pos) else approach(pos, reach) end
        task.wait(0.35)
    end
    settle()
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
        local need, capSum, anyEmpty = {}, {}, {}
        for _, m in ipairs(shelves(plot)) do
            local id, cap = m:GetAttribute("ProductId"), m:GetAttribute("Capacity") or 0
            if id and id ~= "" and cap > 0 then
                local st = m:GetAttribute("Stock") or 0
                need[id] = (need[id] or 0) + (cap - st)
                capSum[id] = (capSum[id] or 0) + cap
                if st <= 0 then anyEmpty[id] = true end
            end
        end
        for id, n in pairs(need) do
            if DC.getProduct(id) and (anyEmpty[id] or n >= capSum[id] * 0.35) then
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

    local list = {}
    for _, d in pairs(dem) do list[#list+1] = d end
    table.sort(list, function(a, b)
        if a.prio ~= b.prio then return a.prio > b.prio end
        return a.need > b.need
    end)

    local cash = money()
    local avail = cash - S.Reserve                 
    local urgent = cash - S.Reserve * 0.3          
    local budget = math.max(avail, 0) * (S.BuyPct / 100)
    local items, total = {}, 0
    for _, d in ipairs(list) do
        if #items >= S.MaxItems or urgent <= 0 then break end
        local prod = DC.getProduct(d.id)
        if prod and not (buyFail[d.id] and now - buyFail[d.id] < 120) then
            local size = DC.getBoxSize(prod) or 10
            local owned = math.max(d.box, handUnits(d.id), tonumber(inv[d.id]) or 0, plot and rackUnits(plot, d.id) + handUnits(d.id) or 0)
            local deficit = d.need - owned
            if deficit > 0 then
                local limitOk, lim = pcall(DC.marketStockLimit, d.id)
                local boxes = math.min(math.ceil(deficit / size), (limitOk and tonumber(lim)) or 3, S.MaxBoxes)
                local unit = (prod.buy or 0) * ((lp:GetAttribute("HotItem") == d.id) and 1.2 or 1)
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


local Win = Rayfield:CreateWindow({Name="Sari-Sari Auto v2.6", LoadingTitle="Sari-Sari Auto v2.6", ConfigurationSaving={Enabled=false}})
local T = Win:CreateTab("Main")
local function tog(name, key)
    T:CreateToggle({Name=name, CurrentValue=S[key], Callback=function(v) S[key]=v applyUI() end})
end
tog("Auto Grab (hops to shelves, skips out-of-stock)", "Grab")
tog("Auto Register + Exact Change", "Checkout")
tog("Stay at the counter (always return home)", "Stay")
tog("Auto KashG (accept real / decline fake)", "KashG")
tog("Auto Accept Utang", "Utang")
tog("Auto E-Load (no phone UI)", "Load")
tog("Auto Clean Dust / Leaves", "Clean")
tog("Auto Restock shelves from backpack", "Restock")
tog("Take boxes from racks when shelves run low", "Racks")
tog("Auto Throw Away empty boxes", "Trash")
tog("Auto Pick Up shop deliveries", "Pickup")
tog("Smart Buy (walks to the shop computer)", "Buy")
tog("Auto Pay Electric Bill", "Bill")
tog("Auto Continue (day summary)", "Continue")
tog("Auto Claim Daily Tasks", "Tasks")
tog("Auto Wake Sleeping Workers (Tsinelas)", "Slap")
tog("Anti-AFK", "AntiAFK")
tog("Auto Unstick (Climbing freeze)", "Unstick")
tog("Hide game popups (register / KashG / Utang)", "HideUI")
tog("Checkout even if an item is out of stock", "SkipOut")
T:CreateButton({Name="Set HOME here (stand at your counter spot first)", Callback=function() setHome() end})
T:CreateButton({Name="Go home now", Callback=function() withMove(function() goHome(true) settle() end) end})
T:CreateButton({Name="Buy now", Callback=function() nextBuyAt = 0 end})
T:CreateSlider({Name="Keep this much cash when buying (P)", Range={0,10000}, Increment=250, CurrentValue=S.Reserve, Callback=function(v) S.Reserve=v end})
T:CreateSlider({Name="Spend this % of spare cash per order", Range={10,100}, Increment=5, Suffix="%", CurrentValue=S.BuyPct, Callback=function(v) S.BuyPct=v end})
T:CreateSlider({Name="Max different items per order", Range={1,12}, Increment=1, CurrentValue=S.MaxItems, Callback=function(v) S.MaxItems=v end})
T:CreateSlider({Name="Max boxes per item", Range={1,10}, Increment=1, CurrentValue=S.MaxBoxes, Callback=function(v) S.MaxBoxes=v end})
T:CreateSlider({Name="Refill shelf when below (%)", Range={10,100}, Increment=5, Suffix="%", CurrentValue=S.Pct, Callback=function(v) S.Pct=v end})
T:CreateSlider({Name="Fetch rack boxes when shelf below (%)", Range={10,100}, Increment=5, Suffix="%", CurrentValue=S.RackPct, Callback=function(v) S.RackPct=v end})
T:CreateSlider({Name="Reach: hop only if shelf is farther than (studs)", Range={8,36}, Increment=1, CurrentValue=S.Reach, Callback=function(v) S.Reach=v end})
T:CreateSlider({Name="Counter spot radius (studs)", Range={3,20}, Increment=1, CurrentValue=S.HomeRadius, Callback=function(v) S.HomeRadius=v end})
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
            lbl2:Set(string.format("Restocked %d | Racked %d | Bought %d | Picked up %d | Trashed %d | Cleaned %d | Tasks %d | Bills %d | Days %d | Woke %d | AFK %d",
                stats.restocked, stats.racked, stats.bought, stats.picked, stats.trashed, stats.cleaned, stats.claimed, stats.bills, stats.continued, stats.slapped, stats.afk))
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
            lbl3:Set(string.format("Empty shelves %d | Wanted %d | Hops %d | Homes %d | From home %d studs | Boxes in bag %d",
                empty, wantedN, stats.hops, stats.homes, hd, #collectBoxes()))
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
