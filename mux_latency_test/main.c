/* SPDX-License-Identifier: BSD-3-Clause
 * Copyright(c) 2010-2014 Intel Corporation
 */
#include <rte_eal.h>
#include <rte_common.h>
#include <rte_debug.h>
#include <rte_errno.h>
#include <rte_ethdev.h>
#include <rte_launch.h>
#include <rte_lcore.h>
#include <rte_log.h>
#include <rte_mbuf.h>
#include <rte_ring.h>
#include <rte_byteorder.h>

#define PACKET_SIZE 128

#define PORTS_COUNT 2
#define TX_PORT_ID 0
#define RX_PORT_ID 1
#define MAX_PKT_QUOTA 128
#define TIMED_BURST_COUNT 1000

#define RX_DESC_PER_QUEUE 1024
#define TX_DESC_PER_QUEUE 512

#define MEM_POOL_SIZE 8192
#define MBUF_SIZE 2048
#define MEM_POOL_CACHE_SIZE 128

#define RING_SIZE (64 * 1024)

struct rte_ring *rings[1];
struct rte_mempool *mbuf_pool;
struct rte_mempool *mbuf_pool_tx;
int overflow_count = 0;

//----------------------------------------------------------------
/* assembly code to read the TSC */
static inline uint64_t RDTSC()
{
  unsigned int hi, lo;
  __asm__ volatile("rdtsc" : "=a" (lo), "=d" (hi));
  return ((uint64_t)hi << 32) | lo;
}

#define MAX_CORES 64
const int NANO_SECONDS_IN_SEC = 1000000000;
static double g_TicksPerNanoSec[MAX_CORES];
volatile uint64_t g_time_ns = 0;

/* returns a static buffer of struct timespec with the time difference of ts1 and ts2
   ts1 is assumed to be greater than ts2 */
struct timespec *TimeSpecDiff(struct timespec *ts1, struct timespec *ts2)
{
  static struct timespec ts;
  ts.tv_sec = ts1->tv_sec - ts2->tv_sec;
  ts.tv_nsec = ts1->tv_nsec - ts2->tv_nsec;
  if (ts.tv_nsec < 0) {
    ts.tv_sec--;
    ts.tv_nsec += NANO_SECONDS_IN_SEC;
  }
  return &ts;
}

static void CalibrateTicks(int core)
{
  struct timespec begints, endts;
  uint64_t begin = 0, end = 0;
  clock_gettime(CLOCK_MONOTONIC, &begints);
  begin = RDTSC();
  volatile uint64_t i;
  for (i = 0; i < 1000000; i++); /* must be CPU intensive */
  end = RDTSC();
  clock_gettime(CLOCK_MONOTONIC, &endts);
  struct timespec *tmpts = TimeSpecDiff(&endts, &begints);
  uint64_t nsecElapsed = tmpts->tv_sec * 1000000000LL + tmpts->tv_nsec;
  g_TicksPerNanoSec[core] = (double)(end - begin)/(double)nsecElapsed;
}

static inline uint64_t GetRdtscTime_ns(int core)
{
    (void)core;
    return g_time_ns;
  //return (uint64_t)((double)RDTSC() / g_TicksPerNanoSec[core]);
}

#define TIMESTAMP_COUNT 32
uint64_t pkt_times[TIMESTAMP_COUNT];
int ts_index = 0;
int ts_count_ready = 0;

//----------------------------------------------------------------


static struct rte_eth_conf port_conf = {
        .rxmode = {
            .split_hdr_size = 0,
        },
        .txmode = {
            .mq_mode = ETH_DCB_NONE,
        },
};

static int
timestamp_stage(__attribute__((unused)) void *args)
{
    unsigned int lcore_id;
    lcore_id = rte_lcore_id();
    CalibrateTicks(lcore_id);
    RTE_LOG(INFO, USER1,
            "[CORE %d] Calibrated Ticks/nanosecond: %lf\n", lcore_id, g_TicksPerNanoSec[lcore_id]);
    RTE_LOG(INFO, USER1,
            "%s() started timestamping on core %u\n", __func__, lcore_id);

    RTE_LOG(INFO, USER1,
            "%s() rte_eth_timesync_enable(0) == %d\n", __func__, rte_eth_timesync_enable(0));

    while (1) {
#ifdef USE_ETH_TIMESYNC
        struct timespec t;
        rte_eth_timesync_read_time(0, &t);
        g_time_ns = t.tv_sec * 1000000000LL + t.tv_nsec;
#else
        g_time_ns = (uint64_t)((double)RDTSC() / g_TicksPerNanoSec[lcore_id]);
#endif
    }
    return 0;
}


