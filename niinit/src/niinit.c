#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/reboot.h>
#include <sys/wait.h>
#include <unistd.h>

#define STAGE1 "/etc/niinit/1"
#define STAGE3 "/etc/niinit/3"
#define SVDIR  "/etc/niinit/services"

enum { ACT_NONE = 0, ACT_REBOOT, ACT_POWEROFF };

static volatile sig_atomic_t action;
static volatile sig_atomic_t got_chld;
static volatile sig_atomic_t svdir_alive;
static pid_t svdir_pid;

static void sig_action(int sig)
{
	action = (sig == SIGCONT) ? ACT_REBOOT : ACT_POWEROFF;
}

static void sig_chld(int sig)
{
	(void)sig;
	got_chld = 1;
}

static int run_stage(const char *path)
{
	pid_t p = fork();
	if (p < 0)
		return -1;
	if (p == 0) {
		execl(path, path, (char *)0);
		_exit(127);
	}
	int st;
	while (waitpid(p, &st, 0) < 0 && errno == EINTR)
		;
	return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

static void spawn_svdir(void)
{
	pid_t p = fork();
	if (p < 0) {
		sleep(1);
		return;
	}
	if (p == 0) {
		execlp("niinit-svdir", "niinit-svdir", SVDIR, (char *)0);
		_exit(127);
	}
	svdir_pid = p;
	svdir_alive = 1;
}

static void boot(void)
{
	for (;;) {
		if (run_stage(STAGE1) == 0)
			return;
		fprintf(stderr,
		    "niinit: stage 1 failed, emergency shell (exit to retry)\n");
		pid_t p = fork();
		if (p == 0) {
			execl("/bin/sh", "/bin/sh", (char *)0);
			_exit(1);
		}
		if (p > 0) {
			int st;
			while (waitpid(p, &st, 0) < 0 && errno == EINTR)
				;
		}
	}
}

static void do_shutdown(int cmd)
{
	pid_t sv = svdir_pid;
	if (sv > 0)
		kill(sv, SIGTERM);
	for (int i = 0; i < 100 && sv > 0; i++) {
		int st;
		pid_t p;
		while ((p = waitpid(-1, &st, WNOHANG)) > 0)
			if (p == sv)
				sv = 0;
		if (sv > 0)
			usleep(100000);
	}
	kill(-1, SIGTERM);
	sleep(1);
	kill(-1, SIGKILL);
	run_stage(STAGE3);
	sync();
	reboot(cmd == ACT_REBOOT ? RB_AUTOBOOT : RB_POWER_OFF);
	_exit(1);
}

int main(void)
{
	if (getpid() != 1) {
		fprintf(stderr, "niinit: must be run as PID 1\n");
		return 1;
	}

	sigset_t block, empty;
	sigfillset(&block);
	sigemptyset(&empty);
	sigprocmask(SIG_SETMASK, &block, NULL);

	struct sigaction sa;
	memset(&sa, 0, sizeof sa);
	sa.sa_handler = SIG_IGN;
	for (int i = 1; i < NSIG; i++)
		sigaction(i, &sa, NULL);
	sa.sa_handler = sig_action;
	sigaction(SIGCONT, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	sa.sa_handler = sig_chld;
	sigaction(SIGCHLD, &sa, NULL);

	setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1);
	boot();
	spawn_svdir();

	for (;;) {
		if (action != ACT_NONE)
			do_shutdown(action);
		if (got_chld) {
			got_chld = 0;
			int st;
			pid_t p;
			while ((p = waitpid(-1, &st, WNOHANG)) > 0)
				if (p == svdir_pid) {
					svdir_pid = 0;
					svdir_alive = 0;
				}
		}
		if (!svdir_alive) {
			fprintf(stderr, "niinit: respawning svdir\n");
			spawn_svdir();
		}
		sigsuspend(&empty);
	}
}
