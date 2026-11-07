--[[
    JASecrets v2.0
    Executor : Any (Synapse X / KRNL / Fluxus / Solara / Delta)
    What it does:
        - Scans workspace every tick for bond/collectible parts
        - Teleports character directly onto each one to trigger .Touched
        - Fires ProximityPrompts if present
        - Loops forever, respawn-safe, toggle via INSERT (PC) or HUD button (mobile)
        - Clean JASecrets titled UI, no aimbot
--]]

------------------------------------------------------------------------
-- SERVICES
------------------------------------------------------------------------
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local Workspace        = game:GetService("Workspace")

------------------------------------------------------------------------
-- DELTA / EXECUTOR COMPAT
------------------------------------------------------------------------
local safeParent = (typeof(gethui) == "function") and gethui()
                or (pcall(function() return game:GetService("CoreGui") end) and game:GetService("CoreGui"))
                or Players.LocalPlayer.PlayerGui

local fireProx   = (typeof(fireproximityprompt)   == "function" and fireproximityprompt)
                or (typeof(fire_proximity_prompt)  == "function" and fire_proximity_prompt)
                or nil

------------------------------------------------------------------------
-- CONFIG
------------------------------------------------------------------------
local CFG = {
    -- bond/collectible name fragments (lowercase matched)
    Keywords = {
        "bond","cash","coin","gem","orb","token","reward",
        "pickup","collect","note","bill","dollar","badge",
        "drop","item","money","credit","chest","loot",
        "government","treasury","saving","certificate",
    },

    IgnoreList     = {},       -- exact part names to never touch
    MaxScan        = 80,       -- max candidates evaluated per tick
    TPOffset       = Vector3.new(0, 2, 0),  -- land above item, avoid floor clip
    CollectWait    = 0.02,     -- seconds to settle after TP before next
    RespawnWait    = 2.0,
    ScanRate       = 0.04,     -- seconds between full scans (25 hz)

    -- PC toggle
    ToggleKey      = Enum.KeyCode.Insert,
}

------------------------------------------------------------------------
-- STATE
------------------------------------------------------------------------
local LP        = Players.LocalPlayer
local running   = false
local collected = 0
local status    = "paused"
local lastScan  = 0

------------------------------------------------------------------------
-- UTIL
------------------------------------------------------------------------
local function getRoot()
    local c = LP.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function getHum()
    local c = LP.Character
    return c and c:FindFirstChildOfClass("Humanoid")
end
local function kw(name)
    name = name:lower()
    for _, k in ipairs(CFG.Keywords) do
        if name:find(k, 1, true) then return true end
    end
    return false
end
local function ignored(name)
    for _, v in ipairs(CFG.IgnoreList) do
        if v == name then return true end
    end
    return false
end

------------------------------------------------------------------------
-- SCANNER — returns parts sorted nearest first
------------------------------------------------------------------------
local function scan()
    local root = getRoot()
    if not root then return {} end
    local origin = root.Position
    local out    = {}
    local n      = 0

    for _, obj in ipairs(Workspace:GetDescendants()) do
        if n >= CFG.MaxScan then break end
        local name = obj.Name
        if not ignored(name) and kw(name) then
            local part
            if obj:IsA("BasePart") or obj:IsA("MeshPart") then
                part = obj
            elseif obj:IsA("Model") then
                part = obj.PrimaryPart or obj:FindFirstChildOfClass("BasePart")
            end
            if part then
                n = n + 1
                table.insert(out, {
                    part = part,
                    dist = (origin - part.Position).Magnitude,
                    pos  = part.Position,
                })
            end
        end
    end

    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end

