local fio = require('fio')
local server = require('luatest.server')
local Proxy = require('luatest.replica_proxy')

-- Creating proxy for connection client_id -> server_id
local function create_proxy_for_connection(cg, client_id, server_id)

    local client_uri = fio.abspath(
        server.build_listen_uri('proxy_'..tostring(client_id)..'_to_' ..tostring(server_id), cg.cluster.id)
    )
    local server_uri = fio.abspath(
        server.build_listen_uri('replica_'..tostring(server_id), cg.cluster.id)
    )

    local proxy = Proxy:new({
        client_socket_path = client_uri,
        server_socket_path = server_uri,
    })

    proxy.alias = string.format("proxy_%d_to_%d", client_id, server_id)

    return proxy
end

local function get_proxy_state(proxy)
    if fio.path.exists(proxy.client_socket_path) then
        return "active"
    else
        return "inactive"
    end
end

-- Finding all proxies whose alias starts with proxy_i
local function find_proxies_by_prefix(cg, i)
    local prefix = string.format("proxy_%d_to_", i)
    local proxies = {}

    for _, proxy in ipairs(cg.proxies) do
        if string.startswith(proxy.alias, prefix) then
            table.insert(proxies, proxy)
        end
    end

    return proxies
end

-- Function for counting non-crashed proxy-connections
-- (the proxy-connection in this case is not crashed unless both i_to_j and j_to_i proxies are crashed)
local function count_non_crashed_proxy_connections(cg, i, activity_states)
    local non_crashed_connections_counter = 0

    local outgoing_proxies = find_proxies_by_prefix(cg, i)

    for _, outgoing_proxy in ipairs(outgoing_proxies) do
    
        local j = tonumber(string.match(outgoing_proxy.alias, "proxy_%d_to_(%d+)"))

        local incoming_proxy_alias = string.format("proxy_%d_to_%d", j, i)

        local incoming_proxy = nil
        for _, proxy in ipairs(cg.proxies) do
            if proxy.alias == incoming_proxy_alias then
                incoming_proxy = proxy
                break
            end
        end
        if not incoming_proxy then
            log_info(string.format("Error: Proxy %s does not exist in cg.proxies", incoming_proxy_alias))
        end

        if incoming_proxy and activity_states[outgoing_proxy.alias] ~= "crashed"
                          and activity_states[incoming_proxy.alias] ~= "crashed" then
            non_crashed_connections_counter = non_crashed_connections_counter + 1
        end
    end

    return non_crashed_connections_counter
end

-- Function to check that more than half of the proxy connections for a given node are not crashed 
-- (the proxy connection in this case is not crashed unless both i_to_j and j_to_i proxies are crashed)
local function is_half_proxy_connections_non_crashed(cg, i, activity_states)

    local total_connections = find_proxies_by_prefix(cg, i)
    local non_crashed_count = count_non_crashed_proxy_connections(cg, i, activity_states)

    local total_count = #total_connections

    return non_crashed_count >= total_count / 2
end

-- Safe function for getting random crash proxies
local function get_random_proxies_for_crash(cg, activity_states, num_to_select)

    local replica_count = #cg.replicas

    -- Finding proxies that can be crashed
    local candidates = {}
    for _, proxy in pairs(cg.proxies) do
        if activity_states[proxy.alias] ~= 'crashed' then
            table.insert(candidates, proxy)
        end
    end

    if #candidates < num_to_select then
        log_info(string.format("[CRASH SIMULATION] Not enough candidates to crash. Needed: %d, available: %d", num_to_select, #candidates))
        return {}
    end

    -- Random proxy selection for crash
    for i = #candidates, 2, -1 do
        local j = math.random(i)
        candidates[i], candidates[j] = candidates[j], candidates[i]
    end

    local selected_proxies = {}
    for i = 1, num_to_select do
        table.insert(selected_proxies, candidates[i])
    end

    -- Creating a temporary states table where the selected proxies are marked as crashed
    local temp_activity_states = {}
    for k, v in pairs(activity_states) do
        temp_activity_states[k] = v
    end

    for _, proxy in ipairs(selected_proxies) do
        temp_activity_states[proxy.alias] = 'crashed'
    end

    -- Check that the is_half_proxy_connections_not_crashed condition is met for each node
    for i = 1, replica_count do
        if not is_half_proxy_connections_non_crashed(cg, i, temp_activity_states) then
            log_info(string.format("[CRASH SIMULATION] Node %d would have less than half of its connections non crashed.", i))
            return {}
        end
    end

    return selected_proxies
end

return {
    create_proxy_for_connection = create_proxy_for_connection,
    get_proxy_state = get_proxy_state,
    find_proxies_by_prefix = find_proxies_by_prefix,
    count_non_crashed_proxy_connections = count_non_crashed_proxy_connections,
    is_half_proxy_connections_non_crashed = is_half_proxy_connections_non_crashed,
    get_random_proxies_for_crash = get_random_proxies_for_crash
}