--[[
    ================================================================
    Simple Anti-AFK with UI (Mobile & PC Optimized)
    - Full Touch & Mouse support
    - Minimize / Floating Pill mode for mobile screens
    - Prevents 20-minute inactivity kicks in Roblox
    ================================================================
]]

local Players = game:GetService("Players")
local VirtualUser = game:GetService("VirtualUser")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer

-- GUI Container resolution (Supports Delta, Codex, Fluxus, Arceus X, etc.)
local parentGui
if gethui then
    parentGui = gethui()
elseif syn and syn.protect_gui then
    parentGui = CoreGui
else
    pcall(function()
        parentGui = CoreGui
    end)
    if not parentGui then
        parentGui = LocalPlayer:WaitForChild("PlayerGui")
    end
end

-- Destroy any previous instance
local existing = parentGui:FindFirstChild("SimpleAntiAFK_UI")
if existing then
    existing:Destroy()
end

-- State variables
local isAntiAfkEnabled = true
local scriptRunning = true
local isMinimized = false
local startTime = os.time()
local idledConnection = nil

-- Create ScreenGui
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "SimpleAntiAFK_UI"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

if syn and syn.protect_gui then
    syn.protect_gui(screenGui)
end
screenGui.Parent = parentGui

-- Main Card Frame
local mainFrame = Instance.new("Frame")
mainFrame.Name = "MainFrame"
mainFrame.Size = UDim2.new(0, 230, 0, 145)
mainFrame.Position = UDim2.new(0.05, 0, 0.25, 0)
mainFrame.BackgroundColor3 = Color3.fromRGB(22, 23, 27)
mainFrame.BorderSizePixel = 0
mainFrame.Active = true
mainFrame.ClipsDescendants = true
mainFrame.Parent = screenGui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 10)
mainCorner.Parent = mainFrame

local mainStroke = Instance.new("UIStroke")
mainStroke.Color = Color3.fromRGB(50, 53, 62)
mainStroke.Thickness = 1
mainStroke.Parent = mainFrame

-- Top Bar (Drag handle)
local topBar = Instance.new("Frame")
topBar.Name = "TopBar"
topBar.Size = UDim2.new(1, 0, 0, 36)
topBar.BackgroundColor3 = Color3.fromRGB(28, 30, 36)
topBar.BorderSizePixel = 0
topBar.Parent = mainFrame

local topBarCorner = Instance.new("UICorner")
topBarCorner.CornerRadius = UDim.new(0, 10)
topBarCorner.Parent = topBar

local topBarFix = Instance.new("Frame")
topBarFix.Size = UDim2.new(1, 0, 0, 10)
topBarFix.Position = UDim2.new(0, 0, 1, -10)
topBarFix.BackgroundColor3 = Color3.fromRGB(28, 30, 36)
topBarFix.BorderSizePixel = 0
topBarFix.Parent = topBar

-- Status Indicator Dot
local dot = Instance.new("Frame")
dot.Name = "Dot"
dot.Size = UDim2.new(0, 9, 0, 9)
dot.Position = UDim2.new(0, 12, 0.5, -4)
dot.BackgroundColor3 = Color3.fromRGB(46, 204, 113)
dot.BorderSizePixel = 0
dot.Parent = topBar

local dotCorner = Instance.new("UICorner")
dotCorner.CornerRadius = UDim.new(1, 0)
dotCorner.Parent = dot

-- Title Text
local title = Instance.new("TextLabel")
title.Name = "Title"
title.Size = UDim2.new(1, -95, 1, 0)
title.Position = UDim2.new(0, 28, 0, 0)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.Text = "ANTI-AFK"
title.TextColor3 = Color3.fromRGB(240, 240, 245)
title.TextSize = 13
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = topBar

-- Minimize Button (Touch friendly)
local minBtn = Instance.new("TextButton")
minBtn.Name = "MinButton"
minBtn.Size = UDim2.new(0, 30, 0, 30)
minBtn.Position = UDim2.new(1, -64, 0.5, -15)
minBtn.BackgroundTransparency = 1
minBtn.Font = Enum.Font.GothamBold
minBtn.Text = "−"
minBtn.TextColor3 = Color3.fromRGB(160, 160, 175)
minBtn.TextSize = 18
minBtn.Parent = topBar

-- Close Button
local closeBtn = Instance.new("TextButton")
closeBtn.Name = "CloseButton"
closeBtn.Size = UDim2.new(0, 30, 0, 30)
closeBtn.Position = UDim2.new(1, -32, 0.5, -15)
closeBtn.BackgroundTransparency = 1
closeBtn.Font = Enum.Font.GothamBold
closeBtn.Text = "✕"
closeBtn.TextColor3 = Color3.fromRGB(160, 160, 175)
closeBtn.TextSize = 14
closeBtn.Parent = topBar

-- Content Area
local content = Instance.new("Frame")
content.Name = "Content"
content.Size = UDim2.new(1, -20, 1, -44)
content.Position = UDim2.new(0, 10, 0, 40)
content.BackgroundTransparency = 1
content.Parent = mainFrame

