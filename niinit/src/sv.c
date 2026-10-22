/*
 * niinit-sv - service supervisor
 *
 * one instance per service directory. starts ./run, restarts it while it
 * wants up, runs ./finish <exitcode> <signal> after each exit, and executes
 * control commands read from ./control (fifo):
 *
 *   u  up        d  down       o  once       t  term+start  k  kill
 *   p  pause     c  cont       h  hup        a  alarm       i  int
 *   q  quit      1  usr1       2  usr2       x  exit
 *
 * the current state is published in ./stat (up, down, want up, want down)
 * and the service pid in ./pid. a ./down file prevents auto-start.
 */

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static char dir[512];
static char runpath[640];
static char finpath[640];
static char downpath[640];
static char ctrlpath[640];
static char statpath[640];
static char pidpath[640];
static pid_t svc_pid;
static pid_t fin_pid;
static int svclog_fd = -1;
static int want_up;
static int want_down;
static int once_only;
static int in_finish;
static int last_code;
static int last_sig;
static volatile sig_atomic_t stopflag;
static volatile sig_atomic_t exitflag;

static void on_term(int sig)
{
        (void)sig;
        stopflag = 1;
}

static const char *numstr(int v)
{
        static char buf[16];

        snprintf(buf, sizeof buf, "%d", v);
        return buf;
}

static void write_stat(const char *state)
{
        char tmp[700];
        FILE *f;

        snprintf(tmp, sizeof tmp, "%s.tmp", statpath);
        f = fopen(tmp, "w");
        if (f) {
                fputs(state, f);
                fclose(f);
                rename(tmp, statpath);
        }
}

static void write_pid(pid_t pid)
{
        char tmp[700];
        FILE *f;

        if (pid > 0) {
                snprintf(tmp, sizeof tmp, "%s.tmp", pidpath);
                f = fopen(tmp, "w");
                if (f) {
                        fprintf(f, "%ld\n", (long)pid);
                        fclose(f);
                        rename(tmp, pidpath);
                }
        } else {
                unlink(pidpath);
        }
}

/* publish the current state derived from the globals */
static void publish(void)
{
        if (svc_pid > 0)
                write_stat(want_down ? "want down" : "up");
        else if (in_finish || !want_up)
                write_stat("down");
        else
                write_stat("want up");
        write_pid(svc_pid);
}

/* run ./finish <exitcode> <signal> if present */
static void run_finish(void)
{
        pid_t p;

        if (access(finpath, X_OK) != 0)
                return;
        p = fork();
        if (p < 0)
                return;
        if (p == 0) {
                setsid();
                execl(finpath, finpath, numstr(last_code), numstr(last_sig),
                    (char *)0);
                _exit(127);
        }
        fin_pid = p;
        in_finish = 1;
        publish();
}

static void note_exit(int st)
{
        last_code = WIFEXITED(st) ? WEXITSTATUS(st) : 0;
        last_sig = WIFSIGNALED(st) ? WTERMSIG(st) : 0;
}

static void start_svc(void)
{
        pid_t p = fork();

        if (p < 0)
                return;
        if (p == 0) {
                setsid();
                int fd = open("/dev/null", O_RDWR);
                if (fd >= 0) {
                        dup2(fd, 0);
                        /* a service without its own logger must still be
                         * debuggable: its output goes to the supervisor's
                         * stderr (the console), not to /dev/null */
                        if (svclog_fd >= 0) {
                                dup2(svclog_fd, 1);
                                dup2(svclog_fd, 2);
                        } else {
                                dup2(fd, 1);
                                dup2(fd, 2);
                        }
                        if (fd > 2)
                                close(fd);
                }
                umask(022);
                execl(runpath, runpath, (char *)0);
                _exit(127);
        }
        svc_pid = p;
        publish();
}

static void stop_svc(void)
{
        int st;

        if (svc_pid <= 0)
                return;
        publish();
        kill(svc_pid, SIGTERM);
        for (int i = 0; i < 100; i++) {
                if (waitpid(svc_pid, &st, WNOHANG) == svc_pid) {
                        note_exit(st);
                        svc_pid = 0;
                        goto done;
                }
                usleep(100000);
        }
        kill(svc_pid, SIGKILL);
        waitpid(svc_pid, &st, 0);
        note_exit(st);
        svc_pid = 0;
done:
        run_finish();
        publish();
}

