#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fnmatch.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <xbps.h>

#define VERSION "0.1.0"

static struct xbps_handle xh;
static char logpath[XBPS_MAXPATH + 32];
static char *cfg_repos, *cfg_cachedir;
static bool use_color, yes_flag, dry_run, force, verbose, debug;

static const char *C(const char *code)
{
	return use_color ? code : "";
}

#define RED    C("\033[31m")
#define GRN    C("\033[32m")
#define YEL    C("\033[33m")
#define CYN    C("\033[36m")
#define DIM    C("\033[2m")
#define BLD    C("\033[1m")
#define RST    C("\033[0m")

static void log_action(const char *fmt, ...)
{
	FILE *f = fopen(logpath, "a");
	if (!f)
		return;
	char ts[32];
	time_t t = time(NULL);
	strftime(ts, sizeof ts, "%F %T", localtime(&t));
	va_list ap;
	va_start(ap, fmt);
	fprintf(f, "%s ", ts);
	vfprintf(f, fmt, ap);
	fputc('\n', f);
	va_end(ap);
	fclose(f);
}

static bool yesno(const char *msg)
{
	if (yes_flag)
		return true;
	printf("%s [Y/n] ", msg);
	fflush(stdout);
	char buf[16];
	if (!fgets(buf, sizeof buf, stdin))
		return false;
	buf[strcspn(buf, "\n")] = '\0';
	return !buf[0] || !strcasecmp(buf, "y") || !strcasecmp(buf, "yes");
}

static void parse_conf(void)
{
	char path[XBPS_MAXPATH + 32];
	snprintf(path, sizeof path, "%s/etc/kipki/kipki.conf",
	    xh.rootdir[0] ? xh.rootdir : "/");
	FILE *f = fopen(path, "r");
	if (!f)
		return;
	char line[1024];
	while (fgets(line, sizeof line, f)) {
		char *p = line;
		while (isspace((unsigned char)*p))
			p++;
		if (*p == '#' || *p == '\n' || !*p)
			continue;
		char *eq = strchr(p, '=');
		if (!eq)
			continue;
		*eq = '\0';
		char *key = p, *val = eq + 1;
		char *e = key + strlen(key);
		while (e > key && isspace((unsigned char)e[-1]))
			*--e = '\0';
		while (isspace((unsigned char)*val))
			val++;
		e = val + strlen(val);
		while (e > val && isspace((unsigned char)e[-1]))
			*--e = '\0';
		if (!strcmp(key, "REPOS") && *val)
			cfg_repos = strdup(val);
		else if (!strcmp(key, "CACHEDIR") && *val)
			cfg_cachedir = strdup(val);
		else if (!strcmp(key, "COLOR") && !strcasecmp(val, "no"))
			setenv("NO_COLOR", "1", 1);
	}
	fclose(f);
}

static int state_cb(const struct xbps_state_cb_data *xscd, void *cbdata)
{
	(void)cbdata;
	switch (xscd->state) {
	case XBPS_STATE_REPOSYNC:
		printf("%s==>%s %s\n", CYN, RST,
		    xscd->arg ? xscd->arg : "syncing repositories");
		break;
	case XBPS_STATE_UNPACK:
		printf("%s>>%s unpack %s\n", BLD, RST, xscd->arg);
		break;
	case XBPS_STATE_CONFIGURE:
		printf("%s>>%s configure %s\n", BLD, RST, xscd->arg);
		break;
	case XBPS_STATE_REMOVE:
		printf("%s>>%s remove %s\n", BLD, RST, xscd->arg);
		break;
	case XBPS_STATE_INSTALL_DONE:
		printf("%s  installed%s %s\n", GRN, RST, xscd->arg);
		break;
	case XBPS_STATE_UPDATE_DONE:
		printf("%s  updated%s %s\n", GRN, RST, xscd->arg);
		break;
	case XBPS_STATE_REMOVE_DONE:
		printf("%s  removed%s %s\n", GRN, RST, xscd->arg);
		break;
	case XBPS_STATE_REPO_KEY_IMPORT:
		printf("%s\nFingerprint: %s\n", xscd->desc, xscd->arg);
		return yesno("Do you want to import this public key?") ? 1 : 0;
	case XBPS_STATE_TRANS_FAIL:
	case XBPS_STATE_UNPACK_FAIL:
	case XBPS_STATE_UPDATE_FAIL:
	case XBPS_STATE_CONFIGURE_FAIL:
	case XBPS_STATE_REMOVE_FAIL:
	case XBPS_STATE_VERIFY_FAIL:
	case XBPS_STATE_FILES_FAIL:
	case XBPS_STATE_DOWNLOAD_FAIL:
	case XBPS_STATE_REPOSYNC_FAIL:
	case XBPS_STATE_CONFIG_FILE_FAIL:
		fprintf(stderr, "%serror:%s %s\n", RED, RST,
		    xscd->desc ? xscd->desc : "unknown");
		break;
	default:
		break;
	}
	return 0;
}

