/*
 * Stand-in for the x86 <emmintrin.h> on arm64, put ahead of the compiler's own include directory
 * by the Dockerfile when the source needs it.
 *
 * The 4.3.4 fork's PCGRand.cpp includes that header for _mm_malloc and _mm_free only, to allocate
 * its generator state 16-byte aligned. The real header refuses to compile off x86.
 */
#pragma once

#include <stdlib.h>

static inline void* _mm_malloc(size_t size, size_t align)
{
    void* p = 0;
    return posix_memalign(&p, align, size) == 0 ? p : 0;
}

static inline void _mm_free(void* p)
{
    free(p);
}
