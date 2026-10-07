-- Sari-Sari Store Auto Farm v2.3 | Rayfield | Plot-scoped
-- Set getgenv().SSAF_DEBUG = true BEFORE running to see decisions in the console.
if getgenv().SSAF_STOP then pcall(getgenv().SSAF_STOP) end

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local lp = Players.LocalPlayer
local R = RS.SariSariStore.Remotes
local DC = require(RS.SariSariStore.Modules.DataConfig)

local S = {Grab=true, Checkout=true, KashG=true, Utang=true, Load=true, Clean=true, Restock=true,
    Pickup=true, Trash=true, Bill=true, Continue=true, Tasks=true, Buy=true,
    HideUI=true, SkipOut=true, Delay=0.05, Pct=100, Reserve=1000}
local alive = true
local conns = {}
local stats = {served=0, change=0, kashOk=0, kashNo=0, loads=0, loadFail=0, utang=0, cleaned=0, restocked=0, picks=0,
    picked=0, trashed=0, claimed=0, bought=0, bills=0, continued=0}

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

-- same rule as the game's sectionInactive(): Hidden up the tree, Locked, or RemodelHidden parts
local function inactive(plot, m)
    local x = m
    while x and x ~= plot do
        if x:GetAttribute("Hidden") == true then return true end
        x = x.Parent
    end
    if m:GetAttribute("Locked") == true then return true end
    for _, d in ipairs(m:GetDescendants()) do
        if d:IsA("BasePart") and d:GetAttribute("RemodelHidden") == true then return true end
    end
    return false
end

