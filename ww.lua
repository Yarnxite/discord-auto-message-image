-- ROBUST INITIALIZATION
if not table.clear then table.clear = function(t) for k in pairs(t) do t[k] = nil end end end

repeat task.wait(0.2) until game:IsLoaded()
local Players = game:GetService("Players")
repeat task.wait(0.2) until Players.LocalPlayer
local player = Players.LocalPlayer
repeat task.wait(0.2) until player:FindFirstChild("PlayerGui") and game:GetService("ReplicatedStorage"):FindFirstChild("remotes")

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")
local CoreGui = game:GetService("CoreGui")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- AUTOMATIC CLEANUP
if _G.TerminateHybridScriptUI then _G.TerminateHybridScriptUI() end

local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid")
local rootPart = character:WaitForChild("HumanoidRootPart")

local httpRequest = (syn and syn.request) or (http and http.request) or http_request or request
local setClipboard = setclipboard or toclipboard or function(text) end
local delFile = delfile or function(path) pcall(function() writefile(path, "") end) end

-- HARDCODED/UNCHANGEABLE CONFIG
local SPOOF_NAME = "fvnito"
local MOVE_SPEED = 19
local PATH_RECOMPUTE_INTERVAL = 0.7
local FOLDER_NAME = "dungeonmacros"
local CONFIG_FILE = FOLDER_NAME .. "/config.json"
local SPAWN_SHIELD_DURATION = 5.0
local MAX_INVENTORY_CAPACITY = 300
local MAIN_LOBBY_PLACE_ID = 77649408247578

-- SAFE UI SEARCH HELPER
local function findNested(parent, ...)
    local current = parent
    for _, name in ipairs({...}) do
        if not current then return nil end
        current = current:FindFirstChild(name)
    end
    return current
end

-- NON-BLOCKING REMOTE FIRE HELPER
local function safeInvoke(remote, ...)
    if not remote then return end
    local args = {...}
    task.spawn(function()
        pcall(function()
            if remote:IsA("RemoteFunction") then
                remote:InvokeServer(unpack(args))
            elseif remote:IsA("RemoteEvent") then
                remote:FireServer(unpack(args))
            end
        end)
    end)
end

-- LIVE SETTINGS (Changeable via UI & Saved to Config)
local SETTINGS = {
    MinDistance = 40,
    MaxDistance = 60,
    AttackReach = 65,
    AttackCooldown = 0,
    DodgeBuffer = 3,
    WaypointTriggerDist = 40,
    MaxNodeDistance = 25,
    WallRayLength = 5.5,
    NoEnemyDelay = 10,
    Webhook = "",
    IgnoreKeywords = "ring1, ring2, ring3, ring4, ring5, ring6, part",
    AutoSellEnabled = false,
    HideUI = false,
    AutoSellRarities = { common = false, uncommon = false, rare = false, epic = false, legendary = false, ultimate = false },
    AutoSellCategories = { weapon = false, ability = false, chest = false, helmet = false },
    AutoLobbyEnabled = true,
    LobbyMode = "Host",
    JoinPlayerName = "",
    LobbyMap = "Volcanic Chambers",
    LobbyDifficulty = "Nightmare",
    LobbyHardcore = false,
    LobbyPrivate = false,
    TargetPartySize = 0 
}

-- STATE VARIABLES
local isAutoplay = false
local isRecording = false
local isCasting = false
local isDodgeBlinking = false
local hasReturnedToLobby = false
local isHandlingLobbyRoutine = false
local waypoints = {}
local visualNodes = {}
local currentWaypointIndex = 1
local traversingManualNodes = false
local selectedMacroName = ""
local connections = {}
local activeDodgePoint = nil
local dodgeExpiration = 0
local characterSpawnTime = os.clock()
local postDodgeHoldUntil = 0
local lastInvCheckTime = 0
local lastEnemySeenTime = os.clock()
local lastStartValueTime = 0 -- Auto-Start Dungeon variable

-- PERFORMANCE OPTIMIZATIONS
local persistentIgnoreList = {character}
local activeHazards = {}
local hazardTracking = {}
local hazardSignals = {}
local trackedHumanoids = setmetatable({}, {__mode = "k"})
local cachedInviswalls = {}
local parsedIgnoreKeywords = {}

local DODGE_DIRECTIONS = (function()
    local dirs = {}
    for i = 0, 11 do
        local angle = (math.pi / 6) * i
        dirs[i + 1] = Vector3.new(math.cos(angle), 0, math.sin(angle))
    end
    return dirs
end)()

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true
raycastParams.FilterDescendantsInstances = persistentIgnoreList

local teleportRayParams = RaycastParams.new()
teleportRayParams.FilterType = Enum.RaycastFilterType.Exclude
teleportRayParams.IgnoreWater = true
teleportRayParams.RespectCanCollide = true
teleportRayParams.FilterDescendantsInstances = persistentIgnoreList

pcall(function()
    if isfolder and makefolder and not isfolder(FOLDER_NAME) then makefolder(FOLDER_NAME) end
end)

local function updateIgnoreKeywords()
    table.clear(parsedIgnoreKeywords)
    table.insert(parsedIgnoreKeywords, "macropathnode")
    if SETTINGS.IgnoreKeywords and SETTINGS.IgnoreKeywords ~= "" then
        for word in string.gmatch(SETTINGS.IgnoreKeywords, "([^,]+)") do
            local cleanWord = word:match("^%s*(.-)%s*$"):lower()
            if cleanWord ~= "" then table.insert(parsedIgnoreKeywords, cleanWord) end
        end
    end
end
updateIgnoreKeywords()

local function isInLobby()
    if game.PlaceId == MAIN_LOBBY_PLACE_ID then return true end
    local dungeonNameObj = Workspace:FindFirstChild("dungeonName")
    return not dungeonNameObj or not dungeonNameObj.Parent
end

--------------------------------------------------------------------------------
-- AUTO-SELL SYSTEM
--------------------------------------------------------------------------------
local function executeAutoSell()
    if not isInLobby() then return end
    local pGui = player:FindFirstChild("PlayerGui")
    if not pGui then return end
    local sellShop = pGui:FindFirstChild("sellShop")
    if not sellShop then return end
    
    local scroll = findNested(sellShop, "Frame", "innerFrame", "rightSideFrame", "ScrollingFrame")
    if not scroll then return end

    local payload = { chest = {}, ability = {}, helmet = {}, weapon = {} }
    local totalItemCount = 0

    for _, slot in ipairs(scroll:GetChildren()) do
        if slot:IsA("GuiObject") then
            local itemTypeObj = slot:FindFirstChild("itemType")
            if itemTypeObj then
                local rarityObj = itemTypeObj:FindFirstChild("rarity") or slot:FindFirstChild("rarity")
                local uniqueNumObj = itemTypeObj:FindFirstChild("uniqueItemNum") or slot:FindFirstChild("uniqueItemNum")
                
                if rarityObj and uniqueNumObj then
                    local s1, catRaw = pcall(function() return itemTypeObj.Value end)
                    local s2, rarRaw = pcall(function() return rarityObj.Value end)
                    local s3, numRaw = pcall(function() return uniqueNumObj.Value end)
                    
                    if s1 and s2 and s3 and catRaw and rarRaw and numRaw then
                        local category = tostring(catRaw):lower():gsub("%s+", "")
                        local rarity = tostring(rarRaw):lower():gsub("%s+", "")
                        local uniqueId = tonumber(numRaw)

                        if uniqueId and SETTINGS.AutoSellCategories[category] and SETTINGS.AutoSellRarities[rarity] then
                            if not payload[category] then payload[category] = {} end
                            table.insert(payload[category], uniqueId)
                            totalItemCount = totalItemCount + 1
                        end
                    end
                end
            end
        end
    end

    if totalItemCount > 0 then
        pcall(function()
            local remotes = ReplicatedStorage:FindFirstChild("remotes")
            if remotes then
                local sellItemEvent = remotes:FindFirstChild("sellItemEvent")
                safeInvoke(sellItemEvent, payload)
            end
        end)
    end
end

--------------------------------------------------------------------------------
-- REPLAY & LOBBY ROUTINE
--------------------------------------------------------------------------------
local screenGui -- Forward declaration for UI updates

local function fireReplayDungeonRemote()
    if isInLobby() then return end
    
    local currentDungeonName = SETTINGS.LobbyMap
    pcall(function()
        local dObj = Workspace:FindFirstChild("dungeonName")
        if dObj then
            if dObj:IsA("StringValue") then currentDungeonName = dObj.Value
            else currentDungeonName = tostring(dObj.Value or dObj) end
        end
    end)
    
    pcall(function()
        local remotes = ReplicatedStorage:WaitForChild("remotes", 5)
        if remotes then
            local replayDungeon = remotes:WaitForChild("replayDungeon", 2)
            safeInvoke(replayDungeon, {
                dungeonProgress = "bossKilled", dungeonStarted = true, hardcore = SETTINGS.LobbyHardcore,
                dungeonFinished = true, dungeonName = currentDungeonName, isHardcore = SETTINGS.LobbyHardcore, fightingBoss = true
            })
        end
    end)
    
    lastEnemySeenTime = os.clock() + 15 -- Buffer timer so it doesn't spam replay