static int
receive_stage(__attribute__((unused)) void *args)
{
    int i;
    uint16_t port_id = RX_PORT_ID;
    uint16_t nb_rx_pkts;
    unsigned int lcore_id;
    char *pkt_ptr;
    uint64_t rx_first_timestamp = 0;
    uint64_t rx_count = 0;
    struct rte_mbuf *pkts[MAX_PKT_QUOTA];

    lcore_id = rte_lcore_id();

    // initialize precise clock
    CalibrateTicks(lcore_id);
    RTE_LOG(INFO, USER1,
            "[CORE %d] Calibrated Ticks/nanosecond: %lf\n", lcore_id, g_TicksPerNanoSec[lcore_id]);
    RTE_LOG(INFO, USER1,
            "%s() started RX on core %u\n", __func__, lcore_id);

    while (1) {
        // receive burst of packets
        nb_rx_pkts = rte_eth_rx_burst(port_id, 0, pkts, MAX_PKT_QUOTA);
        if (unlikely(nb_rx_pkts == 0)) {
            continue;
        }
        else {
            // get and save firsrt packet TX timestamp
            if (rx_count == 0)
            {
                pkt_ptr = rte_pktmbuf_mtod(pkts[0], char *);
                rte_memcpy(&rx_first_timestamp, pkt_ptr + sizeof(struct rte_ether_hdr) + sizeof(struct rte_ipv4_hdr), sizeof(uint64_t));
                rx_count += nb_rx_pkts;
            }

            // count packets
            rx_count += nb_rx_pkts;

            // calculate single packet (TX-RX) interval in nanosecods
            if (rx_count >= (TIMED_BURST_COUNT * MAX_PKT_QUOTA)) {
                pkt_times[ts_index++] = (GetRdtscTime_ns(lcore_id) - rx_first_timestamp) / rx_count;
                if (ts_index >= TIMESTAMP_COUNT) {
                    ts_index = 0;
                    ts_count_ready = 1;
                }
                rx_count = 0;
            }

            // cleanup memory
            for (i = 0; i < nb_rx_pkts; i++)
                rte_pktmbuf_free(pkts[i]);
        }
    }
    return 0;
}

static int
tx_stage(__attribute__((unused)) void *args)
{
    int i;
    uint16_t port_id = TX_PORT_ID;
    uint16_t tx_cnt;
    uint64_t timestamp;
    unsigned int lcore_id;
    struct rte_mbuf *pkts[MAX_PKT_QUOTA];
    char* pkt_ptr;
    lcore_id = rte_lcore_id();
    struct rte_ether_hdr hdr;
    struct rte_ipv4_hdr ip_hdr;

    // initialize precise clock
    CalibrateTicks(lcore_id);
    RTE_LOG(INFO, USER1,
            "[CORE %d] Calibrated Ticks/nanosecond: %lf\n", lcore_id, g_TicksPerNanoSec[lcore_id]);
    rte_delay_ms(1000);
    RTE_LOG(INFO, USER1,
            "%s() started TX on core %u\n",
            __func__, lcore_id);

    // format common L2 header
    rte_eth_random_addr(hdr.d_addr.addr_bytes);
    rte_eth_random_addr(hdr.s_addr.addr_bytes);
    hdr.ether_type = htons(RTE_ETHER_TYPE_IPV4);

    // format ipv4 header
    memset(&ip_hdr, 0, sizeof(ip_hdr));
    ip_hdr.version_ihl = (0x4 << 4) | 5;
    ip_hdr.total_length = htons(PACKET_SIZE - sizeof(struct rte_ether_hdr));
    ip_hdr.next_proto_id = 6;
    ip_hdr.dst_addr = 0x07070702;
    ip_hdr.src_addr = 0x07070701;
    ip_hdr.time_to_live = 128;
    ip_hdr.hdr_checksum = rte_ipv4_cksum(&ip_hdr);

    while (1) {
        // allocate packet buffers
        for (i=0; i< MAX_PKT_QUOTA; i++)
        {
            pkts[i] = rte_pktmbuf_alloc(mbuf_pool_tx);
            if (unlikely(pkts[i] == NULL) ) {
                rte_exit(EXIT_FAILURE, "No memory for packet buffers, i=%d\n", i);
                return -1;
            }
        }

        // insert current timestamp to all packets
        timestamp = GetRdtscTime_ns(lcore_id);
        for (i=0; i< MAX_PKT_QUOTA; i++)
        {
            pkt_ptr = rte_pktmbuf_mtod(pkts[i], char *);

            rte_memcpy(pkt_ptr, &hdr, sizeof(struct rte_ether_hdr));
            rte_memcpy(pkt_ptr + sizeof(struct rte_ether_hdr), &ip_hdr, sizeof(struct rte_ipv4_hdr));
            rte_memcpy(pkt_ptr + sizeof(struct rte_ether_hdr) + sizeof(struct rte_ipv4_hdr), &timestamp, sizeof(timestamp));

            pkts[i]->data_len = PACKET_SIZE;//sizeof(struct rte_ether_hdr) + sizeof(uint64_t);
            pkts[i]->pkt_len = PACKET_SIZE;
        }

        /* send a burst of packets*/
        tx_cnt = rte_eth_tx_burst(port_id, 0, pkts, MAX_PKT_QUOTA);

        // free unsent packets
        for (i = tx_cnt; i < MAX_PKT_QUOTA; i++)
            rte_pktmbuf_free(pkts[i]);
    }

    return 0;
}