-- Status Label
local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "StatusLabel"
statusLabel.Size = UDim2.new(1, 0, 0, 18)
statusLabel.Position = UDim2.new(0, 0, 0, 2)
statusLabel.BackgroundTransparency = 1
statusLabel.Font = Enum.Font.GothamMedium
statusLabel.Text = "Status: Active"
statusLabel.TextColor3 = Color3.fromRGB(46, 204, 113)
statusLabel.TextSize = 12
statusLabel.TextXAlignment = Enum.TextXAlignment.Center
statusLabel.Parent = content

-- Time Protected Label
local timerLabel = Instance.new("TextLabel")
timerLabel.Name = "TimerLabel"
timerLabel.Size = UDim2.new(1, 0, 0, 16)
timerLabel.Position = UDim2.new(0, 0, 0, 22)
timerLabel.BackgroundTransparency = 1
timerLabel.Font = Enum.Font.Gotham
timerLabel.Text = "Time Active: 00:00:00"
timerLabel.TextColor3 = Color3.fromRGB(160, 165, 175)
timerLabel.TextSize = 11
timerLabel.TextXAlignment = Enum.TextXAlignment.Center
timerLabel.Parent = content

-- Toggle Button (Larger touch target)
local toggleBtn = Instance.new("TextButton")
toggleBtn.Name = "ToggleButton"
toggleBtn.Size = UDim2.new(1, 0, 0, 34)
toggleBtn.Position = UDim2.new(0, 0, 1, -34)
toggleBtn.BackgroundColor3 = Color3.fromRGB(39, 174, 96)
toggleBtn.BorderSizePixel = 0
toggleBtn.Font = Enum.Font.GothamBold
toggleBtn.Text = "ENABLED"
toggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
toggleBtn.TextSize = 13
toggleBtn.AutoButtonColor = false
toggleBtn.Parent = content

local toggleCorner = Instance.new("UICorner")
toggleCorner.CornerRadius = UDim.new(0, 7)
toggleCorner.Parent = toggleBtn

-- Update Visual State
local function updateUI()
    if isAntiAfkEnabled then
        statusLabel.Text = "Status: Active"
        statusLabel.TextColor3 = Color3.fromRGB(46, 204, 113)
        dot.BackgroundColor3 = Color3.fromRGB(46, 204, 113)
        toggleBtn.Text = "ENABLED"
        TweenService:Create(toggleBtn, TweenInfo.new(0.2), {
            BackgroundColor3 = Color3.fromRGB(39, 174, 96)
        }):Play()
    else
        statusLabel.Text = "Status: Disabled"
        statusLabel.TextColor3 = Color3.fromRGB(231, 76, 60)
        dot.BackgroundColor3 = Color3.fromRGB(231, 76, 60)
        toggleBtn.Text = "DISABLED"
        TweenService:Create(toggleBtn, TweenInfo.new(0.2), {
            BackgroundColor3 = Color3.fromRGB(48, 51, 60)
        }):Play()
    end
end

toggleBtn.MouseButton1Click:Connect(function()
    isAntiAfkEnabled = not isAntiAfkEnabled
    updateUI()
end)

-- Minimize / Expand Handler for Mobile
minBtn.MouseButton1Click:Connect(function()
    isMinimized = not isMinimized
    if isMinimized then
        content.Visible = false
        minBtn.Text = "+"
        TweenService:Create(mainFrame, TweenInfo.new(0.2), {
            Size = UDim2.new(0, 230, 0, 36)
        }):Play()
    else
        minBtn.Text = "−"
        local tween = TweenService:Create(mainFrame, TweenInfo.new(0.2), {
            Size = UDim2.new(0, 230, 0, 145)
        })
        tween:Play()
        tween.Completed:Connect(function()
            if not isMinimized then
                content.Visible = true
            end
        end)
    end
end)

-- Mobile & PC Draggable Logic
local dragging = false
local dragStart = nil
local startPos = nil

topBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = mainFrame.Position

        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        mainFrame.Position = UDim2.new(
            startPos.X.Scale,
            startPos.X.Offset + delta.X,
            startPos.Y.Scale,
            startPos.Y.Offset + delta.Y
        )
    end
end)

-- Anti-AFK Listener
local function setupAntiAfk()
    if idledConnection then
        idledConnection:Disconnect()
    end
    
    idledConnection = LocalPlayer.Idled:Connect(function()
        if isAntiAfkEnabled then
            pcall(function()
                VirtualUser:CaptureController()
                VirtualUser:ClickButton2(Vector2.zero)
            end)
        end
    end)
end

setupAntiAfk()

-- Background fallback heartbeat (every 10 minutes)
task.spawn(function()
    while scriptRunning do
        task.wait(600)
        if scriptRunning and isAntiAfkEnabled then
            pcall(function()
                VirtualUser:CaptureController()
                VirtualUser:ClickButton2(Vector2.zero)
            end)
        end
    end
end)

-- Live Uptime Timer Loop
task.spawn(function()
    while scriptRunning do
        local elapsed = os.time() - startTime
        local hours = math.floor(elapsed / 3600)
        local mins = math.floor((elapsed % 3600) / 60)
        local secs = elapsed % 60
        timerLabel.Text = string.format("Time Active: %02d:%02d:%02d", hours, mins, secs)
        task.wait(1)
    end
end)

-- Clean exit on close
closeBtn.MouseButton1Click:Connect(function()
    scriptRunning = false
    if idledConnection then
        idledConnection:Disconnect()
        idledConnection = nil
    end
    screenGui:Destroy()
end)