------------------------------------------------------------------------
-- PROXIMITY FIRE
------------------------------------------------------------------------
local function firePrompts(part)
    local function tryOn(p)
        for _, obj in ipairs(p:GetDescendants()) do
            if obj:IsA("ProximityPrompt") then
                if fireProx then pcall(fireProx, obj) end
                pcall(function()
                    obj:InputHoldBegin()
                    task.wait(obj.HoldDuration + 0.05)
                    obj:InputHoldEnd()
                end)
            end
        end
    end
    tryOn(part)
    if part.Parent and part.Parent ~= Workspace then tryOn(part.Parent) end
end

------------------------------------------------------------------------
-- COLLECT — TP onto part, fire touch + prompts
------------------------------------------------------------------------
local function collect(candidate)
    local part = candidate.part
    if not part or not part.Parent then return end

    local root = getRoot()
    if not root then return end

    -- teleport directly onto part
    root.CFrame = CFrame.new(part.Position + CFG.TPOffset)
    task.wait(CFG.CollectWait)

    -- fire prompts if still alive
    if part.Parent then
        firePrompts(part)
    end

    task.wait(0.01)
    if not part.Parent then
        collected = collected + 1
    end
end

------------------------------------------------------------------------
-- FARM LOOP
------------------------------------------------------------------------
local function farmLoop()
    while true do
        task.wait(0.01)

        if not running then
            status = "paused"
            task.wait(0.2)
            continue
        end

        local hum = getHum()
        if not hum or hum.Health <= 0 then
            status = "respawning…"
            task.wait(CFG.RespawnWait)
            continue
        end

        local now = tick()
        if now - lastScan < CFG.ScanRate then
            task.wait(CFG.ScanRate - (now - lastScan))
            continue
        end
        lastScan = tick()

        local targets = scan()
        if #targets == 0 then
            status = "scanning… 0 targets"
            task.wait(0.3)
            continue
        end

        status = string.format("running — %d bonds", #targets)

        -- slam through ALL targets this scan instead of one at a time
        -- re-checks parent each time so claimed ones are skipped clean
        for _, t in ipairs(targets) do
            if not running then break end
            if t.part and t.part.Parent then
                collect(t)
            end
        end
    end
end

------------------------------------------------------------------------
-- GUI
------------------------------------------------------------------------
local hudLabel
local toggleBtn

local function buildGUI()
    local gui = Instance.new("ScreenGui")
    gui.Name           = "JASecrets"
    gui.ResetOnSpawn   = false
    gui.IgnoreGuiInset = true
    gui.Parent         = safeParent

    -- outer frame
    local frame = Instance.new("Frame")
    frame.Size                   = UDim2.new(0, 240, 0, 130)
    frame.Position               = UDim2.new(0, 12, 0.5, -65)
    frame.BackgroundColor3       = Color3.fromRGB(12, 12, 12)
    frame.BackgroundTransparency = 0.15
    frame.BorderSizePixel        = 0
    frame.Parent                 = gui
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

    -- title bar
    local titleBar = Instance.new("Frame")
    titleBar.Size            = UDim2.new(1, 0, 0, 32)
    titleBar.BackgroundColor3= Color3.fromRGB(22, 22, 22)
    titleBar.BorderSizePixel = 0
    titleBar.Parent          = frame
    Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 8)

    -- accent strip
    local accent = Instance.new("Frame")
    accent.Size             = UDim2.new(1, 0, 0, 2)
    accent.Position         = UDim2.new(0, 0, 1, -2)
    accent.BackgroundColor3 = Color3.fromRGB(180, 50, 255)
    accent.BorderSizePixel  = 0
    accent.Parent           = titleBar

    -- glow layer (fake blur)
    local glow = Instance.new("TextLabel")
    glow.Size                   = UDim2.new(1, 0, 1, 0)
    glow.BackgroundTransparency = 1
    glow.Text                   = "JASecrets"
    glow.TextColor3             = Color3.fromRGB(180, 50, 255)
    glow.TextTransparency       = 0.6
    glow.Font                   = Enum.Font.GothamBold
    glow.TextSize               = 18
    glow.TextXAlignment         = Enum.TextXAlignment.Center
    glow.ZIndex                 = 2
    glow.Parent                 = titleBar

    -- title text
    local title = Instance.new("TextLabel")
    title.Size                   = UDim2.new(1, 0, 1, 0)
    title.BackgroundTransparency = 1
    title.Text                   = "JASecrets"
    title.TextColor3             = Color3.fromRGB(255, 255, 255)
    title.Font                   = Enum.Font.GothamBold
    title.TextSize               = 15
    title.TextXAlignment         = Enum.TextXAlignment.Center
    title.ZIndex                 = 3
    title.Parent                 = titleBar

    -- status label
    hudLabel = Instance.new("TextLabel")
    hudLabel.Size                   = UDim2.new(1, -12, 0, 52)
    hudLabel.Position               = UDim2.new(0, 6, 0, 36)
    hudLabel.BackgroundTransparency = 1
    hudLabel.TextColor3             = Color3.fromRGB(80, 220, 80)
    hudLabel.Font                   = Enum.Font.GothamBold
    hudLabel.TextSize               = 13
    hudLabel.TextXAlignment         = Enum.TextXAlignment.Left
    hudLabel.TextYAlignment         = Enum.TextYAlignment.Top
    hudLabel.TextWrapped            = true
    hudLabel.Parent                 = frame

    -- START / STOP button
    toggleBtn = Instance.new("TextButton")
    toggleBtn.Size             = UDim2.new(1, -12, 0, 32)
    toggleBtn.Position         = UDim2.new(0, 6, 0, 92)
    toggleBtn.BackgroundColor3 = Color3.fromRGB(40, 160, 40)
    toggleBtn.TextColor3       = Color3.new(1, 1, 1)
    toggleBtn.Font             = Enum.Font.GothamBold
    toggleBtn.TextSize         = 15
    toggleBtn.Text             = "▶  START"
    toggleBtn.Parent           = frame
    Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0, 6)

    toggleBtn.MouseButton1Click:Connect(function()
        running = not running
        if running then
            toggleBtn.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
            toggleBtn.Text             = "■  STOP"
        else
            toggleBtn.BackgroundColor3 = Color3.fromRGB(40, 160, 40)
            toggleBtn.Text             = "▶  START"
        end
    end)

    -- drag by title bar
    local dragging, dragInput, dragStart, startPos
    titleBar.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging  = true
            dragStart = inp.Position
            startPos  = frame.Position
        end
    end)
    titleBar.InputChanged:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseMovement then
            dragInput = inp
        end
    end)
    titleBar.InputEnded:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = false
        end
    end)
    UserInputService.InputChanged:Connect(function(inp)
        if dragging and inp == dragInput then
            local d = inp.Position - dragStart
            frame.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + d.X,
                startPos.Y.Scale, startPos.Y.Offset + d.Y
            )
        end
    end)
end

------------------------------------------------------------------------
-- HUD UPDATER
------------------------------------------------------------------------
RunService.RenderStepped:Connect(function()
    if hudLabel then
        hudLabel.Text = string.format(
            "JASecrets Bond Farm\nStatus    : %s\nCollected : %d\n[INSERT] to toggle",
            status, collected
        )
    end
end)

------------------------------------------------------------------------
-- PC KEYBIND
------------------------------------------------------------------------
UserInputService.InputBegan:Connect(function(inp, gpe)
    if gpe then return end
    if inp.KeyCode == CFG.ToggleKey then
        running = not running
        if toggleBtn then
            if running then
                toggleBtn.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
                toggleBtn.Text             = "■  STOP"
            else
                toggleBtn.BackgroundColor3 = Color3.fromRGB(40, 160, 40)
                toggleBtn.Text             = "▶  START"
            end
        end
    end
end)

------------------------------------------------------------------------
-- BOOT
------------------------------------------------------------------------
buildGUI()
task.spawn(farmLoop)
print("[JASecrets] loaded — INSERT or tap START")
