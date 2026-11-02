/* lane2-adb-scope.c — LD_PRELOAD shim: scope the Lane 2 emulator's own
 * adb calls to the Lane 2 serial.
 *
 * The Android emulator binary spawns its own guest-setup commands as
 * `adb -e ...` ("the" emulator): screen_off_timeout, logcat -G, overlay
 * list, multidisplay broadcast, ...  With Scout's emulator-5554 attached,
 * every one of those fails with `adb: more than one emulator`
 * (~/.fleet-logs/lane2*.log show 65-70 WARNINGs per boot) and the Lane2b
 * QEMU process then SIGSEGVs (exit 139) under SwiftShader load.
 *
 * Agent-side `-s` cannot fix calls the emulator itself makes, and
 * ANDROID_ADB_SERIAL does not override an explicit `-e` (verified on
 * adb 1.0.41: `-e` wins even with a bogus serial in env). So this shim
 * rewrites `-e` to `-s $LANE2_ADB_SERIAL` (default emulator-5556) in any
 * adb argv it sees. Everything else — including `-s` calls and non-adb
 * execs — passes through byte-identical.
 *
 * Active only in processes that inherit LD_PRELOAD from
 * scripts/boot-lane2b.sh, so Lane 1 (emulator-5554) and the rest of the
 * host are untouched. No root, no mounts, no system modification.
 *
 * Build: gcc -shared -fPIC -O2 -o lane2-adb-scope.so lane2-adb-scope.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

static const char *target_serial(void)
{
    const char *s = getenv("LANE2_ADB_SERIAL");
    return (s && *s) ? s : "emulator-5556";
}

static int is_adb(const char *path)
{
    const char *b;
    if (!path)
        return 0;
    b = strrchr(path, '/');
    b = b ? b + 1 : path;
    return strcmp(b, "adb") == 0;
}

/* If argv is an adb call using -e with no explicit -s, build a rewritten
 * argv (-e -> -s SERIAL). Returns the new argv (caller frees) or NULL for
 * passthrough. Only touches the flag tokens; subcommand args are untouched. */
static char **rewrite_argv(char *const argv[])
{
    int has_e = 0, has_s = 0, n = 0, i, j;
    char **out;
    if (!argv || !argv[0] || !is_adb(argv[0]))
        return NULL;
    for (; argv[n]; n++) {
        if (strcmp(argv[n], "-e") == 0)
            has_e = 1;
        else if (strcmp(argv[n], "-s") == 0)
            has_s = 1;
    }
    if (!has_e || has_s)
        return NULL;
    /* -e (1 slot) -> -s SERIAL (2 slots): at most n+1 entries + NULL. */
    out = (char **)malloc(sizeof(char *) * (n + 2));
    if (!out)
        return NULL;
    for (i = 0, j = 0; i < n; i++) {
        if (strcmp(argv[i], "-e") == 0) {
            out[j++] = (char *)"-s";
            out[j++] = (char *)target_serial();
        } else {
            out[j++] = argv[i];
        }
    }
    out[j] = NULL;
    return out;
}

/* --- interposed exec/spawn entry points ---------------------------------- */

typedef int (*execve_fn)(const char *, char *const[], char *const[]);
typedef int (*execvp_fn)(const char *, char *const[]);
typedef int (*spawn_fn)(pid_t *restrict, const char *restrict,
                        const posix_spawn_file_actions_t *restrict,
                        const posix_spawnattr_t *restrict,
                        char *const argv[restrict], char *const envp[restrict]);

int execve(const char *path, char *const argv[], char *const envp[])
{
    static execve_fn real_execve = NULL;
    char **nargv;
    if (!real_execve)
        real_execve = (execve_fn)dlsym(RTLD_NEXT, "execve");
    nargv = rewrite_argv(argv);
    if (nargv) {
        int r = real_execve(path, nargv, envp);
        free(nargv);
        return r;
    }
    return real_execve(path, argv, envp);
}

int execvp(const char *file, char *const argv[])
{
    static execvp_fn real_execvp = NULL;
    char **nargv;
    if (!real_execvp)
        real_execvp = (execvp_fn)dlsym(RTLD_NEXT, "execvp");
    nargv = rewrite_argv(argv);
    if (nargv) {
        int r = real_execvp(file, nargv);
        free(nargv);
        return r;
    }
    return real_execvp(file, argv);
}

int posix_spawn(pid_t *restrict pid, const char *restrict path,
                const posix_spawn_file_actions_t *restrict actions,
                const posix_spawnattr_t *restrict attr,
                char *const argv[restrict], char *const envp[restrict])
{
    static spawn_fn real_spawn = NULL;
    char **nargv;
    if (!real_spawn)
        real_spawn = (spawn_fn)dlsym(RTLD_NEXT, "posix_spawn");
    nargv = rewrite_argv(argv);
    if (nargv) {
        int r = real_spawn(pid, path, actions, attr, nargv, envp);
        free(nargv);
        return r;
    }
    return real_spawn(pid, path, actions, attr, argv, envp);
}

int posix_spawnp(pid_t *restrict pid, const char *restrict file,
                 const posix_spawn_file_actions_t *restrict actions,
                 const posix_spawnattr_t *restrict attr,
                 char *const argv[restrict], char *const envp[restrict])
{
    static spawn_fn real_spawnp = NULL;
    char **nargv;
    if (!real_spawnp)
        real_spawnp = (spawn_fn)dlsym(RTLD_NEXT, "posix_spawnp");
    nargv = rewrite_argv(argv);
    if (nargv) {
        int r = real_spawnp(pid, file, actions, attr, nargv, envp);
        free(nargv);
        return r;
    }
    return real_spawnp(pid, file, actions, attr, argv, envp);
}
