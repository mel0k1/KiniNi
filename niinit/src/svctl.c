#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *svdir(void)
{
	const char *d = getenv("NIINIT_SVDIR");
	return d && *d ? d : "/etc/niinit/services";
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

static int status_one(const char *svc)
{
	char path[1024], buf[64] = { 0 };
	snprintf(path, sizeof path, "%s/%s/stat", svdir(), svc);
	int fd = open(path, O_RDONLY);
	if (fd >= 0) {
		if (read(fd, buf, sizeof buf - 1) < 0)
			buf[0] = '\0';
		close(fd);
	}
	if (buf[0] == '\0')
		snprintf(buf, sizeof buf, "down");
	buf[strcspn(buf, "\n")] = '\0';

	int up = strcmp(buf, "up") == 0;
	long pid = 0;
	snprintf(path, sizeof path, "%s/%s/pid", svdir(), svc);
	FILE *f = fopen(path, "r");
	if (f) {
		if (fscanf(f, "%ld", &pid) != 1)
			pid = 0;
		fclose(f);
	}

	const char *g = color_ok() ? "\033[32m" : "";
	const char *r = color_ok() ? "\033[31m" : "";
	const char *d = color_ok() ? "\033[0m" : "";
	printf("%-24s %s%-7s%s", svc, up ? g : r, buf, d);
	if (up && pid > 0)
		printf(" (pid %ld)", pid);
	printf("\n");
	return up ? 0 : 3;
}

static int signal_pid1(int sig)
{
	if (kill(1, sig) != 0) {
		fprintf(stderr, "svctl: kill(1): %s\n", strerror(errno));
		return 1;
	}
	return 0;
}

static void usage(void)
{
	fputs("usage: svctl status [SERVICE...]\n"
	    "       svctl up|down|restart|kill SERVICE...\n"
	    "       svctl reboot|poweroff|halt\n", stderr);
}

int main(int argc, char **argv)
{
	const char *self = strrchr(argv[0], '/');
	self = self ? self + 1 : argv[0];

	if (strcmp(self, "reboot") == 0)
		return signal_pid1(SIGCONT);
	if (strcmp(self, "poweroff") == 0 || strcmp(self, "halt") == 0)
		return signal_pid1(SIGINT);

	if (argc < 2) {
		usage();
		return 1;
	}

	const char *cmd = argv[1];
	if (strcmp(cmd, "reboot") == 0)
		return signal_pid1(SIGCONT);
	if (strcmp(cmd, "poweroff") == 0 || strcmp(cmd, "halt") == 0)
		return signal_pid1(SIGINT);

	if (strcmp(cmd, "status") == 0) {
		int rc = 0;
		if (argc > 2) {
			for (int i = 2; i < argc; i++)
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
				if (access(path, X_OK) != 0)
					continue;
				rc |= status_one(e->d_name);
			}
			closedir(dp);
		}
		return rc;
	}

	if (strcmp(cmd, "up") == 0 || strcmp(cmd, "down") == 0 ||
	    strcmp(cmd, "restart") == 0 || strcmp(cmd, "kill") == 0) {
		if (argc < 3) {
			usage();
			return 1;
		}
		char c = strcmp(cmd, "restart") == 0 ? 't' : cmd[0];
		int rc = 0;
		for (int i = 2; i < argc; i++)
			rc |= send_cmd(argv[i], c);
		return rc;
	}

	usage();
	return 1;
}
