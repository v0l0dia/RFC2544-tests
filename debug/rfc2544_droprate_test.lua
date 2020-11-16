-- RFC2544 Throughput Test
-- as defined by https://www.ietf.org/rfc/rfc2544.txt
--  SPDX-License-Identifier: BSD-3-Clause

package.path = package.path ..";?.lua;test/?.lua;app/?.lua;../?.lua"

require "Pktgen";

-- define packet sizes to test
local pkt_sizes		= { 64, 128, 256, 512, 1024, 1280, 1518 };
local pkt_speeds    = {[64]=14880000, [128]=84450000, [256]=45280000, [512]=23490000, [768]=15860000, [1024]=11970000, [1280]=9610000,[1518]=8120000};

-- Time in seconds to transmit for
local packetsToSend = 100000000;
local maxPacketsWait= 10000;
local confirmTrials	= 2;
local pauseTime		= 1000;

-- define the ports in use
local sendport		= "0";
local recvport		= "1";

-- ip addresses to use
local dstip		= "90.90.90.90";
local srcip		= "1.1.1.1";
local netmask		= "/24";

local initialRate	= 100 ;
local results = {};

local function setupTraffic()
	pktgen.set_ipaddr(sendport, "dst", dstip);
	pktgen.set_ipaddr(sendport, "src", srcip..netmask);

	pktgen.set_ipaddr(recvport, "dst", srcip);
	pktgen.set_ipaddr(recvport, "src", dstip..netmask);

	pktgen.set_proto(sendport..","..recvport, "udp");
	-- set Pktgen to send continuous stream of traffic
	pktgen.set(sendport, "count", packetsToSend);
end

local function runTrial(pkt_size, rate, count)
	local num_tx, num_rx, num_dropped;

	pktgen.clr();
	pktgen.delay(pauseTime);
	pktgen.set(sendport, "rate", rate);
	pktgen.set(sendport, "size", pkt_size);
	pktgen.delay(pauseTime);

	pktgen.start(sendport);
	print("Running trial " .. count .. ". % Rate: " .. rate .. ". Packet Size: " .. pkt_size .. ". Packets:" .. packetsToSend);
	file:write("Running trial " .. count .. ". % Rate: " .. rate .. ". Packet Size: " .. pkt_size .. ". Packets:" .. packetsToSend .. "\n");
	pktgen.delay(maxPacketsWait);
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

	return num_dropped;
end

local function runDroprateTest(pkt_size)
	local num_dropped, max_rate, min_rate, trial_rate;
	local trialResults = {};
	
	trial_rate = initialRate;
	for count=1, 99, 1
	do
		num_dropped = runTrial(pkt_size, trial_rate, count);
		trialResults[count] = {Speed=trial_rate, Droprate=(num_dropped / packetsToSend)};
		if num_dropped == 0
		then
			-- Need 2 successive trials for test to complete
			num_dropped = runTrial(pkt_size, trial_rate, "Confirmation "..count);
			if num_dropped == 0 then
				break;
			end
		end
		trial_rate = 100 - count;
	end

	results[tostring(size)] = trialResults;

	if num_dropped == 0
	then
		print("Max rate for packet size "  .. pkt_size .. "B is: " .. trial_rate);
		file:write("Max rate for packet size "  .. pkt_size .. "B is: " .. trial_rate .. "\n\n");
	else
		print("FAILED test for packet size "  .. pkt_size .. "B Min droprate is " .. (num_dropped/packetsToSend));
		file:write("FAILED test for packet size "  .. pkt_size .. "B Min droprate is " .. (num_dropped/packetsToSend) .. "\n\n");
	end
end

local function writeResults()
	file:write("RFC2544 Droprate Test results:\n\n");
	file:write("Size\tSpeed\tDroprate\tPPS\n");
	for _,size in pairs(pkt_sizes)
	do
		for _,entry in pairs(results[tostring(size)])
		do
			local pps = math.floor(pkt_speeds[size] * (entry["Speed"] / 100));
			file:write(size.."\t"..entry["Speed"].."\t"entry["Droprate"].."\t"..pps.."\n");
		end
	end
end

function main()
	file = io.open("RFC2544_droprate_results.txt", "w");
	setupTraffic();
	for _,size in pairs(pkt_sizes)
	do
		runDroprateTest(size);
	end
	writeResults();
	file:close();
end

main();
