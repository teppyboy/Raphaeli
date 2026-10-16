/*
 * recovery-install.c - Raphaeli installer for macOS RecoveryOS (780M / gfx1103).
 *
 * Single-file C program, libSystem only. Build:
 *   clang -O2 -Wall -o recovery-install recovery-install.c
 * (packaged as tools/recovery-install in the dist zip by scripts/package.sh)
 *
 * Run from Recovery (root, no GUI, kextload not possible, WindowServer on the
 * normal volume may be crashing). Differences from install.sh (direct route):
 *   - target volume is NOT /: it lives under /Volumes/<name>; auto-detects the
 *     single macOS volume or requires an explicit one (RAPHAELI_VOLUMES_DIR
 *     overrides the mount root - test hook)
 *   - APFS: tries `mount -uw <vol>` (failure ignored if already rw)
 *   - Sealed System Volume: /usr/lib on the system snapshot is unwritable, so
 *     dylibs go to <vol>/Library/Raphaeli/usr/lib/ and the Vulkan ICD json is
 *     written to <vol>/usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json
 *     (usr/local is on the Data volume, writable; the Vulkan loader default-
 *     scans it) with an ABSOLUTE library_path into /Library/Raphaeli/usr/lib/
 *   - OC-injected setups (EFI/OC/config.plist present): kext copy and auxKC
 *     are skipped - OC injects the kext; only firmware, userspace and
 *     boot-args are touched. config.plist is never edited here; use
 *     oc-install.py from the booted system.
 *   - boot-args (nvram, spawned via posix_spawnp) are only modified with
 *     --apply; --uninstall removes raphaeli-amd=1 and the
 *     raphaeli-gpu-attaching boot-guard marker (nmx_kext.cpp boot guard)
 *   - --dry-run prints every mutating action instead of running it
 *   - firmware census against the request_firmware() names; optional
 *     SHA256SUMS manifest verification via CommonCrypto (skipped if absent)
 *   - auxKC best effort: kmutil + matching KDK from the target build version,
 *     else printed on-macOS follow-up
 *
 * Usage:
 *   recovery-install [/Volumes/Macintosh\ HD] [--apply] [--dry-run]
 *   recovery-install /Volumes/Macintosh\ HD --uninstall
 */
#define _DARWIN_C_SOURCE
#include <CommonCrypto/CommonDigest.h>
#include <copyfile.h>
#include <dirent.h>
#include <errno.h>
#include <ftw.h>
#include <limits.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

#define KEXT_ID     "me.tretrauit.raphaeli"
#define BOOT_ARG    "raphaeli-amd=1"
#define NVRAM_GUARD "raphaeli-gpu-attaching"
#define ICD_LIBRARY "/Library/Raphaeli/usr/lib/libvulkan_radeon.dylib"

static const char *REQUIRED_FW[] = {
    "ip_discovery.bin",   "gc_11_0_1_pfp.bin", "gc_11_0_1_me.bin",
    "gc_11_0_1_rlc.bin",  "gc_11_0_1_mec.bin", "gc_11_0_1_imu.bin",
    "gc_11_0_1_mes1.bin", "sdma_6_0_2.bin",    "psp_13_0_11_toc.bin",
    "psp_13_0_11_ta.bin", "vcn_4_0_2.bin",     "dcn_3_1_4_dmcub.bin",
};
#define N_REQUIRED_FW ((int)(sizeof(REQUIRED_FW) / sizeof(REQUIRED_FW[0])))

static const char ICD_JSON[] =
    "{\n"
    "  \"file_format_version\": \"1.0.0\",\n"
    "  \"ICD\": {\n"
    "    \"library_path\": \"" ICD_LIBRARY "\",\n"
    "    \"api_version\": \"1.3.0\"\n"
    "  }\n"
    "}\n";

static int dry_run = 0, apply = 0, uninstall = 0, oc_mode = 0;
static const char *vol = NULL;
static char srcroot[PATH_MAX];
static char kext_src[PATH_MAX], usrlib_src[PATH_MAX], fw_src[PATH_MAX];

