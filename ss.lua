local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- AUTOMATIC CLEANUP
if _G.TerminateHybridScriptUI then _G.TerminateHybridScriptUI() end

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid")
local rootPart = character:WaitForChild("HumanoidRootPart")

local httpRequest = (syn and syn.request) or (http and http.request) or http_request or request
local setClipboard = setclipboard or toclipboard or function(text) print("Clipboard export not supported by executor. Output: " .. text) end
local delFile = delfile or function(path) writefile(path, "") end

-- HARDCODED/UNCHANGEABLE CONFIG
local SPOOF_NAME = "fvnito"
local MOVE_SPEED = 19
local PATH_RECOMPUTE_INTERVAL = 0.7
local FOLDER_NAME = "dungeonmacros"
local CONFIG_FILE = FOLDER_NAME .. "/config.json"

-- LIVE SETTINGS (Changeable via UI & Saved to Config)
local SETTINGS = {
    MinDistance = 15,
    MaxDistance = 20,
    AttackReach = 55,
    AttackCooldown = 0.9,
    DodgeBuffer = 2.5,
    WaypointTriggerDist = 120,
    MaxNodeDistance = 65,
    WallRayLength = 5.5,
    NoEnemyDelay = 7.0,
    Webhook = "",
    IgnoreKeywords = "ring1, ring2, ring3, ring4, ring5, ring6, part, Ring, Meshes"
}

-- STATE VARIABLES
local isAutoplay = true
local isRecording = false
local isCasting = false
local waypoints = {}
local visualNodes = {}
local currentWaypointIndex = 1
local traversingManualNodes = false
local selectedMacroName = ""
local connections = {}
local activeDodgePoint = nil
local dodgeExpiration = 0

-- PERFORMANCE OPTIMIZATIONS
local persistentIgnoreList = {character}
local activeHazards = {}
local cachedEnemies = {}
local lastEnemyScan = 0
local parsedIgnoreKeywords = {}

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true
raycastParams.FilterDescendantsInstances = persistentIgnoreList

if isfolder and makefolder and not isfolder(FOLDER_NAME) then makefolder(FOLDER_NAME) end

local function updateIgnoreKeywords()
    table.clear(parsedIgnoreKeywords)
    table.insert(parsedIgnoreKeywords, "macropathnode")
    if SETTINGS.IgnoreKeywords and SETTINGS.IgnoreKeywords ~= "" then
        for word in string.gmatch(SETTINGS.IgnoreKeywords, "([^,]+)") do
            local cleanWord = word:match("^%s*(.-)%s*$"):lower()
            if cleanWord ~= "" then
                table.insert(parsedIgnoreKeywords, cleanWord)
            end
        end
    end
end
updateIgnoreKeywords()

--------------------------------------------------------------------------------
-- REMOTE TRIGGERS & WEBHOOK HELPERS
--------------------------------------------------------------------------------
local function fireStartGameRemote()
    pcall(function()
        local remotes = ReplicatedStorage:WaitForChild("remotes", 5)
        if remotes then
            local changeStartValue = remotes:WaitForChild("changeStartValue", 2)
            if changeStartValue then changeStartValue:FireServer() end
        end
    end)
end

local function fireReplayDungeonRemote()
    pcall(function()
        local remotes = ReplicatedStorage:WaitForChild("remotes", 5)
        if remotes then
            local replayDungeon = remotes:WaitForChild("replayDungeon", 2)
            if replayDungeon then
                local currentDungeonName = "Volcanic Chambers"
                pcall(function()
                    local dObj = Workspace:FindFirstChild("dungeonName")
                    if dObj then
                        if dObj:IsA("StringValue") then currentDungeonName = dObj.Value
                        else currentDungeonName = tostring(dObj.Value or dObj) end
                    end
                end)

                replayDungeon:FireServer({
                    dungeonProgress = "bossKilled", dungeonStarted = true, hardcore = false,
                    dungeonFinished = true, dungeonName = currentDungeonName, isHardcore = false, fightingBoss = true
                })
            end
        end
    end)
end

local function formatNumber(n)
    return tostring(n):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

local runStartTime = tick()

local function sendRewardWebhook(rewardData)
    local url = SETTINGS.Webhook
    if not url or url == "" or not url:find("https://") then return end

    local itemsList = {}
    local goldAmount = rewardData.gold or 0

    if rewardData.items and type(rewardData.items) == "table" then
        for _, item in ipairs(rewardData.items) do
            if item.itemName ~= "gold" then
                local name = item.itemName or "Unknown Item"
                local rarity = item.rarity and ("[" .. item.rarity:upper() .. "]") or ""
                local tier = item.tier and ("(" .. item.tier .. ")") or ""
                local itemType = item.itemType and ("• " .. item.itemType) or ""
                table.insert(itemsList, string.format("• **%s** %s %s %s", name, rarity, tier, itemType))
            end
        end
    end

    local elapsed = tick() - runStartTime
    local minutes = math.floor(elapsed / 60)
    local seconds = math.floor(elapsed % 60)
    local timeText = string.format("%dm %ds", minutes, seconds)
    runStartTime = tick()

    local itemsText = #itemsList > 0 and table.concat(itemsList, "\n") or "None"
    local embedPayload = {
        ["username"] = "Dungeon Webhook",
        ["embeds"] = {{
            ["title"] = "Match Ended",
            ["color"] = 16766720,
            ["fields"] = {
                {["name"] = "Time", ["value"] = timeText, ["inline"] = false},
                {["name"] = "Gold Obtained", ["value"] = string.format("**%s** Gold", formatNumber(goldAmount)), ["inline"] = false},
                {["name"] = "Items Received", ["value"] = itemsText, ["inline"] = false}
            },
            ["timestamp"] = DateTime.now():ToIsoDate()
        }}
    }

    local success, encoded = pcall(function() return HttpService:JSONEncode(embedPayload) end)
    if success and httpRequest then
        task.spawn(function()
            httpRequest({ Url = url, Method = "POST", Headers = { ["Content-Type"] = "application/json" }, Body = encoded })
        end)
    end
end

task.spawn(function()
    local remotes = ReplicatedStorage:WaitForChild("remotes", 5)
    if remotes then
        local cloneRewardGui = remotes:WaitForChild("cloneRewardGui", 5)
        if cloneRewardGui then
            local conn = cloneRewardGui.OnClientEvent:Connect(function(data)
                if type(data) == "table" then sendRewardWebhook(data) end
            end)
            table.insert(connections, conn)
        end
    end
end)

--------------------------------------------------------------------------------
-- 1. MODERN UI SYSTEM
--------------------------------------------------------------------------------
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "DungeonMacroManager"
screenGui.ResetOnSpawn = false
screenGui.Parent = (pcall(function() return CoreGui.Name end) and CoreGui) or player:WaitForChild("PlayerGui")

local mainFrame = Instance.new("Frame")
mainFrame.Size = UDim2.new(0, 380, 0, 500)
mainFrame.Position = UDim2.new(0.5, -190, 0.4, -250)
mainFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
mainFrame.BorderSizePixel = 0
mainFrame.Active = true
mainFrame.Draggable = true
mainFrame.Parent = screenGui

Instance.new("UICorner", mainFrame).CornerRadius = UDim.new(0, 10)
Instance.new("UIStroke", mainFrame).Color = Color3.fromRGB(50, 50, 65)

