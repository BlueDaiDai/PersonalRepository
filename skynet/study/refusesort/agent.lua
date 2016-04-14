package.path = "./study/refusesort/?.lua;" .. package.path

local skynet = require "skynet"
local netpack = require "netpack"
local socket = require "socket"


local reqparse = require "reqparse"
local resppack = require "resppack"
local redis_helper = require "redis_helper"


local WATCHDOG
local send_request

local CMD = {}
local REQUEST = {}
local client_fd

local client_user 
local game_time_length = 4*60 --秒 24点
--local game_time_length = 3*60 --秒 垃圾分类
local msg_version = 0x20

local timer_session = 0

local game_rand = 1 --随即数
local game_step = 1 --步进

--产生步进和随机数
local function gen_rand()
	game_rand = math.random(1001,9999)
	game_step = math.random(11,20)
end

--检查客户端发上来的随机数
local function check_rand(req_rand)
	if req_rand == game_rand + game_step then
		game_rand = req_rand
		return true
	else
		return false
	end
end

local function get_user_key(userid)
	return "userinfo." .. os.date("%Y%m%d", os.time()) .. "." .. userid
end

local function send_package(package)
	--print("re message len:" .. #package)
	socket.write(client_fd, package)
end

--刷新用户信息
local function refresh_user()
	local user = skynet.call("LOGICSERVER", "lua", "get_user", client_user.userid)
	client_user.total = tonumber(user.total)
	client_user.best_rank = tonumber(user.rank)
	client_user.best_score = tonumber(user.score)
	client_user.username = user.username
	client_user.remain = tonumber(user.remain)
	
	--储存到simpledb中去
	skynet.send("SIMPLEDB", "lua", "set", client_user.dbkey,client_user)
end

--初始化化用户信息
local function init_userinfo(userid)
	local dbkey = "user." .. userid
	client_user = skynet.call("SIMPLEDB", "lua", "get", dbkey)
	if client_user then print("init_userinfo temp_score:",client_user.temp_score) end
	if client_user == nil then
		client_user = {}
		client_user.userid = userid
		client_user.dbkey = "user." ..userid
		client_user.gamestate = 0
		client_user.temp_score = 0
		client_user.endtime = 0
		refresh_user()
		
	end
	
end


--同时设置好定时器,游戏结束
local function dotimeout()
	timer_session = timer_session -1
	
	--print("dotimeout",timer_session,client_user.gamestate)
	if(timer_session > 0 or client_user.gamestate == 0) then
		--print("不发timeout包",timer_session,client_user.gamestate)
		return
	end
	
	--print("发timeout包")
	local package = resppack.pack(resppack.cmd.timeout,msg_version)
	send_package(package)
end

--设置游戏结束的定时器,保证定时器只有一个生效
local function set_gameover_timeout(seconds)
	skynet.timeout(seconds,dotimeout)
	timer_session = timer_session + 1
end

--检查用户是否需要短信重练
local function check_reconnect(remainseconds,message)
	
	if remainseconds >0 then
		--发用户信息包
		package = resppack.pack(resppack.cmd.userinfo,message.version,client_user)
		send_package(package)
		--发场景包
		gen_rand() --生成随机数和步进
		package = resppack.pack(resppack.cmd.gamescene,message.version,client_user.temp_score,remainseconds,game_rand,game_step)
		send_package(package)
		
		set_gameover_timeout(remainseconds*100)
		
		return true
	end
	
	return false
end







-- function REQUEST:quit()
-- 	skynet.call(WATCHDOG, "lua", "close", client_fd)
-- end

REQUEST[reqparse.cmd.rank] = function(recmdtype,message)
	local rank_items = skynet.call("LOGICSERVER", "lua", "get_rank_items", message.userid)
	-- for i=1,#rank_items do
	-- 	local v = rank_items[i]
	-- 	print(v.userid,v.username,v.rank,v.maxscore)
	-- end
	local package = resppack.pack(recmdtype,message.version,rank_items)
	send_package(package)	
end

--个人信息
REQUEST[reqparse.cmd.userinfo] = function(recmdtype,message)

	local package = resppack.pack(recmdtype,message.version,client_user)
	send_package(package)
end

--奖励
REQUEST[reqparse.cmd.awardinfo] = function(recmdtype,message)
	
	local award_index = tonumber(skynet.getenv "award_index")
    local award_items = require("awarditems")[award_index]
	local package = resppack.pack(recmdtype,message.version,award_items)
	send_package(package)
end

--游戏开始
REQUEST[reqparse.cmd.gamestart] = function(recmdtype,message)
	
	local result = {}
	local package

	--print("剩余次数:" .. client_user.remain)
	if client_user.remain <= 0 then
		result.re = 0
		result.info = "今日挑战次数已用完，明日请早"
		package = resppack.pack(recmdtype,message.version,result)
		send_package(package)
		return
	end
	
	client_user.gamestate = 1
	client_user.remain = client_user.remain -1
	--更新剩余次数,储存到simpledb中去

	local userid = client_user.userid
	skynet.send("LOGICSERVER","lua", "sub_remain", client_user.userid)
	skynet.send("SIMPLEDB", "lua", "set", client_user.dbkey,client_user)
	
	result.re = 1
	result.info = "ok"
	gen_rand() --生成随机数和步进
	result.rand = game_rand
	result.step = game_step
	
	package = resppack.pack(recmdtype,message.version,result)
	send_package(package)
	
	--同时更新用户信息
	package = resppack.pack(resppack.cmd.userinfo,message.version,client_user)
	send_package(package)
	
	
	--4分钟
	set_gameover_timeout(game_time_length*100)
	
	--过程分数，结束时间
	client_user.temp_score = 0
	client_user.endtime = os.time() + game_time_length
	skynet.send("SIMPLEDB", "lua", "set", client_user.dbkey,client_user)
end

--提交成绩,gameover
REQUEST[reqparse.cmd.gameover] = function(recmdtype,message)
	
	local result = {}
	result.iswin = 0
	
	local is_our_client = check_rand(message.rand) --检查是否是我们的客户端
	
	if message.score > client_user.best_score and is_our_client then 
		result.iswin = 1
		--提交成绩，刷新用户
		skynet.call("LOGICSERVER", "lua", "add_score", message.userid,message.score)
		refresh_user()
	end 

	result.best_rank = client_user.best_rank
	result.best_score = client_user.best_score
	local package = resppack.pack(recmdtype,message.version,result)
	send_package(package)
	
	--过程分数
	client_user.temp_score = 0
	client_user.gamestate = 0
	skynet.send("SIMPLEDB", "lua", "set", client_user.dbkey,client_user)
end

--单次提交成绩,gamestep
REQUEST[reqparse.cmd.gamestep] = function(recmdtype,message)
	
	local is_our_client = check_rand(message.rand) --检查是否是我们的客户端
	
	local re = 0
	if is_our_client then
		re = 1
		--过程分数,更新成绩,刷新数据
		client_user.temp_score = client_user.temp_score + message.score
		--print("client_user.temp_score:"..client_user.temp_score)
		skynet.send("SIMPLEDB", "lua", "set", client_user.dbkey,client_user)
	end 

	local package = resppack.pack(recmdtype,message.version,re)
	send_package(package)
end

--心跳
REQUEST[reqparse.cmd.heartbeat] = function(recmdtype,message)
	local package = resppack.pack(recmdtype,message.version)
	send_package(package)
end

--进入房间
REQUEST[reqparse.cmd.enterroom] = function(recmdtype,message)
	
	local state = 1

	--在线人数
	local player_count = 200
	
	msg_version = message.version
	
	print("请求验证1:",skynet.time())
	local isverify = skynet.call("LOGICSERVER", "lua", "verify", message.userid,message.authentic)
	
	print("请求验证2:",skynet.time())
	if isverify == false then
		state = -1 --验证没通过
		local reason = "验证信息已过期，请重新登陆"
		local package = resppack.pack(recmdtype,message.version,state,player_count,reason)
		send_package(package)
		return
	end
	 
	--进入房间时刷新用户信息
	print("获取名字1:",skynet.time())
	init_userinfo(message.userid)
	print("获取名字2:",skynet.time())
	local remainseconds = client_user.endtime - os.time()
	
	if remainseconds >0 then
		state=2
	end
	
	
	

	
	local package = resppack.pack(recmdtype,message.version,state,player_count)
	send_package(package)
	
	--检查是否需要短线重连
	check_reconnect(remainseconds,message)
	
	--进入房间时告知他奖励信息
	local result = skynet.call("LOGICSERVER", "lua", "get_award_info", message.userid)
	
	if result then
		local package = resppack.pack(resppack.cmd.awardresult,message.version,result)
		send_package(package)
	 end
end

--离开房间
REQUEST[reqparse.cmd.leaveroom] = function(recmdtype,message)
	local userid  = client_user.userid
	local reasonid = 0
	--清理用户信息
	skynet.send("SIMPLEDB", "lua", "DEL", client_user.dbkey)
	local package = resppack.pack(recmdtype,message.version,userid,reasonid)
	send_package(package)
	skynet.call(WATCHDOG, "lua", "close", client_fd)
end


local function request(message)
	local userid = message.userid or client_user.userid	
	skynet.error(string.format("userid:%d message type:%x",userid, message.cmdtype))
	local recmdtype = message.cmdtype + 0x80000000
	local f = assert(REQUEST[message.cmdtype])
	if f then
		f(recmdtype,message)
	end
end


skynet.register_protocol {
	name = "client",
	id = skynet.PTYPE_CLIENT,
	unpack = function (msg, sz)

		--此处解析具体的消息
		local message = reqparse.parse(msg,sz)
				
		return "REQUEST",message
		-- return host:dispatch(msg, sz)
	end,
	dispatch = function (_, _, type, ...)
		if type == "REQUEST" then
			local ok, result  = pcall(request, ...)
			if ok == false then
				skynet.error(result)
			end
		else
			assert(type == "RESPONSE")
			error "This example doesn't support request client"
		end
	end
}

function CMD.start(conf)
	local fd = conf.client
	local gate = conf.gate
	WATCHDOG = conf.watchdog
	client_fd = fd
	skynet.call(gate, "lua", "forward", fd)
end

function CMD.disconnect()
	-- todo: do something before exit
	skynet.exit()
end

skynet.start(function()
	--读取配置
	local game_time_length = tonumber(skynet.getenv "game_time_length")
	print(game_time_length)
	skynet.dispatch("lua", function(_,_, command, ...)
		local f = CMD[command]
		skynet.ret(skynet.pack(f(...)))
	end)
end)
