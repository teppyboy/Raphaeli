/*
 * Stub linux/cgroup_dmem.h: macOS has no memcg/cgroup infrastructure, so dmem
 * accounting is a no-op. dmem_cgroup_register_region() returns NULL, which
 * leaves ttm_resource_manager.cg NULL and disables the charging paths entirely.
 * shortcut: no real accounting, upgrade if per-process VRAM limits are ever needed.
 */
#ifndef LINUX_CGROUP_DMEM_H
#define LINUX_CGROUP_DMEM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct dmem_cgroup_region;
struct dmem_cgroup_pool_state;

static inline struct dmem_cgroup_region *
dmem_cgroup_register_region(uint64_t size, const char *name, ...)
{
	return NULL;
}

static inline void
dmem_cgroup_unregister_region(struct dmem_cgroup_region *region)
{
}

static inline void
dmem_cgroup_pool_state_put(struct dmem_cgroup_pool_state *pool)
{
}

static inline bool
dmem_cgroup_state_evict_valuable(struct dmem_cgroup_pool_state *limit_pool,
    void *css, bool try_low, bool *hit_low)
{
	*hit_low = false;
	return true;
}

static inline int
dmem_cgroup_try_charge(void *css, uint64_t size,
    struct dmem_cgroup_pool_state **ret_pool,
    struct dmem_cgroup_pool_state **ret_limit_pool)
{
	if (ret_pool)
		*ret_pool = NULL;
	if (ret_limit_pool)
		*ret_limit_pool = NULL;
	return 0;
}

static inline void
dmem_cgroup_uncharge(struct dmem_cgroup_pool_state *pool, uint64_t size)
{
}

#endif