static void die(const char *fmt, ...) __attribute__((noreturn, format(printf, 1, 2)));
static void die(const char *fmt, ...)
{
    va_list ap;
    fputs("recovery-install: ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(1);
}

static void logmsg(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logmsg(const char *fmt, ...)
{
    va_list ap;
    fputs("== ", stdout);
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    putchar('\n');
}

static void usage(FILE *f)
{
    fprintf(f, "usage: recovery-install /Volumes/Macintosh\\ HD [--apply] [--uninstall] [--dry-run]\n");
}

/* ---- subprocess helpers (PATH-resolved so tests can shim nvram et al) ----- */

/* Run a command; in dry-run mode print it instead. Returns exit status. */
static int run(char *const argv[])
{
    if (dry_run) {
        fputs("DRY-RUN:", stdout);
        for (int i = 0; argv[i]; i++)
            printf(" %s", argv[i]);
        putchar('\n');
        return 0;
    }
    pid_t pid;
    int rc = posix_spawnp(&pid, argv[0], NULL, NULL, argv, environ);
    if (rc) {
        fprintf(stderr, "recovery-install: spawn %s: %s\n", argv[0], strerror(rc));
        return 127;
    }
    int st;
    if (waitpid(pid, &st, 0) < 0)
        return -1;
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

/* Run a command capturing stdout (NUL-terminated, truncated to outsz-1). */
static int capture(char *const argv[], char *out, size_t outsz)
{
    int fds[2];
    if (pipe(fds))
        return -1;
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&fa, fds[0]);
    posix_spawn_file_actions_addclose(&fa, fds[1]);
    pid_t pid;
    int rc = posix_spawnp(&pid, argv[0], &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(fds[1]);
    if (rc) {
        close(fds[0]);
        return -1;
    }
    size_t n = 0;
    ssize_t r;
    while (n < outsz - 1 && (r = read(fds[0], out + n, outsz - 1 - n)) > 0)
        n += (size_t)r;
    close(fds[0]);
    out[n] = '\0';
    int st;
    if (waitpid(pid, &st, 0) < 0)
        return -1;
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

static void trim(char *s)
{
    size_t n = strlen(s);
    while (n && (s[n - 1] == '\n' || s[n - 1] == '\r' || s[n - 1] == ' ' || s[n - 1] == '\t'))
        s[--n] = '\0';
}

/* ---- fs helpers ------------------------------------------------------------ */

static int dir_exists(const char *path)
{
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static int file_exists(const char *path)
{
    struct stat st;
    return stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

/* mkdir -p */
static int mkpath(const char *path)
{
    char tmp[PATH_MAX];
    snprintf(tmp, sizeof(tmp), "%s", path);
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(tmp, 0755) && errno != EEXIST)
                return -1;
            *p = '/';
        }
    }
    return (mkdir(tmp, 0755) && errno != EEXIST) ? -1 : 0;
}

static void run_mkdir(const char *path)
{
    if (dry_run) {
        printf("DRY-RUN: mkdir -p %s\n", path);
        return;
    }
    if (mkpath(path))
        die("mkdir -p %s: %s", path, strerror(errno));
}

static int rm_cb(const char *path, const struct stat *sb, int flag, struct FTW *fb)
{
    (void)sb;
    (void)fb;
    switch (flag) {
    case FTW_DP:
        return rmdir(path);
    case FTW_F:
    case FTW_SL:
        return unlink(path);
    default:
        return 0;
    }
}

static void remove_tree(const char *path)
{
    if (dry_run) {
        printf("DRY-RUN: rm -rf %s\n", path);
        return;
    }
    nftw(path, rm_cb, 16, FTW_DEPTH | FTW_PHYS);
}

static void remove_file(const char *path)
{
    if (dry_run) {
        printf("DRY-RUN: rm -f %s\n", path);
        return;
    }
    unlink(path); /* missing is fine */
}

/* ditto equivalent: recursive metadata-preserving copy (copyfile(3)) */
static void copy_tree(const char *src, const char *dst)
{
    if (dry_run) {
        printf("DRY-RUN: ditto %s %s\n", src, dst);
        return;
    }
    if (copyfile(src, dst, NULL, COPYFILE_ALL | COPYFILE_RECURSIVE))
        die("copy %s -> %s: %s", src, dst, strerror(errno));
}

static void copy_file(const char *src, const char *dst)
{
    if (dry_run) {
        printf("DRY-RUN: cp -f %s %s\n", src, dst);
        return;
    }
    if (copyfile(src, dst, NULL, COPYFILE_ALL))
        die("copy %s -> %s: %s", src, dst, strerror(errno));
}

static int perm_failures;

static int perm_cb(const char *path, const struct stat *sb, int flag, struct FTW *fb)
{
    (void)sb;
    (void)fb;
    if (flag == FTW_SL || flag == FTW_DNR)
        return 0;
    if (chown(path, 0, 0)) /* root:wheel */
        perm_failures++;
    if (chmod(path, 0755))
        perm_failures++;
    return 0;
}

static void set_perms(const char *root)
{
    if (dry_run) {
        printf("DRY-RUN: chown -R root:wheel %s\n", root);
        printf("DRY-RUN: chmod -R 755 %s\n", root);
        return;
    }
    perm_failures = 0;
    nftw(root, perm_cb, 16, FTW_PHYS);
    if (perm_failures)
        logmsg("WARNING: chown/chmod failed on some entries (not root?); kext must be root:wheel to load");
}

static int find_in_path(const char *name)
{
    const char *p = getenv("PATH");
    if (!p)
        return 0;
    char *dup = strdup(p);
    if (!dup)
        return 0;
    char *save = NULL;
    for (char *dir = strtok_r(dup, ":", &save); dir; dir = strtok_r(NULL, ":", &save)) {
        char full[PATH_MAX];
        snprintf(full, sizeof(full), "%s/%s", dir, name);
        if (access(full, X_OK) == 0) {
            free(dup);
            return 1;
        }
    }
    free(dup);
    return 0;
}

static int ends_with(const char *s, const char *suffix)
{
    size_t ls = strlen(s), lf = strlen(suffix);
    return ls >= lf && strcmp(s + ls - lf, suffix) == 0;
}

/* ---- boot-args (nvram) ----------------------------------------------------- */

/* Read the current boot-args value from `nvram -p` ("boot-args\t<value>"). */
static void get_bootargs(char *out, size_t outsz)
{
    out[0] = '\0';
    char buf[4096];
    char *const cmd[] = { "nvram", "-p", NULL };
    if (capture(cmd, buf, sizeof(buf)) != 0)
        return;
    char *p = buf;
    while ((p = strstr(p, "boot-args\t")) != NULL) {
        char *start = p + strlen("boot-args\t");
        char *nl = strchr(start, '\n');
        size_t len = nl ? (size_t)(nl - start) : strlen(start);
        if (len >= outsz)
            len = outsz - 1;
        memcpy(out, start, len);
        out[len] = '\0';
        p = start; /* keep the last match */
    }
}

static int has_token(const char *s, const char *tok)
{
    char buf[4096], pat[256];
    snprintf(buf, sizeof(buf), " %s ", s);
    snprintf(pat, sizeof(pat), " %s ", tok);
    return strstr(buf, pat) != NULL;
}

/* dst = s with the tok word removed (single-space separated). */
static void remove_token(char *dst, size_t n, const char *s, const char *tok)
{
    dst[0] = '\0';
    char *copy = strdup(s);
    if (!copy)
        return;
    char *save = NULL, *p;
    size_t used = 0;
    for (p = strtok_r(copy, " ", &save); p; p = strtok_r(NULL, " ", &save)) {
        if (strcmp(p, tok) == 0)
            continue;
        size_t l = strlen(p);
        if (used && used + 1 < n) {
            dst[used++] = ' ';
            dst[used] = '\0';
        }
        if (used + l < n) {
            memcpy(dst + used, p, l);
            used += l;
            dst[used] = '\0';
        }
    }
    free(copy);
}

/* ---- firmware checksum manifest (CommonCrypto, no shasum dependency) ------- */

static int sha256_hex(const char *path, char out[65])
{
    FILE *f = fopen(path, "rb");
    if (!f)
        return -1;
    CC_SHA256_CTX c;
    CC_SHA256_Init(&c);
    unsigned char buf[65536], md[CC_SHA256_DIGEST_LENGTH];
    size_t r;
    while ((r = fread(buf, 1, sizeof(buf), f)) > 0)
        CC_SHA256_Update(&c, buf, (CC_LONG)r);
    fclose(f);
    CC_SHA256_Final(md, &c);
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
        sprintf(out + 2 * i, "%02x", md[i]);
    return 0;
}

static void verify_manifest(const char *fwdir)
{
    char mpath[PATH_MAX];
    snprintf(mpath, sizeof(mpath), "%s/SHA256SUMS", fwdir);
    FILE *f = fopen(mpath, "r");
    if (!f) {
        logmsg("no SHA256SUMS manifest next to firmware; skipping checksum verification");
        return;
    }
    logmsg("verifying firmware checksums (SHA256SUMS)");
    char line[1024];
    while (fgets(line, sizeof(line), f)) {
        char hex[65], name[512];
        if (sscanf(line, "%64s %511s", hex, name) != 2 || strlen(hex) != 64)
            continue;
        char fpath[PATH_MAX];
        snprintf(fpath, sizeof(fpath), "%s/%s", fwdir, name);
        char got[65];
        if (sha256_hex(fpath, got) || strcmp(got, hex) != 0)
            die("firmware checksum verification FAILED (SHA256SUMS): %s", name);
    }
    fclose(f);
}

/* ---- source tree resolution (dist zip layout, dev-tree fallback) ----------- */

static void resolve_sources(const char *argv0)
{
    char progdir[PATH_MAX];
    snprintf(progdir, sizeof(progdir), "%s", argv0);
    char *slash = strrchr(progdir, '/');
    if (!slash)
        strcpy(progdir, ".");
    else if (slash == progdir)
        strcpy(progdir, "/");
    else
        *slash = '\0';

    char cand[PATH_MAX];
    snprintf(cand, sizeof(cand), "%s/..", progdir);
    if (!realpath(cand, srcroot))
        die("cannot resolve source root from %s: %s", argv0, strerror(errno));

    const char *ov = getenv("RAPHAELI_KEXT");
    if (ov && *ov) {
        snprintf(kext_src, sizeof(kext_src), "%s", ov);
    } else {
        snprintf(cand, sizeof(cand), "%s/kext/Raphaeli.kext", srcroot);
        snprintf(kext_src, sizeof(kext_src), "%s", dir_exists(cand) ? cand : "");
        if (!kext_src[0])
            snprintf(kext_src, sizeof(kext_src), "%s/out/Raphaeli.kext", srcroot);
    }
    snprintf(cand, sizeof(cand), "%s/usr/lib", srcroot);
    snprintf(usrlib_src, sizeof(usrlib_src), "%s", dir_exists(cand) ? cand : "");
    if (!usrlib_src[0])
        snprintf(usrlib_src, sizeof(usrlib_src), "%s/out/usr/lib", srcroot);

    ov = getenv("RAPHAELI_FW_SRC");
    if (ov && *ov)
        snprintf(fw_src, sizeof(fw_src), "%s", ov);
    else
        snprintf(fw_src, sizeof(fw_src), "%s/firmware/amdgpu", srcroot);
}

/* ---- volume resolution ------------------------------------------------------ */

static const char *volumes_dir(void)
{
    const char *v = getenv("RAPHAELI_VOLUMES_DIR");
    return (v && *v) ? v : "/Volumes";
}

static void resolve_volume_explicit(void)
{
    struct stat st;
    if (stat(vol, &st) || !S_ISDIR(st.st_mode))
        die("no such volume: %s", vol);
    char lib[PATH_MAX];
    snprintf(lib, sizeof(lib), "%s/Library", vol);
    if (!dir_exists(lib))
        die("%s does not look like a macOS volume (no Library/)", vol);
}

static void resolve_volume_auto(void)
{
    const char *volsdir = volumes_dir();
    DIR *d = opendir(volsdir);
    if (!d)
        die("cannot list %s: %s", volsdir, strerror(errno));
    char pref[64][PATH_MAX], other[64][PATH_MAX];
    int npref = 0, nother = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.')
            continue;
        char full[PATH_MAX], sub[PATH_MAX];
        snprintf(full, sizeof(full), "%s/%s", volsdir, e->d_name);
        struct stat st;
        if (stat(full, &st) || !S_ISDIR(st.st_mode))
            continue;
        snprintf(sub, sizeof(sub), "%s/Library/Extensions", full);
        if (dir_exists(sub)) {
            if (npref < 64)
                snprintf(pref[npref++], PATH_MAX, "%s", full);
        } else {
            snprintf(sub, sizeof(sub), "%s/Library", full);
            if (dir_exists(sub) && nother < 64)
                snprintf(other[nother++], PATH_MAX, "%s", full);
        }
    }
    closedir(d);
    if (npref == 1 || (npref == 0 && nother == 1)) {
        vol = (npref == 1) ? pref[0] : other[0];
        return;
    }
    fprintf(stderr, "candidates under %s:\n", volsdir);
    for (int i = 0; i < npref; i++)
        fprintf(stderr, "  %s (has Library/Extensions)\n", pref[i]);
    for (int i = 0; i < nother; i++)
        fprintf(stderr, "  %s\n", other[i]);
    usage(stderr);
    die("could not pick a unique target volume; pass it explicitly");
}

/* ---- install steps ---------------------------------------------------------- */

static void step_userspace(void)
{
    char libdest[PATH_MAX], icddir[PATH_MAX], icddest[PATH_MAX];

    snprintf(libdest, sizeof(libdest), "%s/Library/Raphaeli/usr/lib", vol);
    logmsg("installing dylibs -> %s", libdest);
    run_mkdir(libdest);
    DIR *d = opendir(usrlib_src);
    if (!d)
        die("cannot read %s: %s", usrlib_src, strerror(errno));
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (!ends_with(e->d_name, ".dylib"))
            continue;
        char src[PATH_MAX], dst[PATH_MAX];
        snprintf(src, sizeof(src), "%s/%s", usrlib_src, e->d_name);
        snprintf(dst, sizeof(dst), "%s/%s", libdest, e->d_name);
        copy_file(src, dst);
    }
    closedir(d);

    /* ICD json: absolute library_path; the Vulkan loader default-scans
     * /usr/local/share/vulkan/icd.d (on the Data volume, writable). */
    snprintf(icddir, sizeof(icddir), "%s/usr/local/share/vulkan/icd.d", vol);
    snprintf(icddest, sizeof(icddest), "%s/radeon_icd.x86_64.json", icddir);
    logmsg("writing Vulkan ICD json -> %s", icddest);
    run_mkdir(icddir);
    if (dry_run) {
        printf("DRY-RUN: write %s (library_path=%s)\n", icddest, ICD_LIBRARY);
    } else {
        FILE *f = fopen(icddest, "w");
        if (!f)
            die("write %s: %s", icddest, strerror(errno));
        fputs(ICD_JSON, f);
        fclose(f);
    }
}

static void step_firmware(void)
{
    char fwdest[PATH_MAX], amdgpu[PATH_MAX];
    snprintf(fwdest, sizeof(fwdest), "%s/Library/Raphaeli/firmware", vol);
    snprintf(amdgpu, sizeof(amdgpu), "%s/amdgpu", fwdest);
    logmsg("staging firmware -> %s", fwdest);
    run_mkdir(amdgpu);
    DIR *d = opendir(fw_src);
    if (!d)
        die("cannot read %s: %s", fw_src, strerror(errno));
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (!ends_with(e->d_name, ".bin"))
            continue;
        char src[PATH_MAX], dst[PATH_MAX];
        snprintf(src, sizeof(src), "%s/%s", fw_src, e->d_name);
        snprintf(dst, sizeof(dst), "%s/%s", amdgpu, e->d_name);
        copy_file(src, dst);
    }
    closedir(d);
}