static void fetch_cb(const struct xbps_fetch_cb_data *xfcd, void *cbdata)
{
	(void)cbdata;
	char done[8], total[8];
	if (xfcd->cb_update && xfcd->file_size > 0) {
		xbps_humanize_number(done, (int64_t)xfcd->file_dloaded);
		xbps_humanize_number(total, (int64_t)xfcd->file_size);
		printf("\r\033[K  %s%s%s %s/%s", CYN, xfcd->file_name, RST,
		    done, total);
		fflush(stdout);
	} else if (xfcd->cb_end) {
		printf("\r\033[K");
		fflush(stdout);
	}
}

static int repo_import_key_cb(struct xbps_repo *repo, void *arg, bool *done)
{
	(void)arg;
	(void)done;
	int rv = xbps_repo_key_import(repo);
	if (rv != 0)
		fprintf(stderr, "kipki: failed to import pubkey from %s: %s\n",
		    repo->uri, strerror(rv));
	return rv;
}

struct strs {
	char **v;
	size_t n, cap;
};

static int norm(int rv)
{
	return rv < 0 ? -rv : rv;
}

static void push(struct strs *s, char *val)
{
	if (s->n == s->cap) {
		s->cap = s->cap ? s->cap * 2 : 32;
		s->v = realloc(s->v, s->cap * sizeof *s->v);
	}
	s->v[s->n++] = val;
}

static void print_group(const char *header, struct strs *g,
    const char *color)
{
	if (!g->n)
		return;
	printf("%u package%s will be %s:\n", (unsigned)g->n,
	    g->n == 1 ? "" : "s", header);
	for (size_t i = 0; i < g->n; i++)
		printf("  %s%s%s\n", color, g->v[i], RST);
	printf("\n");
}

static void print_array_from_dict(xbps_dictionary_t d, const char *key)
{
	xbps_array_t a = xbps_dictionary_get(d, key);
	if (!a)
		return;
	for (unsigned int i = 0; i < xbps_array_count(a); i++) {
		const char *s = NULL;
		if (xbps_array_get_cstring_nocopy(a, i, &s))
			fprintf(stderr, "  %s\n", s);
	}
}

static int exec_transaction(const char *what)
{
	int rv;

	if (!dry_run) {
		rv = xbps_pkgdb_lock(&xh);
		if (rv != 0) {
			fprintf(stderr, "kipki: cannot lock pkgdb: %s\n",
			    strerror(rv));
			return rv;
		}
	}

	rv = xbps_transaction_prepare(&xh);
	if (rv != 0) {
		if (rv == ENODEV) {
			print_array_from_dict(xh.transd, "missing_deps");
			fprintf(stderr,
			    "kipki: transaction aborted (unresolved dependencies)\n");
		} else if (rv == ENOEXEC) {
			print_array_from_dict(xh.transd, "missing_shlibs");
			fprintf(stderr,
			    "kipki: transaction aborted (unresolved shlibs)\n");
		} else if (rv == EAGAIN) {
			print_array_from_dict(xh.transd, "conflicts");
			fprintf(stderr,
			    "kipki: transaction aborted (package conflicts)\n");
		} else if (rv == ENOSPC) {
			uint64_t isz = 0, fsz = 0;
			char b1[8], b2[8];
			xbps_dictionary_get_uint64(xh.transd,
			    "total-installed-size", &isz);
			xbps_dictionary_get_uint64(xh.transd,
			    "disk-free-size", &fsz);
			xbps_humanize_number(b1, (int64_t)isz);
			xbps_humanize_number(b2, (int64_t)fsz);
			fprintf(stderr,
			    "kipki: not enough disk space (need %s, free %s)\n",
			    b1, b2);
		} else {
			fprintf(stderr, "kipki: transaction error: %s\n",
			    strerror(rv));
		}
		return rv;
	}

	struct strs dl = { 0 }, inst = { 0 }, upd = { 0 }, rm = { 0 },
		    hold = { 0 };
	xbps_object_iterator_t iter =
	    xbps_array_iter_from_dict(xh.transd, "packages");
	xbps_object_t obj;
	while ((obj = xbps_object_iterator_next(iter)) != NULL) {
		const char *pkgver = NULL, *pkgname = NULL;
		bool dload = false;
		xbps_dictionary_get_cstring_nocopy(obj, "pkgver", &pkgver);
		xbps_dictionary_get_cstring_nocopy(obj, "pkgname", &pkgname);
		xbps_dictionary_get_bool(obj, "download", &dload);
		if (!pkgver)
			continue;
		if (dload)
			push(&dl, strdup(pkgver));
		switch (xbps_transaction_pkg_type(obj)) {
		case XBPS_TRANS_INSTALL:
		case XBPS_TRANS_REINSTALL:
			push(&inst, strdup(pkgver));
			break;
		case XBPS_TRANS_UPDATE: {
			char name[256];
			const char *oldver = "?";
			xbps_dictionary_t ipkgd;
			xbps_pkg_name(name, sizeof name, pkgver);
			ipkgd = xbps_pkgdb_get_pkg(&xh, name);
			if (ipkgd) {
				const char *ipkgver = NULL;
				xbps_dictionary_get_cstring_nocopy(ipkgd,
				    "pkgver", &ipkgver);
				oldver = xbps_pkg_version(ipkgver);
			}
			push(&upd, xbps_xasprintf("%s (%s -> %s)", pkgname,
			    oldver, xbps_pkg_version(pkgver)));
			break;
		}
		case XBPS_TRANS_REMOVE:
			push(&rm, strdup(pkgver));
			break;
		case XBPS_TRANS_HOLD:
			push(&hold, strdup(pkgver));
			break;
		default:
			break;
		}
	}
	xbps_object_iterator_release(iter);

	print_group("downloaded", &dl, CYN);
	print_group("installed", &inst, GRN);
	print_group("updated", &upd, YEL);
	print_group("removed", &rm, RED);
	print_group("held", &hold, DIM);

	uint64_t dlsz = 0, insz = 0, rmsz = 0, freesz = 0;
	char b[8];
	xbps_dictionary_get_uint64(xh.transd, "total-download-size", &dlsz);
	xbps_dictionary_get_uint64(xh.transd, "total-installed-size", &insz);
	xbps_dictionary_get_uint64(xh.transd, "total-removed-size", &rmsz);
	xbps_dictionary_get_uint64(xh.transd, "disk-free-size", &freesz);
	if (dlsz || insz || rmsz || freesz)
		printf("\n");
	if (dlsz) {
		xbps_humanize_number(b, (int64_t)dlsz);
		printf("Size to download:      %8s\n", b);
	}
	if (insz) {
		xbps_humanize_number(b, (int64_t)insz);
		printf("Size required on disk: %8s\n", b);
	}
	if (rmsz) {
		xbps_humanize_number(b, (int64_t)rmsz);
		printf("Size freed on disk:    %8s\n", b);
	}
	if (freesz) {
		xbps_humanize_number(b, (int64_t)freesz);
		printf("Space available:       %8s\n", b);
	}
	printf("\n");

	rv = 0;
	if (dry_run)
		goto out;
	if (!yesno("Do you want to continue?")) {
		printf("Aborting.\n");
		goto out;
	}

	rv = xbps_transaction_commit(&xh);
	if (rv == 0) {
		printf("%sdone%s: %u downloaded, %u installed, %u updated, "
		    "%u removed, %u held.\n", GRN, RST, (unsigned)dl.n,
		    (unsigned)inst.n, (unsigned)upd.n, (unsigned)rm.n,
		    (unsigned)hold.n);
		log_action("%s ok (%u installed, %u updated, %u removed)",
		    what, (unsigned)inst.n, (unsigned)upd.n, (unsigned)rm.n);
	} else {
		fprintf(stderr, "kipki: transaction failed: %s\n",
		    strerror(rv));
	}
out:
	for (size_t i = 0; i < dl.n; i++)
		free(dl.v[i]);
	for (size_t i = 0; i < inst.n; i++)
		free(inst.v[i]);
	for (size_t i = 0; i < upd.n; i++)
		free(upd.v[i]);
	for (size_t i = 0; i < rm.n; i++)
		free(rm.v[i]);
	for (size_t i = 0; i < hold.n; i++)
		free(hold.v[i]);
	free(dl.v);
	free(inst.v);
	free(upd.v);
	free(rm.v);
	free(hold.v);
	return rv;
}

