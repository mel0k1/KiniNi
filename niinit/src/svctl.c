/*
 * svctl - control niinit services
 *
 *   svctl [-w SEC] status [SERVICE...]
 *   svctl [-w SEC] up|down|restart|once|start|stop|check SERVICE...
 *   svctl [-w SEC] pause|cont|hup|alarm|int|quit|usr1|usr2|term SERVICE...
 *   svctl [-w SEC] exit|shutdown SERVICE...
 *   svctl enable|disable SERVICE...
 *   svctl reboot|poweroff|halt
 *
 * enable/disable manage entries of $NIINIT_SVDIR (default
 * /etc/niinit/services) by symlinking services from
 * $NIINIT_SVAVAIL (default /etc/niinit/services-available).
 */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static int waitsec = -1;

static const char *svdir(void)
{
        const char *d = getenv("NIINIT_SVDIR");
        return d && *d ? d : "/etc/niinit/services";
}

static const char *svavail(void)
{
        const char *d = getenv("NIINIT_SVAVAIL");
        return d && *d ? d : "/etc/niinit/services-available";
}

static int color_ok(void)
{
        return isatty(1) && !getenv("NO_COLOR");
}

static int send_cmd(const char *svc, char cmd)
{
        char path[1024];

        snprintf(path, sizeof path, "%s/%s/control", svdir(), svc);
        int fd = open(path, O_WRONLY | O_NONBLOCK);
        if (fd < 0) {
                fprintf(stderr, "svctl: %s: not supervised (%s)\n", svc,
                    strerror(errno));
                return 1;
        }
        if (write(fd, &cmd, 1) != 1) {
                fprintf(stderr, "svctl: %s: write failed\n", svc);
                close(fd);
                return 1;
        }
        close(fd);
        return 0;
}

/* read raw state line of the service into buf */
static void read_stat(const char *svc, char *buf, size_t n)
{
        char path[1024];

        snprintf(path, sizeof path, "%s/%s/stat", svdir(), svc);
        buf[0] = '\0';
        int fd = open(path, O_RDONLY);
        if (fd >= 0) {
                if (read(fd, buf, n - 1) < 0)
                        buf[0] = '\0';
                close(fd);
        }
        buf[strcspn(buf, "\n")] = '\0';
}

/* read service pid (0 if none) */
static long read_pid(const char *svc)
{
        char path[1024];
        long pid = 0;

        snprintf(path, sizeof path, "%s/%s/pid", svdir(), svc);
        FILE *f = fopen(path, "r");
        if (f) {
                if (fscanf(f, "%ld", &pid) != 1)
                        pid = 0;
                fclose(f);
        }
        return pid;
}

/* seconds the service process has been running (from /proc) */
static long uptime_of(long pid)
{
        char path[64], buf[2048];
        long startticks = 0;
        long hz = sysconf(_SC_CLK_TCK);
        double bootuptime = 0.0;
        FILE *f;

        if (pid <= 0 || hz <= 0)
                return 0;
        snprintf(path, sizeof path, "/proc/%ld/stat", pid);
        f = fopen(path, "r");
        if (!f)
                return 0;
        if (fgets(buf, sizeof buf, f)) {
                char *p = strrchr(buf, ')');
                if (p && p[1] == ' ')
                        sscanf(p + 2, "%*c %*d %*d %*d %*d %*d %*d %*u %*u "
                            "%*u %*u %*u %*u %*u %*u %*u %*d %*d %*d %*d "
                            "%ld", &startticks);
        }
        fclose(f);
        f = fopen("/proc/uptime", "r");
        if (f) {
                fscanf(f, "%lf", &bootuptime);
                fclose(f);
        }
        long up = (long)bootuptime - startticks / hz;
        return up > 0 ? up : 0;
}