end

local function getInventoryCount()
    local pGui = player:FindFirstChild("PlayerGui")
    if not pGui then return 0 end
    local count = 0
    local sellShop = pGui:FindFirstChild("sellShop")
    
    local sellScroll = findNested(sellShop, "Frame", "innerFrame", "rightSideFrame", "ScrollingFrame")
    if sellScroll then
        for _, slot in ipairs(sellScroll:GetChildren()) do
            if slot:IsA("GuiObject") and slot:FindFirstChild("itemType") then count = count + 1 end
        end
    end

    local invSpaceLabel = findNested(pGui, "inventory", "mainBackground", "innerBackground", "rightSideFrame", "inventorySpace")
    if invSpaceLabel and invSpaceLabel:IsA("TextLabel") then
        local rawNum = invSpaceLabel.Text:match("(%d+)")
        if rawNum and tonumber(rawNum) then count = math.max(count, tonumber(rawNum)) end
    end
    return count
end

local function returnToLobby()
    if hasReturnedToLobby then return end
    hasReturnedToLobby = true
    isAutoplay = false
    task.spawn(function()
        pcall(function()
            local remotes = ReplicatedStorage:WaitForChild("remotes", 5)
            if remotes then
                local returnEvent = remotes:WaitForChild("ReturnToLobbyEvent", 5)
                safeInvoke(returnEvent)
            end
        end)
    end)
end

local function checkInventoryFull()
    if hasReturnedToLobby then return end
    local currentCount = getInventoryCount()
    if currentCount >= MAX_INVENTORY_CAPACITY then returnToLobby() end
end

local function getPartyMemberCount()
    local pGui = player:FindFirstChild("PlayerGui")
    if not pGui then return 0 end
    
    local scroll = findNested(pGui, "queueGui", "lobbyInfo", "backgroundFill", "ScrollingFrame")
    if not scroll then return 0 end

    local count = 0
    for _, child in ipairs(scroll:GetChildren()) do
        if child:IsA("GuiObject") and child.Name ~= "UIListLayout" and child.Name ~= "UIPadding" and child.Name ~= "UIGridLayout" then
            if child.Name ~= player.Name then
                count = count + 1
            end
        end
    end
    return count
end

local function handleLobbyAutomation()
    if isHandlingLobbyRoutine or not isAutoplay or hasReturnedToLobby then return end
    if not isInLobby() then return end

    isHandlingLobbyRoutine = true

    task.spawn(function()
        task.wait(2.5)
        if not isAutoplay then isHandlingLobbyRoutine = false; return end

        if SETTINGS.AutoSellEnabled then
            local dmManager = screenGui and screenGui:FindFirstChild("DungeonMacroManager")
            local statusLabel = dmManager and dmManager:FindFirstChild("TextLabel", true)
            if statusLabel then statusLabel.Text = "Status: Executing Auto-Sell..." end
            executeAutoSell()
            task.wait(1.0)
        end

        checkInventoryFull()
        if hasReturnedToLobby or not isAutoplay then
            isHandlingLobbyRoutine = false
            return
        end

        if not SETTINGS.AutoLobbyEnabled then 
            isHandlingLobbyRoutine = false
            return 
        end

        local remotes = ReplicatedStorage:WaitForChild("remotes", 5)
        if not remotes then isHandlingLobbyRoutine = false; return end

        -- JOIN FRIEND MODE
        if SETTINGS.LobbyMode == "Join" then
            if SETTINGS.JoinPlayerName ~= "" then
                local joinRemote = remotes:WaitForChild("joinDungeon", 2)
                safeInvoke(joinRemote, SETTINGS.JoinPlayerName)
            end
            task.wait(2.0)
            isHandlingLobbyRoutine = false
            return

        -- HOST MODE
        else
            -- 1. Create the lobby
            local createLobbyRemote = remotes:WaitForChild("createLobby", 2)
            safeInvoke(createLobbyRemote, SETTINGS.LobbyMap, SETTINGS.LobbyDifficulty, 0, SETTINGS.LobbyHardcore, SETTINGS.LobbyPrivate, false)
            
            task.wait(0.6)

            -- 2. Force Join the lobby you just created
            local joinRemote = remotes:WaitForChild("joinDungeon", 2)
            safeInvoke(joinRemote, player.Name)

            -- Wait for party size inside the created room
            if SETTINGS.TargetPartySize > 0 then
                local dmManager = screenGui and screenGui:FindFirstChild("DungeonMacroManager")
                local statusLabel = dmManager and dmManager:FindFirstChild("TextLabel", true)
                
                while isAutoplay do
                    local currentOtherPlayers = getPartyMemberCount()
                    if currentOtherPlayers >= SETTINGS.TargetPartySize then break end
                    if statusLabel then 
                        statusLabel.Text = string.format("Status: Waiting for party (%d/%d)...", currentOtherPlayers, SETTINGS.TargetPartySize) 
                    end
                    task.wait(1.0)
                end
            end

            if not isAutoplay then isHandlingLobbyRoutine = false; return end
            task.wait(1.5)

            -- 3. Start the Dungeon
            local startDungeonRemote = remotes:WaitForChild("startDungeon", 2)
            safeInvoke(startDungeonRemote)
            task.wait(0.5)
            safeInvoke(startDungeonRemote) -- Fired twice to guarantee execution

            isHandlingLobbyRoutine = false
        end
    end)
end

local function formatNumber(n) return tostring(n):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "") end
local runStartTime = os.clock()

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

    local elapsed = os.clock() - runStartTime
    local timeText = string.format("%dm %ds", math.floor(elapsed / 60), math.floor(elapsed % 60))
    runStartTime = os.clock()

    local embedPayload = {
        ["username"] = "Dungeon Webhook",
        ["embeds"] = {{
            ["title"] = "Match Ended", ["color"] = 16766720,
            ["fields"] = {
                {["name"] = "Time", ["value"] = timeText, ["inline"] = false},
                {["name"] = "Gold Obtained", ["value"] = string.format("**%s** Gold", formatNumber(goldAmount)), ["inline"] = false},
                {["name"] = "Items Received", ["value"] = #itemsList > 0 and table.concat(itemsList, "\n") or "None", ["inline"] = false}
            },
            ["timestamp"] = DateTime.now():ToIsoDate()
        }}
    }
    local success, encoded = pcall(function() return HttpService:JSONEncode(embedPayload) end)
    if success and httpRequest then task.spawn(function() httpRequest({ Url = url, Method = "POST", Headers = { ["Content-Type"] = "application/json" }, Body = encoded }) end) end
end

-- Reward Gui Hook for Webhook & Auto Replay
task.spawn(function()
    local remotes = ReplicatedStorage:WaitForChild("remotes", 5)
    if remotes then
        local cloneRewardGui = remotes:WaitForChild("cloneRewardGui", 5)
        if cloneRewardGui then
            local conn = cloneRewardGui.OnClientEvent:Connect(function(data)
                if type(data) == "table" then sendRewardWebhook(data) end
                
                if isAutoplay then
                    task.spawn(function()
                        task.wait(1.5)
                        checkInventoryFull()
                        if not hasReturnedToLobby then
                            fireReplayDungeonRemote()
                        end
                    end)
                end
            end)
            table.insert(connections, conn)
        end
    end
end)

--------------------------------------------------------------------------------
-- 1. MODERN UI SYSTEM
--------------------------------------------------------------------------------
screenGui = Instance.new("ScreenGui")
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
    btn.Size = UDim2.new(0.32, 0, 1, 0)
    btn.BackgroundColor3 = selected and Color3.fromRGB(50, 100, 200) or Color3.fromRGB(35, 35, 45)
    btn.TextColor3 = Color3.fromRGB(255, 255, 255)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 12
    btn.Parent = tabContainer
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 5)
    return btn
end

local macroTabBtn = createTabButton("MacroTabBtn", "Macros", true)
local settingsTabBtn = createTabButton("SettingsTabBtn", "Settings", false)
local sellTabBtn = createTabButton("SellTabBtn", "Auto-Sell", false)

local function createPage(visible)
    local page = Instance.new("ScrollingFrame")
    page.Size = UDim2.new(1, -20, 0, 320)
    page.Position = UDim2.new(0, 10, 0, 115)
    page.BackgroundTransparency = 1
    page.ScrollBarThickness = 3
    page.Visible = visible
    page.Parent = mainFrame
    local layout = Instance.new("UIListLayout")
    layout.Parent = page
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 6)
    
    layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        page.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y + 20)
    end)
    
    return page, layout
end

local macroPage, UIListLayoutMacro = createPage(true)
local settingsPage, UIListLayoutSettings = createPage(false)
local sellPage, UIListLayoutSell = createPage(false)

