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
static char ctrlpath[640];
static char statpath[640];
static char pidpath[640];
static pid_t svc_pid;
static int want_up;
static volatile sig_atomic_t stopflag;

static void on_term(int sig)
{
	(void)sig;
	stopflag = 1;
}

static void write_stat(const char *state, pid_t pid)
{
	char tmp[700];
	snprintf(tmp, sizeof tmp, "%s.tmp", statpath);
	FILE *f = fopen(tmp, "w");
	if (f) {
		fputs(state, f);
		fclose(f);
		rename(tmp, statpath);
	}
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
			dup2(fd, 1);
			dup2(fd, 2);
			if (fd > 2)
				close(fd);
		}
		umask(022);
		execl(runpath, runpath, (char *)0);
		_exit(127);
	}
	svc_pid = p;
	want_up = 1;
	write_stat("up", p);
}

static void stop_svc(void)
{
	if (svc_pid <= 0)
		return;
	kill(svc_pid, SIGTERM);
	int st;
	for (int i = 0; i < 100; i++) {
		if (waitpid(svc_pid, &st, WNOHANG) == svc_pid)
			goto done;
		usleep(100000);
	}
	kill(svc_pid, SIGKILL);
	waitpid(svc_pid, &st, 0);
done:
	svc_pid = 0;
	write_stat("down", 0);
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: niinit-sv <servicedir>\n");
		return 1;
	}

	snprintf(dir, sizeof dir, "%s", argv[1]);
	snprintf(runpath, sizeof runpath, "%s/run", dir);
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

	want_up = 1;
	start_svc();

	for (;;) {
		if (stopflag) {
			if (svc_pid > 0)
				stop_svc();
			break;
		}
		if (svc_pid > 0) {
			int st;
			if (waitpid(svc_pid, &st, WNOHANG) == svc_pid) {
				svc_pid = 0;
				write_stat("down", 0);
				if (want_up) {
					sleep(1);
					start_svc();
				}
			}
		}
		struct pollfd pf = { .fd = cfd, .events = POLLIN };
		if (poll(&pf, 1, 500) > 0 && (pf.revents & POLLIN)) {
			char buf[64];
			ssize_t k = read(cfd, buf, sizeof buf);
			for (ssize_t i = 0; i < k; i++) {
				switch (buf[i]) {
				case 'u':
					if (svc_pid <= 0)
						start_svc();
					else
						want_up = 1;
					break;
				case 'd':
					want_up = 0;
					stop_svc();
					break;
				case 't':
					want_up = 1;
					if (svc_pid > 0) {
						stop_svc();
						start_svc();
					}
					break;
				case 'k':
					if (svc_pid > 0)
						kill(svc_pid, SIGKILL);
					break;
				}
			}
		}
	}

	close(cfd);
	write_stat("down", 0);
	return 0;
}