static int status_one(const char *svc)
{
        char path[1024], buf[64];

        snprintf(path, sizeof path, "%s/%s/stat", svdir(), svc);
        if (access(path, R_OK) != 0) {
                printf("%-24s %s\n", svc, "not supervised");
                return 4;
        }
        read_stat(svc, buf, sizeof buf);
        int up = strncmp(buf, "up", 2) == 0;
        char state[96];
        if (up) {
                long pid = read_pid(svc);
                long secs = uptime_of(pid);
                snprintf(state, sizeof state, "up (pid %ld) %lds", pid, secs);
        } else {
                snprintf(state, sizeof state, "%s", buf[0] ? buf : "down");
        }

        const char *g = color_ok() ? "\033[32m" : "";
        const char *r = color_ok() ? "\033[31m" : "";
        const char *d = color_ok() ? "\033[0m" : "";
        printf("%-24s %s%-24s%s\n", svc, up ? g : r, state, d);
        return up ? 0 : 3;
}

/* wait until the service reaches the state; returns 0 on success */
static int wait_state(const char *svc, int want)
{
        int waited = 0;
        char buf[64];

        if (waitsec < 0)
                waitsec = 7;
        for (;;) {
                read_stat(svc, buf, sizeof buf);
                int up = strncmp(buf, "up", 2) == 0;
                int down = strncmp(buf, "down", 4) == 0;
                if (want && up)
                        return 0;
                if (!want && down)
                        return 0;
                if (waited >= waitsec)
                        return 1;
                struct timespec ts = { 0, 200 * 1000 * 1000 };
                nanosleep(&ts, NULL);
                waited++;
        }
}

static int signal_pid1(int sig)
{
        if (kill(1, sig) != 0) {
                fprintf(stderr, "svctl: kill(1): %s\n", strerror(errno));
                return 1;
        }
        return 0;
}

static int cmd_enable(int argc, char **argv, int on)
{
        int rc = 0;
        char dst[1024];

        for (int i = 0; i < argc; i++) {
                snprintf(dst, sizeof dst, "%s/%s", svdir(), argv[i]);
                if (on) {
                        char abs[1024];
                        snprintf(abs, sizeof abs, "%s/%s", svavail(), argv[i]);
                        struct stat sb;
                        if (stat(abs, &sb) != 0 || !S_ISDIR(sb.st_mode)) {
                                fprintf(stderr, "svctl: enable %s: %s: no such service\n",
                                    argv[i], abs);
                                rc = 1;
                                continue;
                        }
                        /* absolute symlink is clearer and svdir follows it */
                        if (symlink(abs, dst) != 0 && errno != EEXIST) {
                                fprintf(stderr, "svctl: enable %s: %s\n",
                                    argv[i], strerror(errno));
                                rc = 1;
                        }
                } else {
                        struct stat sb;
                        if (lstat(dst, &sb) != 0)
                                continue;
                        if (!S_ISLNK(sb.st_mode)) {
                                fprintf(stderr, "svctl: disable %s: not a symlink, "
                                    "remove it manually\n", argv[i]);
                                rc = 1;
                                continue;
                        }
                        if (unlink(dst) != 0) {
                                fprintf(stderr, "svctl: disable %s: %s\n",
                                    argv[i], strerror(errno));
                                rc = 1;
                        }
                }
        }
        return rc;
}

static void usage(void)
{
        fputs("usage: svctl [-w SEC] status [SERVICE...]\n"
            "       svctl [-w SEC] up|down|restart|once|start|stop|check "
            "SERVICE...\n"
            "       svctl [-w SEC] pause|cont|hup|alarm|int|quit|usr1|usr2|"
            "term SERVICE...\n"
            "       svctl [-w SEC] exit|shutdown SERVICE...\n"
            "       svctl enable|disable SERVICE...\n"
            "       svctl reboot|poweroff|halt\n", stderr);
}

