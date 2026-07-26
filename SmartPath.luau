--[[
	Connected Discord-GitHub
	Discord Username: draxxordev
	Roblox Username: StarBossoms2
	
	SmartPath Module - Advanced rig AI System
	An advanced rig AI system for games featuring smart pathfinding, expandable
	for target detection, and combat mechanics. This module demonstrates advanced OOP
	with metatables, raycasting, and the PathfindingService API.
]]

local PathfindingService = game:GetService("PathfindingService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

-- Module initialization with an __indexed metatable for the OOP pattern
local SmartPath = {}
SmartPath.__index = SmartPath

--[[
	Type Definition for SmartPath Configuration
	Defines all required parameters for initializing an rig with AI capabilities.
	
	Config Structure:
	- Rig: Model | The rig's model in workspace
	
	- WaypointsFolder: Folder | Contains patrol waypoints as Parts
	- Height: number | Agent height for pathfinding calculations
	- Width: number | Agent width for pathfinding (affects AgentRadius)
	- CanJump: boolean | Whether rig can jump during pathfinding
	- PatrolCooldown: number | Wait time between patrol cycles (seconds)
]]
export type Config = {
	WaypointsFolder: Folder,
	Height: number,
	Width: number,
	CanJump: boolean,
	PatrolCooldown: number,
}

--[[
	Constructor: Creates a new SmartPath instance
	
	@param rig (Model) - The NPC/rig model to control
	@param config (table) - Configuration table matching the type definition above
	@return (SmartPath) - New SmartPath instance with initialized properties
	
	Implementation Notes:
	- Uses metatables to implement class-like behavior in Lua
	- Stores rig reference and config privately (double underscore prefix)
	- Immediately calls Init() to set up sounds and patrol loop
]]
function SmartPath.new(rig: Model, config: Config)
	-- Validate inputs before creating instance
	if not rig or not rig:FindFirstChild("HumanoidRootPart") then
		warn("SmartPath.new: Invalid rig model or missing HumanoidRootPart")

		return nil
	end

	if not config or type(config) ~= "table" then
		warn("SmartPath.new: Invalid or missing configuration table")

		return nil
	end

	-- Create new instance using metatable
	local self = setmetatable({}, SmartPath)

	-- Store references privately to prevent external modification
	self.__rig = rig
	self.__config = config
	self.__cacheExpiry = 0.5 -- Cache target detection for 0.5 seconds to reduce raycast calls

	self.__lastJumpTime = 0
	self.__jumpCooldown = 0.75 -- Wait 0.75 seconds between jump attempts

	-- Initialize logic, patrol loop, and network ownership
	self:Init()

	return self
end

--[[
	GetPath: Computes a path using Roblox PathfindingService
	
	Purpose:
	- Handles pathfinding calculations using modern Roblox API
	- Configures path with agent dimensions for accurate navigation
	- Handles path computation errors gracefully
	
	@param destination (Vector3) - Target position to path toward
	@return (Path) - The computed path object, or nil if invalid
	
	Configuration Notes:
	- AgentHeight/Radius affect navigability (larger agents can't fit through tight spaces)
	- CanJump determines if agent can traverse obstacles by jumping
	- Path computation is async but we await it immediately
]]
function SmartPath:GetPath(destination)
	local rig = self.__rig
	local rigPos = rig.PrimaryPart.Position

	-- Configure pathfinding parameters based on rig dimensions
	local pathParams = {
		["AgentHeight"] = self.__config.Height,
		["AgentRadius"] = (self.__config.Width / 2), -- Width represents diameter, radius is half
		["AgentCanJump"] = self.__config.CanJump,
		["Costs"] = {
			["DangerZone"] = math.huge -- Avoid hazard areas if they exist
		}
	}

	-- Create and compute path (synchronous wait)
	local path = PathfindingService:CreatePath(pathParams)
	local success, errorMessage = pcall(function()
		path:ComputeAsync(rigPos, destination)
	end)

	-- Return path even if blocked - the caller handles error state
	return path
end

--[[
	WalkTo: Moves rig along computed path while checking for targets
	
	Behavior Loop:
	1. Computes path to destination
	2. Iterates through waypoints
	3. Before each move, checks if target has appeared
	4. If target found, breaks out and attacks
	5. Otherwise, moves to waypoint and waits for arrival
	
	@param destination (Vector3) - Position to navigate to
	
	Path Failure Handling:
	- If PathfindingService can't find valid path, moves directly toward destination
	- This acts as a fallback for areas without generated navigation meshes
]]
function SmartPath:WalkTo(destination)
	local rig = self.__rig
	local humanoid = rig:FindFirstChildOfClass("Humanoid")

	if not humanoid then
		return
	end

	-- Compute path to destination
	local path = self:GetPath(destination)

	-- Check if path was successfully computed
	if path.Status == Enum.PathStatus.Success then
		-- Path found - follow waypoints
		local waypoints = path:GetWaypoints()

		-- Visualize the path with yellow markers (0.6 stud cubes spaced along waypoints)
		-- This helps debug pathfinding and shows the actual route being taken
		self:CreatePathVisualizer(waypoints, Color3.fromRGB(170, 85, 255)) -- Purple

		for _, waypoint in ipairs(waypoints) do
			-- Move to next waypoint
			humanoid:MoveTo(waypoint.Position)

			-- Wait for arrival before proceeding to next waypoint
			local reached = humanoid.MoveToFinished:Wait()
			if not reached then
				-- Movement interrupted (likely by an obstacle or other event) so we exit early
				break
			end
		end
	else
		-- Path not found - attempt direct movement as fallback
		-- Move directly toward destination but maintain distance from rig
		local direction = (destination - rig.PrimaryPart.Position).Unit
		local fallbackDest = destination - (direction * 5) -- Stop 5 studs before destination

		humanoid:MoveTo(fallbackDest)
	end
end

--[[
	Patrol: Selects random waypoint and navigates to it
	
	Implementation:
	- Gets all children of WaypointsFolder
	- Uses math.random() to select random waypoint
	- Calls WalkTo() to navigate with target detection
	
	This is called repeatedly by the patrol loop in Init()
]]
function SmartPath:Patrol()
	local waypoints = self.__config.WaypointsFolder:GetChildren()

	-- Ensure waypoints exist
	if #waypoints == 0 then
		warn("[SmartPath]: Patrol - No waypoints found in WaypointsFolder")

		return
	end

	-- Select random waypoint
	local randomIndex = math.random(1, #waypoints)
	local selectedWaypoint = waypoints[randomIndex]

	-- Navigate to waypoint (this includes target detection during movement)
	self:WalkTo(selectedWaypoint.Position)
end

--[[
	DetectElevationChange: Uses raycasting to detect height differences ahead
	
	Purpose:
	- Determines if there's a ledge or slope ahead
	- Only returns true if elevation change detected
	- Prevents unnecessary jumping on flat ground
	- Smart climbing: jumps only when needed
	
	Implementation:
	- Raycasts down from current position to find ground
	- Raycasts down from ahead position to find next ground
	- Compares Y-axis positions
	- Returns true if significant elevation difference detected
	
	@param lookAheadDistance (number) - How far ahead to check (studs)
	@param minHeightDifference (number) - Minimum Y difference to trigger jump (studs)
	@return (boolean) - True if elevation change detected ahead
]]
function SmartPath:DetectElevationChange(lookAheadDistance, minHeightDifference)
	lookAheadDistance = lookAheadDistance or 5 -- Look 5 studs ahead by default
	minHeightDifference = minHeightDifference or 1 -- Minimum 1 stud height difference

	local rig = self.__rig
	local hrp = rig:FindFirstChild("HumanoidRootPart")

	if not hrp then
		return false
	end

	-- Current position to get ground level beneath rig
	local currentPos = hrp.Position
	local aheadPos = currentPos + (hrp.CFrame.LookVector * lookAheadDistance)

	-- Raycast downward from current position to find current ground
	local currentRayParams = RaycastParams.new()
	currentRayParams.FilterDescendantsInstances = {rig}
	currentRayParams.FilterType = Enum.RaycastFilterType.Exclude

	local currentRayResult = workspace:Raycast(
		currentPos + Vector3.new(0, 2, 0), -- Start above current position
		Vector3.new(0, -10, 0), -- Raycast down
		currentRayParams
	)

	-- Raycast downward from ahead position to find next ground
	local aheadRayParams = RaycastParams.new()
	aheadRayParams.FilterDescendantsInstances = {rig}
	aheadRayParams.FilterType = Enum.RaycastFilterType.Exclude

	local aheadRayResult = workspace:Raycast(
		aheadPos + Vector3.new(0, 2, 0), -- Start above ahead position
		Vector3.new(0, -10, 0), -- Raycast down
		aheadRayParams
	)

	-- Both raycasts must hit something to calculate elevation difference
	if currentRayResult and aheadRayResult then
		local currentGroundY = currentRayResult.Position.Y
		local aheadGroundY = aheadRayResult.Position.Y
		local heightDifference = aheadGroundY - currentGroundY

		-- If ahead is HIGHER (going uphill) or LOWER (going downhill), return true
		-- Positive means uphill (need to jump), negative means downhill (need help with fall)
		return math.abs(heightDifference) >= minHeightDifference
	end

	-- If raycasts fail, assume flat ground (no jump needed)
	return false
end

--[[
	CreatePathVisualizer: Creates yellow debug markers along the computed path
	
	Purpose:
	- Visualizes the path the rig will take
	- Creates small yellow parts (0.6 studs) spaced along waypoints
	- Helps debug pathfinding issues
	- Shows the exact route being traversed
	
	@param waypoints (table) - Array of waypoint Vector3 positions from path
	@param visualizeColor (Color3) - Color of debug parts (default yellow)
	
	Implementation:
	- Creates small neon cubes along the path
	- Parts are semi-transparent (0.3 opacity) to not obstruct gameplay
	- Automatically cleans up after 10 seconds
	- Returns the visualization folder for potential manual cleanup
	
	Usage Example:
	self:CreatePathVisualizer(path:GetWaypoints(), Color3.fromRGB(255, 255, 0))
]]
function SmartPath:CreatePathVisualizer(waypoints, visualizeColor)
	visualizeColor = visualizeColor or Color3.fromRGB(170, 0, 255) -- Purple default

	local uniqueIdentifier = os.time() .. "_" .. math.random(1000, 9999)
	uniqueIdentifier = "PathVisual_" .. uniqueIdentifier .. "_" .. string.byte(string.char(math.random(65, 90)))

	-- Create a folder to hold all visualization parts
	local visualFolder = Instance.new("Folder")
	visualFolder.Name = uniqueIdentifier
	visualFolder.Parent = workspace

	-- Create small parts at each waypoint to visualize the path
	for index, waypoint in ipairs(waypoints) do
		-- Create small yellow cube for path marker
		local part = Instance.new("Part")
		part.Name = "PathMarker_" .. index
		part.Shape = Enum.PartType.Ball -- Ball shape for visibility
		part.Size = Vector3.new(0.6, 0.6, 0.6) -- Small 0.6 stud cube
		part.Color = visualizeColor
		part.Material = Enum.Material.Neon -- Neon material for visibility
		part.Anchored = true
		part.CanCollide = false -- No collision so rig passes through
		part.CFrame = CFrame.new(waypoint.Position + Vector3.new(0, 0.3, 0)) -- Slightly above ground
		part.Transparency = 1 -- Small tween
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = visualFolder

		local tween = TweenService:Create(
			part, 
			TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
			{Transparency = 0.3}
		) -- Give it a nice fade-in tween

		tween:Play()

		task.wait(0.12)
	end

	-- Auto-remove visualization after 3 seconds to keep the workspace clean
	task.delay(3, function()
		local children = visualFolder:GetChildren()

		-- Cascade the fade-outs sequentially
		for _, part in pairs(children) do
			if part:IsA("BasePart") then
				local tween = TweenService:Create(
					part, 
					TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), 
					{Transparency = 1.0}
				)

				tween:Play()
				tween:Destroy() -- Safe to destroy immediately; memory is cleaned but tween still runs

				-- Wait 0.12 seconds before moving to the next part in the loop
				task.wait(0.12)
			end
		end

		-- Wait for the very last part's tween to completely finish
		-- (Tween duration 0.8s minus the final 0.12s loop delay leaves 0.68s)
		task.wait(0.68)

		-- Safely wipe out the empty folder container
		visualFolder:Destroy()
	end)


	return visualFolder
end

--[[
	Init: Initializes the rig AI system
	
	Initialization Steps:
	1. We wait for HumanoidRootPart to exist
	2. Set up the rig's humanoid and root part
	3. Spawn the patrol loop that runs indefinitely
	4. Set network ownership to server for consistent replication
	
	Audio Design:
	- ChaseSound: Looped, plays during pursuit (warns player of danger)
	- MurderSound: Non-looped, plays when kill is achieved
	- MurderSound.Stopped event: Stops chase sound to prevent overlap
	
	Climbing & Jumping:
	- Humanoid.Jump enabled for climbing slopes and obstacles
	- Periodic jump attempts help navigate ramps (like structure in demo)
	- Works with CanJump pathfinding parameter for terrain traversal
	- Jump frequency: Every 0.5 seconds while moving
	
	Network Ownership:
	- Set to nil (server ownership) to ensure all clients see consistent behavior
	- Prevents clients from desynchronizing the rig's position
]]
function SmartPath:Init()
	-- Wait for rig to be fully loaded with HumanoidRootPart
	local root = self.__rig:WaitForChild("HumanoidRootPart")
	local humanoid = self.__rig:WaitForChild("Humanoid")

	-- Spawn patrol loop on separate thread to prevent blocking
	task.spawn(function()
		-- Set network owner to server for consistent replication
		root:SetNetworkOwner(nil)

		-- Run patrol loop indefinitely
		while true do
			-- Wait for patrol cooldown before next patrol cycle
			task.wait(self.__config.PatrolCooldown)

			-- Execute patrol (navigate to random waypoint while checking for targets)
			self:Patrol()
		end
	end)

	-- Spawn adaptive jump assistance for climbing slopes, ledges, and obstacles
	-- Only jumps when elevation change is detected ahead (smart climbing)
	task.spawn(function()
		while true do
			task.wait(0.3) -- Check frequently for elevation changes

			-- Get current time for cooldown check
			local currentTime = tick()
			local timeSinceLastJump = currentTime - self.__lastJumpTime

			-- Check if humanoid is alive and enough time has passed since last jump
			if humanoid.Health > 0 and timeSinceLastJump >= self.__jumpCooldown then
				-- ONLY jump if elevation change is detected ahead
				-- This prevents jumping on flat ground (more natural)
				if self:DetectElevationChange(5, 1) then
					-- Additional check: only jump if not already jumping or falling
					if not (humanoid:GetState() == Enum.HumanoidStateType.Jumping or 
						humanoid:GetState() == Enum.HumanoidStateType.Flying or
						humanoid:GetState() == Enum.HumanoidStateType.Freefall or
						humanoid:GetState() == Enum.HumanoidStateType.Dead) then
						-- Attempt jump - only when elevation change detected (ledges, slopes)
						humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
						-- Record the jump time to enforce cooldown
						self.__lastJumpTime = currentTime
					end
				end
			end
		end
	end)
end

-- ============================================================================
-- Usage E.g.
-- ============================================================================
local rig = script.Parent

SmartPath.new(
	rig,
	{
		WaypointsFolder = workspace.Waypoints,
		Height = 5,
		Width = 3,
		CanJump = true,
		PatrolCooldown = 2,
	}
) -- We're done!
