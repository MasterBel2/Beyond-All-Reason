-- OUTLINE:
-- Passive cons build either at their full speed or not at all.
-- The amount of res expense for non-passive cons is calculated (as total expense - passive cons expense) and the remainder is available to the passive cons, if any.
-- We cycle through the passive cons and allocate this expense until it runs out. All other passive cons have their buildspeed set to 0.

-- ACTUALLY:
-- We only do the check every x frames (controlled by interval) and only allow passive con(s) to act if doing so allows them to sustain their expense
--   until the next check, based on current expense allocations.
-- We allow the interval to be different for each team, because normally it would be wasteful to reconfigure every frame, but if a team has a high income and low
--   storage then not doing the check every frame would result in excessing resources that passive builders could have used
-- We also pick one passive con, per build target, and allow it a tiny build speed for 1 frame per interval, to prevent nanoframes that only have passive cons
--   building them from decaying if a prolonged stall occurs.
-- We cache the buildspeeds of all passive cons to prevent constant use of get/set callouts.

-- REASON:
-- AllowUnitBuildStep is damn expensive and is a serious perf hit if it is used for all this.

function gadget:GetInfo()
    return {
        name      = 'Passive Builders v3',
        desc      = 'Builders marked as passive only use resources after others builder have taken their share',
        author    = 'BD, Bluestone',
        date      = 'Why is date even relevant',
        license   = 'GNU GPL, v2 or later',
        layer     = 0,
        enabled   = true
    }
end

----------------------------------------------------------------
-- Synced only
----------------------------------------------------------------
if not gadgetHandler:IsSyncedCode() then
    return false
end

----------------------------------------------------------------
-- Var
----------------------------------------------------------------
local CMD_PASSIVE = 34571

local stallMarginInc = 0.2
local stallMarginSto = 0.01

local passiveCons = {} -- passiveCons[teamID][builderID]
local teamStalling = {} -- teamStalling[teamID] = {resName = res leftover after non-passive cons took their share}

local buildTargets = {} --the unitIDs of build targets of passive builders
local buildTargetOwners = {} --each build target has one passive builder that doesn't turn fully off, to stop the building decaying

local canBuild = {} --builders[teamID][builderID], contains all builders
local realBuildSpeed = {} --build speed of builderID, as in UnitDefs (contains all builders)
local currentBuildSpeed = {} --build speed of builderID for current interval, not accounting for buildOwners special speed (contains only passive builders)

local costID = {} -- costID[unitID] (contains all units)

local ruleName = "passiveBuilders"

local resTable = {"metal","energy"}

local cmdPassiveDesc = {
      id      = CMD_PASSIVE,
      name    = 'passive',
      action  = 'passive',
      type    = CMDTYPE.ICON_MODE,
      tooltip = 'Builder Mode: Passive wont build when stalling',
      params  = {0, 'Active', 'Passive'}
}

----------------------------------------------------------------
-- Speedups
----------------------------------------------------------------
local spInsertUnitCmdDesc = Spring.InsertUnitCmdDesc
local spFindUnitCmdDesc = Spring.FindUnitCmdDesc
local spGetUnitCmdDescs = Spring.GetUnitCmdDescs
local spEditUnitCmdDesc = Spring.EditUnitCmdDesc
local spGetTeamResources = Spring.GetTeamResources
local spGetTeamList = Spring.GetTeamList
local spGetUnitDefID = Spring.GetUnitDefID
local spSetUnitRulesParam = Spring.SetUnitRulesParam
local spSetUnitBuildSpeed = Spring.SetUnitBuildSpeed
local spGetUnitIsBuilding = Spring.GetUnitIsBuilding
local spValidUnitID = Spring.ValidUnitID
local simSpeed = Game.gameSpeed

local min = math.min
local max = math.max
local floor = math.floor

local teams = {}
local builders = {}

