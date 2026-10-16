// Privileged helper for Hammerspoon proxy switching.
//
// Install with:
//   sudo chown root:wheel bin/setproxy
//   sudo chmod 4755 bin/setproxy
//
// Accepted actions:
//   local  - use the proxy running on this Mac:      127.0.0.1:7890
//   remote - use the proxy on the LAN proxy machine: 192.168.31.101:7890
//   off    - disable HTTP, HTTPS and SOCKS proxies
//
// The network service, proxy endpoints and executable path are compiled in.
// No shell is invoked and no other command-line input is passed to networksetup.

#include <errno.h>
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define NETWORKSETUP "/usr/sbin/networksetup"
#define NETWORK_SERVICE "Wi-Fi"
#define LOCAL_PROXY_HOST "127.0.0.1"
#define REMOTE_PROXY_HOST "192.168.31.101"
#define PROXY_PORT "7890"

// Every command currently has at most six arguments plus the trailing NULL.
#define MAX_ARGS 7

typedef struct {
	const char *host;
} proxy_profile;

static const proxy_profile local_profile = {
	.host = LOCAL_PROXY_HOST,
};

static const proxy_profile remote_profile = {
	.host = REMOTE_PROXY_HOST,
};

// Build one fixed-size argv buffer. Keeping host/port in separate arguments
// avoids shell parsing and makes the command construction explicit.
static void make_command(
	const char *argv[MAX_ARGS],
	const char *subcommand,
	const proxy_profile *profile
) {
	memset((void *)argv, 0, sizeof(const char *) * MAX_ARGS);

	argv[0] = NETWORKSETUP;
	argv[1] = subcommand;
	argv[2] = NETWORK_SERVICE;

	if (strcmp(subcommand, "-setwebproxy") == 0 ||
		strcmp(subcommand, "-setsecurewebproxy") == 0 ||
		strcmp(subcommand, "-setsocksfirewallproxy") == 0) {
		argv[3] = profile->host;
		argv[4] = PROXY_PORT;
	} else {
		// State commands are represented separately and use "on"/"off".
		argv[3] = NULL;
	}
}

static void make_state_command(
	const char *argv[MAX_ARGS],
	const char *subcommand,
	const char *state
) {
	memset((void *)argv, 0, sizeof(const char *) * MAX_ARGS);
	argv[0] = NETWORKSETUP;
	argv[1] = subcommand;
	argv[2] = NETWORK_SERVICE;
	argv[3] = state;
}

static char *safe_environment[] = {
	"PATH=/usr/sbin:/usr/bin:/sbin:/bin",
	"IFS= \t\n",
	NULL,
};

static void reset_environment(void) {
	// Replace the inherited environment with fixed values without calling setenv().
	extern char **environ;
	environ = safe_environment;
}

static int run_command(const char *const argv[]) {
	pid_t pid = fork();
	if (pid < 0) {
		perror("fork failed");
		return -1;
	}

	if (pid == 0) {
		execv(argv[0], (char *const *)argv);
		perror("execv failed");
		_exit(127);
	}

	int status = 0;
	while (waitpid(pid, &status, 0) < 0) {
		if (errno != EINTR) {
			perror("waitpid failed");
			return -1;
		}
	}

	if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
		fprintf(stderr, "%s failed\n", argv[1]);
		return -1;
	}

	return 0;
}

static int enable_profile(const proxy_profile *profile) {
	const char *set_subcommands[] = {
		"-setwebproxy",
		"-setsecurewebproxy",
		"-setsocksfirewallproxy",
	};
	const char *state_subcommands[] = {
		"-setwebproxystate",
		"-setsecurewebproxystate",
		"-setsocksfirewallproxystate",
	};

	for (size_t i = 0; i < sizeof(set_subcommands) / sizeof(set_subcommands[0]); i++) {
		const char *argv[MAX_ARGS];
		make_command(argv, set_subcommands[i], profile);
		if (run_command(argv) != 0) {
			return EXIT_FAILURE;
		}
	}

	for (size_t i = 0; i < sizeof(state_subcommands) / sizeof(state_subcommands[0]); i++) {
		const char *argv[MAX_ARGS];
		make_state_command(argv, state_subcommands[i], "on");
		if (run_command(argv) != 0) {
			return EXIT_FAILURE;
		}
	}

	return EXIT_SUCCESS;
}

static int disable_proxies(void) {
	const char *state_subcommands[] = {
		"-setwebproxystate",
		"-setsecurewebproxystate",
		"-setsocksfirewallproxystate",
	};

	for (size_t i = 0; i < sizeof(state_subcommands) / sizeof(state_subcommands[0]); i++) {
		const char *argv[MAX_ARGS];
		make_state_command(argv, state_subcommands[i], "off");
		if (run_command(argv) != 0) {
			return EXIT_FAILURE;
		}
	}

	return EXIT_SUCCESS;
}

int main(int argc, char *argv[]) {
	if (argc != 2) {
		fprintf(stderr, "Usage: %s [local|remote|off]\n",
			argc > 0 ? argv[0] : "setproxy");
		return EXIT_FAILURE;
	}

	const proxy_profile *profile = NULL;
	if (strcmp(argv[1], "local") == 0) {
		profile = &local_profile;
	} else if (strcmp(argv[1], "remote") == 0) {
		profile = &remote_profile;
	} else if (strcmp(argv[1], "off") != 0) {
		fprintf(stderr, "Invalid action. Use 'local', 'remote' or 'off'.\n");
		return EXIT_FAILURE;
	}

	// Drop supplemental groups before assuming the root identity.
	gid_t root_gid = 0;
	if (setgroups(1, &root_gid) != 0) {
		perror("setgroups failed");
		return EXIT_FAILURE;
	}
	if (setgid(0) != 0) {
		perror("setgid failed");
		return EXIT_FAILURE;
	}
	if (setuid(0) != 0) {
		perror("setuid failed");
		return EXIT_FAILURE;
	}

	reset_environment();

	if (profile != NULL) {
		return enable_profile(profile);
	}
	return disable_proxies();
}