static int cmd_sync(void)
{
	int rv = xbps_rpool_sync(&xh, NULL);
	if (rv == ENOTSUP)
		fprintf(stderr, "kipki: no repositories configured\n");
	else if (rv != 0)
		fprintf(stderr, "kipki: sync failed: %s\n", strerror(rv));
	else
		log_action("sync ok");
	if (rv != 0)
		return rv;
	return norm(xbps_rpool_foreach(&xh, repo_import_key_cb, NULL));
}

static int cmd_install(int argc, char **argv)
{
	int rv, eexist = 0;
	char what[1024] = "install";

	for (int i = 0; i < argc; i++) {
		rv = xbps_transaction_install_pkg(&xh, argv[i], force);
		if (rv == EEXIST) {
			printf("%s: already installed\n", argv[i]);
			eexist++;
			continue;
		} else if (rv == EBUSY) {
			fprintf(stderr,
			    "kipki: the xbps package must be updated first: "
			    "kipki up xbps\n");
			return rv;
		} else if (rv == ENOENT) {
			fprintf(stderr,
			    "kipki: '%s' not found in repositories\n", argv[i]);
			return rv;
		} else if (rv == ENOTSUP) {
			fprintf(stderr, "kipki: no repositories configured\n");
			return rv;
		} else if (rv == ENXIO) {
			fprintf(stderr,
			    "kipki: '%s' has invalid dependencies\n", argv[i]);
			return rv;
		} else if (rv != 0) {
			fprintf(stderr, "kipki: '%s': %s\n", argv[i],
			    strerror(rv));
			return rv;
		}
		xbps_strlcat(what, " ", sizeof what);
		xbps_strlcat(what, argv[i], sizeof what);
	}
	if (eexist == argc)
		return 0;
	return exec_transaction(what);
}