local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, -20, 0, 40)
titleLabel.Position = UDim2.new(0, 10, 0, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Text = "Dungeon Macro Manager"
titleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
titleLabel.TextSize = 18
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Parent = mainFrame

local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -20, 0, 25)
statusLabel.Position = UDim2.new(0, 10, 0, 35)
statusLabel.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
statusLabel.TextColor3 = Color3.fromRGB(0, 255, 150)
statusLabel.TextSize = 12
statusLabel.Font = Enum.Font.GothamSemibold
statusLabel.Text = "Status: Idle"
statusLabel.Parent = mainFrame
Instance.new("UICorner", statusLabel).CornerRadius = UDim.new(0, 5)

local tabContainer = Instance.new("Frame")
tabContainer.Size = UDim2.new(1, -20, 0, 35)
tabContainer.Position = UDim2.new(0, 10, 0, 70)
tabContainer.BackgroundTransparency = 1
tabContainer.Parent = mainFrame

local UIListLayoutTabs = Instance.new("UIListLayout")
UIListLayoutTabs.Parent = tabContainer
UIListLayoutTabs.FillDirection = Enum.FillDirection.Horizontal
UIListLayoutTabs.SortOrder = Enum.SortOrder.LayoutOrder
UIListLayoutTabs.Padding = UDim.new(0, 5)

local function createTabButton(name, text, selected)
    local btn = Instance.new("TextButton")
    btn.Name = name
    btn.Text = text
    btn.Size = UDim2.new(0.5, -2, 1, 0)
    btn.BackgroundColor3 = selected and Color3.fromRGB(50, 100, 200) or Color3.fromRGB(35, 35, 45)
    btn.TextColor3 = Color3.fromRGB(255, 255, 255)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 13
    btn.Parent = tabContainer
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 5)
    return btn
end

local macroTabBtn = createTabButton("MacroTabBtn", "Macros", true)
local settingsTabBtn = createTabButton("SettingsTabBtn", "Settings", false)

local macroPage = Instance.new("ScrollingFrame")
macroPage.Size = UDim2.new(1, -20, 0, 320)
macroPage.Position = UDim2.new(0, 10, 0, 115)
macroPage.BackgroundTransparency = 1
macroPage.ScrollBarThickness = 3
macroPage.Parent = mainFrame
local UIListLayoutMacro = Instance.new("UIListLayout")
UIListLayoutMacro.Parent = macroPage
UIListLayoutMacro.SortOrder = Enum.SortOrder.LayoutOrder
UIListLayoutMacro.Padding = UDim.new(0, 8)

local settingsPage = Instance.new("ScrollingFrame")
settingsPage.Size = UDim2.new(1, -20, 0, 320)
settingsPage.Position = UDim2.new(0, 10, 0, 115)
settingsPage.BackgroundTransparency = 1
settingsPage.ScrollBarThickness = 3
settingsPage.Visible = false
settingsPage.CanvasSize = UDim2.new(0, 0, 0, 560)
settingsPage.Parent = mainFrame
local UIListLayoutSettings = Instance.new("UIListLayout")
UIListLayoutSettings.Parent = settingsPage
UIListLayoutSettings.SortOrder = Enum.SortOrder.LayoutOrder
UIListLayoutSettings.Padding = UDim.new(0, 8)

local function MakeButton(text, color, parent)
    local btn = Instance.new("TextButton")
    btn.Text = text
    btn.Size = UDim2.new(1, 0, 0, 32)
    btn.BackgroundColor3 = color
    btn.TextColor3 = Color3.fromRGB(255, 255, 255)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 13
    btn.Parent = parent
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 5)
    return btn
end

local function MakeInput(placeholder, parent)
    local box = Instance.new("TextBox")
    box.PlaceholderText = placeholder
    box.Size = UDim2.new(1, 0, 0, 32)
    box.BackgroundColor3 = Color3.fromRGB(30, 30, 38)
    box.TextColor3 = Color3.fromRGB(255, 255, 255)
    box.Font = Enum.Font.Gotham
    box.TextSize = 13
    box.Text = ""
    box.ClearTextOnFocus = false
    box.Parent = parent
    Instance.new("UICorner", box).CornerRadius = UDim.new(0, 5)
    Instance.new("UIStroke", box).Color = Color3.fromRGB(60, 60, 75)
    return box
end

