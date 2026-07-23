// ============================================================================
// SECTION: BPF KERNEL CODE
// ============================================================================
// EVOLVE-BLOCK-START
// vulcan_scan_class: single-list scan-resistant LRU (promote to tail only
// on re-access, mirroring vulcan_scan_resist / cache_ext_get_scan), plus a
// vulcan_bpf class-level layer with TWO NAMED classes — CLASS_GENERAL and
// CLASS_SCAN — derived from ground-truth scan-thread identity, not a hash.
//
// scan_pids is a BPF map REUSED from the benchmark harness (see
// eval/get_scan/run_with_policy.sh): the harness creates+pins an empty
// map at /sys/fs/bpf/cache_ext/scan_pids before this policy's loader even
// starts, independent of which policy is attached (every seed in this
// run sees the identical environment). My-YCSB's leveldb-scan benchmark
// writes its single dedicated scan thread's TID into that map on its
// first scan op. This seed's loader attaches to that SAME map via
// bpf_obj_get()+bpf_map__reuse_fd() (see USERSPACE LOADER section) rather
// than creating its own — is_scanning_tid() below is a live read of it,
// exactly mirroring cache_ext/policies/cache_ext_get_scan.bpf.c's
// is_scanning_pid(). class_id is a snapshot of that check taken at
// folio_added (insertion-time attribution, not lifetime attribution).
//
// A class whose population grows large is genuinely the scan thread's
// traffic (ground truth, not a guess) — evicting it aggressively once
// large enough is the whole point of tracking at the class tier instead
// of only per-folio.
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

#include "cache_ext_lib.bpf.h"
#include "dir_watcher.bpf.h"

// vulcan_bpf: BPF-compatible feature-store/listener primitives, including
// the class-level store this seed is built around. See
// cache_ext/vulcan_bpf/README.md.
#include "vulcan_bpf.h"

#define CF_ACCESS_INTERVAL 0

#define VULCAN_NUM_CLASS_FEATURES 1
// Two NAMED, ground-truth classes — ordinary traffic vs. the one
// dedicated scan thread's traffic. Not a hash bucket count.
#define VULCAN_MAX_CLASSES 2
#define CLASS_GENERAL 0
#define CLASS_SCAN    1

#include "vulcan_class.h"

char _license[] SEC("license") = "GPL";

// scan_pids: key=TID (int), value=bool. Declared here so the BPF object
// has a matching map slot for the loader to reuse-fd onto; NOT created
// fresh at load time when reuse succeeds (see USERSPACE LOADER section).
struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__type(key, int);
	__type(value, bool);
	__uint(max_entries, 1024);
} scan_pids SEC(".maps");

// Once CLASS_SCAN's population reaches this, evict its folios
// aggressively even if re-touched — ground truth, so no ranking/guessing
// needed to decide which class is "the scan class."
#define SCAN_CLASS_MIN_POPULATION 64
// If CLASS_SCAN hasn't been fed in this long, don't trust its stats yet
// (e.g. harness restarted the map, or the scan thread hasn't run yet).
#define CLASS_STALE_TTL_NS (30ULL * 1000 * 1000 * 1000)

static u64 main_list;

struct folio_metadata {
	struct vulcan_folio_metadata vulcan;
	u32 class_id;
};

struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__type(key, u64);
	__type(value, struct folio_metadata);
	__uint(max_entries, 4000000);
} folio_metadata_map SEC(".maps");

// Per-folio listener config: recency via interval MinMax + EWMA, same as
// the other vulcan_* seeds.
static const struct vulcan_folio_config folio_cfg = {
	.listener_mask = VULCAN_LISTENER_MINMAX | VULCAN_LISTENER_EWMA,
	.ewma_alpha = 200,
};

