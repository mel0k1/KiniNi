/*
 * niinit-parallel - run boot tasks in parallel, honoring dependencies
 *
 * usage: niinit-parallel [-q] <dir>
 *
 * every executable regular file directly inside <dir> is a task. a task
 * named <name> may declare prerequisites in a <name>.deps file next to
 * it: whitespace-separated names of sibling tasks ('#' starts a comment).
 *
 * scheduling:
 *   - tasks whose dependencies are all satisfied start at once, so
 *     independent work overlaps (udevd trigger and sysctl, say);
 *   - a task waits until all of its dependencies have finished ok;
 *   - a task whose dependency failed or was skipped is skipped too
 *     (its dependents then skip as well - failures cascade);
 *   - a dependency cycle or a missing dependency is reported and fails
 *     the tasks involved instead of hanging forever.
 *
 * output: one line per task ("ok", "failed (rc)", "skipped (dep ...)").
 * the exit status is 0 only if every task ran successfully; boot scripts
 * decide whether that is fatal or just worth a warning.
 *
 * C99, no dependencies. used by /etc/niinit/1 for the independent parts
 * of stage 1 (see /etc/niinit/1.d/).
 */

#include <dirent.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAXTASKS 512
#define MAXDEPS  64
#define NAMELEN  256
#define PATHLEN  1024

enum { T_PENDING = 0, T_RUNNING, T_OK, T_FAIL, T_SKIP };

struct task {
        char name[NAMELEN];
        char path[PATHLEN + NAMELEN];
        int deps[MAXDEPS];
        size_t ndeps;
        char missing[NAMELEN];  /* first dep name not found among tasks */
        pid_t pid;
        int state;
        struct timespec t0;
};

static struct task tasks[MAXTASKS];
static size_t ntasks;
static int quiet;
static char dirbuf[PATHLEN];      /* the task directory, length-checked */

/* single write, so parallel tasks do not tear our lines apart */
static void say(const char *fmt, ...)
{
        char buf[1024];
        va_list ap;
        int n;

        if (quiet)
                return;
        va_start(ap, fmt);
        n = vsnprintf(buf, sizeof buf, fmt, ap);
        va_end(ap);
        if (n > 0) {
                if (n >= (int)sizeof buf)
                        n = (int)sizeof buf - 1;
                buf[n++] = '\n';
                ssize_t rc = write(STDOUT_FILENO, buf, (size_t)n);
                (void)rc;
        }
}

static struct task *find(const char *name)
{
        for (size_t i = 0; i < ntasks; i++)
                if (strcmp(tasks[i].name, name) == 0)
                        return &tasks[i];
        return NULL;
}

static double since(const struct timespec *t0)
{
        struct timespec now;

        clock_gettime(CLOCK_MONOTONIC, &now);
        return (double)(now.tv_sec - t0->tv_sec) +
            (double)(now.tv_nsec - t0->tv_nsec) / 1e9;
}

static void load_tasks(const char *dir)
{
        DIR *d = opendir(dir);

        if (!d) {
                fprintf(stderr, "niinit-parallel: opendir %s: %s\n", dir,
                    strerror(errno));
                exit(1);
        }
        struct dirent *e;
        while ((e = readdir(d)) != NULL) {
                if (e->d_name[0] == '.')
                        continue;
                size_t len = strlen(e->d_name);
                if (len >= 5 && strcmp(e->d_name + len - 5, ".deps") == 0)
                        continue;
                if (ntasks >= MAXTASKS) {
                        fprintf(stderr,
                            "niinit-parallel: too many tasks (max %d)\n",
                            MAXTASKS);
                        exit(1);
                }
                struct task *t = &tasks[ntasks];
                memset(t, 0, sizeof *t);
                snprintf(t->name, sizeof t->name, "%s", e->d_name);
                snprintf(t->path, sizeof t->path, "%s/%s", dir, e->d_name);
                struct stat sb;
                if (stat(t->path, &sb) != 0 || !S_ISREG(sb.st_mode) ||
                    access(t->path, X_OK) != 0)
                        continue;       /* not an executable task */
                ntasks++;
        }
        closedir(d);

        /* resolve dependencies */
        for (size_t i = 0; i < ntasks; i++) {
                struct task *t = &tasks[i];
                /* dir is length-checked in main, name is <= NAMELEN-1,
                 * so the join below cannot truncate - gcc cannot prove
                 * it through the memcpy, silence the false positive */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wformat-truncation"
                char dpath[PATHLEN + NAMELEN + 8];
                snprintf(dpath, sizeof dpath, "%s/%s.deps", dir, t->name);
#pragma GCC diagnostic pop
                FILE *f = fopen(dpath, "r");
                if (!f)
                        continue;
                char line[1024];
                while (fgets(line, sizeof line, f)) {
                        char *hash = strchr(line, '#');
                        if (hash)
                                *hash = '\0';
                        for (char *tok = strtok(line, " \t\r\n"); tok;
                            tok = strtok(NULL, " \t\r\n")) {
                                struct task *dep = find(tok);
                                if (!dep) {
                                        if (!t->missing[0])
                                                snprintf(t->missing,
                                                    sizeof t->missing, "%s",
                                                    tok);
                                        continue;
                                }
                                if (dep == t) {
                                        fprintf(stderr,
                                            "niinit-parallel: %s depends on "
                                            "itself\n", t->name);
                                        exit(1);
                                }
                                if (t->ndeps < MAXDEPS)
                                        t->deps[t->ndeps++] =
                                            (int)(dep - tasks);
                        }
                }
                fclose(f);
        }
}

