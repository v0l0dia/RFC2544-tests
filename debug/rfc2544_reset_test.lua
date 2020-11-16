-- RFC2544 Reset Test
-- as defined by https://www.ietf.org/rfc/rfc2544.txt
--  SPDX-License-Identifier: BSD-3-Clause

package.path = package.path ..";?.lua;test/?.lua;app/?.lua;../?.lua"

require "Pktgen";

-- Time variables
local WarmUpCount = 500;
local TickTime = 10;
local MaxWait_ms = 120000;

-- define the ports in use
local sendport		= "0";
local recvport		= "1";

-- ip addresses to use
local dstip		= "90.90.90.90";
local srcip		= "1.1.1.1";
local netmask		= "/24";

local WARMUP_STATE = 0;
local WAIT_RESET_STATE = 1;
local WAIT_RESTORE_STATE = 2;

local ClockPerSecond = 0;

local function setupTraffic()
	pktgen.set_ipaddr(sendport, "dst", dstip);
	pktgen.set_ipaddr(sendport, "src", srcip..netmask);

	pktgen.set_ipaddr(recvport, "dst", srcip);
	pktgen.set_ipaddr(recvport, "src", dstip..netmask);

	pktgen.set_proto(sendport..","..recvport, "udp");
	-- set Pktgen to send 1 packet
	pktgen.set(sendport, "count", 1);
end

local function calibrateClock()
	print("Calibrating system clock...");
	t0 = os.clock();
	pktgen.delay(5000);
	t1 = os.clock();
	ClockPerSecond = (t1 - t0) / 5;
end

local function runResetTest()
	local state = WARMUP_STATE;
	local reset_time = -1;
	local t_send, t_valid_send, t_valid_rx;
	local pkt_count = 0;
	local no_rx_count = 0;

	print("Warming-Up... ")
	pktgen.clr();
	for tick = 1, (MaxWait_ms / TickTime), 1
	do
		t_send = os.clock();
		pktgen.start(sendport);
		pktgen.delay(TickTime);
		pktgen.stop(sendport);

		statRx = pktgen.portStats(recvport, "port")[tonumber(recvport)];

		if state == WARMUP_STATE then			
			if statRx.ipackets > 0 then				
				t_valid_send = t_send;
				pkt_count = pkt_count + statRx.ipackets;
			end

			if pkt_count >= WarmUpCount then
				state = WAIT_RESET_STATE;				
				print("Warm-Up finished.\n\nRESET MUX BOARD");
				pktgen.clr();
			end
		elseif state == WAIT_RESET_STATE then
			if statRx.ipackets > 0 then
				t_valid_send = t_send;
				no_rx_count = 0;
				pktgen.clr();
			else
				no_rx_count = no_rx_count + 1;
				if no_rx_count > (1000 / TickTime) then
					print("\n -- Board Reset detected\n");
					state = WAIT_RESTORE_STATE;
					pktgen.clr();
				end
			end
		elseif state == WAIT_RESTORE_STATE then
			if statRx.ipackets > 0 then
				t_valid_rx = os.clock();
				reset_time = ((t_valid_rx - t_valid_send) / ClockPerSecond) * 1000 - 1000;
				print("Reset test FINISHED, time: " .. reset_time.."ms");
				file:write("Restore-From-Reset-Time: " .. reset_time .. "ms." .. "\n\n");
				break;
			end
		end		
	end

	if pkt_count < WarmUpCount or reset_time < 0 then
		print("ERROR: Not enough packets forwarded on DUT!");
		file:write("ERROR: Reset test FAILED!\n\n");
	end

	return reset_time;
end

function main()
	file = io.open("RFC2544_reset_results.txt", "w");
	setupTraffic();
	calibrateClock();

	runResetTest(size);
	file:close();

	pktgen.delay(3000);
	pktgen.quit();
end

main();
