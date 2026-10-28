// ============================================================================
// SECTION: BPF KERNEL CODE
// ============================================================================
// EVOLVE-BLOCK-START
// LHD (Least Hit Density): ranks folios by expected hits per unit of cache space-time,
// using per-age hit/eviction statistics, and evicts the lowest density first. Class
// statistics are recomputed periodically: a BPF event wakes the userspace loader through a
// ring buffer and it runs the BPF 'reconfigure' program.
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

#include "cache_ext_lib.bpf.h"
#include "dir_watcher.bpf.h"
#ifndef _CACHE_EXT_LHD_BPF_H
#define _CACHE_EXT_LHD_BPF_H

#define HIT_AGE_CLASSES 16
#define APP_CLASSES 16
#define NUM_CLASSES ((HIT_AGE_CLASSES) * (APP_CLASSES))  // Must be power of two for masking
#define NUM_CLASSES_MASK (NUM_CLASSES - 1)
#define INITIAL_AGE_COARSENING_SHIFT 10
#define REQS_PER_RECONFIG (1 << 20)
#define MAX_AGE (1 << 14)  // Must be power of two for masking
#define MAX_AGE_MASK (MAX_AGE - 1)
#define DEFAULT_APP_ID 1  // TODO: can prob delete app stuff
#define RECENTLY_ADMITTED_SIZE 8

#define HIT_SCALING_FACTOR (1 << 20)
#define HIT_DENSITY_SCALING_FACTOR (1 << 20)
#define NUM_OBJECTS_SCALING_FACTOR (1 << 20)

#define TOTAL_EVENTS_THRESH (HIT_SCALING_FACTOR / 100000)
#define AGE_COARSENING_ERROR_TOLERANCE 100 // Inverse of value in libcachesim

#endif /* _CACHE_EXT_LHD_BPF_H */

char _license[] SEC("license") = "GPL";

static u64 next_reconfiguration = REQS_PER_RECONFIG;
static u32 num_reconfigurations = 0;

static u64 age_coarsening_shift = INITIAL_AGE_COARSENING_SHIFT;
static u64 ewma_num_objects = 0;
static u64 ewma_num_objects_mass = 0;

static u64 ewma_victim_hit_density = 0;

/*
static u64 recently_admitted_head = 0;
static u64 recently_admitted[RECENTLY_ADMITTED_SIZE];
*/

// Current number of requests
static u64 timestamp = 0;

// For debugging purposes
static u64 overflows = 0;

static u64 lhd_list;

static u64 num_objects = 0;

#define INT64_MAX  (9223372036854775807LL)

// We omit size, assume all folios are same size for now
struct folio_metadata {
	u64 last_access_time;
	u64 last_hit_age;
	u64 last_last_hit_age;
	u32 app;
};

struct lhd_class {
	u64 total_hits;
	u64 total_evictions;

	u64 hits[MAX_AGE];
	u64 evictions[MAX_AGE];
	u64 hit_densities[MAX_AGE];
};

static struct lhd_class classes[NUM_CLASSES];

struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__type(key, u64);
	__type(value, struct folio_metadata);
	__uint(max_entries, 4000000);
} folio_metadata_map SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_RINGBUF);
	__uint(max_entries, 4096);
} events SEC(".maps");

static inline long ewma_decay(u64 val) {
	return (val * 9) / 10;
}

static inline long rem_ewma_decay(u64 val) {
	return val / 10;
}

static inline bool is_folio_relevant(struct folio *folio) {
	if (!folio || !folio->mapping || !folio->mapping->host)
		return false;

	return inode_in_watchlist(folio->mapping->host->i_ino);
}

static inline struct folio_metadata *get_folio_metadata(struct folio *folio) {
	u64 key = (u64)folio;
	return bpf_map_lookup_elem(&folio_metadata_map, &key);
}

static inline u32 hit_age_to_class(u64 hit_age) {
	u32 class = 0;

	if (hit_age == 0)
		return 0;

	// Approximates log(MAX_AGE - hit_age)
	while (hit_age < MAX_AGE && class < HIT_AGE_CLASSES - 1) {
		hit_age <<= 1;
		class++;
	}

	return class;
}

