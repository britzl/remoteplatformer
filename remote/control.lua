local p2p_discovery = require "defnet.p2p_discovery"
local udp = require "defnet.udp"

local trickle = require "game.trickle"

local M = {}

local P2P_PORT = 50000
local UDP_SERVER_PORT = 9192

local STATE_LISTENING = "STATE_LISTENING"
local STATE_JOINED_GAME = "STATE_JOINED_GAME"
local STATE_HOSTING_GAME = "STATE_HOSTING_GAME"

local function generate_unique_id()
	return tostring(socket.gettime()) .. tostring(os.clock()) .. tostring(math.random(99999,10000000))
end

local mp = {
	id = nil,
	state = nil,
	clients = {},
	message_signatures = {},
	message_handlers = {},
	stream = trickle.create(),
}


M.HEARTBEAT = "HEARTBEAT"
M.JOIN_SERVER = "JOIN_SERVER"
M.PLAYER_ACTION = "PLAYER_ACTION"

local join_server_signature = {
	{ "id", "string" },
}

local heartbeat_signature = {
	{ "id", "string" },
}

local player_action_signature = {
	{ "id", "string" },
	{ "action", "string" },
}


local function create_join_server_message(id)
	assert(id, "You must provide an id")
	local message = trickle.create()
	message:writeString(M.JOIN_SERVER)
	message:pack({ id = id }, join_server_signature)
	return tostring(message)
end

local function create_heartbeat_message(id)
	assert(id, "You must provide an id")
	local message = trickle.create()
	message:writeString(M.HEARTBEAT)
	message:pack({ id = id }, heartbeat_signature)
	return tostring(message)
end

local function create_player_action_message(id, action)
	assert(id, "You must provide an id")
	local message = trickle.create()
	message:writeString(M.PLAYER_ACTION)
	message:pack({ id = id, action = action }, player_action_signature)
	return tostring(message)
end


function M.register_message(message_type, message_signature)
	assert(message_type, "You must provide a message type")
	assert(message_signature, "You must provide a message signature")
	mp.message_signatures[message_type] = message_signature
end

function M.register_handler(message_type, handler_fn)
	assert(message_type, "You must provide a message type")
	assert(handler_fn, "You must provide a handler function")
	mp.message_handlers[message_type] = mp.message_handlers[message_type] or {}
	table.insert(mp.message_handlers[message_type], handler_fn)
end

local function handle_message(message_type, stream, from_ip, from_port)
	assert(message_type, "You must provide a message type")
	assert(stream, "You must provide a stream")
	print("handle_message", message_type)
	if mp.message_handlers[message_type] and mp.message_signatures[message_type] then
		local message = stream:unpack(mp.message_signatures[message_type])
		for _,handler in ipairs(mp.message_handlers[message_type]) do
			handler(message, from_ip, from_port)
		end
	end
end

--- 
-- Add a client to the list of clients
-- Can be called multiple times without risking duplicates
-- @param ip Client ip
-- @param port Client port
-- @param id Client id
local function add_client(ip, port, id)
	assert(ip, "You must provide an ip")
	assert(port, "You must provide a port")
	assert(id, "You must provide an id")
	mp.clients[id] = { ip = ip, port = port, ts = socket.gettime(), id = id }
end

--- Update the timestamp for a client
-- @param id
local function refresh_client(id)
	assert(id, "You must provide an id")
	if mp.clients[id] then
		mp.clients[id].ts = socket.gettime()
	end
end

--- Send a message to all clients
-- @param message The message to send
local function send_to_clients(message)
	assert(message, "You must provide a message")
	for _,client in pairs(mp.clients) do
		mp.udp_client.send(message, client.ip, client.port)
	end
end


function M.send_player_action(action)
	assert(mp.state == STATE_JOINED_GAME, "Wrong state")
	mp.udp_client.send(create_player_action_message(mp.id, action), mp.host_ip, UDP_SERVER_PORT)
