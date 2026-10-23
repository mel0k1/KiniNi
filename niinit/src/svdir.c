/*
 * service dependencies: a service directory may carry a "deps" file with
 * whitespace-separated names of services it needs ('#' starts a comment).
 * a service is only spawned once every dependency is present in the
 * servicedir AND has stat "up"; until then its stat file says
 * "blocked (...)" and niinit-svdir retries on every scan. dependencies
 * resolve transitively (a blocked dep eventually starts or stays
 * blocked); a dependency cycle keeps all involved services blocked and
 * visible in their stat files. runit semantics apply at runtime: a
 * running service is NOT stopped when its dependency goes down.
 */

#include <dirent.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define MAXSVC 512
#define MSGLEN 160

struct svc {
        char name[256];
        pid_t pid;
};

static struct svc svcs[MAXSVC];
static size_t nsvcs;
static volatile sig_atomic_t stopflag;
static char basedir[512];

struct blocked {
        char name[256];
        char msg[MSGLEN];
};
static struct blocked blockedsvcs[MAXSVC];
static size_t nblocked;

static void on_stop(int sig)
{
        (void)sig;
        stopflag = 1;
}

static struct svc *find(const char *name)
{
        for (size_t i = 0; i < nsvcs; i++)
                if (strcmp(svcs[i].name, name) == 0)
                        return &svcs[i];
        return NULL;
}

static void drop(pid_t pid)
{
        for (size_t i = 0; i < nsvcs; i++) {
                if (svcs[i].pid == pid) {
                        svcs[i] = svcs[--nsvcs];
                        return;
                }
        }
}

static void reap(void)
{
        int st;
        pid_t p;
        while ((p = waitpid(-1, &st, WNOHANG)) > 0)
                drop(p);
}

/* are all dependencies of svc up? 0 = yes, -1 = no (msg says why) */
static int deps_up(const char *svc, char *msg, size_t n)
{
        char path[1024];
        FILE *f;

        snprintf(path, sizeof path, "%s/%s/deps", basedir, svc);
        f = fopen(path, "r");
        if (!f)
                return 0;
        int rc = 0;
        char line[1024];
        while (rc == 0 && fgets(line, sizeof line, f)) {
                char *hash = strchr(line, '#');
                if (hash)
                        *hash = '\0';
                for (char *tok = strtok(line, " \t\r\n"); tok;
                    tok = strtok(NULL, " \t\r\n")) {
                        char dpath[1024];
                        struct stat sb;
                        snprintf(dpath, sizeof dpath, "%s/%s", basedir, tok);
                        if (stat(dpath, &sb) != 0 || !S_ISDIR(sb.st_mode)) {
                                snprintf(msg, n, "dep '%s' is not enabled", tok);
                                rc = -1;
                                break;
                        }
                        snprintf(dpath, sizeof dpath, "%s/%s/stat", basedir,
                            tok);
                        FILE *sf = fopen(dpath, "r");
                        char buf[32] = "";
                        if (sf) {
                                size_t k = fread(buf, 1, sizeof buf - 1, sf);
                                buf[k] = '\0';
                                fclose(sf);
                        }
                        if (strncmp(buf, "up", 2) != 0) {
                                snprintf(msg, n, "waiting for dep '%s'", tok);
                                rc = -1;
                                break;
                        }
                }
        }
        fclose(f);
        return rc;
}

/* publish the blocked state, log only on change */
static void block(const char *svc, const char *msg)
{
        struct blocked *b = NULL;

        for (size_t i = 0; i < nblocked; i++) {
                if (strcmp(blockedsvcs[i].name, svc) == 0) {
                        b = &blockedsvcs[i];
                        break;
                }
        }
        if (b && strcmp(b->msg, msg) == 0)
                return;         /* no change - no spam every 5s */
        if (!b && nblocked < MAXSVC) {
                b = &blockedsvcs[nblocked++];
                snprintf(b->name, sizeof b->name, "%s", svc);
        }
        if (b)
                snprintf(b->msg, sizeof b->msg, "%s", msg);
        char spath[1024];
        snprintf(spath, sizeof spath, "%s/%s/stat", basedir, svc);
        FILE *f = fopen(spath, "w");
        if (f) {
                fprintf(f, "blocked (%s)\n", msg);
                fclose(f);
        }
        fprintf(stderr, "niinit-svdir: %s: blocked (%s)\n", svc, msg);
}

/* the service is about to be supervised: forget the blocked state */
static void unblock(const char *svc)
{
        for (size_t i = 0; i < nblocked; i++) {
                if (strcmp(blockedsvcs[i].name, svc) == 0) {
                        blockedsvcs[i] = blockedsvcs[--nblocked];
                        return;
                }
        }
}

static void scan(void)
{
        DIR *d = opendir(basedir);
        if (!d)
                return;
        struct dirent *e;
        while ((e = readdir(d)) != NULL) {
                if (e->d_name[0] == '.' || find(e->d_name))
                        continue;
                char run[1024];
                char path[1024];
                struct stat sb;
                snprintf(run, sizeof run, "%s/%.255s/run", basedir, e->d_name);
                snprintf(path, sizeof path, "%s/%.255s", basedir, e->d_name);
                if (stat(run, &sb) != 0 || !S_ISREG(sb.st_mode) ||
                    access(run, X_OK) != 0)
                        continue;
                char msg[MSGLEN];
                if (deps_up(e->d_name, msg, sizeof msg) != 0) {
                        block(e->d_name, msg);
                        continue;
                }
                unblock(e->d_name);
                pid_t p = fork();
                if (p < 0)
                        break;
                if (p == 0) {
                        execlp("niinit-sv", "niinit-sv", path, (char *)0);
                        _exit(127);
                }
                if (nsvcs < MAXSVC) {
                        snprintf(svcs[nsvcs].name, sizeof svcs[nsvcs].name,
                            "%s", e->d_name);
                        svcs[nsvcs].pid = p;
                        nsvcs++;
                } else {
                        kill(p, SIGTERM);
                }
        }
        closedir(d);
}

static void prune(void)
{
        for (size_t i = 0; i < nsvcs; i++) {
                char path[1024];
                struct stat sb;
                snprintf(path, sizeof path, "%s/%.255s", basedir, svcs[i].name);
                if (stat(path, &sb) != 0)
                        kill(svcs[i].pid, SIGTERM);
        }
}

int main(int argc, char **argv)
{
        snprintf(basedir, sizeof basedir, "%s",
            argc > 1 ? argv[1] : "/etc/niinit/services");
        signal(SIGTERM, on_stop);
        signal(SIGINT, on_stop);

        while (!stopflag) {
                reap();
                prune();
                scan();
                sleep(5);
        }

        for (size_t i = 0; i < nsvcs; i++)
                kill(svcs[i].pid, SIGTERM);
        int st;
        while (waitpid(-1, &st, 0) > 0 || errno == EINTR)
                ;
        return 0;
}