static int cmd_upgrade(int argc, char **argv)
{
	int rv, eexist = 0;

	if (argc == 0) {
		rv = xbps_transaction_update_packages(&xh);
		if (rv == EEXIST) {
			printf("all packages are up to date\n");
			return 0;
		} else if (rv == ENOENT) {
			fprintf(stderr, "kipki: nothing is installed\n");
			return rv;
		} else if (rv == ENOTSUP) {
			fprintf(stderr, "kipki: no repositories configured\n");
			return rv;
		} else if (rv == EBUSY) {
			fprintf(stderr,
			    "kipki: the xbps package must be updated first: "
			    "kipki up xbps\n");
			return rv;
		} else if (rv != 0) {
			fprintf(stderr, "kipki: upgrade: %s\n", strerror(rv));
			return rv;
		}
		return exec_transaction("upgrade (full)");
	}

	for (int i = 0; i < argc; i++) {
		rv = xbps_transaction_update_pkg(&xh, argv[i], force);
		if (rv == EEXIST) {
			printf("%s: up to date\n", argv[i]);
			eexist++;
		} else if (rv == ENODEV) {
			fprintf(stderr, "kipki: '%s' is not installed\n",
			    argv[i]);
			return rv;
		} else if (rv == ENOENT) {
			fprintf(stderr,
			    "kipki: '%s' not found in repositories\n", argv[i]);
			return rv;
		} else if (rv != 0) {
			fprintf(stderr, "kipki: '%s': %s\n", argv[i],
			    strerror(rv));
			return rv;
		}
	}
	if (eexist == argc)
		return 0;
	return exec_transaction("upgrade");
}

static int cmd_remove(int argc, char **argv)
{
	int rv;
	char what[1024] = "remove";

	for (int i = 0; i < argc; i++) {
		rv = xbps_transaction_remove_pkg(&xh, argv[i], force);
		if (rv == ENOENT) {
			fprintf(stderr, "kipki: '%s' is not installed\n",
			    argv[i]);
			return rv;
		} else if (rv == EEXIST) {
			fprintf(stderr,
			    "kipki: '%s' has reverse dependencies "
			    "(see kipki revdeps %s)\n", argv[i], argv[i]);
			return rv;
		} else if (rv != 0) {
			fprintf(stderr, "kipki: '%s': %s\n", argv[i],
			    strerror(rv));
			return rv;
		}
		xbps_strlcat(what, " ", sizeof what);
		xbps_strlcat(what, argv[i], sizeof what);
	}
	return exec_transaction(what);
}

static int cmd_autoremove(void)
{
	int rv = xbps_transaction_autoremove_pkgs(&xh);
	if (rv == ENOENT) {
		printf("no orphans to remove\n");
		return 0;
	} else if (rv != 0) {
		fprintf(stderr, "kipki: autoremove: %s\n", strerror(rv));
		return rv;
	}
	return exec_transaction("autoremove");
}

struct srch {
	const char *pat;
	xbps_array_t results;
};

static int search_pkg_cb(struct xbps_handle *xhp, xbps_object_t obj,
    const char *key, void *arg, bool *done)
{
	(void)xhp;
	(void)key;
	(void)done;
	struct srch *s = arg;
	const char *pkgver = NULL, *desc = NULL;

	xbps_dictionary_get_cstring_nocopy(obj, "pkgver", &pkgver);
	xbps_dictionary_get_cstring_nocopy(obj, "short_desc", &desc);
	if (!pkgver)
		return 0;
	if (!desc)
		desc = "";
	if (!strcasestr(pkgver, s->pat) && !strcasestr(desc, s->pat) &&
	    xbps_pkgpattern_match(pkgver, s->pat) != 1)
		return 0;
	xbps_array_add_cstring_nocopy(s->results, pkgver);
	xbps_array_add_cstring_nocopy(s->results, desc);
	return 0;
}

static int search_repo_cb(struct xbps_repo *repo, void *arg, bool *done)
{
	(void)done;
	struct srch *s = arg;
	xbps_array_t keys = xbps_dictionary_all_keys(repo->idx);
	if (!keys)
		return 0;
	int rv = xbps_array_foreach_cb(repo->xhp, keys, repo->idx,
	    search_pkg_cb, s);
	xbps_object_release(keys);
	return rv;
}

static int cmd_search(const char *pat)
{
	struct srch s = { .pat = pat };
	int rv;

	s.results = xbps_array_create();
	if (!s.results)
		return ENOMEM;
	rv = norm(xbps_rpool_foreach(&xh, search_repo_cb, &s));

	unsigned int cnt = xbps_array_count(s.results) / 2;
	for (unsigned int i = 0; i < cnt; i++) {
		const char *pkgver = NULL, *desc = NULL;
		xbps_array_get_cstring_nocopy(s.results, i * 2, &pkgver);
		xbps_array_get_cstring_nocopy(s.results, i * 2 + 1, &desc);
		char name[256];
		xbps_pkg_name(name, sizeof name, pkgver);
		printf("%s %s%s%s-%s  %s%s%s\n",
		    xbps_pkgdb_get_pkg(&xh, pkgver) ? "[*]" : "[ ]",
		    BLD, name, RST, xbps_pkg_version(pkgver), DIM, desc, RST);
	}
	if (cnt == 0)
		printf("kipki: no results for '%s'\n", pat);
	else
		printf("\n%u package%s found\n", cnt, cnt == 1 ? "" : "s");
	xbps_object_release(s.results);
	return rv;
}