void configure_eth_port(uint16_t port_id)
{
    int ret;
    uint16_t nb_rxd = RX_DESC_PER_QUEUE;
    uint16_t nb_txd = TX_DESC_PER_QUEUE;
    struct rte_eth_rxconf rxq_conf;
    struct rte_eth_txconf txq_conf;
    struct rte_eth_dev_info dev_info;
    struct rte_eth_conf local_port_conf = port_conf;
    rte_eth_dev_stop(port_id);
    rte_eth_dev_info_get(port_id, &dev_info);
    if (dev_info.tx_offload_capa & DEV_TX_OFFLOAD_MBUF_FAST_FREE)
        local_port_conf.txmode.offloads |=
            DEV_TX_OFFLOAD_MBUF_FAST_FREE;
    ret = rte_eth_dev_configure(port_id, 1, 1, &local_port_conf);
    if (ret < 0)
        rte_exit(EXIT_FAILURE, "Cannot configure port %u (error %d)\n",
                (unsigned int) port_id, ret);
    ret = rte_eth_dev_adjust_nb_rx_tx_desc(port_id, &nb_rxd, &nb_txd);
    if (ret < 0)
        rte_exit(EXIT_FAILURE,
                "Cannot adjust number of descriptors for port %u (error %d)\n",
                (unsigned int) port_id, ret);
    /* Initialize the port's RX queue */
    rxq_conf = dev_info.default_rxconf;
    rxq_conf.offloads = local_port_conf.rxmode.offloads;
    ret = rte_eth_rx_queue_setup(port_id, 0, nb_rxd,
            rte_eth_dev_socket_id(port_id),
            &rxq_conf,
            mbuf_pool);
    if (ret < 0)
        rte_exit(EXIT_FAILURE,
                "Failed to setup RX queue on port %u (error %d)\n",
                (unsigned int) port_id, ret);
    /* Initialize the port's TX queue */
    txq_conf = dev_info.default_txconf;
    txq_conf.offloads = local_port_conf.txmode.offloads;
    ret = rte_eth_tx_queue_setup(port_id, 0, nb_txd,
            rte_eth_dev_socket_id(port_id),
            &txq_conf);
    if (ret < 0)
        rte_exit(EXIT_FAILURE,
                "Failed to setup TX queue on port %u (error %d)\n",
                (unsigned int) port_id, ret);

    /* Start the port */
    ret = rte_eth_dev_start(port_id);
    if (ret < 0)
        rte_exit(EXIT_FAILURE, "Failed to start port %u (error %d)\n",
                (unsigned int) port_id, ret);
    /* Put it in promiscuous mode */
    rte_eth_promiscuous_enable(port_id);
}


int
main(int argc, char **argv)
{
    int ret;
    struct rte_eth_stats stats;
    uint16_t port_id;
    rte_log_set_global_level(RTE_LOG_INFO);
    ret = rte_eal_init(argc, argv);
    if (ret < 0)
        rte_exit(EXIT_FAILURE, "Cannot initialize EAL\n");

    /* Parse the application's arguments */

    /* Create a pool of mbuf to store packets */
    mbuf_pool = rte_pktmbuf_pool_create("mbuf_pool", MEM_POOL_SIZE, MEM_POOL_CACHE_SIZE, 0,
            MBUF_SIZE, rte_socket_id());
    mbuf_pool_tx = rte_pktmbuf_pool_create("mbuf_pool_tx", MEM_POOL_SIZE, MEM_POOL_CACHE_SIZE, 0,
            MBUF_SIZE, rte_socket_id());

    if (mbuf_pool == NULL)
        rte_panic("%s\n", rte_strerror(rte_errno));
    if (mbuf_pool_tx == NULL)
        rte_panic("%s\n", rte_strerror(rte_errno));

    for (port_id = 0; port_id < PORTS_COUNT; port_id++)
        configure_eth_port(port_id);

    rte_eal_remote_launch(timestamp_stage, NULL, 4);
    rte_eal_remote_launch(receive_stage, NULL, 2);
    rte_eal_remote_launch(tx_stage, NULL, 3);

    while( 1 ) {
        int i;
        double pkt_mean = 0;
        rte_delay_ms(1000);

        if (ts_count_ready)
        {
            rte_eth_stats_get(RX_PORT_ID, &stats );

            for (i = 0; i < TIMESTAMP_COUNT; i++) {
                pkt_mean += pkt_times[i];
            }
            pkt_mean /= TIMESTAMP_COUNT;

            RTE_LOG(INFO, USER1,
                    "Stats: pkts: %lu  dropped: %lu  gtms: %lu  PKT_TIME0: %lu PKT_TIME_MEAN: %.3lf\n", stats.ipackets, stats.imissed, g_time_ns, pkt_times[0], pkt_mean);
        }
    }

    return 0;
}