local function MakeButton(text, color, parent)
    local btn = Instance.new("TextButton")
    btn.Text = text
    btn.Size = UDim2.new(1, 0, 0, 30)
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
    box.Size = UDim2.new(1, 0, 0, 30)
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
    frame.Size = UDim2.new(1, 0, 0, 30)
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

local function MakeDropdownRow(labelText, getOptionsFunc, defaultVal, parent, callback)
    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(1, 0, 0, 30)
    frame.BackgroundTransparency = 1
    frame.Parent = parent

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(0.5, 0, 1, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = labelText
    lbl.TextColor3 = Color3.fromRGB(200, 200, 210)
    lbl.Font = Enum.Font.GothamSemibold
    lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = frame

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0.5, 0, 1, 0)
    btn.Position = UDim2.new(0.5, 0, 0, 0)
    btn.BackgroundColor3 = Color3.fromRGB(30, 30, 38)
    btn.TextColor3 = Color3.fromRGB(0, 255, 150)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 12
    btn.Text = tostring(defaultVal) .. " ▼"
    btn.Parent = frame
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 5)

    local dropdownContainer = Instance.new("Frame")
    dropdownContainer.Size = UDim2.new(1, 0, 0, 0)
    dropdownContainer.BackgroundTransparency = 1
    dropdownContainer.ClipsDescendants = true
    dropdownContainer.Visible = false
    dropdownContainer.Parent = parent

    local listLayout = Instance.new("UIListLayout")
    listLayout.Parent = dropdownContainer
    listLayout.SortOrder = Enum.SortOrder.LayoutOrder
    listLayout.Padding = UDim.new(0, 2)

    local currentVal = defaultVal

    local function closeDropdown()
        dropdownContainer.Visible = false
        dropdownContainer.Size = UDim2.new(1, 0, 0, 0)
        btn.Text = tostring(currentVal) .. " ▼"
    end

    btn.MouseButton1Click:Connect(function()
        if dropdownContainer.Visible then
            closeDropdown()
        else
            for _, child in ipairs(dropdownContainer:GetChildren()) do
                if child:IsA("TextButton") then child:Destroy() end
            end
            local opts = getOptionsFunc()
            local height = 0
            for _, opt in ipairs(opts) do
                local optBtn = Instance.new("TextButton")
                optBtn.Size = UDim2.new(1, 0, 0, 25)
                optBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
                optBtn.TextColor3 = Color3.fromRGB(220, 220, 220)
                optBtn.Font = Enum.Font.Gotham
                optBtn.TextSize = 12
                optBtn.Text = tostring(opt)
                optBtn.Parent = dropdownContainer
                Instance.new("UICorner", optBtn).CornerRadius = UDim.new(0, 3)

                optBtn.MouseButton1Click:Connect(function()
                    currentVal = opt
                    callback(opt)
                    closeDropdown()
                end)
                height = height + 27
            end
            dropdownContainer.Size = UDim2.new(1, 0, 0, height)
            dropdownContainer.Visible = true
            btn.Text = tostring(currentVal) .. " ▲"
        end
    end)

    local api = {}
    function api:SetValue(val)
        currentVal = val
        btn.Text = tostring(val) .. " ▼"
    end
    return api
end

local function getAvailableMaps()
    local maps = {}
    pcall(function()
        local scroll = findNested(player, "PlayerGui", "queueGui", "chooseDungeon", "backgroundFillLeft", "ScrollingFrame")
        if scroll then
            for _, child in ipairs(scroll:GetChildren()) do
                if child:IsA("ImageLabel") then table.insert(maps, child.Name) end
            end
        end
    end)
    if #maps == 0 then return {"Desert Ruins", "Volcanic Chambers", "King's Castle", "Underworld", "Samurai Palace"} end
    return maps
end

local function getAvailableDifficulties()
    local diffs = {}
    pcall(function()
        local rightFill = findNested(player, "PlayerGui", "queueGui", "chooseDungeon", "backgroundFillRight")
        if rightFill then
            for _, child in ipairs(rightFill:GetChildren()) do
                if child:IsA("ImageLabel") then table.insert(diffs, child.Name) end
            end
        end
    end)
    if #diffs == 0 then return {"Easy", "Normal", "Hard", "Nightmare"} end
    return diffs
end

-- MACRO TAB ELEMENTS
local recordBtn = MakeButton("Start Recording Mode", Color3.fromRGB(180, 50, 50), macroPage)
local waypointRow = Instance.new("Frame")
waypointRow.Size = UDim2.new(1, 0, 0, 30)
waypointRow.BackgroundTransparency = 1
waypointRow.Parent = macroPage
local addWaypointBtn = MakeButton("Add Node", Color3.fromRGB(45, 110, 200), waypointRow)
addWaypointBtn.Size = UDim2.new(0.48, 0, 1, 0)
local clearWaypointsBtn = MakeButton("Clear Nodes", Color3.fromRGB(100, 100, 105), waypointRow)
clearWaypointsBtn.Size = UDim2.new(0.48, 0, 1, 0)
clearWaypointsBtn.Position = UDim2.new(0.52, 0, 0, 0)

local saveRow = Instance.new("Frame")
saveRow.Size = UDim2.new(1, 0, 0, 30)
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
actionRow.Size = UDim2.new(1, 0, 0, 30)
actionRow.BackgroundTransparency = 1
actionRow.Parent = macroPage
local exportBtn = MakeButton("Export to Clipboard", Color3.fromRGB(130, 80, 200), actionRow)
exportBtn.Size = UDim2.new(0.48, 0, 1, 0)
local deleteBtn = MakeButton("Delete Selected", Color3.fromRGB(180, 50, 50), actionRow)
deleteBtn.Size = UDim2.new(0.48, 0, 1, 0)
deleteBtn.Position = UDim2.new(0.52, 0, 0, 0)

-- SETTINGS TAB ELEMENTS
local lobbyConfigHeader = Instance.new("TextLabel")
lobbyConfigHeader.Size = UDim2.new(1, 0, 0, 24)
lobbyConfigHeader.BackgroundTransparency = 1
lobbyConfigHeader.Text = "Lobby Maker Setup:"
lobbyConfigHeader.TextColor3 = Color3.fromRGB(200, 200, 210)
lobbyConfigHeader.Font = Enum.Font.GothamBold
lobbyConfigHeader.TextSize = 13
lobbyConfigHeader.TextXAlignment = Enum.TextXAlignment.Left
lobbyConfigHeader.Parent = settingsPage

local autoLobbyRow = MakeButton("Auto Lobby Routine: " .. (SETTINGS.AutoLobbyEnabled and "ON" or "OFF"), SETTINGS.AutoLobbyEnabled and Color3.fromRGB(40, 150, 70) or Color3.fromRGB(40, 40, 50), settingsPage)
autoLobbyRow.MouseButton1Click:Connect(function()
    SETTINGS.AutoLobbyEnabled = not SETTINGS.AutoLobbyEnabled
    autoLobbyRow.Text = "Auto Lobby Routine: " .. (SETTINGS.AutoLobbyEnabled and "ON" or "OFF")
    autoLobbyRow.BackgroundColor3 = SETTINGS.AutoLobbyEnabled and Color3.fromRGB(40, 150, 70) or Color3.fromRGB(40, 40, 50)
    saveConfig()
end)

local roleRow = MakeButton("Lobby Role: " .. SETTINGS.LobbyMode:upper(), Color3.fromRGB(40, 100, 180), settingsPage)
roleRow.MouseButton1Click:Connect(function()
    SETTINGS.LobbyMode = (SETTINGS.LobbyMode == "Host") and "Join" or "Host"
    roleRow.Text = "Lobby Role: " .. SETTINGS.LobbyMode:upper()
    saveConfig()
end)

local joinNameInput = MakeSettingRow("Join Player Name:", SETTINGS.JoinPlayerName, settingsPage)
joinNameInput.PlaceholderText = "Friend's Username..."
joinNameInput.FocusLost:Connect(function()
    SETTINGS.JoinPlayerName = joinNameInput.Text
    saveConfig()
end)

local mapDropdown = MakeDropdownRow("Map Name:", getAvailableMaps, SETTINGS.LobbyMap, settingsPage, function(val)
    SETTINGS.LobbyMap = val
    saveConfig()
end)

local diffDropdown = MakeDropdownRow("Difficulty:", getAvailableDifficulties, SETTINGS.LobbyDifficulty, settingsPage, function(val)
    SETTINGS.LobbyDifficulty = val
    saveConfig()
end)

local partySizeInput = MakeSettingRow("Required Party Size (0 for solo):", SETTINGS.TargetPartySize, settingsPage)

local joinDungeonRow = Instance.new("Frame")
joinDungeonRow.Size = UDim2.new(1, 0, 0, 30)
joinDungeonRow.BackgroundTransparency = 1
joinDungeonRow.Parent = settingsPage

