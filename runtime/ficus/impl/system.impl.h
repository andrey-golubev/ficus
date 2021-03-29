/*
    This file is a part of ficus language project.
    See ficus/LICENSE for the licensing terms
*/

#ifndef __FICUS_SYSTEM_IMPL_H__
#define __FICUS_SYSTEM_IMPL_H__

#ifdef __cplusplus
extern "C" {
#endif

int64_t fx_tick_count(void)
{
#if defined _WIN32 || defined WINCE
    LARGE_INTEGER counter;
    QueryPerformanceCounter( &counter );
    return (int64_t)counter.QuadPart;
#elif defined __linux || defined __linux__
    struct timespec tp;
    clock_gettime(CLOCK_MONOTONIC, &tp);
    return (int64_t)tp.tv_sec*1000000000 + tp.tv_nsec;
#elif defined __MACH__ && defined __APPLE__
    return (int64_t)mach_absolute_time();
#else
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec*1000000 + tv.tv_usec;
#endif
}

double fx_tick_frequency(void)
{
#if defined _WIN32 || defined WINCE
    LARGE_INTEGER freq;
    QueryPerformanceFrequency(&freq);
    return (double)freq.QuadPart;
#elif defined __linux || defined __linux__
    return 1e9;
#elif defined __MACH__ && defined __APPLE__
    static double freq = 0;
    if( freq == 0 )
    {
        mach_timebase_info_data_t sTimebaseInfo;
        mach_timebase_info(&sTimebaseInfo);
        freq = sTimebaseInfo.denom*1e9/sTimebaseInfo.numer;
    }
    return freq;
#else
    return 1e6;
#endif
}

#ifdef __cplusplus
}
#endif

#endif
