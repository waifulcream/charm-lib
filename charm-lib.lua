--------------------------------------------------------------------------------
-- CHARM LIBRARY (Embedded Version)
-- Original by: littensy/charm
-- Lua Port for Executors
--------------------------------------------------------------------------------

local Charm = {}

-- Internal State
local context = nil   -- Tracks the currently running effect (dependency tracking)
local batching = false -- Flag for batch operations
local queue = {}      -- Queue for batched updates

-- Helper: Safe iteration to prevent "table modified during iteration" errors
local function copySet(set)
    local copy = {}
    for k in pairs(set) do copy[k] = true end
    return copy
end

-- 1. ATOM: The fundamental state container
function Charm.atom(initialValue)
    local value = initialValue
    local listeners = {} -- Set of effects that depend on this atom
    
    local function atom(...)
        local args = {...}
        if #args > 0 then
            -- [WRITE Operation]
            local newValue = args[1]
            if newValue ~= value then
                value = newValue
                
                -- Notify listeners
                if batching then
                    -- If batching, add listeners to the queue instead of running them
                    for l in pairs(listeners) do queue[l] = true end
                else
                    -- Run all active listeners immediately
                    local safeListeners = copySet(listeners)
                    for l in pairs(safeListeners) do
                        if l.active then l.run() end
                    end
                end
            end
            return value
        else
            -- [READ Operation]
            if context then
                -- Track dependency: The current effect depends on this atom
                listeners[context] = true
                table.insert(context.dependencies, listeners)
            end
            return value
        end
    end
    
    return atom
end

-- 2. EFFECT: Reactive side-effects
-- Runs automatically whenever dependencies change.
function Charm.effect(callback)
    local node = {
        active = true,
        dependencies = {} -- List of listener sets this effect is subscribed to
    }
    
    local cleanupCallback = nil

    local function run()
        if not node.active then return end

        -- 1. Cleanup previous run (unsubscribe from old dependencies)
        if cleanupCallback then 
            cleanupCallback() 
            cleanupCallback = nil 
        end
        
        for _, depSet in ipairs(node.dependencies) do
            depSet[node] = nil -- Unsubscribe self from atom's listeners
        end
        node.dependencies = {} -- Clear local dependency list

        -- 2. Run new callback and track new dependencies
        local prevContext = context
        context = node
        
        local success, result = pcall(callback)
        
        context = prevContext
        
        if success and type(result) == "function" then
            cleanupCallback = result
        elseif not success then
            warn("[Charm] Effect Error:", result)
        end
    end

    node.run = run
    
    -- Initial run
    run()

    -- Return a destroyer function to stop the effect manually
    return function()
        node.active = false
        if cleanupCallback then cleanupCallback() end
        for _, depSet in ipairs(node.dependencies) do
            depSet[node] = nil
        end
    end
end

-- 3. COMPUTED: Derived state
-- Creates a read-only atom that updates automatically when its dependencies change.
function Charm.computed(fn)
    local result = Charm.atom(nil)
    
    -- Use an effect to sync the computed value
    Charm.effect(function()
        result(fn())
    end)
    
    -- Return a getter function (read-only)
    return function()
        return result()
    end
end

-- 4. PEEK: Read atom without subscribing
-- Essential for loops like RenderStepped to prevent memory leaks/performance issues.
function Charm.peek(atom)
    local prevContext = context
    context = nil -- Pause dependency tracking
    local value = atom()
    context = prevContext -- Resume tracking
    return value
end

-- 5. BATCH: Group multiple updates
-- Prevents effects from running multiple times during a single logic update.
function Charm.batch(fn)
    local prevBatching = batching
    batching = true
    
    local success, err = pcall(fn)
    
    batching = prevBatching
    
    if not batching then
        -- Flush the queue: Run all pending effects once
        local safeQueue = copySet(queue)
        queue = {}
        for l in pairs(safeQueue) do
            if l.active then l.run() end
        end
    end
    
    if not success then error(err) end
end

-- 6. OBSERVE: Watch an atom for changes
-- Returns the new value and the old value to the callback.
function Charm.observe(atom, callback)
    local oldValue = Charm.peek(atom)
    return Charm.effect(function()
        local newValue = atom()
        if newValue ~= oldValue then
            local toSendOld = oldValue
            oldValue = newValue
            callback(newValue, toSendOld)
        end
    end)
end

-- 7. SUBSCRIBE: Simple subscription
-- Runs the callback immediately with the current value, and whenever it changes.
function Charm.subscribe(atom, callback)
    return Charm.effect(function()
        callback(atom())
    end)
end

-- 8. MAPPED: Efficient Collection Mapping (Best for ESP/Player Lists)
-- transforms a list atom into another list, handling creation and cleanup efficiently.
function Charm.mapped(sourceAtom, factory)
    local cache = {} -- Stores { [sourceItem] = { result, cleanup } }
    
    -- The result atom containing the mapped list
    local resultTable = Charm.atom({})

    Charm.effect(function()
        local sourceList = sourceAtom()
        local newCache = {}
        local results = {}

        -- 1. Create new items or retrieve from cache
        for _, item in ipairs(sourceList) do
            if cache[item] then
                -- Item exists, reuse it (Memoization)
                newCache[item] = cache[item]
                table.insert(results, cache[item].res)
            else
                -- New item, call factory
                local res, cleanup = factory(item)
                newCache[item] = { res = res, cleanup = cleanup }
                table.insert(results, res)
            end
        end

        -- 2. Cleanup removed items
        for item, data in pairs(cache) do
            if not newCache[item] then
                if data.cleanup then data.cleanup() end
            end
        end

        cache = newCache
        resultTable(results)
    end)

    return resultTable
end

--------------------------------------------------------------------------------
-- END OF CHARM LIBRARY
--------------------------------------------------------------------------------
