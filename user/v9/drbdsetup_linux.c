#include "drbdsetup.h"
#include <linux/drbd.h>
#include <stdio.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include "shared_tool.h"
#include "libgenl.h"
#include <sys/utsname.h>
#include <poll.h>
#include <time.h>

/* Set this environment variable to the UMC fuse mount point to control a
 * usermode DRBD server rather than a kernel-based server.
 */
#define UMC_FS_ROOT_ENV "UMC_FS_ROOT"
#define DO_STAT_CHECKS()	    !getenv(UMC_FS_ROOT_ENV)
#define DO_MODPROBE()		    !getenv(UMC_FS_ROOT_ENV)
#define DO_NETLINK_MULTICAST()	    !getenv(UMC_FS_ROOT_ENV)

#define PROC_DRBD "/proc/drbd"

bool kernel_older_than(int version, int patchlevel, int sublevel)
{
	struct utsname utsname;
	char *rel;
	int l;

	if (uname(&utsname) != 0)
		return false;
	rel = utsname.release;
	l = strtol(rel, &rel, 10);
	if (l > version)
		return false;
	else if (l < version || *rel == 0)
		return true;
	l = strtol(rel + 1, &rel, 10);
	if (l > patchlevel)
		return false;
	else if (l < patchlevel || *rel == 0)
		return true;
	l = strtol(rel + 1, &rel, 10);
	if (l >= sublevel)
		return false;
	return true;
}

int conv_block_dev(struct drbd_argument *ad, struct msg_buff *msg,
		   struct drbd_genlmsghdr *dhdr, char* arg)
{
	if (DO_STAT_CHECKS()) {
		struct stat sb;
		int device_fd;

		if ((device_fd = open(arg,O_RDWR))==-1) {
			PERROR("Can not open device '%s'", arg);
			return OTHER_ERROR;
		}

		if (fstat(device_fd, &sb)) {
			PERROR("fstat(%s) failed", arg);
			close(device_fd);
			return OTHER_ERROR;
		}

		if(!S_ISBLK(sb.st_mode)) {
			fprintf(stderr, "%s is not a block device!\n", arg);
			close(device_fd);
			return OTHER_ERROR;
		}

		close(device_fd);
	}

	nla_put_string(msg, ad->nla_type, arg);

	return NO_ERROR;
}

int genl_join_mc_group_and_ctrl(struct genl_sock *s, const char *name)
{
	int ret = 0;
	if (DO_NETLINK_MULTICAST()) {
		/* also always (try to) listen to nlctrl notify,
		 * so we have a chance to notice rmmod.  */
		int id = GENL_ID_CTRL;

		setsockopt(s->s_fd, SOL_NETLINK, NETLINK_ADD_MEMBERSHIP,
					&id, sizeof(id));

		ret = genl_join_mc_group(s, name);
		if (kernel_older_than(2, 6, 23))
			ret = 0;
	}
	return ret;
}

int poll_hup(struct genl_sock *s, int timeout_ms)
{
	int ret;
	struct pollfd pollfds[2] = {
		[0] = {
			.fd = 1,
			.events = POLLHUP,
		},
		[1] = {
			.fd = s->s_fd,
			.events = POLLIN,
		},
	};

	ret = poll(pollfds, 2, timeout_ms);
	if (ret == 0)
		return E_POLL_TIMEOUT;
	if (pollfds[0].revents == POLLERR || pollfds[0].revents == POLLHUP)
		return E_POLL_ERR;

	return 0;
}

int modprobe_drbd(void)
{
	struct stat sb;
	int ret;

	char proc_name[64];
	const char *root = getenv(UMC_FS_ROOT_ENV);
	if (snprintf(proc_name, sizeof(proc_name),
			"%s%s", root?:"", PROC_DRBD) >= sizeof(proc_name)) {
		fprintf(stderr, "WARNING: ignoring bad environment %s='%s'\n",
			    UMC_FS_ROOT_ENV, root);
		strncpy(proc_name, PROC_DRBD, sizeof(proc_name));
	}

	ret = stat(proc_name, &sb);
	if (ret && errno == ENOENT && DO_MODPROBE()) {
		int retries = 10;
		ret = system("/sbin/modprobe drbd");
		if (ret != 0) {
			fprintf(stderr, "Failed to modprobe drbd (%m)\n");
			return 0;
		}
		for(;;) {
			struct timespec ts = {
				.tv_nsec = 1000000,
			};

			ret = stat(proc_name, &sb);
			if (!ret || retries-- == 0)
				break;
			nanosleep(&ts, NULL);
		}
	}
	if (ret) {
		fprintf(stderr, "Could not stat %s: %m\n", proc_name);
		fprintf(stderr, "Make sure that the DRBD kernel module is installed "
				"and can be loaded!\n");
	}
	return ret == 0;
}