local forceJoinBtn = MakeButton("Create & Join Dungeon Now", Color3.fromRGB(40, 140, 200), joinDungeonRow)
forceJoinBtn.MouseButton1Click:Connect(function()
    task.spawn(function()
        local remotes = ReplicatedStorage:WaitForChild("remotes", 5)
        if not remotes then return end
        
        local createLobbyRemote = remotes:FindFirstChild("createLobby")
        safeInvoke(createLobbyRemote, SETTINGS.LobbyMap, SETTINGS.LobbyDifficulty, 0, SETTINGS.LobbyHardcore, SETTINGS.LobbyPrivate, false)
        
        task.wait(0.6)
        local joinRemote = remotes:FindFirstChild("joinDungeon")
        safeInvoke(joinRemote, player.Name)
        
        task.wait(1.0)
        local startDungeonRemote = remotes:FindFirstChild("startDungeon")
        safeInvoke(startDungeonRemote)
        task.wait(0.5)
        safeInvoke(startDungeonRemote)
    end)
end)

local hcRow = MakeButton("Hardcore Mode: OFF", Color3.fromRGB(40, 40, 50), settingsPage)
hcRow.MouseButton1Click:Connect(function()
    SETTINGS.LobbyHardcore = not SETTINGS.LobbyHardcore
    hcRow.Text = "Hardcore Mode: " .. (SETTINGS.LobbyHardcore and "ON" or "OFF")
    hcRow.BackgroundColor3 = SETTINGS.LobbyHardcore and Color3.fromRGB(40, 150, 70) or Color3.fromRGB(40, 40, 50)
    saveConfig()
end)

local privRow = MakeButton("Private Lobby: OFF", Color3.fromRGB(40, 40, 50), settingsPage)
privRow.MouseButton1Click:Connect(function()
    SETTINGS.LobbyPrivate = not SETTINGS.LobbyPrivate
    privRow.Text = "Private Lobby: " .. (SETTINGS.LobbyPrivate and "ON" or "OFF")
    privRow.BackgroundColor3 = SETTINGS.LobbyPrivate and Color3.fromRGB(40, 150, 70) or Color3.fromRGB(40, 40, 50)
    saveConfig()
end)

local sepHeader = Instance.new("TextLabel")
sepHeader.Size = UDim2.new(1, 0, 0, 24)
sepHeader.BackgroundTransparency = 1
sepHeader.Text = "Combat & Navigation Settings:"
sepHeader.TextColor3 = Color3.fromRGB(200, 200, 210)
sepHeader.Font = Enum.Font.GothamBold
sepHeader.TextSize = 13
sepHeader.TextXAlignment = Enum.TextXAlignment.Left
sepHeader.Parent = settingsPage

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

-- AUTO-SELL TAB ELEMENTS
local autoSellToggleBtn = MakeButton("Auto Sell: OFF", Color3.fromRGB(60, 60, 70), sellPage)
local sellNowBtn = MakeButton("Sell Matching Items Now", Color3.fromRGB(180, 100, 30), sellPage)

local catHeader = Instance.new("TextLabel")
catHeader.Size = UDim2.new(1, 0, 0, 24)
catHeader.BackgroundTransparency = 1
catHeader.Text = "Categories to Sell:"
catHeader.TextColor3 = Color3.fromRGB(200, 200, 210)
catHeader.Font = Enum.Font.GothamBold
catHeader.TextSize = 13
catHeader.TextXAlignment = Enum.TextXAlignment.Left
catHeader.Parent = sellPage

local catGrid = Instance.new("Frame")
catGrid.Size = UDim2.new(1, 0, 0, 64)
catGrid.BackgroundTransparency = 1
catGrid.Parent = sellPage
local catGridLayout = Instance.new("UIGridLayout")
catGridLayout.Parent = catGrid
catGridLayout.CellSize = UDim2.new(0.48, 0, 0, 28)
catGridLayout.CellPadding = UDim2.new(0.04, 0, 0, 6)

local catButtons = {}
for _, catName in ipairs({"weapon", "ability", "chest", "helmet"}) do
    local btn = MakeButton(catName:upper() .. ": OFF", Color3.fromRGB(40, 40, 50), catGrid)
    catButtons[catName] = btn
    btn.MouseButton1Click:Connect(function()
        SETTINGS.AutoSellCategories[catName] = not SETTINGS.AutoSellCategories[catName]
        local state = SETTINGS.AutoSellCategories[catName]
        btn.Text = catName:upper() .. ": " .. (state and "ON" or "OFF")
        btn.BackgroundColor3 = state and Color3.fromRGB(40, 150, 70) or Color3.fromRGB(40, 40, 50)
        saveConfig()
    end)
end

local rarityHeader = Instance.new("TextLabel")
rarityHeader.Size = UDim2.new(1, 0, 0, 24)
rarityHeader.BackgroundTransparency = 1
rarityHeader.Text = "Rarities to Sell:"
rarityHeader.TextColor3 = Color3.fromRGB(200, 200, 210)
rarityHeader.Font = Enum.Font.GothamBold
rarityHeader.TextSize = 13
rarityHeader.TextXAlignment = Enum.TextXAlignment.Left
rarityHeader.Parent = sellPage

local dropdownToggleBtn = MakeButton("Rarities Dropdown [Click to Expand ▼]", Color3.fromRGB(35, 45, 60), sellPage)

local rarityDropdownContainer = Instance.new("Frame")
rarityDropdownContainer.Size = UDim2.new(1, 0, 0, 180)
rarityDropdownContainer.BackgroundTransparency = 1
rarityDropdownContainer.Visible = false
rarityDropdownContainer.Parent = sellPage

local rarityListLayout = Instance.new("UIListLayout")
rarityListLayout.Parent = rarityDropdownContainer
rarityListLayout.SortOrder = Enum.SortOrder.LayoutOrder
rarityListLayout.Padding = UDim.new(0, 4)

local rarityButtons = {}
local RARITY_ORDER = {"common", "uncommon", "rare", "epic", "legendary", "ultimate"}

local function updateDropdownTitle()
    local activeRarities = {}
    for _, r in ipairs(RARITY_ORDER) do
        if SETTINGS.AutoSellRarities[r] then table.insert(activeRarities, r:upper()) end
    end
    if #activeRarities == 0 then dropdownToggleBtn.Text = "Rarities Dropdown [None Selected ▼]"
    else dropdownToggleBtn.Text = "Rarities [" .. table.concat(activeRarities, ", ") .. " ▼]" end
end

for _, rarityName in ipairs(RARITY_ORDER) do
    local btn = MakeButton(rarityName:upper() .. ": OFF", Color3.fromRGB(40, 40, 50), rarityDropdownContainer)
    btn.Size = UDim2.new(1, 0, 0, 26)
    rarityButtons[rarityName] = btn

    btn.MouseButton1Click:Connect(function()
        SETTINGS.AutoSellRarities[rarityName] = not SETTINGS.AutoSellRarities[rarityName]
        local state = SETTINGS.AutoSellRarities[rarityName]
        btn.Text = rarityName:upper() .. ": " .. (state and "ON" or "OFF")
        btn.BackgroundColor3 = state and Color3.fromRGB(40, 150, 70) or Color3.fromRGB(40, 40, 50)
        updateDropdownTitle()
        saveConfig()
    end)
end

dropdownToggleBtn.MouseButton1Click:Connect(function()
    rarityDropdownContainer.Visible = not rarityDropdownContainer.Visible
    dropdownToggleBtn.Text = rarityDropdownContainer.Visible and "Rarities Dropdown [Click to Close ▲]" or "Rarities Dropdown [Click to Expand ▼]"
    if not rarityDropdownContainer.Visible then updateDropdownTitle() end
end)

autoSellToggleBtn.MouseButton1Click:Connect(function()
    SETTINGS.AutoSellEnabled = not SETTINGS.AutoSellEnabled
    autoSellToggleBtn.Text = "Auto Sell: " .. (SETTINGS.AutoSellEnabled and "ON" or "OFF")
    autoSellToggleBtn.BackgroundColor3 = SETTINGS.AutoSellEnabled and Color3.fromRGB(40, 150, 70) or Color3.fromRGB(60, 60, 70)
    saveConfig()
end)

sellNowBtn.MouseButton1Click:Connect(function() executeAutoSell() end)

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

local function switchTab(activeBtn, activePage)
    macroTabBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
    settingsTabBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
    sellTabBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
    macroPage.Visible = false
    settingsPage.Visible = false
    sellPage.Visible = false

    activeBtn.BackgroundColor3 = Color3.fromRGB(50, 100, 200)
    activePage.Visible = true
end

macroTabBtn.MouseButton1Click:Connect(function() switchTab(macroTabBtn, macroPage) end)
settingsTabBtn.MouseButton1Click:Connect(function() switchTab(settingsTabBtn, settingsPage) end)
sellTabBtn.MouseButton1Click:Connect(function() switchTab(sellTabBtn, sellPage) end)

