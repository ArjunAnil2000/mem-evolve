#ifndef _EVO_DUMP_H
#define _EVO_DUMP_H 1

/*
 * Userspace-only helper for dumping policy state to $POLICY_METRICS_OUT.
 *
 * Zero per-access overhead — runs ONCE on policy exit. Each policy's loader
 * picks which BPF globals (or any other state) to surface.
 *
 * Pattern:
 *
 *     #include "evo_dump.h"
 *     ...
 *     while (!exiting) sleep(1);
 *
 *     FILE *m = evo_metrics_open();
 *     evo_dump_u64(m, "small_list_size", skel->bss->small_list_size);
 *     evo_dump_u64(m, "main_list_size", skel->bss->main_list_size);
 *     evo_dump_u64(m, "ghost_map_capacity", skel->rodata->cache_size);
 *     evo_metrics_close(m);
 *
 *     ret = 0;
 *
 * Names appear in next-round LLM feedback under `policy_counters:`. The
 * probe is direction="record" — these surface in feedback but DON'T move
 * the score (throughput owns the score).
 *
 * Why this design vs in-BPF counters
 * ----------------------------------
 * Atomic counters in BPF (__sync_fetch_and_add on a shared global) cost
 * ~50ns/op under multicore contention. Per-CPU maps avoid contention but
 * still pay ~5ns + a map_lookup per increment, on every cache access.
 *
 * On a 100k ops/s workload with 1-2 increments per access, even cheap
 * counters land in the same noise floor as the policy regression we're
 * trying to detect. So we don't add ANY per-access tracking by default.
 * Policies that want event counts add a plain `__u64 g_evictions;` BPF
 * global and bump it where they like — single-CPU contention is the only
 * cost, and the loader exposes it through the same evo_dump_u64() call.
 *
 * Safety: the helpers are no-ops if $POLICY_METRICS_OUT is unset or fopen
 * fails, so it's always safe to call them.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Module-local comma tracker — set in evo_metrics_open(), read by every
 * evo_dump_* helper. Single-process, single-loader, so a static is fine. */
static int _evo_dump_n;

static inline FILE *evo_metrics_open(void)
{
	const char *path = getenv("POLICY_METRICS_OUT");
	FILE *f;

	if (!path || !*path)
		return NULL;
	f = fopen(path, "w");
	if (!f)
		return NULL;
	_evo_dump_n = 0;
	fputc('{', f);
	return f;
}

static inline void _evo_dump_sep(FILE *f)
{
	if (_evo_dump_n++)
		fputc(',', f);
}

static inline void evo_dump_u64(FILE *f, const char *name, unsigned long long v)
{
	if (!f) return;
	_evo_dump_sep(f);
	fprintf(f, "\"%s\":%llu", name, v);
}

static inline void evo_dump_s64(FILE *f, const char *name, long long v)
{
	if (!f) return;
	_evo_dump_sep(f);
	fprintf(f, "\"%s\":%lld", name, v);
}

static inline void evo_dump_str(FILE *f, const char *name, const char *v)
{
	if (!f) return;
	_evo_dump_sep(f);
	/* Caller is responsible for ensuring v contains no JSON metacharacters
	 * (quotes, backslashes). The LLM-generated label space is small and
	 * curated — we don't carry a JSON escaper here. */
	fprintf(f, "\"%s\":\"%s\"", name, v ? v : "");
}

static inline void evo_metrics_close(FILE *f)
{
	if (!f) return;
	fputs("}\n", f);
	fclose(f);
}

#endif /* _EVO_DUMP_H */