int main(int argc, char **argv)
{
        int st;

        if (argc < 2) {
                fprintf(stderr, "usage: niinit-sv <servicedir>\n");
                return 1;
        }

        /* keep the supervisor's stderr alive for the services it spawns
         * (start_svc dups it over the child's stdout/stderr) */
        svclog_fd = dup(2);

        snprintf(dir, sizeof dir, "%s", argv[1]);
        snprintf(runpath, sizeof runpath, "%s/run", dir);
        snprintf(finpath, sizeof finpath, "%s/finish", dir);
        snprintf(downpath, sizeof downpath, "%s/down", dir);
        snprintf(ctrlpath, sizeof ctrlpath, "%s/control", dir);
        snprintf(statpath, sizeof statpath, "%s/stat", dir);
        snprintf(pidpath, sizeof pidpath, "%s/pid", dir);

        if (mkfifo(ctrlpath, 0600) != 0 && errno != EEXIST) {
                fprintf(stderr, "niinit-sv: mkfifo %s: %s\n", ctrlpath,
                    strerror(errno));
                return 1;
        }

        signal(SIGTERM, on_term);
        signal(SIGINT, on_term);

        int cfd = open(ctrlpath, O_RDONLY | O_NONBLOCK);
        if (cfd < 0) {
                fprintf(stderr, "niinit-sv: open %s: %s\n", ctrlpath,
                    strerror(errno));
                return 1;
        }

        if (access(downpath, F_OK) != 0) {
                want_up = 1;
                start_svc();
        } else {
                publish();
        }

        for (;;) {
                pid_t p;

                if (stopflag || exitflag) {
                        want_up = 0;
                        want_down = 1;
                        if (svc_pid > 0)
                                stop_svc();
                        break;
                }
                while ((p = waitpid(-1, &st, WNOHANG)) > 0) {
                        if (p == svc_pid) {
                                svc_pid = 0;
                                note_exit(st);
                                run_finish();
                                publish();
                                once_only = 0;
                                if (want_up) {
                                        sleep(1);
                                        if (stopflag || exitflag)
                                                goto out;
                                        start_svc();
                                }
                        } else if (p == fin_pid) {
                                fin_pid = 0;
                                in_finish = 0;
                                publish();
                                if (want_up && svc_pid <= 0 && !once_only)
                                        start_svc();
                        }
                }
                struct pollfd pf = { .fd = cfd, .events = POLLIN };
                if (poll(&pf, 1, 500) > 0 && (pf.revents & POLLIN)) {
                        char buf[64];
                        ssize_t k = read(cfd, buf, sizeof buf);
                        for (ssize_t i = 0; i < k; i++) {
                                switch (buf[i]) {
                                case 'u':
                                        want_up = 1;
                                        want_down = 0;
                                        once_only = 0;
                                        if (svc_pid <= 0 && !in_finish)
                                                start_svc();
                                        else
                                                publish();
                                        break;
                                case 'd':
                                        want_up = 0;
                                        want_down = 1;
                                        once_only = 0;
                                        stop_svc();
                                        publish();
                                        break;
                                case 'o':
                                        if (svc_pid <= 0 && !in_finish) {
                                                once_only = 1;
                                                want_up = 0;
                                                start_svc();
                                        }
                                        break;
                                case 't':
                                        want_up = 1;
                                        want_down = 0;
                                        once_only = 0;
                                        if (svc_pid > 0) {
                                                stop_svc();
                                                if (!in_finish)
                                                        start_svc();
                                                else
                                                        publish();
                                        } else if (!in_finish) {
                                                start_svc();
                                        } else {
                                                publish();
                                        }
                                        break;
                                case 'k':
                                        if (svc_pid > 0)
                                                kill(svc_pid, SIGKILL);
                                        break;
                                case 'p':
                                        if (svc_pid > 0)
                                                kill(svc_pid, SIGSTOP);
                                        break;
                                case 'c':
                                        if (svc_pid > 0)
                                                kill(svc_pid, SIGCONT);
                                        break;
                                case 'h':
                                        if (svc_pid > 0)
                                                kill(svc_pid, SIGHUP);
                                        break;
                                case 'a':
                                        if (svc_pid > 0)
                                                kill(svc_pid, SIGALRM);
                                        break;
                                case 'i':
                                        if (svc_pid > 0)
                                                kill(svc_pid, SIGINT);
                                        break;
                                case 'q':
                                        if (svc_pid > 0)
                                                kill(svc_pid, SIGQUIT);
                                        break;
                                case '1':
                                        if (svc_pid > 0)
                                                kill(svc_pid, SIGUSR1);
                                        break;
                                case '2':
                                        if (svc_pid > 0)
                                                kill(svc_pid, SIGUSR2);
                                        break;
                                case 'x':
                                        exitflag = 1;
                                        break;
                                }
                        }
                }
        }
out:
        close(cfd);
        while (fin_pid > 0 && waitpid(fin_pid, &st, 0) < 0 && errno == EINTR)
                ;
        write_stat("down");
        write_pid(0);
        return 0;
}
