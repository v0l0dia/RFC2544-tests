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
local recvport		= "1";

-- ip addresses to use
local dstip		= "90.90.90.90";
local srcip		= "1.1.1.1";
local netmask		= "/24";

local initialRate	= 90 ;
local initialBurst  = 32 ;
local results = {};

local function setupTraffic()
	pktgen.set_ipaddr(sendport, "dst", dstip);
	pktgen.set_ipaddr(sendport, "src", srcip..netmask);

	pktgen.set_ipaddr(recvport, "dst", srcip);
	pktgen.set_ipaddr(recvport, "src", dstip..netmask);

	pktgen.set_proto(sendport..","..recvport, "udp");
	-- set Pktgen to send continuous stream of traffic
	pktgen.set(sendport, "count", 0);
end

local function runTrial(pkt_size, rate, burst, duration, count)
	local num_tx, num_rx, num_dropped;

	pktgen.clr();
	pktgen.delay(pauseTime);
	pktgen.set(sendport, "rate", rate);
	pktgen.set(sendport, "size", pkt_size);	
	pktgen.set(sendport, "burst", burst);
	pktgen.set(recvport, "burst", burst);
	pktgen.delay(pauseTime);	

	pktgen.start(sendport);
	print("Running trial " .. count .. ". % Rate: " .. rate .. ". Burst: " .. burst ..". Packet Size: " .. pkt_size .. ". Duration (mS):" .. duration);
	file:write("Running trial " .. count .. ". % Rate: " .. rate .. ". Burst: " .. burst ..". Packet Size: " .. pkt_size .. ". Duration (mS):" .. duration .. "\n");
	pktgen.delay(duration);
	pktgen.stop(sendport);

	pktgen.delay(pauseTime);

	statTx = pktgen.portStats(sendport, "port")[tonumber(sendport)];
	statRx = pktgen.portStats(recvport, "port")[tonumber(recvport)];
	num_tx = statTx.opackets;
	num_rx = statRx.ipackets;
	num_dropped = num_tx - num_rx;

	print("Tx: " .. num_tx .. ". Rx: " .. num_rx .. ". Dropped: " .. num_dropped);
	file:write("Tx: " .. num_tx .. ". Rx: " .. num_rx .. ". Dropped: " .. num_dropped .. "\n");
	pktgen.delay(pauseTime);

	return num_dropped, num_rx;
end

local function runB2BTest(pkt_size)
	local num_dropped, num_rx, num_rx_mean, max_burst, min_burst, trial_burst, last_success_burst;

	min_burst = 4;
	max_burst = 64
	last_success_burst = min_burst;
	trial_burst = initialBurst;
	for count=1, 10, 1
	do
		num_dropped, num_rx = runTrial(pkt_size, initialRate, trial_burst, duration, count);
		if num_dropped == 0
		then
			min_burst = trial_burst;
		else
			max_burst = trial_burst;
		end
		trial_burst = math.floor(min_burst + ((max_burst - min_burst)/2) + 0.5);
		trial_burst = trial_burst - (trial_burst % 2);
		if trial_burst <= min_burst then
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
		num_dropped, num_rx = runTrial(pkt_size, initialRate, trial_burst, duration, trialName);
		num_rx_mean = num_rx_mean + num_rx
	end

	num_rx_mean = math.floor(num_rx_mean / confirmTrials + 0.5);
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

function main()
	file = io.open("RFC2544_b2b_results.txt", "w");
	setupTraffic();
	for _,size in pairs(pkt_sizes)
	do
		runB2BTest(size);
	end
	writeResults();
	file:close();
end

main();
