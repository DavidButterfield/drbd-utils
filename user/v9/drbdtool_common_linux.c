#include <stdlib.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include "drbdtool_common.h"

/* Set this environment variable to the UMC fuse mount point to control a
 * usermode DRBD server rather than a kernel-based server.
 */
#define UMC_FS_ROOT_ENV "UMC_FS_ROOT"

#define PROC_DRBD "/proc/drbd"

extern struct version __drbd_driver_version;

/* For our purpose (finding the revision) SLURP_SIZE is always enough.
 */
static char *slurp_proc_drbd()
{
	const int SLURP_SIZE = 4096;
	char *buffer;
	int rr, fd;

	char proc_name[64];
	const char *root = getenv(UMC_FS_ROOT_ENV);
	if (snprintf(proc_name, sizeof(proc_name), "%s%s", root?:"", PROC_DRBD) >= sizeof(proc_name)) {
		fprintf(stderr, "WARNING: ignoring bad environment %s='%s'\n", UMC_FS_ROOT_ENV, root);
		strncpy(proc_name, PROC_DRBD, sizeof(proc_name));
	}

	fd = open(proc_name, O_RDONLY);
	if (fd == -1)
		return NULL;

	buffer = malloc(SLURP_SIZE);
	if(!buffer)
		goto fail;

	rr = read(fd, buffer, SLURP_SIZE-1);
	if (rr == -1) {
		free(buffer);
		buffer = NULL;
		goto fail;
	}

	buffer[rr]=0;
fail:
	close(fd);

	return buffer;
}

const struct version *get_drbd_driver_version(void)
{
	char *version_txt;

	version_txt = slurp_proc_drbd();
	if (version_txt) {
		parse_version(&__drbd_driver_version, version_txt);
		free(version_txt);
		return &__drbd_driver_version;
	} else {
		FILE *in = popen("modinfo -F version drbd", "r");
		if (in) {
			char buf[32];
			int c = fscanf(in, "%30s", buf);
			pclose(in);
			if (c == 1) {
				version_from_str(&__drbd_driver_version, buf);
				return &__drbd_driver_version;
			}
		}
	}
	return NULL;
}