static void info_str(xbps_dictionary_t d, const char *key, const char *label)
{
	const char *v = NULL;
	if (xbps_dictionary_get_cstring_nocopy(d, key, &v) && v && *v)
		printf("%s%-12s%s %s\n", CYN, label, RST, v);
}

static void info_size(xbps_dictionary_t d, const char *key, const char *label)
{
	uint64_t v = 0;
	char b[8];
	if (!xbps_dictionary_get_uint64(d, key, &v) || !v)
		return;
	xbps_humanize_number(b, (int64_t)v);
	printf("%s%-12s%s %s\n", CYN, label, RST, b);
}

static void info_array(xbps_dictionary_t d, const char *key, const char *label)
{
	xbps_array_t a = xbps_dictionary_get(d, key);
	if (!a)
		return;
	printf("%s%-12s%s\n", CYN, label, RST);
	for (unsigned int i = 0; i < xbps_array_count(a); i++) {
		const char *s = NULL;
		if (xbps_array_get_cstring_nocopy(a, i, &s))
			printf("  %s\n", s);
	}
}

static int cmd_info(const char *pkg)
{
	xbps_dictionary_t d = xbps_rpool_get_pkg(&xh, pkg);
	if (!d)
		d = xbps_rpool_get_virtualpkg(&xh, pkg);
	if (!d) {
		fprintf(stderr, "kipki: '%s' not found in repositories\n", pkg);
		return ENOENT;
	}

	const char *pkgver = NULL;
	char name[256] = "";
	xbps_dictionary_get_cstring_nocopy(d, "pkgver", &pkgver);
	xbps_pkg_name(name, sizeof name, pkgver ? pkgver : "");

	printf("%s%s%s%s\n", BLD, GRN, pkgver ? pkgver : "?", RST);
	info_str(d, "short_desc", "summary");
	info_str(d, "homepage", "homepage");
	info_str(d, "license", "license");
	info_str(d, "maintainer", "maintainer");
	info_str(d, "architecture", "architecture");
	info_str(d, "repository", "repository");

	pkg_state_t st;
	if (name[0] && xbps_pkg_state_installed(&xh, name, &st) == 0)
		printf("%s%-12s%s installed (%s)\n", CYN, "state", RST,
		    st == XBPS_PKG_STATE_INSTALLED ? "ii" :
		    st == XBPS_PKG_STATE_UNPACKED ? "uu" : "hr");

	info_size(d, "installed_size", "install size");
	info_size(d, "filename-size", "download size");
	info_array(d, "run_depends", "dependencies");

	const char *ld = NULL;
	if (xbps_dictionary_get_cstring_nocopy(d, "long_desc", &ld) && ld &&
	    *ld)
		printf("%s%-12s%s %s\n", CYN, "description", RST, ld);
	return 0;
}

struct listctx {
	struct strs ver, desc, state;
};

static int list_cb(struct xbps_handle *xhp, xbps_object_t obj,
    const char *key, void *arg, bool *done)
{
	(void)xhp;
	(void)key;
	(void)done;
	struct listctx *lc = arg;
	const char *pkgver = NULL, *desc = NULL;
	pkg_state_t st = 0;

	xbps_dictionary_get_cstring_nocopy(obj, "pkgver", &pkgver);
	xbps_dictionary_get_cstring_nocopy(obj, "short_desc", &desc);
	if (!pkgver)
		return 0;
	xbps_pkg_state_dictionary(obj, &st);
	push(&lc->ver, strdup(pkgver));
	push(&lc->desc, strdup(desc ? desc : ""));
	push(&lc->state,
	    strdup(st == XBPS_PKG_STATE_INSTALLED ? "ii" :
	    st == XBPS_PKG_STATE_UNPACKED ? "uu" :
	    st == XBPS_PKG_STATE_HALF_REMOVED ? "hr" : "??"));
	return 0;
}

static int cmd_list(void)
{
	struct listctx lc = { 0 };
	int rv = norm(xbps_pkgdb_foreach_cb(&xh, list_cb, &lc));
	if (rv == ENOENT)
		rv = 0;
	else if (rv != 0)
		return rv;

	size_t align = 0;
	for (size_t i = 0; i < lc.ver.n; i++)
		if (strlen(lc.ver.v[i]) > align)
			align = strlen(lc.ver.v[i]);
	for (size_t i = 0; i < lc.ver.n; i++)
		printf("%s %-*s  %s\n", lc.state.v[i], (int)align,
		    lc.ver.v[i], lc.desc.v[i]);
	printf("\n%zu package%s installed\n", lc.ver.n,
	    lc.ver.n == 1 ? "" : "s");

	for (size_t i = 0; i < lc.ver.n; i++) {
		free(lc.ver.v[i]);
		free(lc.desc.v[i]);
		free(lc.state.v[i]);
	}
	free(lc.ver.v);
	free(lc.desc.v);
	free(lc.state.v);
	return 0;
}

static const char *const file_groups[] = {
	"files", "conf_files", "links", "dirs"
};