static void step_kext(void)
{
    char ocfg[PATH_MAX], kextdest[PATH_MAX];
    snprintf(ocfg, sizeof(ocfg), "%s/EFI/OC/config.plist", vol);

    if (file_exists(ocfg)) {
        oc_mode = 1;
        logmsg("OC config found at %s: skipping kext copy + auxKC (OC injects)", ocfg);
        printf("   NOTE: config.plist is not edited from Recovery. Enable/disable the kext\n");
        printf("   with oc-install.py on the booted system: python3 tools/oc-install.py <EFI> --enable|--disable\n");
        return;
    }

    snprintf(kextdest, sizeof(kextdest), "%s/Library/Extensions/Raphaeli.kext", vol);
    logmsg("installing kext -> %s (root:wheel, 755)", kextdest);
    remove_tree(kextdest);
    copy_tree(kext_src, kextdest);
    set_perms(kextdest);

    /* auxKC: best effort. kmutil exists in recent RecoveryOS; needs a matching
     * KDK and the target volume's kernel collections. */
    char kcd[PATH_MAX];
    snprintf(kcd, sizeof(kcd), "%s/System/Library/KernelCollections", vol);
    if (!find_in_path("kmutil") || !dir_exists(kcd)) {
        logmsg("kmutil or target kernel collections not available; skipping auxKC");
    } else {
        char svp[PATH_MAX], build[128] = "";
        snprintf(svp, sizeof(svp), "%s/System/Library/CoreServices/SystemVersion.plist", vol);
        char *const pc[] = { "plutil", "-extract", "ProductBuildVersion", "raw", svp, NULL };
        if (capture(pc, build, sizeof(build)) == 0)
            trim(build);
        char kdks[PATH_MAX], kdk[PATH_MAX] = "";
        snprintf(kdks, sizeof(kdks), "%s/Library/Developer/KDKs", vol);
        DIR *dd = opendir(kdks);
        if (dd) {
            struct dirent *e;
            while ((e = readdir(dd)) != NULL) {
                if (strncmp(e->d_name, "KDK_", 4) != 0 || !ends_with(e->d_name, ".kdk"))
                    continue;
                if (build[0] && strstr(e->d_name, build)) {
                    snprintf(kdk, sizeof(kdk), "%s/%s", kdks, e->d_name);
                    break;
                }
            }
            closedir(dd);
        }
        if (!kdk[0]) {
            logmsg("no matching KDK under %s (target build %s); skipping auxKC", kdks, build[0] ? build : "?");
        } else {
            char kcdir[PATH_MAX], auxkc[PATH_MAX], bootkc[PATH_MAX], syskc[PATH_MAX];
            snprintf(kcdir, sizeof(kcdir), "%s/Library/KernelCollections", vol);
            snprintf(auxkc, sizeof(auxkc), "%s/Raphaeli.auxkc", kcdir);
            snprintf(bootkc, sizeof(bootkc), "%s/BootKernelExtensions.kc", kcd);
            snprintf(syskc, sizeof(syskc), "%s/SystemKernelExtensions.kc", kcd);
            logmsg("building aux KC (kmutil, KDK: %s)", strrchr(kdk, '/') + 1);
            run_mkdir(kcdir);
            char *const km[] = { "kmutil", "create",   "-a", "x86_64", "-n", "aux", "-x",
                                 "-p",      kextdest,   "--no-authentication",
                                 "-A",      auxkc,      "-B", bootkc,
                                 "-S",      syskc,      "--kdk", kdk, NULL };
            if (run(km) && !dry_run)
                logmsg("WARNING: kmutil create failed; build the auxKC from the booted system");
        }
    }
    printf("   If no auxKC was built here, finish from the booted system:\n");
    printf("     sudo ./tools/install.sh kext/Raphaeli.kext --apply\n");
    printf("   (or use OpenCore injection instead - see INSTALL.md)\n");
}

