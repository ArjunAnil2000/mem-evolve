// ============================================================================
// SECTION: BPF KERNEL CODE
// ============================================================================
// EVOLVE-BLOCK-START
// vulcan_bpf-based SLRU (Segmented LRU): two real lists — probationary
// (new / single-touch folios) and protected (re-accessed folios) — with a
// capped protected-segment target size. Structurally distinct from
// vulcan_s3_fifo/vulcan_frequency's small/main/ghost admission: promotion
// here is EAGER, at access time (a single bpf_cache_ext_list_move call),
// not a lazy frequency-threshold scan done at eviction time, and there is
// no ghost map — a re-added folio always re-enters probationary fresh,
// there is no "was this recently evicted" memory. The protected segment's
// size cap is enforced lazily in evo_policy_evict_folios via the same
// iterate_extended "continue_list" relocation mechanism vulcan_s3_fifo
// uses for its small->main promotion, just applied in the opposite
// (demotion) direction. vulcan_bpf per-folio listeners (interval
// MinMax/EWMA) AND a class-level listener (access-interval EWMA, bucketed
// by PID) are layered on top, same as the other seeds.
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

#include "cache_ext_lib.bpf.h"
#include "dir_watcher.bpf.h"

#include "vulcan_bpf.h"

#define CF_ACCESS_INTERVAL 0
#define VULCAN_NUM_CLASS_FEATURES 1
// Generic hash-bucket classing (vulcan_class_from_pid below) — no semantic
// identity, just even spread across a small number of buckets.
#define VULCAN_MAX_CLASSES 8

#include "vulcan_class.h"

char _license[] SEC("license") = "GPL";

const volatile size_t cache_size = 0;

// Protected segment is capped at this percent of cache_size (pages); the
// rest is available to probationary. Demotion (protected->probationary)
// happens lazily in evo_policy_evict_folios when the cap is exceeded.
#define PROTECTED_TARGET_PCT 50

struct folio_metadata {
	struct vulcan_folio_metadata vulcan;
	u32 class_id;
	bool in_protected;
};

struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__type(key, u64);
	__type(value, struct folio_metadata);
	__uint(max_entries, 4000000);
} folio_metadata_map SEC(".maps");

static u64 probationary_list;
static u64 protected_list;
/* Non-static so the userspace loader can read these via skel->bss
 * for next-round LLM feedback (see evo_dump.h). */
__s64 probationary_list_size = 0;
__s64 protected_list_size = 0;

// How many protected-list head items demote_protected_cb is still allowed
// to demote in the CURRENT evo_policy_evict_folios call. Set once right
// before calling bpf_cache_ext_list_iterate_extended below; the kernel-side
// loop in that kfunc is already bounded (max_iter=4096), this variable just
// tells the callback when to stop early via CACHE_EXT_STOP_ITER once enough
// items have been moved.
static s64 demote_budget;

// Per-folio vulcan_bpf listener config: track recency via interval
// MinMax + EWMA, layered alongside the probationary/protected admission
// state.
static const struct vulcan_folio_config folio_cfg = {
	.listener_mask = VULCAN_LISTENER_MINMAX | VULCAN_LISTENER_EWMA,
	.ewma_alpha = 200,
};

// Class-level listener config: EWMA of inter-access interval within a
// class, bucketed by PID via vulcan_class_from_pid. Not consumed by
// evict_cb yet — a mutation can wire vulcan_get_class_ewma /
// vulcan_class_top_by_* into the eviction decision (Tier 2) without
// adding a new feature.
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

s32 BPF_STRUCT_OPS_SLEEPABLE(evo_policy_init, struct mem_cgroup *memcg)
{
	probationary_list = bpf_cache_ext_ds_registry_new_list(memcg);
	if (probationary_list == 0) {
		bpf_printk("evo_policy: init: Failed to create probationary_list\n");
		return -1;
	}

	protected_list = bpf_cache_ext_ds_registry_new_list(memcg);
	if (protected_list == 0) {
		bpf_printk("evo_policy: init: Failed to create protected_list\n");
		return -1;
	}

	return 0;
}

