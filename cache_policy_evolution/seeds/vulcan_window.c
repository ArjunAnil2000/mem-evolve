// ============================================================================
// SECTION: BPF KERNEL CODE
// ============================================================================
// EVOLVE-BLOCK-START
// Vulcan Window: single list, scan-resistant recency like vulcan_recency,
// but the eviction threshold and admission bar adapt to a *trend* — a
// RollingWindow of recent eviction-victim coldness — rather than a single
// EWMA pressure value. Page-cache-only.
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

#include "cache_ext_lib.bpf.h"
#include "dir_watcher.bpf.h"

// vulcan_bpf: BPF-compatible feature-store/listener primitives. No
// network/scheduler signals here on purpose — this policy stays
// page-cache-only. See cache_ext/vulcan_bpf/README.md.
#include "vulcan_bpf.h"

#define VULCAN_NUM_GLOBAL_FEATURES 1
enum vulcan_global_feature {
	// Rolling window of the last few evicted folios' interval EWMAs —
	// "how cold were the things we just had to throw out". Used to
	// detect whether eviction pressure is rising (victims getting
	// hotter / shorter intervals over time) or falling.
	GF_VICTIM_INTERVAL = 0,
};

#include "vulcan_feature.h"

char _license[] SEC("license") = "GPL";

#define COLD_INTERVAL_BASE_NS (50ULL * 1000 * 1000) // baseline "hot" bar before the window has samples
#define VICTIM_WINDOW_SIZE    8                      // RollingWindow size, <= VULCAN_MAX_WINDOW (16)
#define MIN_TREND_SAMPLES     4                      // need this many window samples before trusting the trend
#define MIN_PROTECT_ACCESSES_BASE 2                   // normal re-access bar for "hot" status

static u64 main_list;

/* Plain BPF globals (exposed via skel->bss to the loader) for next-round
 * LLM feedback — see evo_dump.h. Cheap because they're only bumped once
 * per eviction, not per access. */
__u64 g_evictions = 0;
__u64 g_pressure_rising_evictions = 0; // evictions decided under the tightened trend bar

struct folio_metadata {
	struct vulcan_folio_metadata vulcan;
};

struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__type(key, u64);
	__type(value, struct folio_metadata);
	__uint(max_entries, 4000000);
} folio_metadata_map SEC(".maps");

// Per-folio listener config: track recency via interval EWMA only.
static const struct vulcan_folio_config folio_cfg = {
	.listener_mask = VULCAN_LISTENER_EWMA,
	.ewma_alpha = 200,
};

// Global victim-coldness feature: RollingWindow only, fed exclusively from
// folio_evicted (cache-internal, never from outside the cache subsystem).
static const struct vulcan_feature_config gf_victim_interval_cfg = {
	.listener_mask = VULCAN_LISTENER_RW,
	.rw_size = VICTIM_WINDOW_SIZE,
};

static inline bool is_folio_relevant(struct folio *folio) {
	if (!folio || !folio->mapping || !folio->mapping->host)
		return false;
	return inode_in_watchlist(folio->mapping->host->i_ino);
}

static inline struct folio_metadata *get_folio_metadata(struct folio *folio) {
	u64 key = (u64)folio;
	return bpf_map_lookup_elem(&folio_metadata_map, &key);
}

s32 BPF_STRUCT_OPS_SLEEPABLE(evo_policy_init, struct mem_cgroup *memcg)
{
	main_list = bpf_cache_ext_ds_registry_new_list(memcg);
	if (main_list == 0) {
		bpf_printk("evo_policy: init: Failed to create main_list\n");
		return -1;
	}
	return 0;
}