local shelfCache, shelfT = {}, 0
local function shelves(plot)   -- ACTIVE shelves only
    if tick() - shelfT > 2 then
        shelfT = tick()
        table.clear(shelfCache)
        for _, m in ipairs(plot:GetDescendants()) do
            if m:IsA("Model") and m:GetAttribute("ShelfId") and not inactive(plot, m) then
                shelfCache[#shelfCache+1] = m
            end
        end
    end
    return shelfCache
end

local bad = {}
local function stockFor(plot, id, hrp, ignoreBad)
    local best, bd
    for _, m in ipairs(shelves(plot)) do
        if m.Parent and m:GetAttribute("ProductId") == id and (m:GetAttribute("Stock") or 0) > 0
            and (ignoreBad or not (bad[m] and tick() - bad[m] < 5)) then
            local d = hrp and (m:GetPivot().Position - hrp.Position).Magnitude or 0
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

-- nearest customer to the register that actually has an item order (skips queue + load customers)
local function orderCustomer(plot)
    local reg = plot:FindFirstChild("CashRegister")
    if not reg then return end
    local best, bd, brows
    for _, c in ipairs(workspace:GetChildren()) do
        if c:IsA("Model") and c:GetAttribute("SukiOwnerId") == lp.UserId and c:FindFirstChild("HumanoidRootPart") then
            local rows = getRows(c)
            if #rows > 0 then
                local d = (c.HumanoidRootPart.Position - reg.Position).Magnitude
                if not bd or d < bd then best, bd, brows = c, d, rows end
            end
        end
    end
    return best, brows, bd
end

local lastPress, pressBackoff = 0, 0
local function pressRegister(plot)
    if tick() < pressBackoff or tick() - lastPress < 0.4 then return end
    lastPress = tick()
    local reg = plot and plot:FindFirstChild("CashRegister")
    if reg then R.RegisterPress:FireServer(reg) end
end

-- the game tells us when nobody is at the counter: back off instead of spamming
bind(R.ShowWarning.OnClientEvent, function(msg)
    if typeof(msg) == "string" and msg:find("No customer at the register", 1, true) then
        pressBackoff = tick() + 1.5
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
for gui, flag in pairs({KashGGui="KashG", UtangGui="Utang", CashierGui="Checkout"}) do
    local g = pg:FindFirstChild(gui)
    if g then
        bind(g:GetPropertyChangedSignal("Enabled"), function()
            if g.Enabled and S.HideUI and S[flag] then g.Enabled = false end
        end)
    end
end

---------------------------------------------------------------- grab + register loop
-- The server only accepts picks from the shelf's real PickPrompt (the old remote is ignored).
local function pickShelf(shelf)
    local pr = shelf:FindFirstChild("PickPrompt", true)
    if pr then
        fireproximityprompt(pr)
    else
        R.ShelfActivate:FireServer(shelf, "pick")
    end
end

local pend = {}
local grabBusyUntil = 0
local function step()
    local plot = myPlot()
    if not plot then return end
    local c, rows, regDist = orderCustomer(plot)
    if not c then return end
    local hrp = myHRP()
    local needsGrab, missing = false, false
    for _, r in ipairs(rows) do
        if r.have < r.need then
            local shelf = r.id and (stockFor(plot, r.id, hrp) or stockFor(plot, r.id, hrp, true))
            if shelf then
                needsGrab = true
                grabBusyUntil = tick() + 1.5
                if S.Grab then
                    local key = c.Name .. "|" .. r.id
                    local p = pend[key]
                    if p and p.have ~= r.have then p = nil pend[key] = nil end
                    local fired = p and p.fired or 0
                    if fired < r.need - r.have then
                        pend[key] = {have=r.have, fired=fired + 1, t=p and p.t or tick(), shelf=shelf}
                        pickShelf(shelf)
                        stats.picks = stats.picks + 1
                        task.wait(S.Delay)
                    elseif tick() - p.t > 2 then
                        bad[p.shelf] = tick()
                        pend[key] = nil
                        dbg("pick had no effect on", p.shelf.Name)
                    end
                end
            else
                missing = true
            end
        end
    end
    -- only press the register once the customer is actually standing at it
    if S.Checkout and not needsGrab and (not missing or S.SkipOut) and regDist and regDist <= 9 then
        pressRegister(plot)
    end
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
        if S.Checkout then pressRegister(myPlot()) end
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

---------------------------------------------------------------- popups: day summary "Continue" + electric bill "Pay now"
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
                    task.wait(0.8)   -- let the summary animation finish
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
                if eb.Enabled then R.ElectricityChoice:FireServer("pay") end   -- fallback if the button press did not register
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

---------------------------------------------------------------- movement tasks (shared helpers)
local fail = {}
local function failed(k) return fail[k] and tick() - fail[k] < 10 end

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

local function standAt(hrp, pos)
    hrp.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
end

---------------------------------------------------------------- pickup of shop deliveries
-- Deliveries show up in TruckBay for only a couple of seconds and the prompt reaches 14 studs,
-- so we catch it the moment it spawns, hop over, grab it and hop back.
local pickups, trackedPlot = {}, nil
local function trackPickups(plot)
    if trackedPlot == plot then return end
    trackedPlot = plot
    for _, d in ipairs(plot:GetDescendants()) do
        if d:IsA("ProximityPrompt") and d.Name == "PickupPrompt" then pickups[d] = true end
    end
    bind(plot.DescendantAdded, function(d)
        if d:IsA("ProximityPrompt") and d.Name == "PickupPrompt" then pickups[d] = true end
    end)
end

local function hasPickup()
    for d in pairs(pickups) do
        if d.Parent and d:IsDescendantOf(workspace) then return true end
        pickups[d] = nil
    end
    return false
end

local function pickupPass()
    local hrp = myHRP()
    if not hrp then return false end
    local home, did = hrp.CFrame, false
    for d in pairs(pickups) do
        if d.Parent and d:IsDescendantOf(workspace) then
            local part = d.Parent
            local pos = part:IsA("BasePart") and part.Position or part:GetPivot().Position
            for _ = 1, 3 do
                if not (d.Parent and d:IsDescendantOf(workspace)) then break end
                standAt(hrp, pos)
                task.wait(0.15)
                fireproximityprompt(d)
                local t = tick()
                while d.Parent and d:IsDescendantOf(workspace) and tick() - t < 0.8 do task.wait(0.05) end
            end
            if not (d.Parent and d:IsDescendantOf(workspace)) then
                stats.picked = stats.picked + 1
                did = true
                dbg("Picked up delivery", d.ObjectText)
            end
        end
        pickups[d] = nil
    end
    hrp.CFrame = home
    return did
end

---------------------------------------------------------------- trash: throw away empty boxes
-- The trash can asks for confirmation. We let the game open its dialog and press its own "Throw Away" button.
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
    for _, d in ipairs(plot:GetDescendants()) do
        if d:IsA("ProximityPrompt") and d.Name == "TrashPrompt" then trashCache = d return d end
    end
end

local function trashPass(plot)
    local pr = trashPrompt(plot)
    local hrp = myHRP()
    if not pr or not hrp then return false end
    local function empties() return toolsWhere(function(t) return t:GetAttribute("IsEmptyBox") end) end
    if #empties() == 0 then return false end
    local home, moved, did = hrp.CFrame, false, false
    local base = pr.Parent
    if base:IsA("BasePart") and (hrp.Position - base.Position).Magnitude > pr.MaxActivationDistance - 4 then
        standAt(hrp, base.Position)
        moved = true
        task.wait(0.2)
    end
    for _ = 1, 40 do
        if not (alive and S.Trash) or (S.Pickup and hasPickup()) then break end
        local box = empties()[1]
        if not box then break end
        if not equip(box) then break end
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
    if moved then hrp.CFrame = home end
    return did
end

---------------------------------------------------------------- smart restock (uses the boxes in your backpack)
-- Mirrors the game's boxActionFor: category must match, shelf must be empty or hold the same product,
-- and at most 2 shelves per product (1 for rice).
local function targetShelf(plot, box, pid, hrp)
    local prod = DC.getProduct(pid)
    local cat = box:GetAttribute("ShelfCategory") or (prod and prod.category) or "general"
    local exclusive = DC.isExclusiveBox and DC.isExclusiveBox(pid)
    local claimed, mine, empties = 0, {}, {}
    for _, m in ipairs(shelves(plot)) do
        if (m:GetAttribute("Category") or "general") == cat then
            local sp = m:GetAttribute("ProductId") or ""
            local stock = m:GetAttribute("Stock") or 0
            local cap = m:GetAttribute("Capacity") or 0
            local usable = cap > 0 and not failed(m) and m:FindFirstChild("RestockPrompt", true)
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
            local d = (m:GetPivot().Position - hrp.Position).Magnitude
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

-- lowest shelf fill ratio for a product; -1 if it has no shelf at all (most urgent)
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

local function restockPass(plot)
    local hrp = myHRP()
    if not hrp then return false end
    local boxes = collectBoxes()
    if #boxes == 0 then return false end
    local rank = {}
    for _, b in ipairs(boxes) do rank[b] = urgency(plot, b:GetAttribute("ProductId")) end
    table.sort(boxes, function(a, b) return rank[a] < rank[b] end)
    local home, moved, did = hrp.CFrame, false, false
    for _, box in ipairs(boxes) do
        local pid = box:GetAttribute("ProductId")
        for _ = 1, 14 do
            if not alive or not S.Restock or (S.Pickup and hasPickup()) then break end
            if not box.Parent or (box:GetAttribute("Count") or 0) <= 0 then break end
            local shelf = targetShelf(plot, box, pid, hrp)
            if not shelf then break end
            local pr = shelf:FindFirstChild("RestockPrompt", true)
            local base = pr.Parent
            if base:IsA("BasePart") and (hrp.Position - base.Position).Magnitude > pr.MaxActivationDistance - 4 then
                standAt(hrp, base.Position)
                moved = true
                task.wait(0.2)
            end
            if not equip(box) then break end
            local before = shelf:GetAttribute("Stock") or 0
            fireproximityprompt(pr)
            local t = tick()
            while tick() - t < 1.3 and (shelf:GetAttribute("Stock") or 0) == before do task.wait(0.05) end
            local after = shelf:GetAttribute("Stock") or 0
            if after ~= before then
                stats.restocked = stats.restocked + math.max(0, after - before)
                did = true
                dbg("Restocked", pid, "->", shelf.Name, before, "=>", after)
            else
                fail[shelf] = tick()
                dbg("Restock failed", pid, shelf.Name)
            end
        end
    end
    if moved then hrp.CFrame = home end
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
        pr:InputHoldBegin()
        task.wait(pr.HoldDuration + 0.35)
        pr:InputHoldEnd()
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
    local home = hrp.CFrame
    for _, pr in ipairs(todo) do
        if not (alive and S.Clean) or (S.Pickup and hasPickup()) then break end
        local part = pr.Parent
        local pos = part:IsA("BasePart") and part.Position or part:GetPivot().Position
        local toolName = (pr:GetAttribute("CleanArea") == "outdoor") and "BroomStick" or "Broom"
        local tool = getTool(toolName)
        if not tool then
            local holder = plot:FindFirstChild(toolName == "Broom" and "BroomModel" or "BroomStickModel")
            local gp = holder and holder:FindFirstChild("CleaningPrompt", true)
            if gp and gp.Parent:IsA("BasePart") then
                standAt(hrp, gp.Parent.Position)
                task.wait(0.25)
                holdPrompt(gp)
                task.wait(0.5)
                tool = getTool(toolName)
            end
        end
        if tool and equip(tool) then
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
    hrp.CFrame = home
    return true
end

---------------------------------------------------------------- scheduler (one thing moves you at a time)
local nextChore = 0
task.spawn(function()
    while alive do
        task.wait(0.25)
        pcall(function()
            local plot = myPlot()
            if not plot or not lp.Character then return end
            if S.Pickup then
                trackPickups(plot)
                if hasPickup() then pickupPass() return end
            end
            if tick() < grabBusyUntil or tick() < nextChore then return end   -- stay at the counter while grabbing
            nextChore = tick() + 1
            local did = false
            if S.Trash then did = trashPass(plot) or did end
            if S.Restock then did = restockPass(plot) or did end
            if S.Clean then did = cleanPass(plot) or did end
            if did then
                local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
                if hum then hum:UnequipTools() end
            end
        end)
    end
end)

---------------------------------------------------------------- smart buying from the shop
-- Uses the store's own stock report and only buys what you do not already hold (units you own in boxes are
-- subtracted first). The game allows ONE delivery at a time, so everything goes into a single order, and
-- the next order waits until the truck has been emptied. Capped by the market limit and your cash reserve.
local buyFail, lastRes, nextBuyAt = {}, nil, 0
bind(R.PurchaseResult.OnClientEvent, function(ok, msg) lastRes = {ok, msg} end)

local function handUnits(pid)
    local n = 0
    for _, t in ipairs(toolsWhere(function(t) return t:GetAttribute("IsRestockBox") and t:GetAttribute("ProductId") == pid end)) do
        n = n + (t:GetAttribute("Count") or 0)
    end
    return n
end

local function placeOrder(items)
    lastRes = nil
    R.PurchaseOrder:FireServer(items)
    local t = tick()
    while not lastRes and tick() - t < 3 do task.wait(0.1) end
    return lastRes and lastRes[1] == true, lastRes and lastRes[2]
end

local function smartBuy()
    if tick() < nextBuyAt or hasPickup() then return end
    local ok, rep = pcall(function() return R.GetStockReport:InvokeServer() end)
    if not ok or typeof(rep) ~= "table" then return end
    local list = {}
    for _, e in ipairs(rep.outOfStock or {}) do list[#list+1] = {e=e, out=true} end
    for _, e in ipairs(rep.lowStock or {}) do list[#list+1] = {e=e, out=false} end
    local budget = (money() - S.Reserve) * 0.4
    local items, total = {}, 0
    for _, it in ipairs(list) do
        if budget <= 0 or #items >= 8 then break end
        local e = it.e
        local prod = DC.getProduct(e.id)
        if prod and not (buyFail[e.id] and tick() - buyFail[e.id] < 120) then
            local size = DC.getBoxSize(prod) or 10
            local cap = prod.shelfCap or 8
            local slots = (prod.category == "rice") and 1 or 2
            local need = it.out and (cap * slots) or (cap * slots - (e.stock or 0))
            local deficit = need - math.max(e.box or 0, handUnits(e.id))
            if deficit > 0 then
                local limitOk, lim = pcall(DC.marketStockLimit, e.id)
                local boxes = math.min(math.ceil(deficit / size), (limitOk and tonumber(lim)) or 3, 5)
                local unit = (prod.buy or 0) * ((lp:GetAttribute("HotItem") == e.id) and 1.2 or 1)
                local cost = math.max(unit * size, 1)
                boxes = math.min(boxes, math.floor(budget / cost))
                if boxes >= 1 then
                    items[#items+1] = {id=e.id, qty=boxes}
                    budget = budget - cost * boxes
                    total = total + boxes
                end
            end
        end
    end
    if #items == 0 then nextBuyAt = tick() + 10 return end
    local success, msg = placeOrder(items)
    if not success and not tostring(msg):find("on its way", 1, true) then
        -- something in the order was refused (licence / market limit): try the items one at a time
        for _, item in ipairs(items) do
            local s2, m2 = placeOrder({item})
            if s2 then success, total, items = true, item.qty, {item} break end
            if tostring(m2):find("on its way", 1, true) then msg = m2 break end
            buyFail[item.id] = tick()
            dbg("Order refused for", item.id, tostring(m2))
        end
    end
    if success then
        stats.bought = stats.bought + total
        nextBuyAt = tick() + 25
        local names = {}
        for _, i in ipairs(items) do names[#names+1] = i.id .. "x" .. i.qty end
        dbg("Ordered:", table.concat(names, ", "))
    elseif tostring(msg):find("on its way", 1, true) then
        nextBuyAt = tick() + 8
    else
        nextBuyAt = tick() + 20
    end
end

task.spawn(function()
    task.wait(5)
    while alive do
        if S.Buy then pcall(smartBuy) end
        for _ = 1, 10 do if not alive then break end task.wait(1) end
    end
end)

---------------------------------------------------------------- UI
local Win = Rayfield:CreateWindow({Name="Sari-Sari Auto v2.3", LoadingTitle="Sari-Sari Auto v2.3", ConfigurationSaving={Enabled=false}})
local T = Win:CreateTab("Main")
local function tog(name, key)
    T:CreateToggle({Name=name, CurrentValue=S[key], Callback=function(v) S[key]=v applyUI() end})
end
tog("Auto Grab (skip out-of-stock)", "Grab")
tog("Auto Register + Exact Change", "Checkout")
tog("Auto KashG (accept real / decline fake)", "KashG")
tog("Auto Accept Utang", "Utang")
tog("Auto E-Load (no phone UI)", "Load")
tog("Auto Clean Dust / Leaves", "Clean")
tog("Auto Restock shelves from backpack", "Restock")
tog("Auto Throw Away empty boxes", "Trash")
tog("Auto Pick Up shop deliveries", "Pickup")
tog("Smart Buy (shop restock)", "Buy")
tog("Auto Pay Electric Bill", "Bill")
tog("Auto Continue (day summary)", "Continue")
tog("Auto Claim Daily Tasks", "Tasks")
tog("Hide game popups (register / KashG / Utang)", "HideUI")
tog("Checkout even if an item is out of stock", "SkipOut")
T:CreateSlider({Name="Keep this much cash when buying (P)", Range={0,10000}, Increment=250, CurrentValue=S.Reserve, Callback=function(v) S.Reserve=v end})
T:CreateSlider({Name="Refill shelf when below (%)", Range={10,100}, Increment=5, Suffix="%", CurrentValue=S.Pct, Callback=function(v) S.Pct=v end})
T:CreateSlider({Name="Action Delay", Range={0.03,1}, Increment=0.01, CurrentValue=S.Delay, Callback=function(v) S.Delay=v end})
local lbl1 = T:CreateLabel("Starting...")
local lbl2 = T:CreateLabel("")

task.spawn(function()
    while alive do
        pcall(function()
            lbl1:Set(string.format("Served %d | Picks %d | Change P%d | KashG +%d/-%d | Load %d (fail %d) | Utang %d",
                stats.served, stats.picks, stats.change, stats.kashOk, stats.kashNo, stats.loads, stats.loadFail, stats.utang))
            lbl2:Set(string.format("Restocked %d | Bought %d | Picked up %d | Trashed %d | Cleaned %d | Tasks %d | Bills %d | Days %d",
                stats.restocked, stats.bought, stats.picked, stats.trashed, stats.cleaned, stats.claimed, stats.bills, stats.continued))
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
    pcall(function() Rayfield:Destroy() end)
end