static inline u32 get_class_id(struct folio_metadata *data) {
	u32 hit_age_id = hit_age_to_class(data->last_hit_age + data->last_last_hit_age);
	return data->app * HIT_AGE_CLASSES + hit_age_id;
}

static inline struct lhd_class *get_class(struct folio_metadata *data) {
	u32 class_id = get_class_id(data);
	return &classes[class_id & NUM_CLASSES_MASK];
}

static inline u64 get_age(struct folio_metadata *data) {
	u64 age = (timestamp - data->last_access_time) >> age_coarsening_shift;

	if (age >= MAX_AGE) {
		overflows++;
		return MAX_AGE - 1;
	} 

	return age;
}

static inline u64 get_hit_density(struct folio_metadata *data) {
	u64 age = get_age(data);
	if (age == MAX_AGE - 1)
		return 0;

	struct lhd_class *cls = get_class(data);
	if (!cls)
		return -1;

	return cls->hit_densities[age & MAX_AGE_MASK];
}

static inline void update_class(struct lhd_class *class) {
	int i;

	class->total_hits = 0;
	class->total_evictions = 0;

	bpf_for(i, 0, MAX_AGE) {
		class->hits[i] = ewma_decay(class->hits[i]);
		class->evictions[i] = ewma_decay(class->evictions[i]);

		class->total_hits += class->hits[i];
		class->total_evictions += class->evictions[i];
	}
}

static inline void stretch_distribution(s32 delta) {
	int i;
	bpf_for(i, 0, NUM_CLASSES) {
		struct lhd_class *cls = &classes[i];
		int init_age = MAX_AGE >> (-delta);
		u32 j;

		bpf_for(j, init_age, MAX_AGE - 1) {
			cls->hits[MAX_AGE - 1] += cls->hits[j];
			cls->evictions[MAX_AGE - 1] = cls->evictions[j];
		}
		bpf_for(j, 2, MAX_AGE + 1) { // MAX_AGE -2 -> 0
			u32 index = MAX_AGE - j;
			cls->hits[index & MAX_AGE_MASK] =
				cls->hits[(j >> (-delta)) & MAX_AGE_MASK] /
				(1 << (-delta));
			cls->evictions[index & MAX_AGE_MASK] =
				cls->evictions[(j >> (-delta)) & MAX_AGE_MASK] /
				(1 << (-delta));
		}
	}
}

static inline void compress_distribution(s32 delta) {
	int i;
	bpf_for(i, 0, NUM_CLASSES) {
		struct lhd_class *cls = &classes[i];
		u32 j;

		bpf_for(j, 0, MAX_AGE >> delta) {
			cls->hits[j & MAX_AGE_MASK] =
				cls->hits[(j << delta) & MAX_AGE_MASK];
			cls->evictions[j & MAX_AGE_MASK] =
				cls->evictions[(j << delta) & MAX_AGE_MASK];
			int k;
			bpf_for(k, 1, (1 << delta)) {
				cls->hits[j & MAX_AGE_MASK] +=
					cls->hits[((j << delta) + k) &
						  MAX_AGE_MASK];
				cls->evictions[j & MAX_AGE_MASK] +=
					cls->evictions[((j << delta) + k) &
						       MAX_AGE_MASK];
			}
		}

		bpf_for(j, MAX_AGE >> delta, MAX_AGE - 1) {
			cls->hits[j & MAX_AGE_MASK] = 0;
			cls->evictions[j & MAX_AGE_MASK] = 0;
		}
	}
}

static inline void adapt_age_coarsening(void) {
	ewma_num_objects = ewma_decay(ewma_num_objects);
	ewma_num_objects_mass = ewma_decay(ewma_num_objects_mass);

	ewma_num_objects += num_objects * NUM_OBJECTS_SCALING_FACTOR;
	ewma_num_objects_mass += 1;

	u64 num_objects_coarsening = ewma_num_objects / ewma_num_objects_mass;

	u64 optimal_age_coarsening =
		1 * num_objects_coarsening * AGE_COARSENING_ERROR_TOLERANCE / MAX_AGE;

	if (num_reconfigurations == 5 || num_reconfigurations == 25) {
		u32 optimal_age_coarsening_log2 = 1;

		while ((1 << optimal_age_coarsening_log2) * NUM_OBJECTS_SCALING_FACTOR <
		       optimal_age_coarsening)
			optimal_age_coarsening_log2++;

		s32 delta = optimal_age_coarsening_log2 - age_coarsening_shift;
		age_coarsening_shift = optimal_age_coarsening_log2;

		ewma_num_objects *= 8;
		ewma_num_objects_mass *= 8;

		if (delta < 0)
			stretch_distribution(delta);
		else if (delta > 0)
			compress_distribution(delta);
	}
}