--------------------------------------------------------------------------------
-- 2. DISK PERSISTENCE & CONFIGURATION SYSTEM
--------------------------------------------------------------------------------
function saveConfig()
    if not writefile then return end
    pcall(function() if not isfolder(FOLDER_NAME) then makefolder(FOLDER_NAME) end end)
    
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
        NoEnemyDelay = SETTINGS.NoEnemyDelay,
        AutoSellEnabled = SETTINGS.AutoSellEnabled,
        HideUI = SETTINGS.HideUI,
        AutoSellRarities = SETTINGS.AutoSellRarities,
        AutoSellCategories = SETTINGS.AutoSellCategories,
        AutoLobbyEnabled = SETTINGS.AutoLobbyEnabled,
        LobbyMode = SETTINGS.LobbyMode,
        JoinPlayerName = SETTINGS.JoinPlayerName,
        LobbyMap = SETTINGS.LobbyMap,
        LobbyDifficulty = SETTINGS.LobbyDifficulty,
        LobbyHardcore = SETTINGS.LobbyHardcore,
        LobbyPrivate = SETTINGS.LobbyPrivate,
        TargetPartySize = SETTINGS.TargetPartySize
    }

    local encodeSuccess, encodedData = pcall(function() return HttpService:JSONEncode(cfgData) end)
    if encodeSuccess and encodedData then pcall(function() writefile(CONFIG_FILE, encodedData) end) end
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
partySizeInput.FocusLost:Connect(function() applySetting(partySizeInput, "TargetPartySize") end)

filterInput.FocusLost:Connect(function()
    SETTINGS.IgnoreKeywords = filterInput.Text
    updateIgnoreKeywords()
    saveConfig()
    statusLabel.Text = "Hazard filters updated!"
end)

local function rebuildIgnoreList()
    table.clear(persistentIgnoreList)
    if character then table.insert(persistentIgnoreList, character) end
    for _, nodePart in ipairs(visualNodes) do
        if nodePart and nodePart.Parent then table.insert(persistentIgnoreList, nodePart) end
    end
    raycastParams.FilterDescendantsInstances = persistentIgnoreList
    teleportRayParams.FilterDescendantsInstances = persistentIgnoreList
end

local function clearWaypoints()
    for _, nodePart in ipairs(visualNodes) do if nodePart then nodePart:Destroy() end end
    table.clear(visualNodes)
    table.clear(waypoints)
    rebuildIgnoreList()
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
    rebuildIgnoreList()
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
end

local function loadConfigAndAutoExecute()
    if not readfile or not isfile or not isfile(CONFIG_FILE) then refreshMacroList(); return end
    
    local readSuccess, fileData = pcall(function() return readfile(CONFIG_FILE) end)
    if not readSuccess or not fileData then refreshMacroList(); return end
    
    local success, cfg = pcall(function() return HttpService:JSONDecode(fileData) end)

    if success and type(cfg) == "table" then
        SETTINGS.MinDistance = cfg.MinDistance or SETTINGS.MinDistance
        SETTINGS.MaxDistance = cfg.MaxDistance or SETTINGS.MaxDistance
        SETTINGS.AttackReach = cfg.AttackReach or SETTINGS.AttackReach
        SETTINGS.AttackCooldown = cfg.AttackCooldown or SETTINGS.AttackCooldown
        SETTINGS.DodgeBuffer = cfg.DodgeBuffer or SETTINGS.DodgeBuffer
        SETTINGS.WaypointTriggerDist = cfg.WaypointTriggerDist or SETTINGS.WaypointTriggerDist
        SETTINGS.MaxNodeDistance = cfg.MaxNodeDistance or SETTINGS.MaxNodeDistance
        SETTINGS.WallRayLength = cfg.WallRayLength or SETTINGS.WallRayLength
        SETTINGS.NoEnemyDelay = cfg.NoEnemyDelay or SETTINGS.NoEnemyDelay
        SETTINGS.Webhook = cfg.Webhook or ""
        SETTINGS.IgnoreKeywords = cfg.IgnoreKeywords or SETTINGS.IgnoreKeywords
        
        if cfg.AutoLobbyEnabled ~= nil then SETTINGS.AutoLobbyEnabled = cfg.AutoLobbyEnabled end
        if cfg.LobbyMode then SETTINGS.LobbyMode = cfg.LobbyMode end
        if cfg.JoinPlayerName then SETTINGS.JoinPlayerName = cfg.JoinPlayerName end
        SETTINGS.LobbyMap = cfg.LobbyMap or SETTINGS.LobbyMap
        SETTINGS.LobbyDifficulty = cfg.LobbyDifficulty or SETTINGS.LobbyDifficulty
        SETTINGS.LobbyHardcore = cfg.LobbyHardcore or false
        SETTINGS.LobbyPrivate = cfg.LobbyPrivate or false
        SETTINGS.TargetPartySize = cfg.TargetPartySize or 0
        SETTINGS.AutoSellEnabled = cfg.AutoSellEnabled or false
        if cfg.HideUI ~= nil then SETTINGS.HideUI = cfg.HideUI end

        if cfg.AutoSellRarities and type(cfg.AutoSellRarities) == "table" then
            for rName, rVal in pairs(cfg.AutoSellRarities) do
                SETTINGS.AutoSellRarities[rName] = rVal
                if rarityButtons[rName] then
                    rarityButtons[rName].Text = rName:upper() .. ": " .. (rVal and "ON" or "OFF")
                    rarityButtons[rName].BackgroundColor3 = rVal and Color3.fromRGB(40, 150, 70) or Color3.fromRGB(40, 40, 50)
                end
            end
            updateDropdownTitle()
        end

        if cfg.AutoSellCategories and type(cfg.AutoSellCategories) == "table" then
            for cName, cVal in pairs(cfg.AutoSellCategories) do
                SETTINGS.AutoSellCategories[cName] = cVal
                if catButtons[cName] then
                    catButtons[cName].Text = cName:upper() .. ": " .. (cVal and "ON" or "OFF")
                    catButtons[cName].BackgroundColor3 = cVal and Color3.fromRGB(40, 150, 70) or Color3.fromRGB(40, 40, 50)
                end
            end
        end

        -- Sync UI
        autoLobbyRow.Text = "Auto Lobby Routine: " .. (SETTINGS.AutoLobbyEnabled and "ON" or "OFF")
        autoLobbyRow.BackgroundColor3 = SETTINGS.AutoLobbyEnabled and Color3.fromRGB(40, 150, 70) or Color3.fromRGB(40, 40, 50)
        roleRow.Text = "Lobby Role: " .. SETTINGS.LobbyMode:upper()
        joinNameInput.Text = SETTINGS.JoinPlayerName
        mapDropdown:SetValue(SETTINGS.LobbyMap)
        diffDropdown:SetValue(SETTINGS.LobbyDifficulty)
        autoSellToggleBtn.Text = "Auto Sell: " .. (SETTINGS.AutoSellEnabled and "ON" or "OFF")
        autoSellToggleBtn.BackgroundColor3 = SETTINGS.AutoSellEnabled and Color3.fromRGB(40, 150, 70) or Color3.fromRGB(60, 60, 70)
        hcRow.Text = "Hardcore Mode: " .. (SETTINGS.LobbyHardcore and "ON" or "OFF")
        hcRow.BackgroundColor3 = SETTINGS.LobbyHardcore and Color3.fromRGB(40, 150, 70) or Color3.fromRGB(40, 40, 50)
        privRow.Text = "Private Lobby: " .. (SETTINGS.LobbyPrivate and "ON" or "OFF")
        privRow.BackgroundColor3 = SETTINGS.LobbyPrivate and Color3.fromRGB(40, 150, 70) or Color3.fromRGB(40, 40, 50)
        partySizeInput.Text = tostring(SETTINGS.TargetPartySize)
        noEnemyDelayInput.Text = tostring(SETTINGS.NoEnemyDelay)

        updateIgnoreKeywords()

        if cfg.SelectedMacro then selectedMacroName = cfg.SelectedMacro end
        refreshMacroList()

        if cfg.Autoplay == true then
            if selectedMacroName ~= "" then loadMacroFromFile(selectedMacroName) end
            isAutoplay = true
            runMacroBtn.Text = "STOP AUTOPLAY"
            runMacroBtn.BackgroundColor3 = Color3.fromRGB(200, 40, 40)
            if not isInLobby() then
                -- Do nothing; heartbeat starts combat
            end
        end
    end
end

--------------------------------------------------------------------------------
-- SYSTEM HELPERS & CLEANUP
--------------------------------------------------------------------------------
local function cleanupPartConnections(obj)
    if hazardSignals[obj] then
        for _, conn in ipairs(hazardSignals[obj]) do conn:Disconnect() end
        hazardSignals[obj] = nil
    end
end