static void step_bootargs(void)
{
    char cur[2048], val[2200], arg[2400];
    if (!apply) {
        logmsg("not applying boot-args (pass --apply to add %s)", BOOT_ARG);
        return;
    }
    get_bootargs(cur, sizeof(cur));
    if (has_token(cur, BOOT_ARG)) {
        logmsg("boot-args already contain %s", BOOT_ARG);
        return;
    }
    logmsg("applying boot-arg opt-in (%s)", BOOT_ARG);
    snprintf(val, sizeof(val), "%s%s%s", cur, cur[0] ? " " : "", BOOT_ARG);
    snprintf(arg, sizeof(arg), "boot-args=%s", val);
    char *const cmd[] = { "nvram", arg, NULL };
    if (run(cmd) && !dry_run)
        die("nvram boot-args failed");
    printf("\nRollback / safety:\n");
    printf("  nvram -d %s      # clear the boot-guard marker to retry an attach\n", NVRAM_GUARD);
    printf("  nvram -d boot-args         # full reset (only if no other boot-args were set)\n");
}

static void do_uninstall(void)
{
    char path[PATH_MAX];
    char cur[2048], rest[2048], arg[2400];

    logmsg("uninstalling Raphaeli from %s (kext, firmware, userspace, boot-arg)", vol);
    snprintf(path, sizeof(path), "%s/Library/Extensions/Raphaeli.kext", vol);
    remove_tree(path);
    snprintf(path, sizeof(path), "%s/Library/Raphaeli", vol);
    remove_tree(path);
    snprintf(path, sizeof(path), "%s/usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json", vol);
    remove_file(path);
    snprintf(path, sizeof(path), "%s/Library/KernelCollections/Raphaeli.auxkc", vol);
    remove_file(path);

    get_bootargs(cur, sizeof(cur));
    if (cur[0]) {
        remove_token(rest, sizeof(rest), cur, BOOT_ARG);
        if (rest[0]) {
            snprintf(arg, sizeof(arg), "boot-args=%s", rest);
            char *const cmd[] = { "nvram", arg, NULL };
            run(cmd);
        } else {
            char *const cmd[] = { "nvram", "-d", "boot-args", NULL };
            run(cmd);
        }
    }
    char *const cmd[] = { "nvram", "-d", NVRAM_GUARD, NULL };
    run(cmd);
    logmsg("done. If the kext was OC-injected, disable it with oc-install.py --disable.");
}