static inline void model_hit_density(void) {
	int i;

	bpf_for(i, 0, NUM_CLASSES) {
		struct lhd_class *cls = &classes[i];
		u64 total_hits = cls->hits[MAX_AGE - 1];
		u64 total_events = total_hits + cls->evictions[MAX_AGE - 1];
		u64 lifetime_unconditoned = total_events;

		int j;
		bpf_for(j, 2, MAX_AGE + 1) {
			u32 index = MAX_AGE - j;

			total_hits += cls->hits[index & MAX_AGE_MASK];
			total_events += cls->evictions[index & MAX_AGE_MASK];
			lifetime_unconditoned += total_events;

			if (total_events > TOTAL_EVENTS_THRESH)
				cls->hit_densities[index & MAX_AGE_MASK] =
					total_hits * HIT_DENSITY_SCALING_FACTOR /
					lifetime_unconditoned;
			else
				cls->hit_densities[index & MAX_AGE_MASK] = 0;
		}
	}
}

SEC("syscall")
int reconfigure(void) {
	int i;

	bpf_for(i, 0, NUM_CLASSES) {
		update_class(&classes[i]);
	}

	adapt_age_coarsening();

	model_hit_density();

	overflows = 0;

	return 0;
}

s32 BPF_STRUCT_OPS_SLEEPABLE(evo_policy_init, struct mem_cgroup *memcg) {
	uint32_t i;

	lhd_list = bpf_cache_ext_ds_registry_new_list(memcg);
	if (lhd_list == 0) {
		bpf_printk("cache_ext: init: Failed to create lhd_list\n");
		return -1;
	}
	bpf_printk("cache_ext: Created lhd_list: %llu\n", lhd_list);

	/*
	 * BPF global variables are zero-initialized, so we only need to
	 * initialize the hit densities.
	 */
	bpf_for(i, 0, NUM_CLASSES) {
		uint32_t j;

		// Initialize hit densities to GDSF
		struct lhd_class *cls = &classes[i];
		bpf_for(j, 0, MAX_AGE) {
			cls->hit_densities[j] = 1 * HIT_DENSITY_SCALING_FACTOR * (i + 1) / (j + 1);
		}
	}

	return 0;
}

static s64 bpf_lhd_score_fn(struct cache_ext_list_node *a) {
	if (!folio_test_uptodate(a->folio) || !folio_test_lru(a->folio))
		return INT64_MAX;

	if (folio_test_dirty(a->folio) || folio_test_writeback(a->folio))
		return INT64_MAX;

	struct folio_metadata *data = get_folio_metadata(a->folio);
	if (!data) {
		bpf_printk("cache_ext: score_fn: Failed to get metadata\n");
		return INT64_MAX;
	}

	return get_hit_density(data);
}

void BPF_STRUCT_OPS(evo_policy_evict_folios, struct cache_ext_eviction_ctx *eviction_ctx,
	       struct mem_cgroup *memcg)
{
	struct sampling_options opts = {
		.sample_size = 16,
	};

	if (bpf_cache_ext_list_sample(memcg, lhd_list, bpf_lhd_score_fn, &opts, eviction_ctx)) {
		bpf_printk("cache_ext: evict: Failed to sample\n");
		return;
	}