static void start_task(struct task *t)
{
        pid_t p = fork();

        if (p < 0) {
                say("niinit-parallel: %s: fork: %s", t->name,
                    strerror(errno));
                t->state = T_FAIL;
                return;
        }
        if (p == 0) {
                execl(t->path, t->path, (char *)0);
                /* a script without a shebang fails with ENOEXEC: fall
                 * back to /bin/sh like sysvinit and niinit-sv do */
                if (errno == ENOEXEC)
                        execl("/bin/sh", "sh", t->path, (char *)0);
                _exit(127);
        }
        t->pid = p;
        t->state = T_RUNNING;
        clock_gettime(CLOCK_MONOTONIC, &t->t0);
}

/* collect one finished child; returns 1 when a task was reaped */
static int reap_one(int block)
{
        int st;

        pid_t p = waitpid(-1, &st, block ? 0 : WNOHANG);
        if (p <= 0)
                return 0;
        for (size_t i = 0; i < ntasks; i++) {
                struct task *t = &tasks[i];
                if (t->state != T_RUNNING || t->pid != p)
                        continue;
                t->pid = 0;
                int rc = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
                t->state = rc == 0 ? T_OK : T_FAIL;
                say("niinit-parallel: %s: %s (%.2fs)", t->name,
                    rc == 0 ? "ok" : "failed", since(&t->t0));
                if (rc != 0 && !quiet) {
                        char buf[64];
                        int n = snprintf(buf, sizeof buf, "exit %d\n", rc);
                        ssize_t w = write(STDERR_FILENO, buf, (size_t)n);
                        (void)w;
                }
                return 1;
        }
        return 1;       /* foreign child (should not happen) - reaped */
}

/* can the task start right now? 0 = yes, 1 = blocked, -1 = skip */
static int dep_state(const struct task *t, char *why, size_t n)
{
        for (size_t i = 0; i < t->ndeps; i++) {
                const struct task *d = &tasks[t->deps[i]];
                switch (d->state) {
                case T_OK:
                        continue;
                case T_FAIL:
                case T_SKIP:
                        snprintf(why, n, "%s", d->name);
                        return -1;
                default:
                        snprintf(why, n, "%s", d->name);
                        return 1;
                }
        }
        return 0;
}

int main(int argc, char **argv)
{
        if (argc > 1 && strcmp(argv[1], "-q") == 0) {
                quiet = 1;
                argc--;
                argv++;
        }
        if (argc != 2) {
                fprintf(stderr, "usage: niinit-parallel [-q] <dir>\n");
                return 1;
        }
        if (strlen(argv[1]) >= sizeof dirbuf) {
                fprintf(stderr, "niinit-parallel: %s: path too long\n",
                    argv[1]);
                return 1;
        }
        memcpy(dirbuf, argv[1], strlen(argv[1]) + 1);
        load_tasks(dirbuf);

        size_t pending = 0;
        for (size_t i = 0; i < ntasks; i++)
                if (tasks[i].state == T_PENDING)
                        pending++;

        while (pending > 0) {
                int progress = 0;
                char why[NAMELEN];

                for (size_t i = 0; i < ntasks; i++) {
                        struct task *t = &tasks[i];
                        if (t->state != T_PENDING)
                                continue;
                        if (t->missing[0]) {
                                t->state = T_SKIP;
                                pending--;
                                progress = 1;
                                say("niinit-parallel: %s: skipped (missing "
                                    "dep '%s')", t->name, t->missing);
                                continue;
                        }
                        int ds = dep_state(t, why, sizeof why);
                        if (ds == 0) {
                                start_task(t);
                                pending--;
                                progress = 1;
                        } else if (ds < 0) {
                                t->state = T_SKIP;
                                pending--;
                                progress = 1;
                                say("niinit-parallel: %s: skipped (dep %s "
                                    "failed)", t->name, why);
                        }
                }

                if (pending == 0)
                        break;

                /* a finished dependency changes what is startable: reap
                 * first and re-evaluate before concluding anything */
                int reaped = 0;
                while (reap_one(0))
                        reaped = 1;
                if (reaped)
                        continue;

                int running = 0;
                for (size_t i = 0; i < ntasks; i++)
                        if (tasks[i].state == T_RUNNING)
                                running++;

                if (progress)
                        continue;
                if (running > 0) {
                        reap_one(1);    /* block until a task finishes */
                        continue;
                }
                /* nothing startable, nothing running: a dependency cycle */
                for (size_t i = 0; i < ntasks; i++) {
                        struct task *t = &tasks[i];
                        if (t->state != T_PENDING)
                                continue;
                        t->state = T_FAIL;
                        pending--;
                        say("niinit-parallel: %s: failed (dependency cycle)",
                            t->name);
                }
        }

        while (reap_one(1))
                ;       /* drain remaining running tasks */

        int bad = 0;
        for (size_t i = 0; i < ntasks; i++)
                if (tasks[i].state == T_FAIL || tasks[i].state == T_SKIP)
                        bad++;
        return bad > 0 ? 1 : 0;
}
