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

-- Module initialization with an __indexed metatable for OOP pattern
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
	- CanClimb: boolean | Whether the rig can climb
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

	local pathParams = {
		AgentHeight   = self.__config.Height,
		AgentRadius   = self.__config.Width / 2,
		AgentCanJump  = self.__config.CanJump,
		AgentCanClimb = self.__config.CanClimb ~= false, -- NEW – defaults to true
		Costs = {
			DangerZone = math.huge
		}
	}

	local path = PathfindingService:CreatePath(pathParams)
	pcall(function()
		path:ComputeAsync(rigPos, destination)
	end)

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
	- If the path becomes blocked (or MoveTo is interrupted) it automatically
	- rebuilds a new path around the obstacle and continues
]]
function SmartPath:WalkTo(destination)
	local rig = self.__rig
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	local MAX_RETRIES = 6
	local retries = 0

	while retries < MAX_RETRIES do
		local path = self:GetPath(destination)

		if path.Status ~= Enum.PathStatus.Success then
			local hrp = rig.PrimaryPart
			if hrp then
				local direction = (destination - hrp.Position)
				if direction.Magnitude > 0.1 then
					direction = direction.Unit
					humanoid:MoveTo(destination - direction * 5)
					humanoid.MoveToFinished:Wait()
				end
			end
			return
		end

		local waypoints = path:GetWaypoints()
		self:CreatePathVisualizer(waypoints, Color3.fromRGB(0, 170, 255)) -- fixed color

		local blocked = false
		local blockedConn
		blockedConn = path.Blocked:Connect(function()
			blocked = true
			if blockedConn then
				blockedConn:Disconnect()
				blockedConn = nil
			end
		end)

		local finishedSuccessfully = true

		for _, waypoint in ipairs(waypoints) do
			if blocked then
				finishedSuccessfully = false
				break
			end

			humanoid:MoveTo(waypoint.Position)
			local reached = humanoid.MoveToFinished:Wait()

			if not reached then
				finishedSuccessfully = false
				break
			end
		end

		if blockedConn then
			blockedConn:Disconnect()
		end

		if finishedSuccessfully and not blocked then
			return
		end

		retries += 1
		task.wait(0.15)
	end

	warn("[SmartPath]: WalkTo – exceeded max retries")
end

--[[
DetectClimbable: Raycasts for nearby TrussParts or climbable surfaces
@return (BasePart?) - The climbable part if found, otherwise nil
]]
function SmartPath:DetectClimbable(lookDistance: number?)
	lookDistance = lookDistance or 4

	local hrp = self.__rig:FindFirstChild("HumanoidRootPart")
	if not hrp then return nil end

	local params = RaycastParams.new()
	params.FilterDescendantsInstances = {self.__rig}
	params.FilterType = Enum.RaycastFilterType.Exclude

	-- Forward + slightly upward ray (catches vertical trusses)
	local origin = hrp.Position + Vector3.new(0, 1, 0)
	local direction = (hrp.CFrame.LookVector * lookDistance) + Vector3.new(0, 2, 0)

	local result = workspace:Raycast(origin, direction, params)
	if result and result.Instance then
		local part = result.Instance
		if part:IsA("TrussPart") or part.Name:lower():find("truss") or part.Name:lower():find("ladder") then
			return part
		end
	end

	return nil
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
	visualizeColor = visualizeColor or Color3.fromRGB(170, 0, 255)

	-- Run entirely off the main thread so WalkTo is never delayed
	task.spawn(function()
		local uniqueIdentifier = "PathVisual_" .. os.time() .. "_" .. math.random(1000, 9999)
		local visualFolder = Instance.new("Folder")
		visualFolder.Name = uniqueIdentifier
		visualFolder.Parent = workspace

		for index, waypoint in ipairs(waypoints) do
			local part = Instance.new("Part")
			part.Name = "PathMarker_" .. index
			part.Shape = Enum.PartType.Ball
			part.Size = Vector3.new(0.6, 0.6, 0.6)
			part.Color = visualizeColor
			part.Material = Enum.Material.Neon
			part.Anchored = true
			part.CanCollide = false
			part.CFrame = CFrame.new(waypoint.Position + Vector3.new(0, 0.3, 0))
			part.Transparency = 1
			part.TopSurface = Enum.SurfaceType.Smooth
			part.BottomSurface = Enum.SurfaceType.Smooth
			part.Parent = visualFolder

			local tween = TweenService:Create(
				part,
				TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
				{Transparency = 0.3}
			)
			tween:Play()
			task.wait(0.08) -- staggered spawn only (no longer blocks walking)
		end

		-- Fade out and clean up
		task.delay(3, function()
			for _, part in pairs(visualFolder:GetChildren()) do
				if part:IsA("BasePart") then
					local tween = TweenService:Create(
						part,
						TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
						{Transparency = 1}
					)
					tween:Play()
					task.wait(0.08)
				end
			end
			task.wait(0.7)
			visualFolder:Destroy()
		end)
	end)
end