	/*
	 * Yields the following verifier error:
	 * 	R2 is ptr_cache_ext_eviction_ctx invalid variable offset: off=272, var_off=(0x0; 0xf8)
	 */
	// Deal with recently_admitted folios
	/*for (int i = 0; i < RECENTLY_ADMITTED_SIZE; i++) {
		size_t index = (recently_admitted_head + i) % RECENTLY_ADMITTED_SIZE;
		struct folio *folio = (struct folio *)recently_admitted[index];
		if (!folio)
			break;

		struct folio_metadata *data = get_folio_metadata(folio);
		if (!data) {
			bpf_printk("cache_ext: Failed to get metadata\n");
			continue;
		}

		u64 hit_density = get_hit_density(data);
		if (hit_density == -1) {
			bpf_printk("cache_ext: Failed to get hit density\n");
			continue;
		}

		// TODO: improve this?
		int j;
		bpf_for(j, 0, eviction_ctx->nr_folios_to_evict) {
			if (hit_density < eviction_ctx->scores[j & 31]) {
				eviction_ctx->folios_to_evict[j & 31] = folio;
				eviction_ctx->scores[j & 31] = hit_density;
				break;
			}
		}
	}*/
}

void BPF_STRUCT_OPS(evo_policy_folio_accessed, struct folio *folio) {
	if (!is_folio_relevant(folio))
		return;

	struct folio_metadata *data = get_folio_metadata(folio);
	if (!data) {
		bpf_printk("cache_ext: accessed: Failed to get metadata\n");
		return;
	}

	u64 age = get_age(data);
	struct lhd_class *cls = get_class(data);
	if (!cls) {
		bpf_printk("cache_ext: Failed to get class\n");
		return;
	}

	data->last_last_hit_age = data->last_hit_age;
	data->last_hit_age = age;
	data->last_access_time = timestamp;
	// data->app = DEFAULT_APP_ID % APP_CLASSES;

	u64 *hits = cls->hits + age;

	__sync_fetch_and_add(hits, 1 * HIT_SCALING_FACTOR);

	__sync_fetch_and_add(&timestamp, 1);

	if (__sync_sub_and_fetch(&next_reconfiguration, 1) == 0) {
		next_reconfiguration = REQS_PER_RECONFIG;
		num_reconfigurations++;

		// Submit reconfigure event to ring buffer
		if (bpf_ringbuf_output(&events, &num_reconfigurations, sizeof(num_reconfigurations), 0))
			bpf_printk("cache_ext: Failed to submit reconfigure event\n");
	}
}

void BPF_STRUCT_OPS(evo_policy_folio_evicted, struct folio *folio) {
	u64 key = (u64)folio;
	u64 age, hit_density, *evictions;
	struct lhd_class *cls;

	// if (bpf_cache_ext_list_del(folio)) {
	// 	bpf_printk("cache_ext: Failed to delete folio from sampling_list\n");
	// 	return;
	// }

	struct folio_metadata *data = bpf_map_lookup_elem(&folio_metadata_map, &key);
	if (!data) {
		//bpf_printk("cache_ext: evicted: Failed to get metadata\n");
		return;
	}

	age = get_age(data);
	cls = get_class(data);
	if (!cls) {
		bpf_printk("cache_ext: evicted: Failed to get class\n");
		return;
	}

	evictions = cls->evictions + age;

	__sync_fetch_and_add(evictions, 1 * HIT_SCALING_FACTOR);

	__sync_fetch_and_sub(&num_objects, 1);

	// Open-coded get_hit_density()
	hit_density = cls->hit_densities[age];
	ewma_victim_hit_density = ewma_decay(ewma_victim_hit_density) + rem_ewma_decay(hit_density);

	// Remove folio metadata
	if (bpf_map_delete_elem(&folio_metadata_map, &key))
		bpf_printk("cache_ext: evicted: Failed to delete metadata\n");
}