static int evict_cb(int idx, struct cache_ext_list_node *a)
{
	struct folio_metadata *data = get_folio_metadata(a->folio);
	if (!data)
		return CACHE_EXT_EVICT_NODE; // no metadata -> safe to evict

	u32 window_count = vulcan_get_window_count(GF_VICTIM_INTERVAL);
	s64 window_avg = vulcan_get_window_avg(GF_VICTIM_INTERVAL);
	s64 latest = vulcan_get_latest(GF_VICTIM_INTERVAL);

	u32 min_protect_accesses = MIN_PROTECT_ACCESSES_BASE;
	bool pressure_rising = false;

	if (window_count >= MIN_TREND_SAMPLES && latest < window_avg) {
		// The most recently evicted folio was hotter (shorter interval)
		// than the windowed average victim -> we're cutting closer to
		// the working set than usual. Demand one more re-access before
		// granting protected status.
		min_protect_accesses = MIN_PROTECT_ACCESSES_BASE + 1;
		pressure_rising = true;
	}

	// Folios touched only once have an uninitialized interval_ewma
	// (vulcan_ewma_get returns 0, which would look "hot" by accident) -
	// treat under-the-bar folios as cold explicitly.
	if (data->vulcan.access_count < min_protect_accesses) {
		if (pressure_rising)
			__sync_fetch_and_add(&g_pressure_rising_evictions, 1);
		return CACHE_EXT_EVICT_NODE;
	}

	s64 interval_ewma = vulcan_ewma_get(&data->vulcan.interval_ewma);
	s64 threshold = window_count >= MIN_TREND_SAMPLES
		? window_avg
		: (s64)COLD_INTERVAL_BASE_NS;

	if (interval_ewma > threshold) {
		if (pressure_rising)
			__sync_fetch_and_add(&g_pressure_rising_evictions, 1);
		return CACHE_EXT_EVICT_NODE;
	}

	if (idx < 200)
		return CACHE_EXT_CONTINUE_ITER;

	return CACHE_EXT_EVICT_NODE;
}

void BPF_STRUCT_OPS(evo_policy_evict_folios, struct cache_ext_eviction_ctx *eviction_ctx,
		    struct mem_cgroup *memcg)
{
	if (bpf_cache_ext_list_iterate(memcg, main_list, evict_cb, eviction_ctx) < 0) {
		bpf_printk("evo_policy: evict: Failed to iterate main_list\n");
		return;
	}
}

void BPF_STRUCT_OPS(evo_policy_folio_accessed, struct folio *folio) {
	if (!is_folio_relevant(folio))
		return;

	struct folio_metadata *data = get_folio_metadata(folio);
	if (data)
		vulcan_folio_on_access(&data->vulcan, bpf_ktime_get_ns(), &folio_cfg);

	/* Promote to tail (protected end) on re-access - the scan-resistance
	 * mechanism: one-shot scan pages stay near the head and get evicted,
	 * hot re-accessed pages move to the safe tail. */
	bpf_cache_ext_list_move(main_list, folio, true);
}

void BPF_STRUCT_OPS(evo_policy_folio_evicted, struct folio *folio) {
	struct folio_metadata *data = get_folio_metadata(folio);
	if (data && data->vulcan.access_count > 1) {
		s64 interval_ewma = vulcan_ewma_get(&data->vulcan.interval_ewma);
		vulcan_update_feature(GF_VICTIM_INTERVAL, interval_ewma, &gf_victim_interval_cfg);
	}

	u64 key = (u64)folio;
	bpf_map_delete_elem(&folio_metadata_map, &key);
	bpf_cache_ext_list_del(folio);
	__sync_fetch_and_add(&g_evictions, 1);
}

void BPF_STRUCT_OPS(evo_policy_folio_added, struct folio *folio) {
	if (!is_folio_relevant(folio))
		return;

	u64 key = (u64)folio;
	struct folio_metadata new_meta = { .vulcan = vulcan_folio_init(bpf_ktime_get_ns()) };
	if (bpf_map_update_elem(&folio_metadata_map, &key, &new_meta, BPF_ANY)) {
		bpf_printk("evo_policy: added: Failed to create metadata\n");
		return;
	}

	/* Add at HEAD (probationary). Re-accessed folios get promoted to
	 * tail by folio_accessed. If already in list (readahead re-add),
	 * demote back to HEAD. */
	if (bpf_cache_ext_list_add(main_list, folio))
		bpf_cache_ext_list_move(main_list, folio, false);
}

SEC(".struct_ops.link")
struct cache_ext_ops evo_policy_ops = {
	.init = (void *)evo_policy_init,
	.evict_folios = (void *)evo_policy_evict_folios,
	.folio_accessed = (void *)evo_policy_folio_accessed,
	.folio_evicted = (void *)evo_policy_folio_evicted,
	.folio_added = (void *)evo_policy_folio_added,
};
// EVOLVE-BLOCK-END

// ============================================================================
// SECTION: USERSPACE LOADER
// ============================================================================
// EVOLVE-BLOCK-START
#include <argp.h>
#include <bpf/bpf.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "dir_watcher.h"
#include "evo_policy.skel.h"
#include "evo_dump.h"

struct cmdline_args {
	char *watch_dir;
	uint64_t cgroup_size;
	char *cgroup_path;
};

