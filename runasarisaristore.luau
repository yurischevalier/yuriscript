local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local lp = Players.LocalPlayer
local R = RS.SariSariStore.Remotes
local DC = require(RS.SariSariStore.Modules.DataConfig)

local S = {Grab=true, Checkout=true, KashG=true, Utang=true, Load=true, Clean=true, Restock=true, HideUI=true, SkipOut=true, Delay=0.05, Pct=100}
local alive = true
local conns = {}
local stats = {served=0, change=0, kashOk=0, kashNo=0, loads=0, loadFail=0, utang=0, cleaned=0, restocked=0, picks=0}

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
    return best, brows
end

local lastPress = 0
local function pressRegister(plot)
    if tick() - lastPress < 0.3 then return end
    lastPress = tick()
    local reg = plot and plot:FindFirstChild("CashRegister")
    if reg then R.RegisterPress:FireServer(reg) end
end

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
    local c, rows = orderCustomer(plot)
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
                    if p and p.have ~= r.have then p = nil pend[key] = nil end  -- server accepted a pick
                    local fired = p and p.fired or 0
                    if fired < r.need - r.have then
                        pend[key] = {have=r.have, fired=fired + 1, t=p and p.t or tick(), shelf=shelf}
                        pickShelf(shelf)
                        stats.picks = stats.picks + 1
                        task.wait(S.Delay)
                    elseif tick() - p.t > 2 then
                        bad[p.shelf] = tick()   -- nothing happened: try another shelf next time
                        pend[key] = nil
                        dbg("pick had no effect on", p.shelf.Name)
                    end
                end
            else
                missing = true   
            end
        end
    end
    if S.Checkout and not needsGrab and (not missing or S.SkipOut) then
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

local function collectBoxes()
    local out = {}
    for _, holder in ipairs({lp.Backpack, lp.Character}) do
        if holder then
            for _, t in ipairs(holder:GetChildren()) do
                if t:IsA("Tool") and t:GetAttribute("IsRestockBox") and (t:GetAttribute("Count") or 0) > 0 then
                    out[#out+1] = t
                end
            end
        end
    end
    return out
end

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

local function restockPass(plot)
    local hrp = myHRP()
    if not hrp then return false end
    local boxes = collectBoxes()
    if #boxes == 0 then return false end
    local home, moved, did = hrp.CFrame, false, false
    for _, box in ipairs(boxes) do
        local pid = box:GetAttribute("ProductId")
        for _ = 1, 14 do
            if not alive or not S.Restock then break end
            if not box.Parent or (box:GetAttribute("Count") or 0) <= 0 then break end
            local shelf = targetShelf(plot, box, pid, hrp)
            if not shelf then break end
            local pr = shelf:FindFirstChild("RestockPrompt", true)
            local base = pr.Parent
            if base:IsA("BasePart") and (hrp.Position - base.Position).Magnitude > pr.MaxActivationDistance - 4 then
                hrp.CFrame = CFrame.new(base.Position + Vector3.new(0, 3, 0))
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
        if not (alive and S.Clean) then break end
        local part = pr.Parent
        local pos = part:IsA("BasePart") and part.Position or part:GetPivot().Position
        local toolName = (pr:GetAttribute("CleanArea") == "outdoor") and "BroomStick" or "Broom"
        local tool = getTool(toolName)
        if not tool then
            local holder = plot:FindFirstChild(toolName == "Broom" and "BroomModel" or "BroomStickModel")
            local gp = holder and holder:FindFirstChild("CleaningPrompt", true)
            if gp and gp.Parent:IsA("BasePart") then
                hrp.CFrame = CFrame.new(gp.Parent.Position + Vector3.new(0, 3, 0))
                task.wait(0.25)
                holdPrompt(gp)
                task.wait(0.5)
                tool = getTool(toolName)
            end
        end
        if tool and equip(tool) then
            local t = tick()
            while not pr.Enabled and tick() - t < 1 do task.wait(0.05) end
            hrp.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
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

task.spawn(function()
    while alive do
        task.wait(1)
        -- don't walk away from the counter while an order is being grabbed
        if (S.Clean or S.Restock) and lp.Character and tick() > grabBusyUntil then
            pcall(function()
                local plot = myPlot()
                if not plot then return end
                local did = false
                if S.Restock then did = restockPass(plot) or did end
                if S.Clean then did = cleanPass(plot) or did end
                if did then
                    local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
                    if hum then hum:UnequipTools() end
                end
            end)
        end
    end
end)

local Win = Rayfield:CreateWindow({Name="Sari-Sari Auto v2.2", LoadingTitle="Sari-Sari Auto v2.2", ConfigurationSaving={Enabled=false}})
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
tog("Hide game popups (register / KashG / Utang)", "HideUI")
tog("Checkout even if an item is out of stock", "SkipOut")
T:CreateSlider({Name="Refill shelf when below (%)", Range={10,100}, Increment=5, Suffix="%", CurrentValue=S.Pct, Callback=function(v) S.Pct=v end})
T:CreateSlider({Name="Action Delay", Range={0.03,1}, Increment=0.01, CurrentValue=S.Delay, Callback=function(v) S.Delay=v end})
local lbl = T:CreateLabel("Starting...")

task.spawn(function()
    while alive do
        pcall(function()
            lbl:Set(string.format("Served %d | Picks %d | Change P%d | KashG +%d/-%d | Load %d (fail %d) | Utang %d | Cleaned %d | Restocked %d",
                stats.served, stats.picks, stats.change, stats.kashOk, stats.kashNo, stats.loads, stats.loadFail, stats.utang, stats.cleaned, stats.restocked))
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