int main(int argc, char **argv)
{
        int opt;
        const char *self = strrchr(argv[0], '/');

        self = self ? self + 1 : argv[0];

        while ((opt = getopt(argc, argv, "+w:")) != -1) {
                switch (opt) {
                case 'w':
                        waitsec = atoi(optarg);
                        break;
                default:
                        usage();
                        return 1;
                }
        }
        argc -= optind;
        argv += optind;

        if (strcmp(self, "reboot") == 0)
                return signal_pid1(SIGCONT);
        if (strcmp(self, "poweroff") == 0)
                return signal_pid1(SIGINT);
        if (strcmp(self, "halt") == 0)
                return signal_pid1(SIGUSR1);

        if (argc < 1) {
                usage();
                return 1;
        }
        const char *cmd = argv[0];

        if (strcmp(cmd, "reboot") == 0)
                return signal_pid1(SIGCONT);
        if (strcmp(cmd, "poweroff") == 0)
                return signal_pid1(SIGINT);
        if (strcmp(cmd, "halt") == 0)
                return signal_pid1(SIGUSR1);

        if (strcmp(cmd, "enable") == 0)
                return argc < 2 ? (usage(), 1) : cmd_enable(argc - 1,
                    argv + 1, 1);
        if (strcmp(cmd, "disable") == 0)
                return argc < 2 ? (usage(), 1) : cmd_enable(argc - 1,
                    argv + 1, 0);

        if (strcmp(cmd, "status") == 0) {
                int rc = 0;
                if (argc > 1) {
                        for (int i = 1; i < argc; i++)
                                rc |= status_one(argv[i]);
                } else {
                        const char *d = svdir();
                        DIR *dp = opendir(d);
                        if (!dp) {
                                fprintf(stderr, "svctl: opendir %s: %s\n", d,
                                    strerror(errno));
                                return 1;
                        }
                        struct dirent *e;
                        while ((e = readdir(dp)) != NULL) {
                                if (e->d_name[0] == '.')
                                        continue;
                                char path[1024];
                                snprintf(path, sizeof path, "%s/%s", d,
                                    e->d_name);
                                struct stat sb;
                                if (stat(path, &sb) != 0 ||
                                    !S_ISDIR(sb.st_mode))
                                        continue;
                                rc |= status_one(e->d_name);
                        }
                        closedir(dp);
                }
                return rc;
        }

        static const struct {
                const char *name;
                char cmd;
                int waitmode; /* 0 none, 1 wait up, 2 wait down */
        } cmds[] = {
                { "up", 'u', 0 },       { "down", 'd', 0 },
                { "restart", 't', 0 },  { "term", 't', 0 },
                { "once", 'o', 0 },     { "pause", 'p', 0 },
                { "cont", 'c', 0 },     { "hup", 'h', 0 },
                { "alarm", 'a', 0 },    { "int", 'i', 0 },
                { "quit", 'q', 0 },     { "usr1", '1', 0 },
                { "usr2", '2', 0 },     { "kill", 'k', 0 },
                { "exit", 'x', 0 },     { "shutdown", 'x', 0 },
                { "start", 'u', 1 },    { "stop", 'd', 2 },
        };

        if (argc < 2) {
                usage();
                return 1;
        }
        for (size_t i = 0; i < sizeof cmds / sizeof cmds[0]; i++) {
                if (strcmp(cmd, cmds[i].name) != 0)
                        continue;
                int rc = 0;
                for (int j = 1; j < argc; j++) {
                        rc |= send_cmd(argv[j], cmds[i].cmd);
                        if (cmds[i].waitmode == 1)
                                rc |= wait_state(argv[j], 1);
                        else if (cmds[i].waitmode == 2)
                                rc |= wait_state(argv[j], 0);
                }
                return rc;
        }

        if (strcmp(cmd, "check") == 0) {
                int rc = 0;
                for (int j = 1; j < argc; j++) {
                        if (wait_state(argv[j], 1) != 0) {
                                fprintf(stderr, "svctl: %s: not up\n",
                                    argv[j]);
                                rc |= 1;
                        }
                }
                return rc;
        }

        usage();
        return 1;
}