static int cmd_files(const char *pkg)
{
	char name[256];
	xbps_dictionary_t d;
	unsigned int n = 0;

	if (!xbps_pkg_name(name, sizeof name, pkg))
		snprintf(name, sizeof name, "%s", pkg);
	d = xbps_pkgdb_get_pkg_files(&xh, name);
	if (!d) {
		fprintf(stderr, "kipki: '%s' is not installed\n", pkg);
		return ENOENT;
	}
	for (size_t g = 0; g < sizeof file_groups / sizeof *file_groups; g++) {
		xbps_array_t a = xbps_dictionary_get(d, file_groups[g]);
		if (!a)
			continue;
		for (unsigned int i = 0; i < xbps_array_count(a); i++) {
			xbps_dictionary_t od = xbps_array_get(a, i);
			const char *file = NULL;
			if (!od ||
			    !xbps_dictionary_get_cstring_nocopy(od, "file",
			    &file))
				continue;
			if (g == 1)
				printf("%s%s%s\n", YEL, file, RST);
			else
				printf("%s\n", file);
			n++;
		}
	}
	printf("\n%u file%s\n", n, n == 1 ? "" : "s");
	return 0;
}

struct ownsctx {
	const char *pat;
	bool found;
};

static int owns_files_cb(struct xbps_handle *xhp, const char *pkgver,
    const char *key, void *arg)
{
	(void)xhp;
	struct ownsctx *o = arg;
	xbps_dictionary_t fd = xbps_pkgdb_get_pkg_files(xhp, pkgver);
	if (!fd)
		return 0;
	xbps_array_t a = xbps_dictionary_get(fd, key);
	if (!a)
		return 0;
	for (unsigned int i = 0; i < xbps_array_count(a); i++) {
		xbps_dictionary_t od = xbps_array_get(a, i);
		const char *file = NULL;
		if (!od ||
		    !xbps_dictionary_get_cstring_nocopy(od, "file", &file))
			continue;
		if (fnmatch(o->pat, file, FNM_PERIOD) == 0) {
			printf("%s: %s\n", pkgver, file);
			o->found = true;
		}
	}
	return 0;
}

static int owns_pkg_cb(struct xbps_handle *xhp, xbps_object_t obj,
    const char *key, void *arg, bool *done)
{
	(void)key;
	(void)done;
	struct ownsctx *o = arg;
	const char *pkgver = NULL;
	xbps_dictionary_get_cstring_nocopy(obj, "pkgver", &pkgver);
	if (!pkgver)
		return 0;
	for (size_t g = 0; g < sizeof file_groups / sizeof *file_groups; g++)
		owns_files_cb(xhp, pkgver, file_groups[g], o);
	return 0;
}

static int cmd_owns(const char *pat)
{
	struct ownsctx o = { .pat = pat };
	int rv = norm(xbps_pkgdb_foreach_cb(&xh, owns_pkg_cb, &o));
	if (rv == ENOENT)
		rv = 0;
	if (!o.found)
		printf("kipki: no package owns '%s'\n", pat);
	return rv;
}

static int cmd_deps(const char *pkg, bool full)
{
	bool inst = false;
	xbps_array_t a = NULL;
	xbps_dictionary_t d = xbps_pkgdb_get_pkg(&xh, pkg);

	if (d) {
		inst = true;
		if (full)
			a = xbps_pkgdb_get_pkg_fulldeptree(&xh, pkg);
	} else {
		d = xbps_rpool_get_pkg(&xh, pkg);
		if (d && full)
			a = xbps_rpool_get_pkg_fulldeptree(&xh, pkg);
	}
	if (!d) {
		fprintf(stderr, "kipki: '%s' not found\n", pkg);
		return ENOENT;
	}
	if (!a)
		a = xbps_dictionary_get(d, "run_depends");
	if (!a) {
		printf("(no dependencies)\n");
		return 0;
	}
	for (unsigned int i = 0; i < xbps_array_count(a); i++) {
		const char *s = NULL;
		if (xbps_array_get_cstring_nocopy(a, i, &s))
			printf("%s\n", s);
	}
	if (!inst)
		xbps_object_release(d);
	return 0;
}

static int cmd_revdeps(const char *pkg)
{
	xbps_array_t a = xbps_pkgdb_get_pkg_revdeps(&xh, pkg);
	if (!a)
		a = xbps_rpool_get_pkg_revdeps(&xh, pkg);
	if (!a || xbps_array_count(a) == 0) {
		printf("(no reverse dependencies)\n");
		return 0;
	}
	for (unsigned int i = 0; i < xbps_array_count(a); i++) {
		const char *s = NULL;
		if (xbps_array_get_cstring_nocopy(a, i, &s))
			printf("%s\n", s);
	}
	if (a)
		xbps_object_release(a);
	return 0;
}

static int cmd_orphans(void)
{
	xbps_array_t a = xbps_find_pkg_orphans(&xh, NULL);
	unsigned int n = a ? xbps_array_count(a) : 0;

	for (unsigned int i = 0; i < n; i++) {
		xbps_dictionary_t d = xbps_array_get(a, i);
		const char *pkgver = NULL;
		if (d && xbps_dictionary_get_cstring_nocopy(d, "pkgver",
		    &pkgver))
			printf("%s\n", pkgver);
	}
	if (n == 0)
		printf("no orphans\n");
	else
		printf("\n%u orphan%s found (kipki autoremove)\n", n,
		    n == 1 ? "" : "s");
	if (a)
		xbps_object_release(a);
	return 0;
}