/* ---- main ------------------------------------------------------------------- */

int main(int argc, char **argv)
{
    const char *volarg = NULL;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--dry-run") == 0) {
            dry_run = 1;
        } else if (strcmp(argv[i], "--apply") == 0) {
            apply = 1;
        } else if (strcmp(argv[i], "--uninstall") == 0) {
            uninstall = 1;
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            usage(stdout);
            return 0;
        } else if (argv[i][0] == '-') {
            fprintf(stderr, "recovery-install: unknown option: %s\n", argv[i]);
            usage(stderr);
            return 1;
        } else {
            if (volarg)
                die("only one volume path may be given");
            volarg = argv[i];
        }
    }

    resolve_sources(argv[0]);

    /* volume resolution */
    if (volarg) {
        vol = volarg;
        resolve_volume_explicit();
    } else {
        resolve_volume_auto();
    }
    logmsg("target volume: %s", vol);

    if (uninstall) {
        do_uninstall();
        return 0;
    }

    /* ---- source tree validation ---- */
    logmsg("source root: %s", srcroot);
    char info[PATH_MAX];
    snprintf(info, sizeof(info), "%s/Contents/Info.plist", kext_src);
    if (!dir_exists(kext_src))
        die("not a kext bundle: %s", kext_src);
    char bid[128] = "";
    char *const pc[] = { "plutil", "-extract", "CFBundleIdentifier", "raw", info, NULL };
    if (capture(pc, bid, sizeof(bid)) != 0)
        die("Info.plist does not lint: %s", info);
    trim(bid);
    if (strcmp(bid, KEXT_ID) != 0)
        die("unexpected bundle id '%s' (expected %s)", bid, KEXT_ID);
    char vdylib[PATH_MAX];
    snprintf(vdylib, sizeof(vdylib), "%s/libvulkan_radeon.dylib", usrlib_src);
    if (!file_exists(vdylib))
        die("missing %s (dist zip usr/lib/)", vdylib);

    /* firmware census */
    logmsg("firmware census in %s (required: %d)", fw_src, N_REQUIRED_FW);
    int nmissing = 0;
    for (int i = 0; i < N_REQUIRED_FW; i++) {
        char f[PATH_MAX];
        snprintf(f, sizeof(f), "%s/%s", fw_src, REQUIRED_FW[i]);
        if (!file_exists(f)) {
            if (!nmissing)
                fprintf(stderr, "MISSING REQUIRED firmware blobs:\n");
            fprintf(stderr, "  amdgpu/%s\n", REQUIRED_FW[i]);
            nmissing++;
        }
    }
    if (nmissing)
        die("the dist zip should contain firmware/amdgpu/*.bin");
    verify_manifest(fw_src);

    /* APFS: make the Data volume writable (failure ignored if already rw) */
    char *const mcmd[] = { "mount", "-uw", (char *)vol, NULL };
    if (dry_run) {
        printf("DRY-RUN: mount -uw %s\n", vol);
    } else {
        run(mcmd); /* status ignored */
    }

    step_userspace();
    step_firmware();
    step_kext();
    step_bootargs();

    printf("\nUserspace (Vulkan) notes:\n");
    printf("  - dylibs: /Library/Raphaeli/usr/lib/ (NOT /usr/lib - Sealed System Volume)\n");
    printf("  - ICD json: /usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json\n");
    printf("    (library_path is absolute into /Library/Raphaeli/usr/lib/)\n");
    printf("  - If the loader does not pick it up, set VK_DRIVER_FILES=/usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json\n");
    printf("\nReboot. Without %s the kext stays inert (probe() declines every device).\n", BOOT_ARG);
    logmsg("done (dry-run: %d, oc-mode: %d)", dry_run, oc_mode);
    return 0;
}