local function cleanup()
    isAutoplay = false
    isRecording = false
    isCasting = false
    isDodgeBlinking = false

    for _, conn in ipairs(connections) do conn:Disconnect() end
    table.clear(connections)

    for obj, _ in pairs(hazardSignals) do cleanupPartConnections(obj) end
    table.clear(hazardSignals)
    table.clear(activeHazards)
    table.clear(hazardTracking)
    table.clear(trackedHumanoids)
    table.clear(cachedInviswalls)

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

--------------------------------------------------------------------------------
-- ZERO-IMPACT INSTANT NAME SPOOFER
--------------------------------------------------------------------------------
local function applyFakeName(char)
    if not char then return end
    local function spoofLabel(nameLbl)
        if not nameLbl then return end
        nameLbl.Text = SPOOF_NAME
        local spoofConn
        spoofConn = nameLbl:GetPropertyChangedSignal("Text"):Connect(function()
            if nameLbl.Text ~= SPOOF_NAME then nameLbl.Text = SPOOF_NAME end
        end)
        table.insert(connections, spoofConn)
        local destroyConn
        destroyConn = nameLbl.AncestryChanged:Connect(function()
            if not nameLbl.Parent then spoofConn:Disconnect(); destroyConn:Disconnect() end
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
    activeDodgePoint = nil
    isDodgeBlinking = false
    hasReturnedToLobby = false
    characterSpawnTime = os.clock()
    postDodgeHoldUntil = 0
    lastEnemySeenTime = os.clock()
    lastStartValueTime = os.clock()
    rebuildIgnoreList()

    local diedConn
    diedConn = humanoid.Died:Connect(function()
        traversingManualNodes = false
        currentWaypointIndex = 1
        activeDodgePoint = nil
        isDodgeBlinking = false
        characterSpawnTime = os.clock()
        postDodgeHoldUntil = 0
        local dmManager = screenGui and screenGui:FindFirstChild("DungeonMacroManager")
        local statusLabel = dmManager and dmManager:FindFirstChild("TextLabel", true)
        if statusLabel then statusLabel.Text = "Status: Died -- nodes reset" end
        diedConn:Disconnect()
    end)
    table.insert(connections, diedConn)
    applyFakeName(character)
end
setupCharacterConstraints(character)
table.insert(connections, player.CharacterAdded:Connect(setupCharacterConstraints))

local function hasSpawnShield()
    if not character or not character.Parent then return false end
    if (os.clock() - characterSpawnTime) > SPAWN_SHIELD_DURATION then return false end
    if character:FindFirstChildOfClass("ForceField") then return true end
    for _, child in ipairs(character:GetChildren()) do
        if not child:IsA("Accessory") and not child:IsA("Tool") and not child:IsA("Clothing") then
            local name = child.Name:lower()
            if name:find("spawnshield") or name:find("forcefield") or name:find("invuln") or name:find("immunity") then return true end
        end
    end
    return false
end

local function findBestTarget()
    local closestMob, shortestDist = nil, math.huge
    for hum, _ in pairs(trackedHumanoids) do
        if hum and hum.Parent and hum.Health > 0 then
            local mob = hum.Parent
            if mob:IsA("Model") and mob ~= character and not Players:GetPlayerFromCharacter(mob) then
                local mobRoot = mob:FindFirstChild("HumanoidRootPart") or mob.PrimaryPart
                if mobRoot then
                    local dist = (mobRoot.Position - rootPart.Position).Magnitude
                    if dist < shortestDist then shortestDist = dist; closestMob = mob end
                end
            end
        elseif not hum or not hum.Parent then
            trackedHumanoids[hum] = nil
        end
    end
    return closestMob
end

--------------------------------------------------------------------------------
-- INTELLIGENT MULTI-SIGNAL HAZARD SCORING SYSTEM
--------------------------------------------------------------------------------
local HAZARD_KEYWORDS = { "cast", "spikes", "mage", "warrior", "hitbox", "damage", "hurt", "hazard", "danger", "warning", "telegraph", "indicator", "marker", "aoe", "blast", "explosion", "magic", "fire", "ice", "poison", "toxic", "meteor"}

local function scoreHazardPart(obj)
    if not obj:IsA("BasePart") then return 0 end
    local score = 0
    local name = obj.Name:lower()
    for _, kw in ipairs(HAZARD_KEYWORDS) do if name:find(kw) then score = score + 3; break end end
    if obj.Material == Enum.Material.Neon then
        score = score + 2
        local col = obj.Color
        if col.R > 0.5 and col.G < 0.3 then score = score + 2 end
    end
    if obj:FindFirstChildOfClass("ParticleEmitter") or obj:FindFirstChildOfClass("Fire") then score = score + 3 end
    if obj.Transparency > 0 and obj.Transparency < 1 then score = score + 1 end
    return score
end

local function evaluateAndAddHazardPart(obj)
    if not obj:IsA("BasePart") then return end
    if character and obj:IsDescendantOf(character) then return end
    if obj.Name == "Terrain" or obj.Name == "Baseplate" then return end
    local score = scoreHazardPart(obj)
    if score >= 3 then activeHazards[obj] = true else activeHazards[obj] = nil end
end

local function bindHazardEvents(obj)
    cleanupPartConnections(obj)
    local function onPropChanged() evaluateAndAddHazardPart(obj) end
    hazardSignals[obj] = {
        obj:GetPropertyChangedSignal("Transparency"):Connect(onPropChanged),
        obj:GetPropertyChangedSignal("Color"):Connect(onPropChanged),
        obj:GetPropertyChangedSignal("Size"):Connect(onPropChanged)
    }
end

local function handleInviswall(obj)
    if obj.Name:lower() == "inviswall" and obj:IsA("BasePart") then
        cachedInviswalls[obj] = true
        if math.max(obj.Size.X, obj.Size.Y, obj.Size.Z) < 80 then
            obj.CanCollide = false
            obj.Transparency = 1
            if not obj:FindFirstChildOfClass("PathfindingModifier") then
                local mod = Instance.new("PathfindingModifier")
                mod.PassThrough = true
                mod.Parent = obj
            end
        end
    end
end

local function onDescendantAdded(child)
    if child.Name == "Terrain" or child.Name == "Baseplate" or child:IsA("Camera") then return end
    handleInviswall(child)
    if child:IsA("BasePart") then
        evaluateAndAddHazardPart(child); bindHazardEvents(child)
    elseif child:IsA("Model") or child:IsA("Folder") then
        for _, desc in ipairs(child:GetDescendants()) do
            if desc:IsA("BasePart") then handleInviswall(desc); evaluateAndAddHazardPart(desc); bindHazardEvents(desc)
            elseif desc:IsA("Humanoid") then trackedHumanoids[desc] = true end
        end
    end
    if child:IsA("Humanoid") then trackedHumanoids[child] = true end
end

table.insert(connections, Workspace.DescendantAdded:Connect(onDescendantAdded))
table.insert(connections, Workspace.DescendantRemoving:Connect(function(child)
    cleanupPartConnections(child)
    if activeHazards[child] then activeHazards[child] = nil; hazardTracking[child] = nil end
    if trackedHumanoids[child] then trackedHumanoids[child] = nil end
    if cachedInviswalls[child] then cachedInviswalls[child] = nil end
    if child:IsA("Model") or child:IsA("Folder") then
        for _, desc in ipairs(child:GetDescendants()) do
            cleanupPartConnections(desc)
            if activeHazards[desc] then activeHazards[desc] = nil; hazardTracking[desc] = nil end
            if trackedHumanoids[desc] then trackedHumanoids[desc] = nil end
        end
    end
end))
for _, child in ipairs(Workspace:GetChildren()) do onDescendantAdded(child) end

local function getDangerousHazards(playerPos)
    local hazards = {}
    local now = os.clock()

    for part, _ in pairs(activeHazards) do
        if part and part.Parent then
            if part.Transparency < 1 then
                if (part.Position - playerPos).Magnitude > 150 then continue end
                local name = part.Name:lower()
                local isIgnored = false
                for _, kw in ipairs(parsedIgnoreKeywords) do if name:find(kw) then isIgnored = true; break end end

                if not isIgnored and math.max(part.Size.X, part.Size.Y, part.Size.Z) <= 300 then
                    local currentPos = part.Position
                    local velocity = part.AssemblyLinearVelocity or Vector3.zero

                    if hazardTracking[part] then
                        local dt = now - hazardTracking[part].lastTime
                        if dt > 0.01 then
                            velocity = (currentPos - hazardTracking[part].lastPos) / dt
                            hazardTracking[part] = {lastPos = currentPos, lastTime = now, velocity = velocity}
                        else velocity = hazardTracking[part].velocity end
                    else
                        hazardTracking[part] = {lastPos = currentPos, lastTime = now, velocity = velocity}
                    end

                    local shape = "Box"
                    if part:IsA("Part") then
                        if part.Shape == Enum.PartType.Ball then shape = "Ball"
                        elseif part.Shape == Enum.PartType.Cylinder then shape = "Cylinder" end
                    end

                    table.insert(hazards, { cframe = part.CFrame, size = part.Size, name = part.Name, velocity = velocity, shape = shape })
                end
            end
        else
            cleanupPartConnections(part); activeHazards[part] = nil; hazardTracking[part] = nil
        end
    end
    return hazards
end

local function getDistanceToHazard(localP, hazard)
    if hazard.shape == "Ball" then return localP.Magnitude - (math.min(hazard.size.X, hazard.size.Y, hazard.size.Z) / 2)
    elseif hazard.shape == "Cylinder" then
        return math.max(math.sqrt(localP.Y^2 + localP.Z^2) - (math.max(hazard.size.Y, hazard.size.Z) / 2), math.abs(localP.X) - (hazard.size.X / 2))
    else
        return math.max(math.abs(localP.X) - (hazard.size.X / 2), math.abs(localP.Y) - (hazard.size.Y / 2), math.abs(localP.Z) - (hazard.size.Z / 2))
    end
end

local function isPointInDanger(point, hazards)
    local minHazardDist = math.huge
    for _, hazard in ipairs(hazards) do
        local dEdge = getDistanceToHazard(hazard.cframe:PointToObjectSpace(point), hazard)
        if dEdge < minHazardDist then minHazardDist = dEdge end
        if dEdge <= SETTINGS.DodgeBuffer then return true, hazard.name, hazard, minHazardDist end

        if hazard.velocity.Magnitude > 5 then
            for t = 0.15, 0.75, 0.2 do
                local futurePos = hazard.cframe.Position + (hazard.velocity * t)
                local fdEdge = getDistanceToHazard((hazard.cframe - hazard.cframe.Position + futurePos):PointToObjectSpace(point), hazard)
                if fdEdge < minHazardDist then minHazardDist = fdEdge end
                if fdEdge <= (SETTINGS.DodgeBuffer * 2) then return true, hazard.name .. " (Incoming)", hazard, minHazardDist end
            end
        end
    end
    return false, nil, nil, minHazardDist
end

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
                local flatSlide = Vector3.new(slideDir.X, 0, slideDir.Z)
                if flatSlide.Magnitude > 0.05 then return startPos + (flatSlide.Unit * math.min(dist, 10)) end
            end
        end
    end
    return rawTargetPos
end

local activePathWaypoints, pathIndex = {}, 1
local lastPathComputeTime = 0
local pathObject = PathfindingService:CreatePath({AgentRadius = 2.5, AgentHeight = 5.0, AgentCanJump = true, AgentCanClimb = false, WaypointSpacing = 12})

local function isValidTeleport(startPos, endPos)
    local direction = endPos - startPos
    local wallRayResult = Workspace:Raycast(startPos, direction, teleportRayParams)
    if wallRayResult and wallRayResult.Instance and wallRayResult.Instance.CanCollide then
        local hitModel = wallRayResult.Instance:FindFirstAncestorOfClass("Model")
        local isEntity = hitModel and (hitModel:FindFirstChildOfClass("Humanoid") or Players:GetPlayerFromCharacter(hitModel))
        if not isEntity then return false end
    end
    local groundRayResult = Workspace:Raycast(endPos + Vector3.new(0, 3.5, 0), Vector3.new(0, -28.5, 0), teleportRayParams)
    if not groundRayResult or not groundRayResult.Instance or not groundRayResult.Instance.CanCollide then return false end
    return (endPos.Y - groundRayResult.Position.Y) >= -1.0 and (endPos.Y - groundRayResult.Position.Y) <= 10.0
end

local lastMoveToPos, lastMoveToTime = Vector3.zero, 0
local stuckCheckPos, stuckCheckTime = Vector3.zero, os.clock()
local lastTpDodgeTime = 0

local function smoothMoveTo(pos)
    if not humanoid or humanoid.Health <= 0 or not rootPart or isDodgeBlinking then return end
    local glidedPos = getGlidedTargetPos(rootPart.Position, pos)
    if (glidedPos - lastMoveToPos).Magnitude > 1.0 or (os.clock() - lastMoveToTime) > 0.35 then
        lastMoveToPos, lastMoveToTime = glidedPos, os.clock()
        humanoid:MoveTo(glidedPos)
    end
end

local function executeSafeBlink(destination, facingPos)
    if isDodgeBlinking or not rootPart or not humanoid or humanoid.Health <= 0 then return end
    isDodgeBlinking = true
    humanoid:MoveTo(rootPart.Position)
    local startPos = rootPart.Position
    local delta = destination - startPos
    local stepVec = delta / 4
    local lookTarget = facingPos or (destination + delta)

    task.spawn(function()
        for i = 1, 4 do
            if not rootPart or not rootPart.Parent or humanoid.Health <= 0 then break end
            local nextPos = rootPart.Position + stepVec
            rootPart.CFrame = CFrame.new(nextPos, Vector3.new(lookTarget.X, nextPos.Y, lookTarget.Z))
            rootPart.AssemblyLinearVelocity = stepVec.Unit * (MOVE_SPEED * 1.5)
            RunService.Heartbeat:Wait()
        end
        if rootPart and rootPart.Parent then rootPart.AssemblyLinearVelocity = Vector3.zero end
        isDodgeBlinking = false
        postDodgeHoldUntil = os.clock() + 0.85
    end)
end

--------------------------------------------------------------------------------
-- UNIFIED MAIN LOOP
--------------------------------------------------------------------------------
local lastAttackSequenceTime = 0

local mainConnection = RunService.Heartbeat:Connect(function(deltaTime)
    if not isAutoplay then return end

    if isInLobby() then
        handleLobbyAutomation()
        return 
    end

    local now = os.clock()

    -- =========================================================================
    -- AUTO-START DUNGEON
    -- Ensures the match begins once teleported into the map 
    -- =========================================================================
    if now - lastStartValueTime > 3.0 then
        lastStartValueTime = now
        pcall(function()
            local remotes = ReplicatedStorage:FindFirstChild("remotes")
            if remotes then
                local changeStartValue = remotes:FindFirstChild("changeStartValue")
                safeInvoke(changeStartValue)
            end
        end)
    end

    if not humanoid or humanoid.Health <= 0 or not rootPart or isDodgeBlinking or hasReturnedToLobby then return end

    local playerPos = rootPart.Position

    if now - lastInvCheckTime > 3.0 then
        lastInvCheckTime = now
        checkInventoryFull()
        if hasReturnedToLobby then return end
    end

    local hazards = getDangerousHazards(playerPos)
    local activeTarget = findBestTarget()

    -- Auto Replay If No Enemies Detected
    if activeTarget then
        lastEnemySeenTime = now
    else
        if (now - lastEnemySeenTime) >= SETTINGS.NoEnemyDelay then
            local dmManager = screenGui and screenGui:FindFirstChild("DungeonMacroManager")
            local statusLabel = dmManager and dmManager:FindFirstChild("TextLabel", true)
            if statusLabel then statusLabel.Text = "Status: No enemies found! Replaying..." end
            lastEnemySeenTime = now + 9999 
            fireReplayDungeonRemote()
            return
        end
    end

    ----------------------------------------------------------------------------
    -- COMBAT
    ----------------------------------------------------------------------------
    if not isCasting and (now - lastAttackSequenceTime >= SETTINGS.AttackCooldown) then
        if activeTarget and activeTarget:FindFirstChild("HumanoidRootPart") then
            local tRoot = activeTarget.HumanoidRootPart
            local distToTarget = (playerPos - tRoot.Position).Magnitude

            if distToTarget <= SETTINGS.AttackReach then
                local rayResult = Workspace:Raycast(playerPos + Vector3.new(0, 1.8, 0), (tRoot.Position - playerPos), raycastParams)
                if not rayResult or not rayResult.Instance.CanCollide or rayResult.Instance:IsDescendantOf(activeTarget) then
                    isCasting = true
                    local capturedTarget = activeTarget

                    task.spawn(function()
                        local function faceEnemy()
                            if capturedTarget and capturedTarget:FindFirstChild("HumanoidRootPart") and alignOrient and alignOrient.Parent and rootPart then
                                alignOrient.CFrame = CFrame.lookAt(rootPart.Position, Vector3.new(capturedTarget.HumanoidRootPart.Position.X, rootPart.Position.Y, capturedTarget.HumanoidRootPart.Position.Z))
                            end
                        end
                        faceEnemy()
                        task.wait(0.04)
                        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Q, false, game); task.wait(0.06); VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Q, false, game)
                        task.wait(math.max(SETTINGS.AttackCooldown, 0.22))
                        if capturedTarget and capturedTarget:FindFirstChild("HumanoidRootPart") and (rootPart.Position - capturedTarget.HumanoidRootPart.Position).Magnitude <= SETTINGS.AttackReach then
                            faceEnemy()
                            task.wait(0.04)
                            VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.E, false, game); task.wait(0.06); VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game)
                        end
                        lastAttackSequenceTime = os.clock()
                        isCasting = false
                    end)
                end
            end
        end
    end

    ----------------------------------------------------------------------------
    -- MOVEMENT & DODGING
    ----------------------------------------------------------------------------
    local currentlyInDanger = false
    if not hasSpawnShield() then currentlyInDanger = isPointInDanger(playerPos, hazards) end

    if now < postDodgeHoldUntil and not currentlyInDanger then
        if activeTarget and activeTarget:FindFirstChild("HumanoidRootPart") and (playerPos - activeTarget.HumanoidRootPart.Position).Magnitude < SETTINGS.MinDistance then
            smoothMoveTo(playerPos + (playerPos - activeTarget.HumanoidRootPart.Position).Unit * 8)
        end
        return
    end

    if currentlyInDanger or (activeDodgePoint and now < dodgeExpiration) then
        if not activeDodgePoint or now >= dodgeExpiration or isPointInDanger(activeDodgePoint, hazards) then
            local enemyPos = activeTarget and activeTarget:FindFirstChild("HumanoidRootPart") and activeTarget.HumanoidRootPart.Position or playerPos
            local idealCombatDist = (SETTINGS.MinDistance + SETTINGS.MaxDistance) * 0.5
            local bestCandidate, bestExitCandidate = nil, nil
            local bestScore, bestExitClearance = math.huge, -math.huge

            for _, dist in ipairs({2, 3.5, 5, 7, 9, 12, 16, 20, 25, 30, 38}) do
                for _, dir in ipairs(DODGE_DIRECTIONS) do
                    local candidate = playerPos + dir * dist
                    local inDanger, _, _, clearance = isPointInDanger(candidate, hazards)
                    if not inDanger then
                        local score = (dist <= 8 and -45 or 0) - math.min(clearance, 12) + dist * 0.35 + math.abs((candidate - enemyPos).Magnitude - idealCombatDist) * 0.04
                        if score < bestScore and isValidTeleport(playerPos, candidate) then bestScore = score; bestCandidate = candidate end
                    elseif clearance > bestExitClearance then bestExitClearance = clearance; bestExitCandidate = candidate end
                end
            end
            activeDodgePoint = bestCandidate or (bestExitCandidate and isValidTeleport(playerPos, bestExitCandidate) and bestExitCandidate)
            dodgeExpiration  = activeDodgePoint and (now + 0.9) or 0
        end

        if activeDodgePoint then
            local toTarget = activeDodgePoint - playerPos
            local dist = toTarget.Magnitude
            if dist < 1.5 then activeDodgePoint = nil; dodgeExpiration = 0; return end

            if not isCasting and alignOrient and alignOrient.Parent then
                alignOrient.CFrame = CFrame.lookAt(playerPos, Vector3.new(activeDodgePoint.X, playerPos.Y, activeDodgePoint.Z))
            end

            if now - lastTpDodgeTime >= 0.88 then
                if dist <= 9 and isValidTeleport(playerPos, activeDodgePoint) then
                    lastTpDodgeTime = now
                    executeSafeBlink(activeDodgePoint, activeDodgePoint + toTarget)
                    activeDodgePoint = nil
                else
                    smoothMoveTo(activeDodgePoint)
                end
            else smoothMoveTo(activeDodgePoint) end
        end
        return
    end

    activeDodgePoint = nil

    if (playerPos - stuckCheckPos).Magnitude < 0.75 then
        if now - stuckCheckTime > 0.4 then humanoid.Jump = true; stuckCheckTime = now end
    else stuckCheckPos = playerPos; stuckCheckTime = now end

    local function safeSmoothMoveTo(targetPos) smoothMoveTo(targetPos) end

    if #waypoints > 0 then
        if currentWaypointIndex <= #waypoints then
            local targetNode = waypoints[currentWaypointIndex]
            local distToNode = (playerPos - targetNode).Magnitude
            if not traversingManualNodes or distToNode > SETTINGS.MaxNodeDistance then
                local nearIdx = nil
                for i = currentWaypointIndex, #waypoints do
                    if (playerPos - waypoints[i]).Magnitude <= SETTINGS.WaypointTriggerDist then nearIdx = i; break end
                end
                if nearIdx then currentWaypointIndex = nearIdx; traversingManualNodes = true else traversingManualNodes = false end
            end
            if traversingManualNodes then
                local dmManager = screenGui and screenGui:FindFirstChild("DungeonMacroManager")
                local statusLabel = dmManager and dmManager:FindFirstChild("TextLabel", true)
                if statusLabel and statusLabel.Text:sub(1,6) ~= "Status" then
                    statusLabel.Text = string.format("MACRO ACTIVE: Node %d/%d (%.1f st)", currentWaypointIndex, #waypoints, distToNode)
                end
                safeSmoothMoveTo(targetNode)
                if distToNode <= 3.8 then currentWaypointIndex = currentWaypointIndex + 1 end
                return
            end
        else traversingManualNodes = false end
    end

    if activeTarget and activeTarget:FindFirstChild("HumanoidRootPart") then
        local enemyPos = activeTarget.HumanoidRootPart.Position
        if not isCasting and alignOrient and alignOrient.Parent then alignOrient.CFrame = CFrame.lookAt(playerPos, Vector3.new(enemyPos.X, playerPos.Y, enemyPos.Z)) end

        local distToEnemy = (playerPos - enemyPos).Magnitude
        if distToEnemy <= SETTINGS.MaxDistance then
            table.clear(activePathWaypoints)
            if distToEnemy < SETTINGS.MinDistance then safeSmoothMoveTo(playerPos + (playerPos - enemyPos).Unit * 14)
            else
                local strafeDir = Vector3.new(-(enemyPos - playerPos).Z, 0, (enemyPos - playerPos).X).Unit
                if math.floor(now * 0.7) % 2 == 1 then strafeDir = -strafeDir end
                safeSmoothMoveTo(playerPos + strafeDir * 6)
            end
        else
            if now - lastPathComputeTime > PATH_RECOMPUTE_INTERVAL then
                lastPathComputeTime = now
                if pcall(function() pathObject:ComputeAsync(playerPos, enemyPos) end) and pathObject.Status == Enum.PathStatus.Success then
                    activePathWaypoints = pathObject:GetWaypoints(); pathIndex = 2
                else safeSmoothMoveTo(enemyPos) end
            end
            if #activePathWaypoints > 0 and pathIndex <= #activePathWaypoints then
                if activePathWaypoints[pathIndex].Action == Enum.PathWaypointAction.Jump then humanoid.Jump = true end
                safeSmoothMoveTo(activePathWaypoints[pathIndex].Position)
                if (playerPos - activePathWaypoints[pathIndex].Position).Magnitude <= 4.5 then pathIndex = pathIndex + 1 end
            end
        end
    end
end)
table.insert(connections, mainConnection)