static int cmd_hold_set(int argc, char **argv, bool set)
{
	for (int i = 0; i < argc; i++) {
		xbps_dictionary_t d = xbps_pkgdb_get_pkg(&xh, argv[i]);
		if (!d) {
			fprintf(stderr, "kipki: '%s' is not installed\n",
			    argv[i]);
			return ENOENT;
		}
		if (set)
			xbps_dictionary_set_bool(d, "hold", true);
		else
			xbps_dictionary_remove(d, "hold");
		printf("%s: %s\n", argv[i], set ? "held" : "unheld");
	}
	if (argc)
		return xbps_pkgdb_update(&xh, true, false);
	return 0;
}

static int hold_list_cb(struct xbps_handle *xhp, xbps_object_t obj,
    const char *key, void *arg, bool *done)
{
	(void)xhp;
	(void)key;
	(void)done;
	bool held = false;
	xbps_dictionary_get_bool(obj, "hold", &held);
	if (!held)
		return 0;
	struct strs *out = arg;
	const char *pkgver = NULL;
	xbps_dictionary_get_cstring_nocopy(obj, "pkgver", &pkgver);
	if (pkgver)
		push(out, strdup(pkgver));
	return 0;
}

static int cmd_hold_list(void)
{
	struct strs out = { 0 };
	int rv = norm(xbps_pkgdb_foreach_cb(&xh, hold_list_cb, &out));
	if (rv == ENOENT)
		rv = 0;
	for (size_t i = 0; i < out.n; i++) {
		printf("%s\n", out.v[i]);
		free(out.v[i]);
	}
	if (!out.n)
		printf("no packages on hold\n");
	free(out.v);
	return rv;
}

static int cmd_clean(void)
{
	DIR *d = opendir(xh.cachedir);
	uint64_t total = 0;
	unsigned int n = 0;
	char b[8];

	if (!d) {
		printf("cache is empty (%s)\n", xh.cachedir);
		return 0;
	}
	struct dirent *e;
	while ((e = readdir(d)) != NULL) {
		if (!strstr(e->d_name, ".xbps"))
			continue;
		char p[1024];
		struct stat sb;
		snprintf(p, sizeof p, "%s/%s", xh.cachedir, e->d_name);
		if (stat(p, &sb) != 0)
			continue;
		unlink(p);
		total += (uint64_t)sb.st_size;
		n++;
	}
	closedir(d);
	xbps_humanize_number(b, (int64_t)total);
	printf("removed %u file%s, %s freed (%s)\n", n, n == 1 ? "" : "s", b,
	    xh.cachedir);
	return 0;
}

static int cmd_log(void)
{
	FILE *f = fopen(logpath, "r");
	if (!f) {
		printf("log is empty (%s)\n", logpath);
		return 0;
	}
	int ch;
	while ((ch = fgetc(f)) != EOF)
		fputc(ch, stdout);
	fclose(f);
	return 0;
}

static void usage(bool fail)
{
	fputs(
	    "kipki " VERSION " - KiniNi package manager (libxbps " XBPS_RELVER ")\n\n"
	    "usage: kipki [OPTIONS] COMMAND [ARGS...]\n\n"
	    "options:\n"
	    "  -r ROOT      operate on alternative rootdir\n"
	    "  -R REPO      add repository URL\n"
	    "  -c CACHEDIR  cache directory\n"
	    "  -C CONFDIR   xbps configuration directory\n"
	    "  -y           assume yes\n"
	    "  -n           dry run\n"
	    "  -f           force (reinstall / recursive remove)\n"
	    "  -v           verbose\n"
	    "  -d           debug\n"
	    "  -V           version\n\n"
	    "commands:\n"
	    "  sync              sync remote repository indexes\n"
	    "  install PKG...    install packages (i, add)\n"
	    "  upgrade [PKG...]  upgrade all or given packages (up)\n"
	    "  remove PKG...     remove packages (rm, del)\n"
	    "  autoremove        remove orphan packages (auto)\n"
	    "  search PAT        search repositories (se)\n"
	    "  info PKG          show package details (show)\n"
	    "  list              list installed packages (ls)\n"
	    "  files PKG         list files of installed package\n"
	    "  owns FILE         find package owning file (owner)\n"
	    "  deps PKG          dependencies (-f for full tree)\n"
	    "  revdeps PKG       reverse dependencies\n"
	    "  orphans           list orphan packages\n"
	    "  hold [PKG...]     put on hold / list held\n"
	    "  unhold PKG...     release hold\n"
	    "  clean             clear package cache\n"
	    "  log               show transaction log\n", fail ? stderr : stdout);
	exit(fail ? 1 : 0);
}

