#include "RuntimeIntegrity.h"

#if !defined(DEBUG)
#include <ctype.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <unistd.h>

static void ttx_xor_decode(const uint8_t *enc, const uint8_t *msk, size_t len, char *out) {
    for (size_t i = 0; i < len; ++i) {
        out[i] = (char)(enc[i] ^ msk[i]);
    }
    out[len] = '\0';
}

static bool ttx_contains_ci(const char *haystack, const char *needle) {
    if (!haystack || !needle || !*needle) {
        return false;
    }
    for (const char *h = haystack; *h; ++h) {
        const char *p1 = h;
        const char *p2 = needle;
        while (*p1 && *p2 && tolower((unsigned char)*p1) == tolower((unsigned char)*p2)) {
            ++p1;
            ++p2;
        }
        if (*p2 == '\0') {
            return true;
        }
    }
    return false;
}

static bool ttx_is_debugger_attached(void) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    struct kinfo_proc info;
    size_t size = sizeof(info);
    info.kp_proc.p_flag = 0;
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) {
        return false;
    }
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

static bool ttx_has_forbidden_dyld(void) {
    static const uint8_t frida_enc[5] = { 0xa7, 0x28, 0xbe, 0x31, 0x16 };
    static const uint8_t frida_msk[5] = { 0xc1, 0x5a, 0xd7, 0x55, 0x77 };
    char needle[6];
    ttx_xor_decode(frida_enc, frida_msk, sizeof(frida_enc), needle);

    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; ++i) {
        const char *img = _dyld_get_image_name(i);
        if (img && ttx_contains_ci(img, needle)) {
            return true;
        }
    }
    return false;
}
#endif

void totorox_harden_runtime(void) {
#if !defined(DEBUG)
    if (getenv("XCTestConfigurationFilePath") != NULL) {
        return;
    }

    static const uint8_t ptr_enc[6] = { 0x42, 0x50, 0xec, 0xa0, 0x68, 0x02 };
    static const uint8_t ptr_msk[6] = { 0x32, 0x24, 0x9e, 0xc1, 0x0b, 0x67 };
    char sym_name[7];
    ttx_xor_decode(ptr_enc, ptr_msk, sizeof(ptr_enc), sym_name);

    typedef int (*ttx_ptrace_fn)(int, pid_t, void *, int);
    ttx_ptrace_fn pfn = (ttx_ptrace_fn)dlsym(RTLD_DEFAULT, sym_name);
    if (pfn != NULL) {
        pfn(31 /* PT_DENY_ATTACH */, 0, NULL, 0);
    }

    if (ttx_is_debugger_attached() || ttx_has_forbidden_dyld()) {
        /* Do not _exit(0) silently: a silent exit leaves no crash log and
           makes the cause impossible to diagnose. Log and continue instead;
           PT_DENY_ATTACH above is still in effect. */
        fprintf(stderr, "[totorox] debugger/forbidden dyld detected; continuing (not exiting)\n");
    }
#endif
}
