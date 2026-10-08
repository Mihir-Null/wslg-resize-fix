/*
 * wslg-resize-fix: version-checking shim for a WSLg Weston module.
 *
 * WSLGd starts weston with --backend=rdp-backend.so --shell=rdprail-shell.so.
 * With WESTON_MODULE_MAP (set through .wslgconfig [system-distro-env]) those
 * names resolve to this shim instead of the stock modules. The shim reads the
 * weston commit this WSLg was built from (/mnt/wslg/versions.txt) and loads
 *
 *   1. <shim dir>/weston-<commit>/<module>   patched build for exactly this WSLg
 *   2. otherwise the stock module shipped in the WSLg system distro
 *
 * and forwards the module entry point to it. A WSLg update therefore never
 * loads a module built against a different weston: it falls back to stock
 * behaviour (and the Windows helper reports that a rebuild is needed).
 *
 * Built twice by linux/build-shell.sh:
 *   -DSHIM_BACKEND -DSHIM_MODULE='"rdp-backend.so"'
 *   -DSHIM_SHELL   -DSHIM_MODULE='"rdprail-shell.so"'
 * It has no libweston build dependency: the entry points only pass opaque
 * pointers through, and weston_log() is looked up at runtime.
 *
 * Set WSLG_RESIZE_FIX_DISABLE=1 in [system-distro-env] to force stock modules
 * without touching anything else.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <glob.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define VERSIONS_TXT "/mnt/wslg/versions.txt"
#define EXPORT __attribute__((visibility("default")))

#if defined(SHIM_BACKEND)
#define ENTRY "weston_backend_init"
static const char *const stock_globs[] = {
	"/usr/lib/libweston-*/rdp-backend.so",
	"/usr/lib64/libweston-*/rdp-backend.so",
	NULL,
};
#elif defined(SHIM_SHELL)
#define ENTRY "wet_shell_init"
static const char *const stock_globs[] = {
	"/usr/lib/weston/rdprail-shell.so",
	"/usr/lib64/weston/rdprail-shell.so",
	NULL,
};
#else
#error "define SHIM_BACKEND or SHIM_SHELL"
#endif

static void
shim_log(const char *fmt, ...)
{
	int (*wlog)(const char *, ...);
	char msg[1024];
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(msg, sizeof msg, fmt, ap);
	va_end(ap);

	/* weston_log() writes to /mnt/wslg/weston.log; it lives in libweston,
	 * which the weston binary has already loaded globally. */
	*(void **)&wlog = dlsym(RTLD_DEFAULT, "weston_log");
	if (wlog)
		wlog("wslg-resize-fix: %s: %s\n", SHIM_MODULE, msg);
	else
		fprintf(stderr, "wslg-resize-fix: %s: %s\n", SHIM_MODULE, msg);
}

/* "weston: <40 hex digits>" from WSLg's own version manifest. */
static int
read_weston_commit(char *out, size_t len)
{
	char line[256];
	int found = 0;
	FILE *f;

	if (len < 41 || !(f = fopen(VERSIONS_TXT, "re")))
		return 0;
	while (!found && fgets(line, sizeof line, f))
		found = sscanf(line, "weston: %40[0-9a-f]", out) == 1 && strlen(out) == 40;
	fclose(f);
	return found;
}

/* Directory this shim was loaded from. */
static int
shim_dir(char *out, size_t len)
{
	Dl_info info;
	char *slash;

	if (!dladdr((void *)shim_dir, &info) || !info.dli_fname ||
	    snprintf(out, len, "%s", info.dli_fname) >= (int)len ||
	    !(slash = strrchr(out, '/')))
		return 0;
	*slash = '\0';
	return 1;
}

/* True if path is this shim itself (e.g. someone installed the shim over the
 * stock module): loading it would just find our own entry point again. */
static int
is_self(const char *path)
{
	struct stat a, b;
	Dl_info info;

	return dladdr((void *)is_self, &info) && info.dli_fname &&
	       stat(info.dli_fname, &a) == 0 && stat(path, &b) == 0 &&
	       a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}

static void *
load_stock(const char *why)
{
	const char *const *pat;
	size_t i;

	for (pat = stock_globs; *pat; pat++) {
		glob_t g;

		if (glob(*pat, 0, NULL, &g) != 0)
			continue;
		for (i = 0; i < g.gl_pathc; i++) {
			void *h;

			if (is_self(g.gl_pathv[i]))
				continue;
			h = dlopen(g.gl_pathv[i], RTLD_NOW);

			if (h) {
				shim_log("%s; using stock %s", why, g.gl_pathv[i]);
				globfree(&g);
				return h;
			}
		}
		globfree(&g);
	}
	shim_log("%s; and no stock module found", why);
	return NULL;
}

static void *
load_target(void)
{
	char commit[41], dir[PATH_MAX], path[PATH_MAX + 64], why[512];
	void *h;

	if (getenv("WSLG_RESIZE_FIX_DISABLE"))
		return load_stock("disabled by WSLG_RESIZE_FIX_DISABLE");
	if (!read_weston_commit(commit, sizeof commit))
		return load_stock("cannot read the weston commit from " VERSIONS_TXT);
	if (!shim_dir(dir, sizeof dir))
		return load_stock("cannot locate the shim's own directory");

	snprintf(path, sizeof path, "%s/weston-%s/%s", dir, commit, SHIM_MODULE);
	if (access(path, R_OK) != 0) {
		snprintf(why, sizeof why,
			 "no patched build for weston %.12s (rebuild wslg-resize-fix)", commit);
		return load_stock(why);
	}
	h = dlopen(path, RTLD_NOW);
	if (!h) {
		snprintf(why, sizeof why, "cannot load %.200s: %.280s", path, dlerror());
		return load_stock(why);
	}
	shim_log("loaded patched %s", path);
	return h;
}

#if defined(SHIM_BACKEND)
EXPORT int
weston_backend_init(void *compositor, void *config_base)
{
	int (*init)(void *, void *);
	void *h = load_target();

	if (!h)
		return -1;
	*(void **)&init = dlsym(h, ENTRY);
	if (!init) {
		shim_log("loaded module has no %s", ENTRY);
		return -1;
	}
	return init(compositor, config_base);
}
#else
EXPORT int
wet_shell_init(void *compositor, int *argc, char *argv[])
{
	int (*init)(void *, int *, char **);
	void *h = load_target();

	if (!h)
		return -1;
	*(void **)&init = dlsym(h, ENTRY);
	if (!init) {
		shim_log("loaded module has no %s", ENTRY);
		return -1;
	}
	return init(compositor, argc, argv);
}
#endif