-- UI BUTTON BINDINGS
recordBtn.MouseButton1Click:Connect(function()
    isRecording = not isRecording
    recordBtn.Text = isRecording and "Stop Recording Mode" or "Start Recording Mode"
    recordBtn.BackgroundColor3 = isRecording and Color3.fromRGB(220, 100, 30) or Color3.fromRGB(180, 50, 50)
    
    local dmManager = screenGui and screenGui:FindFirstChild("DungeonMacroManager")
    local statusLabel = dmManager and dmManager:FindFirstChild("TextLabel", true)
    if statusLabel then
        statusLabel.Text = isRecording and "Status: Recording Mode Active" or "Status: Recording Stopped"
    end
end)
addWaypointBtn.MouseButton1Click:Connect(function()
    if isRecording then 
        addWaypointNode() 
    else
        local dmManager = screenGui and screenGui:FindFirstChild("DungeonMacroManager")
        local statusLabel = dmManager and dmManager:FindFirstChild("TextLabel", true)
        if statusLabel then statusLabel.Text = "Error: Enable Recording Mode first!" end
    end 
end)
clearWaypointsBtn.MouseButton1Click:Connect(clearWaypoints)
runMacroBtn.MouseButton1Click:Connect(function()
    isAutoplay = not isAutoplay
    runMacroBtn.Text = isAutoplay and "STOP AUTOPLAY" or "RUN SCRIPT (Autoplay)"
    runMacroBtn.BackgroundColor3 = isAutoplay and Color3.fromRGB(200, 40, 40) or Color3.fromRGB(30, 180, 100)
    hasReturnedToLobby = false
    lastEnemySeenTime = os.clock()
    if isAutoplay then
        if #waypoints == 0 and selectedMacroName ~= "" then loadMacroFromFile(selectedMacroName) end
    end
    saveConfig()
end)
terminateBtn.MouseButton1Click:Connect(cleanup)

-- RIGHT SHIFT UI TOGGLE
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.KeyCode == Enum.KeyCode.RightShift then
        if screenGui then
            SETTINGS.HideUI = not screenGui.Enabled
            screenGui.Enabled = not SETTINGS.HideUI
            saveConfig()
        end
    end
end)

loadConfigAndAutoExecute()

-- Apply saved HideUI state after configuration has loaded.
if screenGui then
    screenGui.Enabled = not SETTINGS.HideUI
end
