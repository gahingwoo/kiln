// SPDX-License-Identifier: MIT
/*
 * LD_PRELOAD capture of librknnrt's FULL submission for the simplest conv, so it
 * can be replayed faithfully through either UABI (Tomeu #55). The ioctl trace
 * showed the conv is 3 tiled tasks over 5 BOs (regcmd/task, weights+bias, a
 * 300KB scratch, input, output). This shim records every BO librknnrt creates
 * and, on the first SUBMIT, maps each itself (MEM_MAP+mmap -- robust vs tracking
 * librknnrt's own mmap/mmap64) and dumps the content + submit + task array to
 * /rknpu_replay/.
 *
 * Build: aarch64-linux-gnu-gcc -shared -fPIC -o capture.so capture.c -ldl
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <stdarg.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>

#define DRM_BASE 0x40
#define NR_SUBMIT 1
#define NR_MEM_CREATE 2

struct mem_create { uint32_t handle, flags; uint64_t size, obj_addr, dma_addr,
	sram_size; int32_t iommu_domain_id; uint32_t core_mask; };
struct mem_map { uint32_t handle, reserved; uint64_t offset; };
struct subcore_task { uint32_t task_start, task_number; };
struct submit { uint32_t flags, timeout, task_start, task_number, task_counter;
	int32_t priority; uint64_t task_obj_addr; uint32_t iommu_domain_id, rsvd;
	uint64_t task_base_addr; int64_t hw_elapse; uint32_t core_mask; int32_t fence_fd;
	struct subcore_task subcore[5]; };
#define IOCTL_MEM_MAP _IOWR('d', DRM_BASE + 3, struct mem_map)

struct bo { uint32_t handle; uint64_t dma, obj, size; };
static struct bo bos[32];
static int nbo, done;
static int (*real_ioctl)(int, unsigned long, void *);

static void dump(int fd, struct submit *s)
{
	char p[128];

	mkdir("/rknpu_replay", 0755);
	FILE *m = fopen("/rknpu_replay/meta.txt", "w");
	if (m) {
		fprintf(m, "flags=0x%x timeout=%u task_start=%u task_number=%u core_mask=%u iommu_domain_id=%u task_obj_addr=0x%llx task_base_addr=0x%llx\n",
			s->flags, s->timeout, s->task_start, s->task_number,
			s->core_mask, s->iommu_domain_id,
			(unsigned long long)s->task_obj_addr,
			(unsigned long long)s->task_base_addr);
		for (int i = 0; i < nbo; i++)
			fprintf(m, "bo idx=%d handle=%u dma=0x%llx obj=0x%llx size=%llu\n",
				i, bos[i].handle, (unsigned long long)bos[i].dma,
				(unsigned long long)bos[i].obj,
				(unsigned long long)bos[i].size);
		for (int i = 0; i < nbo; i++)
			if (bos[i].obj == s->task_obj_addr)
				fprintf(m, "task_array_bo=%d\n", i);
		/* the fields trace.so can't see -- these are what the replay
		 * was guessing (subcore array, task_counter, priority). */
		fprintf(m, "priority=%d task_counter=%u\n", s->priority, s->task_counter);
		for (int i = 0; i < 5; i++)
			fprintf(m, "subcore%d start=%u number=%u\n", i,
				s->subcore[i].task_start, s->subcore[i].task_number);
		fclose(m);
	}
	/* the raw submit struct, so the replay can use it verbatim (only the
	 * task_obj_addr kernel pointer is re-pointed at the replay's task BO). */
	FILE *sf = fopen("/rknpu_replay/submit.bin", "wb");
	if (sf) { fwrite(s, 1, sizeof(*s), sf); fclose(sf); }

	for (int i = 0; i < nbo; i++) {
		struct mem_map mm = { .handle = bos[i].handle };
		if (real_ioctl(fd, IOCTL_MEM_MAP, &mm))
			continue;
		void *v = mmap(NULL, bos[i].size, PROT_READ, MAP_SHARED, fd,
			       mm.offset);
		if (v == MAP_FAILED) {
			fprintf(stderr, "CAPTURE: mmap bo%d failed\n", i);
			continue;
		}
		snprintf(p, sizeof(p), "/rknpu_replay/bo%02d.bin", i);
		FILE *f = fopen(p, "wb");
		if (f) { fwrite(v, 1, bos[i].size, f); fclose(f); }
		munmap(v, bos[i].size);
	}
	sync();
	fprintf(stderr, "CAPTURE: dumped %d BOs + submit to /rknpu_replay/ (task_number=%u)\n",
		nbo, s->task_number);
}

int ioctl(int fd, unsigned long req, ...)
{
	va_list ap; va_start(ap, req);
	void *arg = va_arg(ap, void *); va_end(ap);
	if (!real_ioctl)
		real_ioctl = dlsym(RTLD_NEXT, "ioctl");

	unsigned nr = _IOC_NR(req), type = _IOC_TYPE(req);
	if (type == 'd' && nr >= DRM_BASE && nr <= DRM_BASE + 0xf) {
		int op = nr - DRM_BASE;
		if (op == NR_MEM_CREATE && arg) {
			int r = real_ioctl(fd, req, arg);
			struct mem_create *c = arg;
			if (!r && nbo < 32) {
				bos[nbo].handle = c->handle; bos[nbo].dma = c->dma_addr;
				bos[nbo].obj = c->obj_addr; bos[nbo].size = c->size;
				nbo++;
			}
			return r;
		}
		if (op == NR_SUBMIT && arg && !done) {
			done = 1;
			dump(fd, (struct submit *)arg);
		}
	}
	return real_ioctl(fd, req, arg);
}