static int evict_probationary_cb(int idx, struct cache_ext_list_node *a)
{
	if (!folio_test_uptodate(a->folio) || !folio_test_lru(a->folio))
		return CACHE_EXT_CONTINUE_ITER;

	if (folio_test_dirty(a->folio) || folio_test_writeback(a->folio))
		return CACHE_EXT_CONTINUE_ITER;

	return CACHE_EXT_EVICT_NODE;
}

static int evict_protected_cb(int idx, struct cache_ext_list_node *a)
{
	if (!folio_test_uptodate(a->folio) || !folio_test_lru(a->folio))
		return CACHE_EXT_CONTINUE_ITER;

	if (folio_test_dirty(a->folio) || folio_test_writeback(a->folio))
		return CACHE_EXT_CONTINUE_ITER;

	return CACHE_EXT_EVICT_NODE;
}

// Demote protected-list head items back to probationary until either the
// list is exhausted or demote_budget items have been moved. No
// dirty/writeback/uptodate guard here on purpose: demotion only changes
// which of OUR OWN lists a folio is tracked under, it never touches kernel
// reclaim state directly, so it is always safe regardless of folio state.
static int demote_protected_cb(int idx, struct cache_ext_list_node *a)
{
	if (demote_budget <= 0)
		return CACHE_EXT_STOP_ITER;

	demote_budget--;
	return CACHE_EXT_CONTINUE_ITER;
}

static void evict_probationary(struct cache_ext_eviction_ctx *eviction_ctx, struct mem_cgroup *memcg)
{
	if (bpf_cache_ext_list_iterate(memcg, probationary_list, evict_probationary_cb, eviction_ctx) < 0)
		bpf_printk("evo_policy: evict: Failed to iterate probationary_list\n");
}

static void evict_protected(struct cache_ext_eviction_ctx *eviction_ctx, struct mem_cgroup *memcg)
{
	if (bpf_cache_ext_list_iterate(memcg, protected_list, evict_protected_cb, eviction_ctx) < 0)
		bpf_printk("evo_policy: evict: Failed to iterate protected_list\n");
}

static void demote_protected(struct cache_ext_eviction_ctx *eviction_ctx, struct mem_cgroup *memcg)
{
	struct cache_ext_iterate_opts opts = {
		.continue_list = probationary_list,
		.continue_mode = CACHE_EXT_ITERATE_HEAD,
		.evict_list = CACHE_EXT_ITERATE_SELF,
		.evict_mode = CACHE_EXT_ITERATE_TAIL,
	};

	if (bpf_cache_ext_list_iterate_extended(memcg, protected_list, demote_protected_cb, &opts,
						eviction_ctx) < 0) {
		bpf_printk("evo_policy: evict: Failed to iterate protected_list for demotion\n");
		return;
	}

	if (__sync_fetch_and_sub(&protected_list_size, opts.nr_folios_continue) < 0)
		protected_list_size = 0;
	__sync_fetch_and_add(&probationary_list_size, opts.nr_folios_continue);
}

void BPF_STRUCT_OPS(evo_policy_evict_folios, struct cache_ext_eviction_ctx *eviction_ctx,
		    struct mem_cgroup *memcg)
{
	/* Division stays on cache_size (unsigned size_t) — never cast to a
	 * signed type before dividing, see Fatal Pitfall J. */
	s64 target = (s64)(cache_size * PROTECTED_TARGET_PCT / 100);

	if (protected_list_size > target) {
		demote_budget = protected_list_size - target;
		demote_protected(eviction_ctx, memcg);
		return;
	}

	if (probationary_list_size > 0)
		evict_probationary(eviction_ctx, memcg);
	else
		evict_protected(eviction_ctx, memcg);
}