local function MakeSettingRow(labelText, defaultVal, parent)
    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(1, 0, 0, 32)
    frame.BackgroundTransparency = 1
    frame.Parent = parent

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(0.7, 0, 1, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = labelText
    lbl.TextColor3 = Color3.fromRGB(200, 200, 210)
    lbl.Font = Enum.Font.GothamSemibold
    lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = frame

    local box = Instance.new("TextBox")
    box.Size = UDim2.new(0.3, 0, 1, 0)
    box.Position = UDim2.new(0.7, 0, 0, 0)
    box.BackgroundColor3 = Color3.fromRGB(30, 30, 38)
    box.TextColor3 = Color3.fromRGB(0, 255, 150)
    box.Font = Enum.Font.GothamBold
    box.TextSize = 13
    box.Text = tostring(defaultVal)
    box.Parent = frame
    Instance.new("UICorner", box).CornerRadius = UDim.new(0, 5)

    return box
end

local recordBtn = MakeButton("Start Recording Mode", Color3.fromRGB(180, 50, 50), macroPage)

local waypointRow = Instance.new("Frame")
waypointRow.Size = UDim2.new(1, 0, 0, 32)
waypointRow.BackgroundTransparency = 1
waypointRow.Parent = macroPage
local addWaypointBtn = MakeButton("Add Node", Color3.fromRGB(45, 110, 200), waypointRow)
addWaypointBtn.Size = UDim2.new(0.48, 0, 1, 0)
local clearWaypointsBtn = MakeButton("Clear Nodes", Color3.fromRGB(100, 100, 105), waypointRow)
clearWaypointsBtn.Size = UDim2.new(0.48, 0, 1, 0)
clearWaypointsBtn.Position = UDim2.new(0.52, 0, 0, 0)

local saveRow = Instance.new("Frame")
saveRow.Size = UDim2.new(1, 0, 0, 32)
saveRow.BackgroundTransparency = 1
saveRow.Parent = macroPage
local nameInput = MakeInput("Macro Name (e.g. Run1)", saveRow)
nameInput.Size = UDim2.new(0.65, 0, 1, 0)
local saveBtn = MakeButton("Save", Color3.fromRGB(40, 160, 80), saveRow)
saveBtn.Size = UDim2.new(0.32, 0, 1, 0)
saveBtn.Position = UDim2.new(0.68, 0, 0, 0)

local macroListTitle = Instance.new("TextLabel")
macroListTitle.Size = UDim2.new(1, 0, 0, 20)
macroListTitle.BackgroundTransparency = 1
macroListTitle.Text = "Saved Macros:"
macroListTitle.TextColor3 = Color3.fromRGB(180, 180, 190)
macroListTitle.Font = Enum.Font.GothamBold
macroListTitle.TextSize = 12
macroListTitle.TextXAlignment = Enum.TextXAlignment.Left
macroListTitle.Parent = macroPage

local macroScroll = Instance.new("ScrollingFrame")
macroScroll.Size = UDim2.new(1, 0, 0, 100)
macroScroll.BackgroundColor3 = Color3.fromRGB(15, 15, 18)
macroScroll.BorderSizePixel = 0
macroScroll.ScrollBarThickness = 4
macroScroll.Parent = macroPage
Instance.new("UICorner", macroScroll).CornerRadius = UDim.new(0, 5)
local UIListLayoutList = Instance.new("UIListLayout")
UIListLayoutList.Parent = macroScroll
UIListLayoutList.Padding = UDim.new(0, 2)

local actionRow = Instance.new("Frame")
actionRow.Size = UDim2.new(1, 0, 0, 32)
actionRow.BackgroundTransparency = 1
actionRow.Parent = macroPage
local exportBtn = MakeButton("Export to Clipboard", Color3.fromRGB(130, 80, 200), actionRow)
exportBtn.Size = UDim2.new(0.48, 0, 1, 0)
local deleteBtn = MakeButton("Delete Selected", Color3.fromRGB(180, 50, 50), actionRow)
deleteBtn.Size = UDim2.new(0.48, 0, 1, 0)
deleteBtn.Position = UDim2.new(0.52, 0, 0, 0)

local importRow = Instance.new("Frame")
importRow.Size = UDim2.new(1, 0, 0, 32)
importRow.BackgroundTransparency = 1
importRow.Parent = macroPage
local importInput = MakeInput("Paste JSON to Import...", importRow)
importInput.Size = UDim2.new(0.65, 0, 1, 0)
local importBtn = MakeButton("Import", Color3.fromRGB(200, 150, 40), importRow)
importBtn.Size = UDim2.new(0.32, 0, 1, 0)
importBtn.Position = UDim2.new(0.68, 0, 0, 0)

local minDistInput = MakeSettingRow("Min Combat Dist (Run Away):", SETTINGS.MinDistance, settingsPage)
local maxDistInput = MakeSettingRow("Max Combat Dist (Kite):", SETTINGS.MaxDistance, settingsPage)
local atkReachInput = MakeSettingRow("Attack Reach (Max Fire Dist):", SETTINGS.AttackReach, settingsPage)
local atkDelayInput = MakeSettingRow("Attack Cooldown (Sec):", SETTINGS.AttackCooldown, settingsPage)
local dodgeBufferInput = MakeSettingRow("Dodge Buffer (Margin):", SETTINGS.DodgeBuffer, settingsPage)
local wpTriggerInput = MakeSettingRow("Waypoint Trigger Distance:", SETTINGS.WaypointTriggerDist, settingsPage)
local maxNodeDistInput = MakeSettingRow("Max Next Node Dist (Abort):", SETTINGS.MaxNodeDistance, settingsPage)
local wallRayInput = MakeSettingRow("Wall Ray Length (Gliding):", SETTINGS.WallRayLength, settingsPage)
local noEnemyDelayInput = MakeSettingRow("No Enemy Replay Delay (s):", SETTINGS.NoEnemyDelay, settingsPage)

local filterTitle = Instance.new("TextLabel")
filterTitle.Size = UDim2.new(1, 0, 0, 20)
filterTitle.BackgroundTransparency = 1
filterTitle.Text = "Filter/Ignore Hazards (comma sep):"
filterTitle.TextColor3 = Color3.fromRGB(180, 180, 190)
filterTitle.Font = Enum.Font.GothamBold
filterTitle.TextSize = 12
filterTitle.TextXAlignment = Enum.TextXAlignment.Left
filterTitle.Parent = settingsPage
local filterInput = MakeInput("e.g. ring1, ring2, safezone", settingsPage)

local webhookTitle = Instance.new("TextLabel")
webhookTitle.Size = UDim2.new(1, 0, 0, 20)
webhookTitle.BackgroundTransparency = 1
webhookTitle.Text = "Discord Webhook (Rewards):"
webhookTitle.TextColor3 = Color3.fromRGB(180, 180, 190)
webhookTitle.Font = Enum.Font.GothamBold
webhookTitle.TextSize = 12
webhookTitle.TextXAlignment = Enum.TextXAlignment.Left
webhookTitle.Parent = settingsPage
local webhookInput = MakeInput("Paste Webhook URL...", settingsPage)

local bottomBar = Instance.new("Frame")
bottomBar.Size = UDim2.new(1, -20, 0, 40)
bottomBar.Position = UDim2.new(0, 10, 1, -50)
bottomBar.BackgroundTransparency = 1
bottomBar.Parent = mainFrame

local runMacroBtn = MakeButton("RUN SCRIPT (Autoplay)", Color3.fromRGB(30, 180, 100), bottomBar)
runMacroBtn.Size = UDim2.new(0.65, 0, 1, 0)
local terminateBtn = MakeButton("Kill Script", Color3.fromRGB(70, 70, 75), bottomBar)
terminateBtn.Size = UDim2.new(0.32, 0, 1, 0)
terminateBtn.Position = UDim2.new(0.68, 0, 0, 0)

macroTabBtn.MouseButton1Click:Connect(function()
    macroTabBtn.BackgroundColor3 = Color3.fromRGB(50, 100, 200)
    settingsTabBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
    macroPage.Visible = true
    settingsPage.Visible = false
end)
settingsTabBtn.MouseButton1Click:Connect(function()
    settingsTabBtn.BackgroundColor3 = Color3.fromRGB(50, 100, 200)
    macroTabBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
    settingsPage.Visible = true
    macroPage.Visible = false
end)

--------------------------------------------------------------------------------
-- 2. DISK PERSISTENCE & CONFIGURATION SYSTEM
--------------------------------------------------------------------------------
local function saveConfig()
    if not writefile then return end
    local cfgData = {
        Autoplay = isAutoplay,
        SelectedMacro = selectedMacroName,
        Webhook = SETTINGS.Webhook,
        IgnoreKeywords = SETTINGS.IgnoreKeywords,
        MinDistance = SETTINGS.MinDistance,
        MaxDistance = SETTINGS.MaxDistance,
        AttackReach = SETTINGS.AttackReach,
        AttackCooldown = SETTINGS.AttackCooldown,
        DodgeBuffer = SETTINGS.DodgeBuffer,
        WaypointTriggerDist = SETTINGS.WaypointTriggerDist,
        MaxNodeDistance = SETTINGS.MaxNodeDistance,
        WallRayLength = SETTINGS.WallRayLength,
        NoEnemyDelay = SETTINGS.NoEnemyDelay
    }
    pcall(function() writefile(CONFIG_FILE, HttpService:JSONEncode(cfgData)) end)
end

local function applySetting(inputBox, settingKey)
    local val = tonumber(inputBox.Text)
    if val then
        SETTINGS[settingKey] = val
        statusLabel.Text = settingKey .. " updated to " .. tostring(val)
        saveConfig()
    else
        inputBox.Text = tostring(SETTINGS[settingKey])
    end
end

minDistInput.FocusLost:Connect(function() applySetting(minDistInput, "MinDistance") end)
maxDistInput.FocusLost:Connect(function() applySetting(maxDistInput, "MaxDistance") end)
atkReachInput.FocusLost:Connect(function() applySetting(atkReachInput, "AttackReach") end)
atkDelayInput.FocusLost:Connect(function() applySetting(atkDelayInput, "AttackCooldown") end)
dodgeBufferInput.FocusLost:Connect(function() applySetting(dodgeBufferInput, "DodgeBuffer") end)
wpTriggerInput.FocusLost:Connect(function() applySetting(wpTriggerInput, "WaypointTriggerDist") end)
maxNodeDistInput.FocusLost:Connect(function() applySetting(maxNodeDistInput, "MaxNodeDistance") end)
wallRayInput.FocusLost:Connect(function() applySetting(wallRayInput, "WallRayLength") end)
noEnemyDelayInput.FocusLost:Connect(function() applySetting(noEnemyDelayInput, "NoEnemyDelay") end)
webhookInput.FocusLost:Connect(function() SETTINGS.Webhook = webhookInput.Text; saveConfig() end)

filterInput.FocusLost:Connect(function()
    SETTINGS.IgnoreKeywords = filterInput.Text
    updateIgnoreKeywords()
    saveConfig()
    statusLabel.Text = "Hazard filters updated!"
end)

local function clearWaypoints()
    for _, nodePart in ipairs(visualNodes) do if nodePart then nodePart:Destroy() end end
    table.clear(visualNodes)
    table.clear(waypoints)

    table.clear(persistentIgnoreList)
    if character then table.insert(persistentIgnoreList, character) end
    raycastParams.FilterDescendantsInstances = persistentIgnoreList

    currentWaypointIndex = 1
    traversingManualNodes = false
    statusLabel.Text = "Status: Waypoints Cleared"
end

local function renderVisualNode(pos, index)
    local visualPart = Instance.new("Part")
    visualPart.Name = "MacroPathNode_" .. index
    visualPart.Shape = Enum.PartType.Ball
    visualPart.Size = Vector3.new(1.5, 1.5, 1.5)
    visualPart.Anchored = true
    visualPart.CanCollide = false
    visualPart.Material = Enum.Material.Neon
    visualPart.Color = Color3.fromRGB(0, 255, 128)
    visualPart.Transparency = 0.4
    visualPart.CFrame = CFrame.new(pos)
    visualPart.Parent = Workspace
    table.insert(visualNodes, visualPart)

    table.insert(persistentIgnoreList, visualPart)
    raycastParams.FilterDescendantsInstances = persistentIgnoreList
end

local function addWaypointNode()
    if not rootPart then return end
    local pos = rootPart.Position
    table.insert(waypoints, pos)
    renderVisualNode(pos, #waypoints)
    statusLabel.Text = string.format("Waypoint (%.1f, %.1f, %.1f) added", pos.X, pos.Y, pos.Z)
end

local function loadMacroFromFile(macroName)
    local filePath = FOLDER_NAME .. "/" .. macroName .. ".json"
    if not isfile or not isfile(filePath) then return false end
    clearWaypoints()
    local success, decoded = pcall(function() return HttpService:JSONDecode(readfile(filePath)) end)
    if success and type(decoded) == "table" then
        for i, posData in ipairs(decoded) do
            local vec = Vector3.new(posData.X, posData.Y, posData.Z)
            table.insert(waypoints, vec)
            renderVisualNode(vec, i)
        end
        return true
    end
    return false
end

local function refreshMacroList()
    for _, child in ipairs(macroScroll:GetChildren()) do
        if child:IsA("TextButton") then child:Destroy() end
    end
    if not listfiles or not isfolder(FOLDER_NAME) then return end

    local files = listfiles(FOLDER_NAME)
    local count = 0
    for _, filePath in ipairs(files) do
        local fileName = filePath:match("([^/\\]+)$") or filePath
        if fileName:sub(-5) == ".json" and fileName ~= "config.json" then
            count = count + 1
            local cleanName = fileName:sub(1, -6)

            local itemBtn = Instance.new("TextButton")
            itemBtn.Name = cleanName
            itemBtn.Text = "  " .. cleanName
            itemBtn.Size = UDim2.new(1, -4, 0, 24)
            itemBtn.BackgroundColor3 = (selectedMacroName == cleanName) and Color3.fromRGB(50, 100, 160) or Color3.fromRGB(25, 25, 30)
            itemBtn.TextColor3 = Color3.fromRGB(240, 240, 240)
            itemBtn.Font = Enum.Font.Gotham
            itemBtn.TextSize = 13
            itemBtn.TextXAlignment = Enum.TextXAlignment.Left
            itemBtn.BorderSizePixel = 0
            itemBtn.Parent = macroScroll
            Instance.new("UICorner", itemBtn).CornerRadius = UDim.new(0, 3)

            itemBtn.MouseButton1Click:Connect(function()
                if selectedMacroName == cleanName then
                    selectedMacroName = ""
                    clearWaypoints()
                    statusLabel.Text = "Unselected Macro: " .. cleanName
                else
                    selectedMacroName = cleanName
                    loadMacroFromFile(cleanName)
                    statusLabel.Text = "Selected Macro: " .. cleanName
                end
                refreshMacroList()
                saveConfig()
            end)
        end
    end
    macroScroll.CanvasSize = UDim2.new(0, 0, 0, count * 26)
    macroPage.CanvasSize = UDim2.new(0,0,0, UIListLayoutMacro.AbsoluteContentSize.Y + 20)
end

exportBtn.MouseButton1Click:Connect(function()
    if selectedMacroName == "" then
        statusLabel.Text = "Select a macro to export first!"
        return
    end
    local filePath = FOLDER_NAME .. "/" .. selectedMacroName .. ".json"
    if isfile and isfile(filePath) then
        local data = readfile(filePath)
        setClipboard(data)
        statusLabel.Text = "Copied " .. selectedMacroName .. " to Clipboard!"
    end
end)

importBtn.MouseButton1Click:Connect(function()
    local text = importInput.Text
    local name = nameInput.Text
    if text == "" or name == "" then
        statusLabel.Text = "Need Name AND pasted JSON to import!"
        return
    end

    local success, decoded = pcall(function() return HttpService:JSONDecode(text) end)
    if success and type(decoded) == "table" and decoded[1] and decoded[1].X then
        local filePath = FOLDER_NAME .. "/" .. name .. ".json"
        writefile(filePath, text)
        statusLabel.Text = "Imported Macro as: " .. name
        importInput.Text = ""
        refreshMacroList()
    else
        statusLabel.Text = "Invalid JSON Macro Data!"
    end
end)

deleteBtn.MouseButton1Click:Connect(function()
    if selectedMacroName == "" then return end
    local filePath = FOLDER_NAME .. "/" .. selectedMacroName .. ".json"
    pcall(function() delFile(filePath) end)
    statusLabel.Text = "Deleted Macro: " .. selectedMacroName
    selectedMacroName = ""
    clearWaypoints()
    refreshMacroList()
    saveConfig()
end)

saveBtn.MouseButton1Click:Connect(function()
    local macroName = nameInput.Text
    if macroName == "" or #waypoints == 0 then return end
    local serializableTable = {}
    for _, vec in ipairs(waypoints) do table.insert(serializableTable, {X = vec.X, Y = vec.Y, Z = vec.Z}) end
    writefile(FOLDER_NAME .. "/" .. macroName .. ".json", HttpService:JSONEncode(serializableTable))
    selectedMacroName = macroName
    refreshMacroList()
    saveConfig()
end)

local function loadConfigAndAutoExecute()
    if not readfile or not isfile or not isfile(CONFIG_FILE) then refreshMacroList(); return end
    local success, cfg = pcall(function() return HttpService:JSONDecode(readfile(CONFIG_FILE)) end)

    if success and type(cfg) == "table" then
        SETTINGS.MinDistance = cfg.MinDistance or 15
        SETTINGS.MaxDistance = cfg.MaxDistance or 20
        SETTINGS.AttackReach = cfg.AttackReach or 55
        SETTINGS.AttackCooldown = cfg.AttackCooldown or 0.9
        SETTINGS.DodgeBuffer = cfg.DodgeBuffer or 2.5
        SETTINGS.WaypointTriggerDist = cfg.WaypointTriggerDist or 120
        SETTINGS.MaxNodeDistance = cfg.MaxNodeDistance or 65
        SETTINGS.WallRayLength = cfg.WallRayLength or 5.5
        SETTINGS.NoEnemyDelay = cfg.NoEnemyDelay or 5.0
        SETTINGS.Webhook = cfg.Webhook or ""
        SETTINGS.IgnoreKeywords = cfg.IgnoreKeywords or "ring1, ring2, ring3, ring4, ring5, ring6, part"

        minDistInput.Text = tostring(SETTINGS.MinDistance)
        maxDistInput.Text = tostring(SETTINGS.MaxDistance)
        atkReachInput.Text = tostring(SETTINGS.AttackReach)
        atkDelayInput.Text = tostring(SETTINGS.AttackCooldown)
        dodgeBufferInput.Text = tostring(SETTINGS.DodgeBuffer)
        wpTriggerInput.Text = tostring(SETTINGS.WaypointTriggerDist)
        maxNodeDistInput.Text = tostring(SETTINGS.MaxNodeDistance)
        wallRayInput.Text = tostring(SETTINGS.WallRayLength)
        noEnemyDelayInput.Text = tostring(SETTINGS.NoEnemyDelay)
        webhookInput.Text = SETTINGS.Webhook
        filterInput.Text = SETTINGS.IgnoreKeywords

        updateIgnoreKeywords()

        if cfg.SelectedMacro then selectedMacroName = cfg.SelectedMacro end

        refreshMacroList()

        if cfg.Autoplay == true then
            if selectedMacroName ~= "" then loadMacroFromFile(selectedMacroName) end
            isAutoplay = true
            runMacroBtn.Text = "STOP AUTOPLAY"
            runMacroBtn.BackgroundColor3 = Color3.fromRGB(200, 40, 40)

            fireStartGameRemote()
        end
    end
end

--------------------------------------------------------------------------------
-- SYSTEM HELPERS & CLEANUP
--------------------------------------------------------------------------------
local function cleanup()
    isAutoplay = false
    isRecording = false
    isCasting = false

    for _, conn in ipairs(connections) do conn:Disconnect() end
    table.clear(connections)

    for _, nodePart in ipairs(visualNodes) do if nodePart then nodePart:Destroy() end end
    table.clear(visualNodes)
    table.clear(waypoints)

    if screenGui then screenGui:Destroy() end
    if rootPart and rootPart:FindFirstChild("FacingAlign") then rootPart.FacingAlign:Destroy() end
    if rootPart and rootPart:FindFirstChild("FacingAttachment") then rootPart.FacingAttachment:Destroy() end

    if humanoid then
        humanoid.AutoRotate = true
        humanoid.WalkSpeed = 16
    end
    _G.TerminateHybridScriptUI = nil
end
_G.TerminateHybridScriptUI = cleanup

task.spawn(function()
    while true do
        task.wait(1.5)
        for _, obj in ipairs(Workspace:GetDescendants()) do
            if obj.Name:lower() == "inviswall" and obj:IsA("BasePart") then
                local maxDim = math.max(obj.Size.X, obj.Size.Y, obj.Size.Z)
                if maxDim < 80 then
                    obj.CanCollide = false
                    obj.Transparency = 1
                    if not obj:FindFirstChildOfClass("PathfindingModifier") then
                        local mod = Instance.new("PathfindingModifier")
                        mod.PassThrough = true
                        mod.Parent = obj
                    end
                else
                    if not obj:FindFirstChildOfClass("PathfindingModifier") then
                        local mod = Instance.new("PathfindingModifier")
                        mod.PassThrough = false
                        mod.Parent = obj
                    end
                end
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- ZERO-IMPACT INSTANT NAME SPOOFER (UPDATES ON SPAWN)
--------------------------------------------------------------------------------
local function applyFakeName(char)
    if not char then return end

    local function spoofLabel(nameLbl)
        if not nameLbl then return end
        nameLbl.Text = SPOOF_NAME

        local spoofConn
        spoofConn = nameLbl:GetPropertyChangedSignal("Text"):Connect(function()
            if nameLbl.Text ~= SPOOF_NAME then
                nameLbl.Text = SPOOF_NAME
            end
        end)
        table.insert(connections, spoofConn)

        local destroyConn
        destroyConn = nameLbl.AncestryChanged:Connect(function()
            if not nameLbl.Parent then
                spoofConn:Disconnect()
                destroyConn:Disconnect()
            end
        end)
        table.insert(connections, destroyConn)
    end

    task.spawn(function()
        local nameplate = char:WaitForChild("playerNameplate", 5)
        if nameplate then
            local frame = nameplate:WaitForChild("Frame", 2)
            spoofLabel(frame and frame:WaitForChild("name", 2))
        end
    end)

    task.spawn(function()
        local pGui = player:WaitForChild("PlayerGui", 5)
        if pGui then
            local statusGui = pGui:WaitForChild("playerStatus", 5)
            if statusGui then
                local frame = statusGui:WaitForChild("Frame", 2)
                spoofLabel(frame and frame:WaitForChild("playerName", 2))
            end
        end
    end)
end

--------------------------------------------------------------------------------
-- CHARACTER, SCANNING & COMBAT ENGINE
--------------------------------------------------------------------------------
local attachment, alignOrient

local function setupCharacterConstraints(newChar)
    character = newChar
    humanoid = character:WaitForChild("Humanoid")
    rootPart = character:WaitForChild("HumanoidRootPart")
    humanoid.WalkSpeed = MOVE_SPEED
    humanoid.AutoRotate = false

    local oldAlign = rootPart:FindFirstChild("FacingAlign")
    local oldAttach = rootPart:FindFirstChild("FacingAttachment")
    if oldAlign then oldAlign:Destroy() end
    if oldAttach then oldAttach:Destroy() end

    attachment = Instance.new("Attachment")
    attachment.Name = "FacingAttachment"
    attachment.Parent = rootPart
    alignOrient = Instance.new("AlignOrientation")
    alignOrient.Name = "FacingAlign"
    alignOrient.Mode = Enum.OrientationAlignmentMode.OneAttachment
    alignOrient.Attachment0 = attachment
    alignOrient.Responsiveness = 100
    alignOrient.MaxTorque = 1e6
    alignOrient.Parent = rootPart

    traversingManualNodes = false
    currentWaypointIndex = 1
    activeDodgePoint = nil -- Reset dodge state on new character load

    table.clear(persistentIgnoreList)
    table.insert(persistentIgnoreList, character)
    for _, node in ipairs(visualNodes) do table.insert(persistentIgnoreList, node) end
    raycastParams.FilterDescendantsInstances = persistentIgnoreList

    local diedConn
    diedConn = humanoid.Died:Connect(function()
        traversingManualNodes = false
        currentWaypointIndex = 1
        activeDodgePoint = nil -- Clear target immediately on death to prevent rubber-band loops
        statusLabel.Text = "Status: Died -- nodes reset"
        diedConn:Disconnect()
    end)
    table.insert(connections, diedConn)

    applyFakeName(character)
end
setupCharacterConstraints(character)
table.insert(connections, player.CharacterAdded:Connect(setupCharacterConstraints))
local function findBestTarget()
    if tick() - lastEnemyScan > 0.25 then
        table.clear(cachedEnemies)
        for _, obj in ipairs(Workspace:GetDescendants()) do
            if obj:IsA("Model") and obj ~= character and not Players:GetPlayerFromCharacter(obj) then
                if obj:FindFirstChildOfClass("Humanoid") and obj:FindFirstChild("HumanoidRootPart") then
                    table.insert(cachedEnemies, obj)
                end
            end
        end
        lastEnemyScan = tick()
    end

    local closestMob, shortestDist = nil, math.huge
    for _, mob in ipairs(cachedEnemies) do
        local mobHum = mob:FindFirstChildOfClass("Humanoid")
        local mobRoot = mob:FindFirstChild("HumanoidRootPart") or mob.PrimaryPart
        if mobHum and mobHum.Health > 0 and mobRoot then
            local dist = (mobRoot.Position - rootPart.Position).Magnitude
            if dist < shortestDist then shortestDist = dist; closestMob = mob end
        end
    end
    return closestMob
end
--------------------------------------------------------------------------------
-- INTELLIGENT MULTI-SIGNAL HAZARD SCORING SYSTEM
--------------------------------------------------------------------------------
local HAZARD_KEYWORDS = {
    "hitbox", "damage", "hurt", "hazard", "danger", "warning", "telegraph", "indicator", "marker",
    "shot", "projectile", "bullet", "missile", "beam", "laser", "ray", "orb", "sphere", "arrow", "spear",
    "aoe", "blast", "explosion", "burst", "ring", "zone", "wave", "eruption", "pylon", "cylinder",
    "attack", "strike", "slash", "smash", "punch", "kick", "slam", "stomp", "cleave", "combo",
    "spell", "magic", "fire", "flame", "burn", "ice", "frost", "lightning", "shock", "spark", "poison", "toxic", "meteor", "bomb"
}

local function scoreHazardPart(obj)
    if not obj:IsA("BasePart") then return 0 end
    local score = 0
    local name = obj.Name:lower()

    -- 1. Keyword Check
    for _, kw in ipairs(HAZARD_KEYWORDS) do
        if name:find(kw) then
            score = score + 3
            break
        end
    end

    -- 2. Visual Material & Color Check (Neon / Bright Red-Orange indicators)
    if obj.Material == Enum.Material.Neon then
        score = score + 2
        local col = obj.Color
        if col.R > 0.5 and col.G < 0.3 then -- High red spectrum
            score = score + 2
        end
    end

    -- 3. Dynamic Effects Check (Emitters, Fire, Beams, Trails)
    if obj:FindFirstChildOfClass("ParticleEmitter") or obj:FindFirstChildOfClass("Fire") or obj:FindFirstChildOfClass("Beam") or obj:FindFirstChildOfClass("Trail") then
        score = score + 3
    end

    -- 4. Transparency indicators (often semi-transparent warning zones)
    if obj.Transparency > 0 and obj.Transparency < 1 then
        score = score + 1
    end

    return score
end

local function evaluateAndAddHazardPart(obj)
    if not obj:IsA("BasePart") then return end
    if obj.Parent and obj.Parent:FindFirstChildOfClass("Humanoid") then return end
    if character and obj:IsDescendantOf(character) then return end
    if obj.Name == "Terrain" or obj.Name == "Baseplate" then return end

    local score = scoreHazardPart(obj)
    -- If multi-signal score hits 3 or higher, register as an active hazard
    if score >= 3 then
        activeHazards[obj] = true
    end
end

local function onDescendantAdded(child)
    if child.Name == "Terrain" or child.Name == "Baseplate" or child:IsA("Camera") then return end
    if child:IsA("BasePart") then
        evaluateAndAddHazardPart(child)
    elseif child:IsA("Model") or child:IsA("Folder") then
        for _, desc in ipairs(child:GetDescendants()) do
            if desc:IsA("BasePart") then evaluateAndAddHazardPart(desc) end
        end
    end
end

table.insert(connections, Workspace.DescendantAdded:Connect(onDescendantAdded))
table.insert(connections, Workspace.DescendantRemoving:Connect(function(child)
    if activeHazards[child] then activeHazards[child] = nil end
    if child:IsA("Model") or child:IsA("Folder") then
        for _, desc in ipairs(child:GetDescendants()) do
            if activeHazards[desc] then activeHazards[desc] = nil end
        end
    end
end))
for _, child in ipairs(Workspace:GetChildren()) do onDescendantAdded(child) end

local function getDangerousHazards()
    local hazards = {}
    for part, _ in pairs(activeHazards) do
        if part and part.Parent then
            if part.Transparency < 1 then
                local name = part.Name:lower()
                local isIgnored = false

                for _, kw in ipairs(parsedIgnoreKeywords) do
                    if name:find(kw) then isIgnored = true; break end
                end

                if not isIgnored then
                    local size = part.Size
                    if math.max(size.X, size.Y, size.Z) <= 300 then
                        -- ADVANCED LOGIC: Capture AssemblyLinearVelocity to predict projectile paths
                        table.insert(hazards, {
                            cframe = part.CFrame,
                            size = size,
                            name = part.Name,
                            velocity = part.AssemblyLinearVelocity or Vector3.zero
                        })
                    end
                end
            end
        else
            activeHazards[part] = nil
        end
    end
    return hazards
end

local function isPointInDanger(point, hazards)
    local minHazardDist = math.huge
    for _, hazard in ipairs(hazards) do
        -- 1. Check current position 
        local localP = hazard.cframe:PointToObjectSpace(point)
        local dx = math.abs(localP.X) - (hazard.size.X / 2)
        local dy = math.abs(localP.Y) - (hazard.size.Y / 2)
        local dz = math.abs(localP.Z) - (hazard.size.Z / 2)
        local dEdge = math.max(dx, dy, dz)
        
        if dEdge < minHazardDist then minHazardDist = dEdge end
        
        if dEdge <= SETTINGS.DodgeBuffer then
            return true, hazard.name, hazard, minHazardDist
        end
        
        -- 2. ADVANCED LOGIC: Projectile Path Prediction
        if hazard.velocity.Magnitude > 5 then
            for t = 0.2, 0.6, 0.2 do
                local futurePos = hazard.cframe.Position + (hazard.velocity * t)
                -- Preserve rotation while shifting position
                local futureCFrame = hazard.cframe - hazard.cframe.Position + futurePos
                local futureLocalP = futureCFrame:PointToObjectSpace(point)
                
                local fdx = math.abs(futureLocalP.X) - (hazard.size.X / 2)
                local fdy = math.abs(futureLocalP.Y) - (hazard.size.Y / 2)
                local fdz = math.abs(futureLocalP.Z) - (hazard.size.Z / 2)
                local fdEdge = math.max(fdx, fdy, fdz)
                
                if fdEdge < minHazardDist then minHazardDist = fdEdge end
                
                if fdEdge <= (SETTINGS.DodgeBuffer * 2) then
                    return true, hazard.name .. " (Incoming)", hazard, minHazardDist
                end
            end
        end
    end
    return false, nil, nil, minHazardDist
end
task.spawn(function()
    while true do
        task.wait(0.05)
        if isAutoplay and humanoid and humanoid.Health > 0 and rootPart then
            local target = findBestTarget()
            if target and target:FindFirstChild("HumanoidRootPart") then
                local dist = (rootPart.Position - target.HumanoidRootPart.Position).Magnitude

                if dist <= SETTINGS.AttackReach then
                    -- NEW: Only attack if there is a clear line of sight
                    local rayResult = Workspace:Raycast(rootPart.Position, (target.HumanoidRootPart.Position - rootPart.Position).Unit * dist, raycastParams)
                    if not rayResult or not rayResult.Instance.CanCollide then

                        isCasting = true
                        if alignOrient then alignOrient.CFrame = CFrame.lookAt(rootPart.Position, Vector3.new(target.HumanoidRootPart.Position.X, rootPart.Position.Y, target.HumanoidRootPart.Position.Z)) end
                        task.wait(0.15)
                        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Q, false, game)
                        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Q, false, game)
                        isCasting = false

                        task.wait(SETTINGS.AttackCooldown)

                        if target and target:FindFirstChild("HumanoidRootPart") and (rootPart.Position - target.HumanoidRootPart.Position).Magnitude <= SETTINGS.AttackReach then
                            isCasting = true
                            if alignOrient then alignOrient.CFrame = CFrame.lookAt(rootPart.Position, Vector3.new(target.HumanoidRootPart.Position.X, rootPart.Position.Y, target.HumanoidRootPart.Position.Z)) end
                            task.wait(0.15)
                            VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.E, false, game)
                            VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game)
                            isCasting = false
                            task.wait(SETTINGS.AttackCooldown)
                        end
                    end
                end
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- ADVANCED NAVIGATION ENGINE
--------------------------------------------------------------------------------
local function getGlidedTargetPos(startPos, rawTargetPos)
    local moveVector = (rawTargetPos - startPos)
    local dist = moveVector.Magnitude
    if dist < 0.2 then return rawTargetPos end
    local moveDir = Vector3.new(moveVector.X, 0, moveVector.Z).Unit

    for _, angle in ipairs({0, math.rad(32), math.rad(-32)}) do
        local rayResult = Workspace:Raycast(startPos, (CFrame.Angles(0, angle, 0) * moveDir) * SETTINGS.WallRayLength, raycastParams)
        if rayResult and rayResult.Instance and rayResult.Instance.CanCollide then
            if math.abs(rayResult.Normal.Y) < 0.7 then
                local slideDir = moveDir - (moveDir:Dot(rayResult.Normal) * rayResult.Normal)
                if slideDir.Magnitude > 0.05 then
                    return startPos + (Vector3.new(slideDir.X, 0, slideDir.Z).Unit * math.min(dist, 10))
                end
            end
        end
    end
    return rawTargetPos