int main(int argc, char **argv)
{
	const char *root = NULL, *cachedir = NULL, *repo = NULL,
	    *confdir = NULL;
	int c;

	while ((c = getopt(argc, argv, "+r:R:c:C:yfnvdVh")) != -1) {
		switch (c) {
		case 'r': root = optarg; break;
		case 'R': repo = optarg; break;
		case 'c': cachedir = optarg; break;
		case 'C': confdir = optarg; break;
		case 'y': yes_flag = true; break;
		case 'n': dry_run = true; break;
		case 'f': force = true; break;
		case 'v': verbose = true; break;
		case 'd': debug = true; break;
		case 'V':
			printf("kipki %s\nlibxbps %s\n", VERSION, XBPS_RELVER);
			return 0;
		default:
			usage(true);
		}
	}
	argc -= optind;
	argv += optind;
	if (argc < 1)
		usage(true);
	const char *cmd = *argv++;
	argc--;

	use_color = isatty(1) && !getenv("NO_COLOR");

	memset(&xh, 0, sizeof xh);
	if (root)
		xbps_strlcpy(xh.rootdir, root, sizeof xh.rootdir);
	parse_conf();
	if (cachedir)
		xbps_strlcpy(xh.cachedir, cachedir, sizeof xh.cachedir);
	else if (cfg_cachedir)
		xbps_strlcpy(xh.cachedir, cfg_cachedir, sizeof xh.cachedir);
	if (confdir)
		xbps_strlcpy(xh.confdir, confdir, sizeof xh.confdir);
	if (verbose)
		xh.flags |= XBPS_FLAG_VERBOSE;
	if (debug) {
		xh.flags |= XBPS_FLAG_DEBUG;
		xbps_debug_level = 1;
	}
	if (cfg_repos)
		xh.flags |= XBPS_FLAG_IGNORE_CONF_REPOS;
	xh.state_cb = state_cb;
	xh.fetch_cb = fetch_cb;

	const char *r = xh.rootdir[0] ? xh.rootdir : "/";
	const char *sep = r[strlen(r) - 1] == '/' ? "" : "/";
	snprintf(logpath, sizeof logpath, "%s%svar/log/kipki.log", r, sep);

	int rv = xbps_init(&xh);
	if (rv != 0) {
		fprintf(stderr, "kipki: failed to initialize libxbps: %s\n",
		    strerror(rv));
		return rv;
	}

	if (cfg_repos) {
		xbps_array_t arr = xbps_array_create();
		char *dup = strdup(cfg_repos), *tok, *save = NULL;
		for (tok = strtok_r(dup, " ,", &save); tok;
		    tok = strtok_r(NULL, " ,", &save))
			xbps_array_add_cstring(arr, tok);
		free(dup);
		xh.repositories = arr;
	}
	if (repo)
		xbps_repo_store(&xh, repo);

	if (!strcmp(cmd, "sync") || !strcmp(cmd, "y"))
		rv = cmd_sync();
	else if (!strcmp(cmd, "install") || !strcmp(cmd, "i") ||
	    !strcmp(cmd, "add"))
		rv = cmd_install(argc, argv);
	else if (!strcmp(cmd, "upgrade") || !strcmp(cmd, "up"))
		rv = cmd_upgrade(argc, argv);
	else if (!strcmp(cmd, "remove") || !strcmp(cmd, "rm") ||
	    !strcmp(cmd, "del"))
		rv = cmd_remove(argc, argv);
	else if (!strcmp(cmd, "autoremove") || !strcmp(cmd, "auto"))
		rv = cmd_autoremove();
	else if (!strcmp(cmd, "search") || !strcmp(cmd, "se"))
		rv = argc ? cmd_search(argv[0]) : (usage(true), 1);
	else if (!strcmp(cmd, "info") || !strcmp(cmd, "show"))
		rv = argc ? cmd_info(argv[0]) : (usage(true), 1);
	else if (!strcmp(cmd, "list") || !strcmp(cmd, "ls"))
		rv = cmd_list();
	else if (!strcmp(cmd, "files"))
		rv = argc ? cmd_files(argv[0]) : (usage(true), 1);
	else if (!strcmp(cmd, "owns") || !strcmp(cmd, "owner"))
		rv = argc ? cmd_owns(argv[0]) : (usage(true), 1);
	else if (!strcmp(cmd, "deps"))
		rv = argc ? cmd_deps(argv[0], force) : (usage(true), 1);
	else if (!strcmp(cmd, "revdeps"))
		rv = argc ? cmd_revdeps(argv[0]) : (usage(true), 1);
	else if (!strcmp(cmd, "orphans"))
		rv = cmd_orphans();
	else if (!strcmp(cmd, "hold"))
		rv = cmd_hold_set(argc, argv, true);
	else if (!strcmp(cmd, "unhold"))
		rv = cmd_hold_set(argc, argv, false);
	else if (!strcmp(cmd, "held"))
		rv = cmd_hold_list();
	else if (!strcmp(cmd, "clean"))
		rv = cmd_clean();
	else if (!strcmp(cmd, "log"))
		rv = cmd_log();
	else if (!strcmp(cmd, "version"))
		printf("kipki %s\nlibxbps %s\n", VERSION, XBPS_RELVER);
	else if (!strcmp(cmd, "help"))
		usage(false);
	else {
		fprintf(stderr, "kipki: unknown command '%s'\n", cmd);
		usage(true);
	}

	xbps_end(&xh);
	return rv != 0 ? 1 : 0;
}