void BPF_STRUCT_OPS(evo_policy_folio_accessed, struct folio *folio) {
	if (!is_folio_relevant(folio))
		return;

	struct folio_metadata *data = get_folio_metadata(folio);
	if (!data)
		return;

	u64 now = bpf_ktime_get_ns();

	if (data->vulcan.access_count > 1) {
		s64 class_interval = (s64)(now - data->vulcan.last_access_ts);
		vulcan_update_class_feature(data->class_id, CF_ACCESS_INTERVAL,
					    class_interval, &class_cfg[CF_ACCESS_INTERVAL]);
		vulcan_class_touch(data->class_id, now);
	}

	vulcan_folio_on_access(&data->vulcan, now,
			       BPF_CORE_READ(folio, _refcount.counter),
			       BPF_CORE_READ(folio, _mapcount.counter),
			       &folio_cfg);

	if (!data->in_protected) {
		/* Promote eagerly, right at access time — no lazy
		 * frequency-threshold scan like S3-FIFO. */
		bpf_cache_ext_list_move(protected_list, folio, true);
		data->in_protected = true;
		__sync_fetch_and_sub(&probationary_list_size, 1);
		__sync_fetch_and_add(&protected_list_size, 1);
	} else {
		/* Already protected — just refresh recency. */
		bpf_cache_ext_list_move(protected_list, folio, true);
	}
}

void BPF_STRUCT_OPS(evo_policy_folio_evicted, struct folio *folio) {
	u64 key = (u64)folio;

	struct folio_metadata *data = get_folio_metadata(folio);
	if (data) {
		vulcan_class_member_removed(data->class_id);

		if (data->in_protected)
			__sync_fetch_and_sub(&protected_list_size, 1);
		else
			__sync_fetch_and_sub(&probationary_list_size, 1);
	}

	bpf_map_delete_elem(&folio_metadata_map, &key);
	bpf_cache_ext_list_del(folio);
}

void BPF_STRUCT_OPS(evo_policy_folio_added, struct folio *folio) {
	if (!is_folio_relevant(folio))
		return;

	u64 key = (u64)folio;
	u64 now = bpf_ktime_get_ns();
	u32 class_id = vulcan_class_from_pid(VULCAN_MAX_CLASSES);

	/* size_pages=1 (see cache_ext_lib.bpf.h folio_nr_pages); is_anonymous=0
	 * (watched folios are file-backed, Fatal Pitfall B); client_tag=0
	 * unused by this seed's logic. */
	struct folio_metadata new_meta = {
		.vulcan = vulcan_folio_init(now, /*size_pages=*/1,
					    /*is_anonymous=*/0, class_id,
					    /*client_tag=*/0),
		.class_id = class_id,
		.in_protected = false,
	};

	if (bpf_map_update_elem(&folio_metadata_map, &key, &new_meta, BPF_ANY)) {
		bpf_printk("evo_policy: added: Failed to create metadata\n");
		return;
	}

	vulcan_class_member_added(class_id);
	vulcan_class_touch(class_id, now);

	/* New pages always start probationary. If already in a list
	 * (readahead re-add), demote back to probationary tail. */
	if (bpf_cache_ext_list_add_tail(probationary_list, folio))
		bpf_cache_ext_list_move(probationary_list, folio, true);

	__sync_fetch_and_add(&probationary_list_size, 1);
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
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
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

static const uint64_t page_size = 4096;
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

	skel->rodata->cache_size = args.cgroup_size / page_size;
	fprintf(stderr, "Cgroup size: %lu bytes, Cache size: %lu pages\n",
		args.cgroup_size, skel->rodata->cache_size);

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

	if (evo_policy_bpf__attach(skel)) {
		perror("Failed to attach BPF skeleton");
		goto cleanup;
	}

	printf("evo_policy (Vulcan SLRU) running. Press Ctrl+C to exit...\n");
	while (!exiting)
		sleep(1);

	/* Dump per-policy state for next-round LLM feedback. Read via
	 * skel->bss because probationary_list_size / protected_list_size are
	 * declared at BPF file scope without static (see top of BPF section).
	 * cache_size is in rodata. Zero per-access overhead — runs once. */
	{
		FILE *m = evo_metrics_open();
		evo_dump_str(m, "policy_name", "vulcan_slru");
		evo_dump_u64(m, "cache_size_pages",          skel->rodata->cache_size);
		evo_dump_s64(m, "probationary_list_size_exit", skel->bss->probationary_list_size);
		evo_dump_s64(m, "protected_list_size_exit",     skel->bss->protected_list_size);
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