static struct argp_option options[] = {
	{ "watch_dir", 'w', "DIR", 0, "Directory to watch" },
	{ "cgroup_size", 's', "SIZE", 0, "Size of the cgroup in bytes" },
	{ "cgroup_path", 'c', "PATH", 0, "Path to cgroup" },
	{ 0 },
};

static volatile sig_atomic_t exiting;

static void sig_handler(int signo) { exiting = 1; }

static error_t parse_opt(int key, char *arg, struct argp_state *state)
{
	struct cmdline_args *args = state->input;
	switch (key) {
	case 'w': args->watch_dir = arg; break;
	case 's':
		errno = 0;
		args->cgroup_size = strtoull(arg, NULL, 10);
		if (errno) args->cgroup_size = 0;
		break;
	case 'c': args->cgroup_path = arg; break;
	default: return ARGP_ERR_UNKNOWN;
	}
	return 0;
}

static int parse_args(int argc, char **argv, struct cmdline_args *args) {
	struct argp argp = { options, parse_opt, 0, 0 };
	argp_parse(&argp, argc, argv, 0, 0, args);

	if (!args->watch_dir) {
		fprintf(stderr, "Missing required argument: watch_dir\n");
		return 1;
	}
	if (args->cgroup_size == 0) {
		fprintf(stderr, "Invalid cgroup size\n");
		return 1;
	}
	if (!args->cgroup_path) {
		fprintf(stderr, "Missing required argument: cgroup_path\n");
		return 1;
	}
	return 0;
}

static int validate_watch_dir(const char *watch_dir, char *watch_dir_full_path) {
	if (access(watch_dir, F_OK) == -1) {
		fprintf(stderr, "Directory does not exist: %s\n", watch_dir);
		return 1;
	}
	if (realpath(watch_dir, watch_dir_full_path) == NULL) {
		perror("realpath");
		return 1;
	}
	if (strlen(watch_dir_full_path) > 128) {
		fprintf(stderr, "watch_dir path too long\n");
		return 1;
	}
	return 0;
}

int main(int argc, char **argv) {
	struct cmdline_args args = { 0 };
	struct evo_policy_bpf *skel = NULL;
	struct bpf_link *link = NULL;
	struct sigaction sa;
	char watch_dir_path[PATH_MAX];
	int cgroup_fd = -1;
	int ret = 1;

	libbpf_set_strict_mode(LIBBPF_STRICT_ALL);

	if (parse_args(argc, argv, &args))
		return 1;

	memset(&sa, 0, sizeof(sa));
	sigemptyset(&sa.sa_mask);
	sa.sa_handler = sig_handler;

	if (sigaction(SIGINT, &sa, NULL)) {
		perror("Failed to set up signal handling");
		return 1;
	}

	if (validate_watch_dir(args.watch_dir, watch_dir_path))
		return 1;

	cgroup_fd = open(args.cgroup_path, O_RDONLY);
	if (cgroup_fd < 0) {
		perror("Failed to open cgroup path");
		return 1;
	}

	skel = evo_policy_bpf__open();
	if (!skel) {
		perror("Failed to open BPF skeleton");
		goto cleanup;
	}

	watch_dir_path_len_map(skel) = strlen(watch_dir_path);
	strcpy(watch_dir_path_map(skel), watch_dir_path);

	if (evo_policy_bpf__load(skel)) {
		perror("Failed to load BPF skeleton");
		goto cleanup;
	}

	if (initialize_watch_dir_map(watch_dir_path, bpf_map__fd(inode_watchlist_map(skel)), true)) {
		perror("Failed to initialize watch_dir map");
		goto cleanup;
	}

	link = bpf_map__attach_cache_ext_ops(skel->maps.evo_policy_ops, cgroup_fd);
	if (!link) {
		perror("Failed to attach cache_ext_ops to cgroup");
		goto cleanup;
	}

	printf("evo_policy (Vulcan Window) running. Press Ctrl+C to exit...\n");
	while (!exiting)
		sleep(1);

	/* Surface vulcan-derived state for next-round LLM feedback. */
	{
		FILE *m = evo_metrics_open();
		evo_dump_str(m, "policy_name", "vulcan_window");
		evo_dump_u64(m, "evictions", skel->bss->g_evictions);
		evo_dump_u64(m, "pressure_rising_evictions", skel->bss->g_pressure_rising_evictions);
		evo_metrics_close(m);
	}
	ret = 0;

cleanup:
	close(cgroup_fd);
	bpf_link__destroy(link);
	evo_policy_bpf__destroy(skel);
	return ret;
}
// EVOLVE-BLOCK-END