end


function M.server(on_player_action)
	assert(on_player_action)
	mp.id = generate_unique_id()
	mp.p2p_broadcast = p2p_discovery.create(P2P_PORT)

	M.register_message(M.JOIN_SERVER, join_server_signature)
	M.register_message(M.PLAYER_ACTION, player_action_signature)
	M.register_message(M.HEARTBEAT, heartbeat_signature)

	M.register_handler(M.HEARTBEAT, function(message, from_ip, from_port)
		refresh_client(message.id)
	end)
	M.register_handler(M.JOIN_SERVER, function(message, from_ip, from_port)
		add_client(from_ip, from_port, message.id)
	end)
	M.register_handler(M.PLAYER_ACTION, function(message, from_ip, from_port)
		on_player_action(message, from_ip, from_port)
	end)
	
	coroutine.wrap(function()
		mp.state = STATE_HOSTING_GAME
		mp.host_ip = "127.0.0.1"

		-- incoming message handler
		mp.udp_server = udp.create(function(data, ip, port)
			local stream = trickle.create(data)
			local message_type = stream:readString()
			while message_type and message_type ~= "" do
				handle_message(message_type, stream, ip, port)
				message_type = stream:readString()
			end
		end, UDP_SERVER_PORT)

		-- start broadcasting server existence
		print("BROADCAST")
		mp.p2p_broadcast.broadcast("findme")

		timer.repeating(1, function()
			-- check for clients that haven't sent a heartbeat for a while
			-- and consider those clients disconnected
			for k,client in pairs(mp.clients) do
				if (socket.gettime() - client.ts) > 5 then
					print("removing client", k)
					mp.clients[k] = nil
				end
			end
		end)
	end)()
end


function M.client(on_connected)
	assert(on_connected)
	mp.id = generate_unique_id()
	mp.p2p_listen = p2p_discovery.create(P2P_PORT)

	coroutine.wrap(function()
		-- create our UDP connection
		-- we use this to communicate with the server
		mp.udp_client = udp.create(function(data, ip, port)
			local stream = trickle.create(data)
			local message_type = stream:readString()
			handle_message(message_type, stream, ip, port)
		end)

		-- let's start by listening if there's someone already looking for players
		-- wait for a while and if we don't find a server we start broadcasting
		print("LISTEN")
		mp.state = STATE_LISTENING
		mp.p2p_listen.listen("findme", function(ip, port)
			print("Found server", ip, port)
			mp.state = STATE_JOINED_GAME
			mp.host_ip = ip
			mp.p2p_listen.stop()

			-- send join message to server
			print("sending to server")
			mp.udp_client.send(create_join_server_message(mp.id), mp.host_ip, UDP_SERVER_PORT)
			on_connected(mp.id)
		end)

		-- send client heartbeat
		timer.repeating(1, function()
			if mp.state == STATE_JOINED_GAME then
				print("sending heartbeat")
				mp.udp_client.send(create_heartbeat_message(mp.id), mp.host_ip, UDP_SERVER_PORT)
			end
		end)
	end)()
end

--- Stop the multiplayer module and all underlying systems
function M.stop()
	if mp.p2p_listen then
		mp.p2p_listen.stop()
	end
	if mp.p2p_broadcast then
		mp.p2p_broadcast.stop()
	end
	if mp.udp_server then
		mp.udp_server.destroy()
	end
	if mp.udp_client then
		mp.udp_client.destroy()
	end
end

--- Update the multiplayer module and all underlying systems
-- Any data added to the stream will be sent at this time and the
-- stream will be cleared
-- @param dt
function M.update(dt)
	if mp.p2p_listen then
		mp.p2p_listen.update()
	end
	if mp.p2p_broadcast then
		mp.p2p_broadcast.update()
	end
	if mp.udp_server then
		mp.udp_server.update()
	end
	if mp.udp_client then
		mp.udp_client.update()
	end
end


return M