// Class-level listener config: EWMA of inter-access interval within a
// class, used to tell "actively reused" apart from "one-shot scan" beyond
// the per-folio signal alone.
static const struct vulcan_feature_config class_cfg[VULCAN_NUM_CLASS_FEATURES] = {
	[CF_ACCESS_INTERVAL] = {
		.listener_mask = VULCAN_LISTENER_EWMA,
		.ewma_alpha = 150,
	},
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

// Ground-truth check: is the CURRENT thread the benchmark's dedicated
// scan thread? Mirrors cache_ext_get_scan.bpf.c's is_scanning_pid()
// exactly (same map shape, same TID-not-PID lookup — the lower 32 bits
// of bpf_get_current_pid_tgid() are the thread id in kernel terminology).
static inline bool is_scanning_tid(void) {
	__u64 pid_tgid = bpf_get_current_pid_tgid();
	int tid = (int)(pid_tgid & 0xFFFFFFFF);
	bool *ret = bpf_map_lookup_elem(&scan_pids, &tid);
	return ret != NULL;
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
	if (!folio_test_uptodate(a->folio) || !folio_test_lru(a->folio))
		return CACHE_EXT_CONTINUE_ITER;

	if (folio_test_dirty(a->folio) || folio_test_writeback(a->folio))
		return CACHE_EXT_CONTINUE_ITER;

	struct folio_metadata *data = get_folio_metadata(a->folio);
	if (!data)
		return CACHE_EXT_EVICT_NODE; // no metadata -> safe to evict

	// Single-touch folios are always eviction candidates regardless of
	// class (mirrors the scan-resistance seeds' base rule).
	if (data->vulcan.access_count <= 1)
		return CACHE_EXT_EVICT_NODE;

	// Class-level check: this folio was inserted by the ground-truth scan
	// thread AND that class has grown large enough to be confidently
	// "the scan" (not just a couple of incidental re-touches) — evict it
	// even though it was re-touched. No ranking/guessing needed: we KNOW
	// which class is the scan thread's traffic, ground truth via
	// scan_pids, not inferred from which class happens to be biggest.
	u64 now = bpf_ktime_get_ns();
	if (data->class_id == CLASS_SCAN &&
	    !vulcan_class_is_stale(CLASS_SCAN, now, CLASS_STALE_TTL_NS) &&
	    vulcan_get_class_count(CLASS_SCAN) >= SCAN_CLASS_MIN_POPULATION)
		return CACHE_EXT_EVICT_NODE;

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
	if (data) {
		u64 now = bpf_ktime_get_ns();

		if (data->vulcan.access_count > 1) {
			s64 interval = (s64)(now - data->vulcan.last_access_ts);
			vulcan_update_class_feature(data->class_id, CF_ACCESS_INTERVAL,
						    interval, &class_cfg[CF_ACCESS_INTERVAL]);
			vulcan_class_touch(data->class_id, now);
		}

		vulcan_folio_on_access(&data->vulcan, now,
				       BPF_CORE_READ(folio, _refcount.counter),
				       BPF_CORE_READ(folio, _mapcount.counter),
				       &folio_cfg);
	}

	/* Promote to tail (protected end) on re-access — same
	 * scan-resistance mechanism as vulcan_scan_resist: one-shot pages
	 * stay near the head, re-accessed pages move to the safe tail. */
	bpf_cache_ext_list_move(main_list, folio, true);
}

void BPF_STRUCT_OPS(evo_policy_folio_evicted, struct folio *folio) {
	u64 key = (u64)folio;

	struct folio_metadata *data = get_folio_metadata(folio);
	if (data)
		vulcan_class_member_removed(data->class_id);

	bpf_map_delete_elem(&folio_metadata_map, &key);
	bpf_cache_ext_list_del(folio);
}

void BPF_STRUCT_OPS(evo_policy_folio_added, struct folio *folio) {
	if (!is_folio_relevant(folio))
		return;

	u64 key = (u64)folio;
	u64 now = bpf_ktime_get_ns();
	u32 class_id = is_scanning_tid() ? CLASS_SCAN : CLASS_GENERAL;

	/* size_pages=1 (see cache_ext_lib.bpf.h folio_nr_pages); is_anonymous=0
	 * (watched folios are file-backed, Fatal Pitfall B); client_tag=0
	 * unused by this seed's logic. */
	struct folio_metadata new_meta = {
		.vulcan = vulcan_folio_init(now, /*size_pages=*/1,
					    /*is_anonymous=*/0, class_id,
					    /*client_tag=*/0),
		.class_id = class_id,
	};
	if (bpf_map_update_elem(&folio_metadata_map, &key, &new_meta, BPF_ANY)) {
		bpf_printk("evo_policy: added: Failed to create metadata\n");
		return;
	}

	vulcan_class_member_added(class_id);
	vulcan_class_touch(class_id, now);

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
	int scan_pids_attached = 0;

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

	/* Attach our scan_pids map slot to the harness-owned pinned map
	 * (see eval/get_scan/run_with_policy.sh) instead of letting load()
	 * create a fresh one. Must happen after open(), before load() —
	 * reuse_fd tells the skeleton "don't create this map, use the
	 * existing kernel object at this fd." Non-fatal if the pin doesn't
	 * exist (e.g. running under a different benchmark, or
	 * ENABLE_BPF_SCAN_MAP disabled): the skeleton falls back to
	 * creating its own empty scan_pids, is_scanning_tid() always
	 * returns false, every folio is CLASS_GENERAL — degrades cleanly
	 * rather than failing to load. */
	{
		int scan_pids_fd = bpf_obj_get("/sys/fs/bpf/cache_ext/scan_pids");
		if (scan_pids_fd >= 0) {
			if (bpf_map__reuse_fd(skel->maps.scan_pids, scan_pids_fd)) {
				perror("Failed to reuse scan_pids map fd");
				close(scan_pids_fd);
				goto cleanup;
			}
			close(scan_pids_fd);
			scan_pids_attached = 1;
			fprintf(stderr, "vulcan_scan_class: attached to harness scan_pids map\n");
		} else {
			fprintf(stderr, "vulcan_scan_class: no scan_pids pin found — "
					"running with every folio as CLASS_GENERAL\n");
		}
	}

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

	if (evo_policy_bpf__attach(skel)) {
		perror("Failed to attach BPF skeleton");
		goto cleanup;
	}

	printf("evo_policy (Vulcan Scan-Class) running. Press Ctrl+C to exit...\n");
	while (!exiting)
		sleep(1);

	{
		FILE *m = evo_metrics_open();
		evo_dump_str(m, "policy_name", "vulcan_scan_class");
		evo_dump_u64(m, "scan_pids_attached", scan_pids_attached);
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