--[[
DetectVerticalOpportunity: Advanced vertical / ledge / shortcut detection
Returns a table with useful info so the AI can decide how to react.

@return {
	shouldJump: boolean,
	shouldClimb: boolean,
	heightDiff: number,          -- positive = higher ground ahead
	ledgePosition: Vector3?,     -- approximate position of the ledge/platform
	reason: string               -- "ledge_up", "wall_over", "drop", "none"
}
]]
function SmartPath:DetectVerticalOpportunity(lookAhead: number?)
	lookAhead = lookAhead or 6

	local hrp = self.__rig:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return { shouldJump = false, shouldClimb = false, heightDiff = 0, reason = "none" }
	end

	local params = RaycastParams.new()
	params.FilterDescendantsInstances = { self.__rig }
	params.FilterType = Enum.RaycastFilterType.Exclude

	local origin = hrp.Position
	local look = hrp.CFrame.LookVector

	-- Current ground height
	local currentGround = workspace:Raycast(origin + Vector3.new(0, 2, 0), Vector3.new(0, -12, 0), params)
	local currentY = currentGround and currentGround.Position.Y or origin.Y

	-- Forward scan at multiple heights (detects walls + ledges)
	local heightsToCheck = { 1.5, 3, 4.5, 6, 8 } -- studs above HRP
	local wallHit, highestSolidY = nil, -math.huge

	for _, h in ipairs(heightsToCheck) do
		local rayOrigin = origin + Vector3.new(0, h, 0)
		local result = workspace:Raycast(rayOrigin, look * lookAhead, params)
		if result then
			wallHit = result
			highestSolidY = math.max(highestSolidY, result.Position.Y)
		end
	end

	-- Check for ground / platform above the potential wall (classic ledge detection)
	local ledgePos = nil
	local heightDiff = 0

	if wallHit then
		-- Raycast slightly past the wall and downward to find a platform
		local checkPos = wallHit.Position + look * 1.2 + Vector3.new(0, 3, 0)
		local platformRay = workspace:Raycast(checkPos, Vector3.new(0, -10, 0), params)

		if platformRay then
			ledgePos = platformRay.Position
			heightDiff = platformRay.Position.Y - currentY
		else
			-- No platform found – treat as a tall wall
			heightDiff = highestSolidY - currentY
		end
	else
		-- No wall – just compare ground ahead (old elevation logic, improved)
		local aheadPos = origin + look * lookAhead
		local aheadGround = workspace:Raycast(aheadPos + Vector3.new(0, 4, 0), Vector3.new(0, -14, 0), params)
		if aheadGround then
			heightDiff = aheadGround.Position.Y - currentY
			ledgePos = aheadGround.Position
		end
	end

	-- Decision logic
	local shouldJump = false
	local shouldClimb = false
	local reason = "none"

	if heightDiff >= 1.0 and heightDiff <= 7.5 then
		-- Jumpable ledge / platform (parkour height range)
		shouldJump = true
		reason = heightDiff > 3.5 and "ledge_up" or "wall_over"
	elseif heightDiff > 7.5 then
		-- Too high for a normal jump → try climbing if possible
		shouldClimb = true
		reason = "too_high"
	elseif heightDiff <= -2.5 then
		-- Significant drop – still useful to know
		reason = "drop"
	end

	return {
		shouldJump = shouldJump,
		shouldClimb = shouldClimb,
		heightDiff = heightDiff,
		ledgePosition = ledgePos,
		reason = reason
	}
end

--[[
	Init: Initializes the rig AI system
	
	Initialization Steps:
	1. We wait for HumanoidRootPart to exist
	2. Set up the rig's humanoid and root part
	3. Spawn the patrol loop that runs indefinitely
	4. Set network ownership to server for consistent replication
	
	Climbing & Jumping:
	- Humanoid.Jump enabled for climbing slopes and obstacles
	- Periodic jump attempts help navigate ramps (like structure in demo)
	- Works with CanJump pathfinding parameter for terrain traversal
	- Can Climb, and jump at the perfect moment, while also computing shortcuts.
	
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
	-- Adaptive jump + climb assistance
	-- Advanced vertical + climb + parkour assist
	task.spawn(function()
		while true do
			task.wait(0.2)

			local currentTime = tick()
			if humanoid.Health <= 0 then continue end
			if currentTime - self.__lastJumpTime < self.__jumpCooldown then continue end

			local state = humanoid:GetState()
			local busy = state == Enum.HumanoidStateType.Jumping
				or state == Enum.HumanoidStateType.Freefall
				or state == Enum.HumanoidStateType.Flying
				or state == Enum.HumanoidStateType.Dead
				or state == Enum.HumanoidStateType.Climbing

			if busy then continue end

			-- Trusses / ladder
			local climbable = self:DetectClimbable(4.5)
			if climbable then
				humanoid:ChangeState(Enum.HumanoidStateType.Climbing)
				
				self.__lastJumpTime = currentTime
				
				continue
			end

			-- Vertical opportunity (for ledges / shortcuts)
			local vertical = self:DetectVerticalOpportunity(6.5)

			if vertical.shouldJump then
				-- Face the ledge a bit and then we jump
				if vertical.ledgePosition then
					local dir = (vertical.ledgePosition - humanoid.RootPart.Position) * Vector3.new(1, 0, 1)
					if dir.Magnitude > 0.5 then
						humanoid:MoveTo(humanoid.RootPart.Position + dir.Unit * 3)
					end
				end

				humanoid:ChangeState(Enum.HumanoidStateType.Jumping)

				-- Stronger jump for higher ledges
				if vertical.heightDiff > math.pi then
					humanoid.JumpPower = math.clamp(50 + vertical.heightDiff * 4, 50, 85)
					
					task.delay(0.35, function()
						if humanoid and humanoid.Parent then
							humanoid.JumpPower = 50 -- reset to default
						end
					end)
				end

				self.__lastJumpTime = currentTime

			elseif vertical.shouldClimb then
				-- Too high for jump – we try climbing motion
				humanoid:ChangeState(Enum.HumanoidStateType.Climbing)
				self.__lastJumpTime = currentTime
			end
		end
	end)
end

-- ============================================================================
-- Usage E.g.
-- ============================================================================
local rig = script.Parent

task.wait(3)

SmartPath.new(
	rig,
	{
		WaypointsFolder = workspace.Waypoints,
		Height = 5,
		Width = 3,
		CanJump = true,
		CanClimb = true,
		PatrolCooldown = 2,
	}
) -- We're done!
