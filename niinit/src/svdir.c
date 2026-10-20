#include <dirent.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define MAXSVC 512

struct svc {
        char name[256];
        pid_t pid;
};

static struct svc svcs[MAXSVC];
static size_t nsvcs;
static volatile sig_atomic_t stopflag;
static char basedir[512];

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