void BPF_STRUCT_OPS(evo_policy_folio_added, struct folio *folio) {
	if (!is_folio_relevant(folio))
		return;

	if (bpf_cache_ext_list_add_tail(lhd_list, folio)) {
		bpf_printk("cache_ext: added: Failed to add folio to lhd_list\n");
		return;
	}

	u64 key = (u64)folio;
	struct folio_metadata new_meta = {
		.last_access_time = timestamp,
		.last_hit_age = 0,
		.last_last_hit_age = MAX_AGE,
		.app = DEFAULT_APP_ID % APP_CLASSES,
	};

	if (bpf_map_update_elem(&folio_metadata_map, &key, &new_meta, BPF_ANY)) {
		bpf_cache_ext_list_del(folio);
		bpf_printk("cache_ext: added: Failed to create folio metadata\n");
		return;
	}

	// Track likely eviction candidates
	// u64 hit_density = get_hit_density(&new_meta);
	// if (hit_density == -1) {
	// 	bpf_printk("cache_ext: added: Failed to get hit density\n");
	// 	return;
	// }

	/*
	if (hit_density < ewma_victim_hit_density)
		recently_admitted[recently_admitted_head++ % RECENTLY_ADMITTED_SIZE] = (u64)folio;
	*/

	__sync_fetch_and_add(&timestamp, 1);

	__sync_fetch_and_add(&num_objects, 1);

	if (__sync_sub_and_fetch(&next_reconfiguration, 1) == 0) {
		next_reconfiguration = REQS_PER_RECONFIG;
		num_reconfigurations++;

		// Submit reconfigure event to ring buffer
		if (bpf_ringbuf_output(&events, &num_reconfigurations, sizeof(num_reconfigurations), 0))
			bpf_printk("cache_ext: added: Failed to submit reconfigure event\n");
	}
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
// Loader for the LHD policy: parses -w/-s/-c like every policy in this repo,
// attaches the struct_ops to the cgroup and waits for SIGINT/SIGTERM.
// EVOLVE-BLOCK-START
#include <argp.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <bpf/bpf.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "dir_watcher.h"
#ifndef _CACHE_EXT_LHD_BPF_H
#define _CACHE_EXT_LHD_BPF_H

#define HIT_AGE_CLASSES 16
#define APP_CLASSES 16
#define NUM_CLASSES ((HIT_AGE_CLASSES) * (APP_CLASSES))  // Must be power of two for masking
#define NUM_CLASSES_MASK (NUM_CLASSES - 1)
#define INITIAL_AGE_COARSENING_SHIFT 10
#define REQS_PER_RECONFIG (1 << 20)
#define MAX_AGE (1 << 14)  // Must be power of two for masking
#define MAX_AGE_MASK (MAX_AGE - 1)
#define DEFAULT_APP_ID 1  // TODO: can prob delete app stuff
#define RECENTLY_ADMITTED_SIZE 8

#define HIT_SCALING_FACTOR (1 << 20)
#define HIT_DENSITY_SCALING_FACTOR (1 << 20)
#define NUM_OBJECTS_SCALING_FACTOR (1 << 20)

#define TOTAL_EVENTS_THRESH (HIT_SCALING_FACTOR / 100000)
#define AGE_COARSENING_ERROR_TOLERANCE 100 // Inverse of value in libcachesim

#endif /* _CACHE_EXT_LHD_BPF_H */
#include "evo_policy.skel.h"

char *USAGE = "Usage: ./evo_policy --watch_dir <dir> --cgroup_path <path>\n";
struct cmdline_args {
	char *watch_dir;
	char *cgroup_path;
	uint64_t cgroup_size;	/* accepted for harness compatibility */
};

static struct argp_option options[] = {
	{ "watch_dir", 'w', "DIR", 0, "Directory to watch" },
	{ "cgroup_path", 'c', "PATH", 0, "Path to cgroup (e.g., /sys/fs/cgroup/cache_ext_test)" },
	{ "cgroup_size", 's', "SIZE", 0,
	  "Size of the cgroup in bytes (accepted for harness compatibility)" },
					{ 0 },
};

static long num_reconfigurations;

static volatile sig_atomic_t exiting;

static void sig_handler(int signo) {
	exiting = 1;
}

static error_t parse_opt(int key, char *arg, struct argp_state *state)
{
	struct cmdline_args *args = state->input;
	switch (key) {
	case 'w':
		args->watch_dir = arg;
		break;
	case 'c':
		args->cgroup_path = arg;
		break;
	case 's':
		errno = 0;
		args->cgroup_size = strtoull(arg, NULL, 10);
		if (errno)
			args->cgroup_size = 0;
		break;
	default:
		return ARGP_ERR_UNKNOWN;
	}
	return 0;
}

static int parse_args(int argc, char **argv, struct cmdline_args *args) {
	struct argp argp = { options, parse_opt, 0, 0 };
	argp_parse(&argp, argc, argv, 0, 0, args);

	if (args->watch_dir == NULL) {
		fprintf(stderr, "Missing required argument: watch_dir\n");
		return 1;
	}

	if (args->cgroup_path == NULL) {
		fprintf(stderr, "Missing required argument: cgroup_path\n");
		return 1;
	}

	return 0;
}

/*
 * Validate watch_dir
 *
 * watch_dir_full_path must be able to hold PATH_MAX bytes.
 */
static int validate_watch_dir(const char *watch_dir, char *watch_dir_full_path) {
	// Does watch_dir exist?
	if (access(watch_dir, F_OK) == -1) {
		fprintf(stderr, "Directory does not exist: %s\n", watch_dir);
		return 1;
	}

	// Get full path of watch_dir
	if (realpath(watch_dir, watch_dir_full_path) == NULL) {
		perror("realpath");
		return 1;
	}

	// BPF policy restriction
	if (strlen(watch_dir_full_path) > 128) {
		fprintf(stderr, "watch_dir path too long\n");
		return 1;
	}

	return 0;
}

static int handle_event(void *ctx, void *data, size_t data_sz) {
	// Run BPF reconfigure program using BPF_PROG_RUN
	int ret = 0;
	int reconfigure_prog_fd = *(int *)ctx;

	struct bpf_test_run_opts opts = {
		.sz = sizeof(opts),
	};
	
	++num_reconfigurations;

	ret = bpf_prog_test_run_opts(reconfigure_prog_fd, &opts);
	if (ret)
		perror("Failed to run reconfigure program");

	return ret;
}

int main(int argc, char **argv) {
	struct cmdline_args args = { 0 };
	struct evo_policy_bpf *skel = NULL;
	struct bpf_link *link = NULL;
	struct ring_buffer *events = NULL;
	struct sigaction sa;
	char watch_dir_path[PATH_MAX];
	int reconfigure_prog_fd;
	int cgroup_fd = -1;
	int ret = 1;

	libbpf_set_strict_mode(LIBBPF_STRICT_ALL);

	if (parse_args(argc, argv, &args))
		return 1;

	memset(&sa, 0, sizeof(sa));
	sigemptyset(&sa.sa_mask);
	sa.sa_handler = sig_handler;

	// Install signal handler
	if (sigaction(SIGINT, &sa, NULL) || sigaction(SIGTERM, &sa, NULL)) {
		perror("Failed to set up signal handling");
		return 1;
	}

	if (validate_watch_dir(args.watch_dir, watch_dir_path))
		return 1;

	cgroup_fd = open(args.cgroup_path, O_RDONLY);
	if (cgroup_fd < 0) {
		fprintf(stderr, "Failed to open cgroup path %s: %s\n",
			args.cgroup_path, strerror(errno));
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

	if (initialize_watch_dir_map(watch_dir_path, bpf_map__fd(inode_watchlist_map(skel)), false)) {
		perror("Failed to initialize watch_dir map");
		goto cleanup;
	}

	// Get fd of reconfigure program
	reconfigure_prog_fd = bpf_program__fd(skel->progs.reconfigure);

	events = ring_buffer__new(bpf_map__fd(skel->maps.events), handle_event, &reconfigure_prog_fd, NULL);
	if (!events) {
		perror("Failed to create ring buffer");
		goto cleanup;
	}

	link = bpf_map__attach_cache_ext_ops(skel->maps.evo_policy_ops, cgroup_fd);
	if (link == NULL) {
		perror("Failed to attach cache_ext_ops to cgroup");
		goto cleanup;
	}

	// This is necessary for the dir_watcher functionality
	if (evo_policy_bpf__attach(skel)) {
		perror("Failed to attach BPF skeleton");
		goto cleanup;
	}

	while (!exiting) {
		ret = ring_buffer__poll(events, -1); // infinite timeout
		
		if (ret == -EINTR) {
			ret = 0;
			break;
		} else if (ret < 0) {
			fprintf(stderr, "error polling ring buffer: %d\n", ret);
			ret = 1;
			goto cleanup;
		} else {
			ret = 0;
		}
	}

	printf("Number of reconfigurations: %ld\n", num_reconfigurations);

cleanup:
	close(cgroup_fd);
	ring_buffer__free(events);
	bpf_link__destroy(link);
	evo_policy_bpf__destroy(skel);
	return ret;
}
// EVOLVE-BLOCK-END