end

local activePathWaypoints, pathIndex = {}, 1
local lastPathComputeTime = 0
local pathObject = PathfindingService:CreatePath({AgentRadius = 2.5, AgentHeight = 5.0, AgentCanJump = true, AgentCanClimb = false, WaypointSpacing = 12})

task.spawn(function()
    local lastMoveToPos, lastMoveToTime = Vector3.zero, 0
    local stuckCheckPos, stuckCheckTime = Vector3.zero, tick()
    local lastTpDodgeTime = 0

    local function smoothMoveTo(pos)
        if not humanoid or humanoid.Health <= 0 or not rootPart then return end
        local glidedPos = getGlidedTargetPos(rootPart.Position, pos)
        if (glidedPos - lastMoveToPos).Magnitude > 1.0 or (tick() - lastMoveToTime) > 0.35 then
            lastMoveToPos, lastMoveToTime = glidedPos, tick()
            humanoid:MoveTo(glidedPos)
        end
    end

    while true do
        task.wait(0.04)
        -- STRICT CHECK: Instantly skip loop if player is dead or script stopped
        if not isAutoplay or not humanoid or humanoid.Health <= 0 or not rootPart then continue end

        local playerPos = rootPart.Position
        local hazards = getDangerousHazards()
        local currentlyInDanger = (isPointInDanger(playerPos, hazards))

        local TP_DODGE_DIST   = 8
        local TP_DODGE_WAIT   = 0.77

        if currentlyInDanger or (activeDodgePoint and tick() < dodgeExpiration) then
            -- Double check health before executing TP dodge logic
            if not humanoid or humanoid.Health <= 0 or not rootPart then continue end

            local needNewPoint = true
            if activeDodgePoint and tick() < dodgeExpiration then
                if not (isPointInDanger(activeDodgePoint, hazards)) then needNewPoint = false end
            end

            if needNewPoint then
                local target  = findBestTarget()
                local enemyPos = target and (target:FindFirstChild("HumanoidRootPart") and target.HumanoidRootPart.Position) or playerPos
                local bestPoint, bestScore = nil, math.huge

                for _, dist in ipairs({2, 4, 6, 8, 11, 16, 22, 30}) do
                    for angle = 0, math.pi * 2 - 0.01, math.pi / 12 do
                        local candidate = playerPos + Vector3.new(math.cos(angle), 0, math.sin(angle)) * dist
                        local safe, minHazardDist = true, math.huge

                        for _, hazard in ipairs(hazards) do
                            local localP  = hazard.cframe:PointToObjectSpace(candidate)
                            local dx      = math.abs(localP.X) - (hazard.size.X / 2)
                            local dz      = math.abs(localP.Z) - (hazard.size.Z / 2)
                            local dEdge   = math.max(dx, dz)
                            if dEdge <= SETTINGS.DodgeBuffer then
                                safe = false; break
                            elseif dEdge < minHazardDist then
                                minHazardDist = dEdge
                            end
                        end

                        if safe then
                            local score = (candidate - enemyPos).Magnitude + (math.max(0, 5 - minHazardDist) * 2)
                            if score < bestScore then bestScore = score; bestPoint = candidate end
                        end
                    end
                    if bestPoint then break end
                end

                activeDodgePoint = bestPoint or playerPos
                dodgeExpiration  = tick() + 0.5
            end

            if activeDodgePoint then
                local toTarget = activeDodgePoint - playerPos
                local dist     = toTarget.Magnitude

                if alignOrient and alignOrient.Parent and dist > 0.5 then
                    alignOrient.CFrame = CFrame.lookAt(playerPos, Vector3.new(activeDodgePoint.X, playerPos.Y, activeDodgePoint.Z))
                end

                local now = tick()
                                if (now - lastTpDodgeTime) >= TP_DODGE_WAIT then
                                    -- Final safeguard check before applying CFrame teleport
                                    if humanoid and humanoid.Health > 0 and rootPart then

                                        -- SIMPLE LOGIC: If the dodge distance is tiny, just walk to it
                                        if dist <= 2.0 then
                                            smoothMoveTo(activeDodgePoint)
                                            statusLabel.Text = string.format("Micro-dodge Walk (%.1f st)", dist)

                                        -- Otherwise, perform the teleport dodge
                                        elseif dist <= TP_DODGE_DIST + 1 then
                                            rootPart.CFrame = CFrame.new(activeDodgePoint, Vector3.new(activeDodgePoint.X + toTarget.X, activeDodgePoint.Y, activeDodgePoint.Z + toTarget.Z))
                                            lastTpDodgeTime = now
                                            statusLabel.Text = string.format("TP DODGE -> safe point (%.1f st)", dist)
                                        else
                                            local stepDir   = Vector3.new(toTarget.X, 0, toTarget.Z).Unit
                                            local stepPoint = playerPos + stepDir * TP_DODGE_DIST
                                            local stepSafe  = not isPointInDanger(stepPoint, hazards)
                                            if stepSafe then
                                                rootPart.CFrame = CFrame.new(stepPoint, stepPoint + stepDir)
                                                lastTpDodgeTime = now
                                                statusLabel.Text = string.format("TP DODGE step -> safe zone (%.1f st remaining)", dist - TP_DODGE_DIST)
                                            else
                                                smoothMoveTo(activeDodgePoint)
                                                statusLabel.Text = "Running to TP-able position..."
                                            end
                                        end
                                    end
                                else
                                    smoothMoveTo(activeDodgePoint)
                                end
            end
            continue
        end

        if isCasting and not currentlyInDanger then humanoid:MoveTo(playerPos); continue end

        if (playerPos - stuckCheckPos).Magnitude < 0.75 then
            if tick() - stuckCheckTime > 0.4 then humanoid.Jump = true; stuckCheckTime = tick() end
        else
            stuckCheckPos = playerPos; stuckCheckTime = tick()
        end

        local function safeSmoothMoveTo(targetPos)
            local glidedPos = getGlidedTargetPos(playerPos, targetPos)
            local moveDir = (glidedPos - playerPos)

            if moveDir.Magnitude > 0.1 then
                for stepDist = 1.5, math.min(moveDir.Magnitude, 7), 1.5 do
                    local stepPos = playerPos + moveDir.Unit * stepDist
                    local inDanger, blockName = isPointInDanger(stepPos, hazards)
                    if inDanger then
                        statusLabel.Text = "WAITING / BLOCKED BY: " .. tostring(blockName)
                        humanoid:MoveTo(playerPos)
                        return
                    end
                end
            end
            smoothMoveTo(targetPos)
        end

        if #waypoints > 0 then
            if currentWaypointIndex > #waypoints then
                if traversingManualNodes then
                    statusLabel.Text = "Route complete: All nodes visited"
                    traversingManualNodes = false
                end
            else
                local function findNextReachableNode()
                    for i = currentWaypointIndex, #waypoints do
                        if (playerPos - waypoints[i]).Magnitude <= SETTINGS.WaypointTriggerDist then
                            return i
                        end
                    end
                    return nil
                end

                local currentDist = (playerPos - waypoints[currentWaypointIndex]).Magnitude

                if not traversingManualNodes or currentDist > SETTINGS.MaxNodeDistance then
                    local nearIdx = findNextReachableNode()
                    if nearIdx then
                        if traversingManualNodes and nearIdx > currentWaypointIndex then
                            statusLabel.Text = string.format("Skipped to Node %d (nearest in range)", nearIdx)
                        end
                        currentWaypointIndex = nearIdx
                        traversingManualNodes = true
                    else
                        if traversingManualNodes then
                            statusLabel.Text = "Waiting: No nodes in range..."
                        end
                        traversingManualNodes = false
                    end
                end

                if traversingManualNodes and currentWaypointIndex <= #waypoints then
                    local targetNode = waypoints[currentWaypointIndex]
                    local distToNode = (playerPos - targetNode).Magnitude
                    statusLabel.Text = string.format("MACRO ACTIVE: Node %d / %d (Dist: %.1f)", currentWaypointIndex, #waypoints, distToNode)
                    safeSmoothMoveTo(targetNode)
                    if distToNode <= 3.8 then
                        currentWaypointIndex = currentWaypointIndex + 1
                    end
                    continue
                end
            end
        end

        local activeTarget = findBestTarget()
        if activeTarget and activeTarget:FindFirstChild("HumanoidRootPart") then
            local enemyPos = activeTarget.HumanoidRootPart.Position
            if alignOrient and alignOrient.Parent then
                alignOrient.CFrame = CFrame.lookAt(playerPos, Vector3.new(enemyPos.X, playerPos.Y, enemyPos.Z))
            end

            if (playerPos - enemyPos).Magnitude <= SETTINGS.MaxDistance then
                table.clear(activePathWaypoints)
                if (playerPos - enemyPos).Magnitude < SETTINGS.MinDistance then
                    safeSmoothMoveTo(playerPos + ((playerPos - enemyPos).Unit * 14))
                else humanoid:MoveTo(playerPos) end
            else
                if tick() - lastPathComputeTime > PATH_RECOMPUTE_INTERVAL then
                    lastPathComputeTime = tick()
                    if pcall(function() pathObject:ComputeAsync(playerPos, enemyPos) end) and pathObject.Status == Enum.PathStatus.Success then
                        activePathWaypoints = pathObject:GetWaypoints(); pathIndex = 2
                    else
                        local rayHit = Workspace:Raycast(playerPos, (enemyPos - playerPos), raycastParams)
                        if not rayHit or not rayHit.Instance or not rayHit.Instance.CanCollide then safeSmoothMoveTo(enemyPos) end
                    end
                end

                if #activePathWaypoints > 0 and pathIndex <= #activePathWaypoints then
                    local furthest = pathIndex
                    for i = math.min(pathIndex + 4, #activePathWaypoints), pathIndex + 1, -1 do
                        local rayHit = Workspace:Raycast(playerPos, (activePathWaypoints[i].Position - playerPos), raycastParams)
                        if not rayHit or not rayHit.Instance or not rayHit.Instance.CanCollide then furthest = i; break end
                    end
                    pathIndex = furthest
                    if activePathWaypoints[pathIndex].Action == Enum.PathWaypointAction.Jump then humanoid.Jump = true end
                    safeSmoothMoveTo(activePathWaypoints[pathIndex].Position)
                    if (playerPos - activePathWaypoints[pathIndex].Position).Magnitude <= 4.5 then pathIndex = pathIndex + 1 end
                end
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- TIMED COMBO ROUTINE
--------------------------------------------------------------------------------
task.spawn(function()
    while true do
        task.wait(0.05)
        if isAutoplay and humanoid and humanoid.Health > 0 and rootPart then
            local target = findBestTarget()
            if target and target:FindFirstChild("HumanoidRootPart") then
                local dist = (rootPart.Position - target.HumanoidRootPart.Position).Magnitude

                if dist <= SETTINGS.AttackReach then
                    isCasting = true
                    if alignOrient then alignOrient.CFrame = CFrame.lookAt(rootPart.Position, Vector3.new(target.HumanoidRootPart.Position.X, rootPart.Position.Y, target.HumanoidRootPart.Position.Z)) end
                    task.wait(0.15)
                    VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Q, false, game)
                    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Q, false, game)
                    isCasting = false

                    task.wait(SETTINGS.AttackCooldown)

                    if target and target:FindFirstChild("HumanoidRootPart") and (rootPart.Position - target.HumanoidRootPart.Position).Magnitude <= SETTINGS.AttackReach then
                        isCasting = true
                        if alignOrient then alignOrient.CFrame = CFrame.lookAt(rootPart.Position, Vector3.new(target.HumanoidRootPart.Position.X, rootPart.Position.Y, target.HumanoidRootPart.Position.Z)) end
                        task.wait(0.15)
                        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.E, false, game)
                        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game)
                        isCasting = false
                        task.wait(SETTINGS.AttackCooldown)
                    end
                end
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- BUTTON EVENT BINDINGS
--------------------------------------------------------------------------------
recordBtn.MouseButton1Click:Connect(function()
    isRecording = not isRecording
    recordBtn.Text = isRecording and "Stop Recording Mode" or "Start Recording Mode"
    recordBtn.BackgroundColor3 = isRecording and Color3.fromRGB(220, 100, 30) or Color3.fromRGB(180, 50, 50)
    statusLabel.Text = isRecording and "Status: Recording Mode Active" or "Status: Recording Stopped"
end)
addWaypointBtn.MouseButton1Click:Connect(function()
    if isRecording then addWaypointNode() else statusLabel.Text = "Error: Enable Recording Mode first!" end
end)
clearWaypointsBtn.MouseButton1Click:Connect(clearWaypoints)
runMacroBtn.MouseButton1Click:Connect(function()
    isAutoplay = not isAutoplay
    runMacroBtn.Text = isAutoplahiy and "STOP AUTOPLAY" or "RUN SCRIPT (Autoplay)"
    runMacroBtn.BackgroundColor3 = isAutoplay and Color3.fromRGB(200, 40, 40) or Color3.fromRGB(30, 180, 100)
    if isAutoplay then
        if #waypoints == 0 and selectedMacroName ~= "" then loadMacroFromFile(selectedMacroName) end
        fireStartGameRemote()
    end
    saveConfig()
end)
terminateBtn.MouseButton1Click:Connect(cleanup)

loadConfigAndAutoExecute()
