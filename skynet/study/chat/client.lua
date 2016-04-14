package.cpath = "luaclib/?.so"
package.path = "lualib/?.lua;examples/?.lua"

if _VERSION ~= "Lua 5.3" then
	error "Use lua 5.3"
end

local socket = require "clientsocket"
local proto = require "proto"
local sproto = require "sproto"

local host = sproto.new(proto.s2c):host "package"
local request = host:attach(sproto.new(proto.c2s))

--local fd = assert(socket.connect("127.0.0.1", 8888))
local fd = assert(socket.connect("192.168.31.136", 8888))



local function send_package(fd, pack)
	local package = string.pack(">s2", pack)
	socket.send(fd, package)
end

local function unpack_package(text)
	local size = #text
	if size < 2 then
		return nil, text
	end
	local s = text:byte(1) * 256 + text:byte(2)
	if size < s+2 then
		return nil, text
	end

	return text:sub(3,2+s), text:sub(3+s)
end

local function recv_package(last)
	local result
	result, last = unpack_package(last)
	if result then
		return result, last
	end
	local r = socket.recv(fd)
	if not r then
		return nil, last
	end
	if r == "" then
		error "Server closed"
	end
	return unpack_package(last .. r)
end

local session = 0

local function send_request(name, args)
	session = session + 1
	local str = request(name, args, session)
	send_package(fd, str)
	--print("Request:", session)
end

local last = ""

local function print_request(name, args)
	--print("REQUEST", name)
	if args then
		for k,v in pairs(args) do
			print(k,v)
		end
	end
end

local function print_response(session, args)
	print("RESPONSE", session)
	if args then
		for k,v in pairs(args) do
			print(k,v)
		end
	end
end

local function print_package(t, ...)
	if t == "REQUEST" then
		print_request(...)
	else
		assert(t == "RESPONSE")
		print_response(...)
	end
end

local function dispatch_package()
	while true do
		local v
		v, last = recv_package(last)
		if not v then
			break
		end

		print_package(host:dispatch(v))
	end
end

send_request("handshake")
send_request("set", { what = "hello", value = "world" })
while true do
	dispatch_package()
	local cmd = socket.readstdin()
	if cmd then
		if cmd == "quit" then
			send_request("quit")
		-- else
		-- 	send_request("get", { what = cmd })
		elseif cmd == "g" then
			print("进入群聊")
			while true do
				dispatch_package()
				local g_cmd = socket.readstdin()
				if g_cmd == "q" then
					print("退出群聊")
					break
				elseif g_cmd == "help" then
					print("g开始发送群聊消息，p开始发送私聊消息，q退出发送群聊或者私聊消息！")
					print("发送私聊消息格式：名字+#+消息内容！")
				elseif g_cmd then
					send_request("getGroupChat", { what = g_cmd })
				else
					socket.usleep(100)
				end
			end
		elseif cmd == "p" then
			print("进入私聊")
			send_request("getMember")
			while true do
				dispatch_package()
				local p_cmd = socket.readstdin()
				if p_cmd == "q" then
					print("退出私聊")
					break
				elseif p_cmd == "help" then
					print("g开始发送群聊消息，p开始发送私聊消息，q退出发送群聊或者私聊消息！")
					print("发送私聊消息格式：名字+#+消息内容！")
				elseif p_cmd then
					send_request("getPrivateChat", { what = p_cmd })
				else
					socket.usleep(100)
				end
			end
		elseif cmd == "help" then
			print("g开始发送群聊消息，p开始发送私聊消息，q退出发送群聊或者私聊消息！")
			print("发送私聊消息格式：名字+#+消息内容！")
		end
	else
		socket.usleep(100)
	end
end
