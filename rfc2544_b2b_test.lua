-- RFC2544 B2B Test
-- as defined by https://www.ietf.org/rfc/rfc2544.txt
--  SPDX-License-Identifier: BSD-3-Clause

package.path = package.path ..";?.lua;test/?.lua;app/?.lua;../?.lua"

require "Pktgen";

-- define packet sizes to test
local pkt_sizes		= { 64, 128, 256, 512, 1024, 1280, 1518 };

-- Time in seconds to transmit for
local duration		= 2000;
local confirmTrials	= 50;
local pauseTime		= 1000;

-- define the ports in use
local sendport		= "0";
local recvports		= {"1"};

-- ip addresses to use
local dstip		= "90.90.90.90";
local srcip		= "1.1.1.1";
local netmask		= "/24";

local initialBurst  = 64 ;
local results = {};
local pkt_rates = {};

local function setupTraffic()
	pktgen.set_ipaddr(sendport, "dst", dstip);
	pktgen.set_ipaddr(sendport, "src", srcip..netmask);

	for _, p in pairs(recvports) do
		pktgen.set_ipaddr(p, "dst", srcip);
		pktgen.set_ipaddr(p, "src", dstip..netmask);
		pktgen.set_proto(p, "udp");
	end

	pktgen.set_proto(sendport, "udp");
	-- set Pktgen to send continuous stream of traffic
	pktgen.set(sendport, "count", 0);
end

local function accumulateRxStats()
	local rxStats;
	for idx, p in pairs(recvports) do
		if idx == 1 then
			rxStats = pktgen.portStats(p, "port")[tonumber(p)];
		else
			local nextStats = pktgen.portStats(p, "port")[tonumber(p)];
			rxStats.ipackets = rxStats.ipackets + nextStats.ipackets;
		end
	end

	return rxStats;
end

local function runTrial(pkt_size, rate, burst, duration, count)
	local num_tx, num_rx, num_dropped;

	pktgen.clr();
	pktgen.delay(pauseTime);
	pktgen.set(sendport, "rate", rate);
	pktgen.set(sendport, "size", pkt_size);		
	pktgen.set(sendport, "burst", burst);
	pktgen.delay(pauseTime);	

	pktgen.start(sendport);
	print("Running trial " .. count .. ". % Rate: " .. rate .. ". Burst: " .. burst ..". Packet Size: " .. pkt_size .. ". Duration (mS):" .. duration);
	file:write("Running trial " .. count .. ". % Rate: " .. rate .. ". Burst: " .. burst ..". Packet Size: " .. pkt_size .. ". Duration (mS):" .. duration .. "\n");
	pktgen.delay(duration);
	pktgen.stop(sendport);

	pktgen.delay(pauseTime);

	statTx = pktgen.portStats(sendport, "port")[tonumber(sendport)];
	statRx = accumulateRxStats();
	num_tx = statTx.opackets;
	num_rx = statRx.ipackets;
	num_dropped = num_tx - num_rx;

	if num_tx == 0 then
		print("FAILED to send packets. Check DPDK ports available!");
		file:close();		
		pktgen.quit();
		return;
	end

	print("Tx: " .. num_tx .. ". Rx: " .. num_rx .. ". Dropped: " .. num_dropped);
	file:write("Tx: " .. num_tx .. ". Rx: " .. num_rx .. ". Dropped: " .. num_dropped .. "\n");
	pktgen.delay(pauseTime);

	return num_dropped, num_rx;
end

local function runB2BTest(pkt_size)
	local num_dropped, num_rx, num_rx_mean, max_burst, min_burst, trial_burst;
	local rate = pkt_rates[tostring(pkt_size)];

	min_burst = 0;
	max_burst = 64
	trial_burst = initialBurst;
	for count=1, 10, 1
	do
		num_dropped, num_rx = runTrial(pkt_size, rate, trial_burst, duration, count);
		if num_dropped == 0
		then
			min_burst = trial_burst;
		else
			max_burst = trial_burst;
		end
		trial_burst = min_burst + math.max(4, math.floor(((max_burst - min_burst)/2) + 0.5));

		if trial_burst <= min_burst or trial_burst >= max_burst then
			break;
		end
	end

	-- Ensure we test confirmation run with the last succesfull zero-drop rate
	trial_burst = min_burst;

	-- confirm burst for at least 50 trials 2seconds each
	num_rx_mean = 0;
	for t = 1, confirmTrials, 1 
	do
		local trialName = "Confirmation " .. tostring(t);
		num_dropped, num_rx = runTrial(pkt_size, rate, trial_burst, duration, trialName);
		num_rx_mean = num_rx_mean + num_rx
	end

	num_rx_mean = math.floor((num_rx_mean / 2) / confirmTrials + 0.5);
	results[tostring(pkt_size)] = num_rx_mean;

	print("Max Burst for packet size "  .. pkt_size .. "B is: " .. num_rx_mean);
	file:write("Max Burst for packet size "  .. pkt_size .. "B is: " .. num_rx_mean .. "\n\n");	
end

local function writeResults()
	file:write("RFC2544 Back-to-Back Test results:\n\n");
	file:write("Size\tBurst\n");
	for _,size in pairs(pkt_sizes)
	do
		file:write(size.."\t"..results[tostring(size)].."\n");
	end
end

local function file_exists(file)
	local f = io.open(file, "rb")
	if f then f:close() end
	return f ~= nil
end

local function loadPortsMapping()
	local rx_ports = {}
	if not file_exists("mux_ports.cfg") then return; end
	for line in io.lines("mux_ports.cfg") do 
		if line:find("^TX_100G") then
			s1, s2 = line:find("=%d")
			if s1 ~= nil then
				sendport = line:sub(s1+1,s2);
			end
		elseif line:find("^RX_") then
			s1, s2 = line:find("=%d")
			if s1 ~= nil then
				rx_ports[#rx_ports + 1] = line:sub(s1+1,s2);
			end
		end
	end

	if #rx_ports > 0 then
		recvports = rx_ports;
	end
end

local function split_number(str)
    local t = {}
    for n in str:gmatch("%S+") do
        table.insert(t, tonumber(n))
    end
    return table.unpack(t)
end

local function loadPacketMaxRates()
	local max_rates = {}
	local start = 0;
	if not file_exists("RFC2544_throughput_results.txt") then
		print("FAILED to test Back-to-Back performance: MUST test Throughput FIRST!");
		pktgen.quit();
		return;
	end

	for line in io.lines("RFC2544_throughput_results.txt") do 
		if line:find("^Size") then
			start = 1;
		elseif start == 1 then
			psize, speed, pps = split_number(line);
			if speed ~= nill then
				pkt_rates[tostring(psize)] = speed;
				print("Loaded packet rate "..speed.." for psize="..psize);
			else
				pkt_rates[tostring(psize)] = 100;
			end
		end
	end
end

function main()
	loadPacketMaxRates();
	loadPortsMapping();
	file = io.open("RFC2544_b2b_results.txt", "w");
	setupTraffic();
	for _,size in pairs(pkt_sizes)
	do
		runB2BTest(size);
	end
	writeResults();
	file:close();

	pktgen.delay(3000);
	pktgen.quit();
end

main();