local canPassive = {}
for unitDefID, unitDef in pairs(UnitDefs) do
    canPassive[unitDefID] = ((unitDef.canAssist and unitDef.buildSpeed > 0) or #unitDef.buildOptions > 0)
end

-- MARK: Objects

function Builder(unitID, unitDef, isPassive)
    local newBuilder = {}
    newBuilder.unitID = unitID
    newBuilder.unitDef = unitDef or UnitDef(unitID)
    newBuilder.isPassive = isPassive or false
    newBuilder.buildSpeed = unitDef.buildSpeed
    return newBuilder
end

function SetPassive(unitID)
    builders[unitID].isPassive = true
    Spring.Echo("Builder " .. unitID .. " is now in Passive mode. Was building with a buildspeed of " .. builders[unitID].buildSpeed)
end

function SetActive(unitID)
    local builder = builders[unitID]
    Spring.Echo("Builder " .. unitID .. " is now in Active mode. Was building with a buildspeed of " .. builder.buildSpeed)
    spSetUnitBuildSpeed(unitID, builder.unitDef.buildSpeed)
    builder.isPassive = false
    builder.buildSpeed = builder.unitDef.buildSpeed
end

function Team(buildersNotBuilding, buildTargets)
    local newTeam = {}
    newTeam.buildersNotBuilding = buildersNotBuilding or {}
    newTeam.buildTargets = buildTargets or {}
    return newTeam
end

function GetResources(teamID)
    local currentMetal = spGetTeamResources(teamID, "metal")
    local currentEnergy = spGetTeamResources(teamID, "energy") 
    return Expense(currentMetal, currentEnergy)
end

function UnitDef(unitID)
    return UnitDefs[spGetUnitDefID(unitID)]
end

function AddBuilder(builderID, builderUnitDefID, teamID)
    local builder = Builder(builderID, UnitDefs[builderUnitDefID])
    builders[builderID] = builder
    teams[teamID].buildersNotBuilding[builderID] = builder
end

function RemoveBuilder(teamID, builderID)
    local team = teams[teamID]

    builders[builderID] = nil
    team.buildersNotBuilding[builderID] = nil

    for _,target in pairs(team.buildTargets) do
        target.builders[builderID] = nil
    end
end 

function Copy(expense)
    return Expense(expense.metal, expense.energy)
end
function Expense(metal, energy)
    local newExpense = {}
    newExpense.metal = metal or 0
    newExpense.energy = energy or 0
    return newExpense
end
function ExpenseFor(unitDef)
    return Expense(unitDef.metalCost, unitDef.energyCost)
end

function Add(expense, otherExpense)
    -- Spring.Echo("Initial expense: " .. expense.metal .. ", " .. expense.energy .. ". Adding " .. otherExpense.metal .. ", " .. otherExpense.energy)
    expense.metal = expense.metal + otherExpense.metal
    expense.energy = expense.energy + otherExpense.energy
    -- Spring.Echo("Final expense: " .. expense.metal .. ", " .. expense.energy .. ".")
end
function Subtract(expense, otherExpense, cap)
    expense.metal = expense.metal - otherExpense.metal
    expense.energy = expense.energy - otherExpense.energy
end
function Multiply(expense, number)
    expense.metal = expense.metal * number
    expense.energy = expense.energy * number
end
function Divide(expense, number)
    expense.metal = expense.metal / number
    expense.energy = expense.energy / number
end

function BuildTarget(builders, unitID, remainingExpense)
    local newTarget = {}
    newTarget.builders = builders
    newTarget.unitID = unitID
    newTarget.unitDef = UnitDef(unitID)
    newTarget.remainingExpense = remainingExpense or ExpenseFor(newTarget.unitDef)
    return newTarget
end

function TotalExpenses(buildTarget)
    local expenses = {}
    expenses[true] = Expense()
    expenses[false] = Expense()
    
    for builderID,builder in pairs(buildTarget.builders) do
        if not IsUnitValid(builder) then
            buildTarget.builders[builderID] = nil
            break
        end
        Add(expenses[builder.isPassive], IdealExpense(buildTarget, builder))
    end
    return expenses
end

function MinExpense(expense1, expense2)
    return Expense(min(expense1.metal, expense2.metal), min(expense1.energy, expense2.energy))
end

function IdealExpense(buildTarget, builder)
    local idealExpense = ExpenseFor(buildTarget.unitDef)
    local rate = builder.unitDef.buildSpeed / buildTarget.unitDef.buildTime
    Multiply(idealExpense, rate)
    return idealExpense
end

-- MARK: Spring Commands

function IsUnitValid(unit)
    return Spring.ValidUnitID(unit.unitID)
end

-- MARK: Helpers

function Clamp(number, lowerBound, upperBound)
    return max(min(number, upperBound), lowerBound)
end

----------------------------------------------------------------
-- Callins
----------------------------------------------------------------
function gadget:Initialize()
    for _,teamID in pairs(Spring.GetTeamList()) do
        teams[teamID] = Team()
    end

    for _,unitID in pairs(Spring.GetAllUnits()) do
        gadget:UnitCreated(unitID, spGetUnitDefID(unitID), Spring.GetUnitTeam(unitID))
    end
end

function gadget:UnitCreated(unitID, unitDefID, teamID)
    if canPassive[unitDefID] then
        spInsertUnitCmdDesc(unitID, cmdPassiveDesc)
        AddBuilder(unitID, unitDefID, teamID)
    end
end

function gadget:UnitGiven(unitID, unitDefID, newTeamID, oldTeamID)
    if canPassive[unitDefID] then
        local oldTeam = teams[oldTeamID]
        local newTeam = teams[newTeamID]

        local builder = oldTeam.buildersNotBuilding[unitID]
        
        if builder then
            oldTeam.buildersNotBuilding[unitID] = nil
            newTeam.buildersNotBuilding[unitID] = builder
        end

        for targetID,target in pairs(oldTeam.buildTargets) do
            local builder = target.builders[unitID]
            if builder then
                target.builders[unitID] = nil
                local newTarget = newTeam.buildTargets[targetID] or BuildTarget({}, unitID)
                newTarget.builders[unitID] = builder
                newTeam.buildTargets[target.unitID] = newTarget
                break
            end
        end
    end
end

function gadget:UnitTaken(unitID, unitDefID, oldTeamID, newTeamID)
    gadget:UnitGiven(unitID, unitDefID, newTeamID, oldTeamID)
end

function gadget:UnitDestroyed(unitID, unitDefID, teamID)
    if canPassive[unitDefID] then
        RemoveBuilder(teamID, unitID)
    end
end

function gadget:AllowCommand(unitID, unitDefID, teamID, cmdID, cmdParams, cmdOptions, cmdTag, playerID, fromSynced, fromLua)
    -- track which cons are set to passive
    if cmdID == CMD_PASSIVE and canPassive[unitDefID] then
        local cmdIdx = spFindUnitCmdDesc(unitID, CMD_PASSIVE)
        if cmdIdx then
            local cmdDesc = spGetUnitCmdDescs(unitID, cmdIdx, cmdIdx)[1]
            cmdDesc.params[1] = cmdParams[1]
            spEditUnitCmdDesc(unitID, cmdIdx, cmdDesc)
            spSetUnitRulesParam(unitID,ruleName,cmdParams[1])
            if cmdParams[1] == 1 then
                SetPassive(unitID)
            else
                SetActive(unitID)
            end
        end
        return false -- Allowing command causes command queue to be lost if command is unshifted
    end
    return true
end

function gadget:GameFrame(n)
    for teamID,team in pairs(teams) do
        -- Check if any idle builders are building now
        for _,builder in pairs(team.buildersNotBuilding) do
            local targetID = spGetUnitIsBuilding(builder.unitID)
            if targetID then
                local target = team.buildTargets[targetID]
                if target then
                    target.builders[builder.unitID] = builder
                else
                    local builders = {}
                    builders[builder.unitID] = builder
                    team.buildTargets[targetID] = BuildTarget(builders, targetID)
                end
            end
        end

        -- Check if any builders have stopped building
        for _,buildTarget in pairs(team.buildTargets) do
            for builderID, builder in pairs(buildTarget.builders) do
                local targetID = spGetUnitIsBuilding(builderID)
                if targetID then
                    if targetID ~= buildTarget.unitID then
                        buildTarget.builders[builder.unitID] = nil
                        team[targetID].builders[builder.unitID] = builder
                    end
                else
                    buildTarget.builders[builder.unitID] = nil
                    team.buildersNotBuilding[builder.unitID] = builder
                end
            end
        end

        -- Calculate expenses
        local activeConstructorExpense = Expense()
        local passiveConstructorExpense = Expense()

        for buildTargetID,buildTarget in pairs(team.buildTargets) do
            if not IsUnitValid(buildTarget) then
                team.buildTargets[buildTargetID] = nil
                Spring.Echo(buildTargetID .. "was not a valid unit!")
                break
            end
            local expenses = TotalExpenses(buildTarget)
            Add(activeConstructorExpense, expenses[false])
            Add(passiveConstructorExpense, expenses[true])
        end
        
        -- Calculate how much passive builders must be slowed by

        local remainingExpense = GetResources(teamID)
        Subtract(remainingExpense, activeConstructorExpense)

        local passiveConstructorSpeedFactor = min(remainingExpense.metal / passiveConstructorExpense.metal, remainingExpense.energy / passiveConstructorExpense.energy)
        passiveConstructorSpeedFactor = Clamp(passiveConstructorSpeedFactor, 0, 1)
        
        for _,buildTarget in pairs(team.buildTargets) do
            for builderID,builder in pairs(buildTarget.builders) do
                if builder.isPassive then
                    spSetUnitBuildSpeed(builderID, builder.unitDef.buildSpeed * passiveConstructorSpeedFactor)
                    builder.buildSpeed = builder.unitDef.buildSpeed * passiveConstructorSpeedFactor
                end
            end
        end
    end
end