// sfcommon.c — time helpers, CSPRNG seam, constant-time compare.
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE 1

#include "sfcommon.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef __APPLE__
#include <stdlib.h> /* arc4random_buf */
#else
#if defined(__linux__)
#include <errno.h>
#include <sys/syscall.h>
#include <unistd.h>
#endif
#include <stdio.h>
#endif

// ---------------------------------------------------------------- time

int64_t sf_now_unix(void) {
    return (int64_t)time(NULL);
}

void sf_iso_from_unix(int64_t t, char out[32]) {
    time_t tt = (time_t)t;
    struct tm tmv;
    struct tm *r;
#if defined(_WIN32)
    r = gmtime(&tt);
    if (r) tmv = *r;
#else
    r = gmtime_r(&tt, &tmv);
#endif
    if (!r) {
        out[0] = '\0';
        return;
    }
    {
        char tmp[128];
        size_t n;
        snprintf(tmp, sizeof tmp, "%04d-%02d-%02dT%02d:%02d:%02dZ",
                 tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
                 tmv.tm_hour, tmv.tm_min, tmv.tm_sec);
        n = strlen(tmp);
        if (n > 31) n = 31;
        memcpy(out, tmp, n);
        out[n] = '\0';
    }
}

void sf_now_iso(char out[32]) {
    sf_iso_from_unix(sf_now_unix(), out);
}

// Days from civil date (Howard Hinnant's algorithm), proleptic Gregorian.
static int64_t days_from_civil(int64_t y, unsigned m, unsigned d) {
    int64_t era;
    unsigned yoe, doy, doe;
    y -= (m <= 2);
    era = (y >= 0 ? y : y - 399) / 400;
    yoe = (unsigned)(y - era * 400);                       // [0, 399]
    {
        int adj = (m > 2) ? (int)m - 3 : (int)m + 9;
        doy = (unsigned)((153 * adj + 2) / 5) + d - 1;
    }
    doe = yoe * 365u + yoe / 4u - yoe / 100u + doy;
    return era * 146097 + (int64_t)doe - 719468;
}

static int is_leap(int64_t y) {
    return (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0);
}

static int digit_at(const char *s, int i) {
    if (s[i] < '0' || s[i] > '9') return -1;
    return s[i] - '0';
}

int64_t sf_unix_from_iso(const char *iso) {
    static const int mdays[12] = {
        31,28,31,30,31,30,31,31,30,31,30,31
    };
    int64_t year;
    int mon, day, hour, min, sec, dim, i;
    int d[14];
    int idx = 0;
    if (!iso) return -1;
    if (strlen(iso) != 20) return -1;
    if (iso[4] != '-' || iso[7] != '-' || iso[10] != 'T' ||
        iso[13] != ':' || iso[16] != ':' || iso[19] != 'Z')
        return -1;
    for (i = 0; i < 20; i++) {
        if (i == 4 || i == 7 || i == 10 || i == 13 || i == 16 || i == 19)
            continue;
        int v = digit_at(iso, i);
        if (v < 0) return -1;
        d[idx++] = v;
    }
    year = d[0] * 1000 + d[1] * 100 + d[2] * 10 + d[3];
    mon  = d[4] * 10 + d[5];
    day  = d[6] * 10 + d[7];
    hour = d[8] * 10 + d[9];
    min  = d[10] * 10 + d[11];
    sec  = d[12] * 10 + d[13];
    if (mon < 1 || mon > 12) return -1;
    dim = mdays[mon - 1];
    if (mon == 2 && is_leap(year)) dim = 29;
    if (day < 1 || day > dim) return -1;
    if (hour > 23 || min > 59 || sec > 60) return -1;
    // Leap seconds (sec == 60) are folded onto the following second's
    // start in unix time; this service never emits them.
    if (sec == 60) sec = 59;
    return days_from_civil(year, (unsigned)mon, (unsigned)day) * 86400
         + hour * 3600 + min * 60 + sec;
}

// ---------------------------------------------------------------- RNG

int sf_random_bytes(void *buf, size_t len) {
    if (!buf && len) return -1;
    if (len == 0) return 0;
#ifdef __APPLE__
    arc4random_buf(buf, len);
    return 0;
#else
#if defined(__linux__) && defined(SYS_getrandom)
    {
        uint8_t *p = (uint8_t *)buf;
        size_t off = 0;
        while (off < len) {
            long n = syscall(SYS_getrandom, p + off, len - off, 0);
            if (n < 0) {
                if (errno == EINTR) continue;
                break; // fall through to /dev/urandom
            }
            if (n == 0) break;
            off += (size_t)n;
        }
        if (off == len) return 0;
        // Partial fill: keep the bytes obtained and top up below by
        // re-reading into the remainder only.
        if (off > 0) {
            FILE *f = fopen("/dev/urandom", "rb");
            if (!f) return -1;
            while (off < len) {
                size_t n = fread((uint8_t *)buf + off, 1, len - off, f);
                if (n == 0) { fclose(f); return -1; }
                off += n;
            }
            fclose(f);
            return 0;
        }
    }
#endif
    {
        FILE *f = fopen("/dev/urandom", "rb");
        size_t off = 0;
        if (!f) return -1;
        while (off < len) {
            size_t n = fread((uint8_t *)buf + off, 1, len - off, f);
            if (n == 0) { fclose(f); return -1; }
            off += n;
        }
        fclose(f);
        return 0;
    }
#endif
}

// ------------------------------------------------- constant-time compare

int sf_ct_equal(const void *a, const void *b, size_t len) {
    const uint8_t *pa = (const uint8_t *)a;
    const uint8_t *pb = (const uint8_t *)b;
    uint8_t diff = 0;
    size_t i;
    if (len == 0) return 0;
    if (!a || !b) return 1;
    for (i = 0; i < len; i++) diff |= (uint8_t)(pa[i] ^ pb[i]);
    return diff == 0 ? 0 : 1;
}
