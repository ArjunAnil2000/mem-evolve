// ============================================================================
// SECTION: BPF KERNEL CODE
// ============================================================================
// EVOLVE-BLOCK-START
// No-op: registers struct_ops but makes no eviction decisions; vanilla
// kernel reclaim baseline, used for calibration.
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

#include "cache_ext_lib.bpf.h"
#include "dir_watcher.bpf.h"

char _license[] SEC("license") = "GPL";

s32 BPF_STRUCT_OPS_SLEEPABLE(evo_policy_init, struct mem_cgroup *memcg)
{
	return 0;
}

void BPF_STRUCT_OPS(evo_policy_evict_folios, struct cache_ext_eviction_ctx *eviction_ctx,
		    struct mem_cgroup *memcg)
{
}

void BPF_STRUCT_OPS(evo_policy_folio_evicted, struct folio *folio) {
}

void BPF_STRUCT_OPS(evo_policy_folio_added, struct folio *folio) {
}

SEC(".struct_ops.link")
struct cache_ext_ops evo_policy_ops = {
	.init = (void *)evo_policy_init,
	.evict_folios = (void *)evo_policy_evict_folios,
	.folio_evicted = (void *)evo_policy_folio_evicted,
	.folio_added = (void *)evo_policy_folio_added,
};
// EVOLVE-BLOCK-END

// ============================================================================
// SECTION: USERSPACE LOADER
// ============================================================================
// Baseline loader: parses the same args as a real policy and holds the cgroup
// open until SIGINT, but never attaches struct_ops. The kernel runs its
// default page-cache eviction policy on the cgroup, giving a clean "vanilla
// Linux" reference point for normalization.
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

struct cmdline_args {
	char *watch_dir;
	uint64_t cgroup_size;
	char *cgroup_path;
};

static struct argp_option options[] = {
	{ "watch_dir", 'w', "DIR", 0, "Directory to watch (ignored by noop)" },
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
	if (!args->cgroup_path) {
		fprintf(stderr, "Missing required argument: cgroup_path\n");
		return 1;
	}
	return 0;
}

int main(int argc, char **argv) {
	struct cmdline_args args = { 0 };
	struct sigaction sa;
	int cgroup_fd = -1;
	int ret = 1;

	if (parse_args(argc, argv, &args))
		return 1;

	memset(&sa, 0, sizeof(sa));
	sigemptyset(&sa.sa_mask);
	sa.sa_handler = sig_handler;
	if (sigaction(SIGINT, &sa, NULL) || sigaction(SIGTERM, &sa, NULL)) {
		perror("Failed to set up signal handling");
		return 1;
	}

	cgroup_fd = open(args.cgroup_path, O_RDONLY);
	if (cgroup_fd < 0) {
		perror("Failed to open cgroup path");
		return 1;
	}

	printf("evo_policy (NOOP baseline) running — kernel default policy. "
	       "Press Ctrl+C to exit...\n");
	fflush(stdout);

	while (!exiting)
		sleep(1);
	ret = 0;

	close(cgroup_fd);
	return ret;
}
// EVOLVE-BLOCK-END
