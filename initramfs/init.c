// Minimal /init: find partition named "userdata" via sysfs PARTNAME, mount ext4, switch_root.
// kenzo's partition numbers differ from ginkgo, so we never hardcode mmcblk0pN.
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

static void die(const char *m){ dprintf(2, "initramfs: %s\n", m); sleep(10); _exit(1); }
static void mkp(const char *p){ if (mkdir(p,0755) && errno!=EEXIST) die(p); }

// scan /sys/class/block/*/uevent for PARTNAME=<name>; create /dev/<blk> node and return path
static int find_part(const char *want, char *out, size_t n)
{
	DIR *d = opendir("/sys/class/block");
	struct dirent *e;
	if (!d) return -1;
	while ((e = readdir(d))) {
		char p[300], line[256]; FILE *f; int ma=-1, mi=-1, hit=0;
		if (strncmp(e->d_name, "mmcblk", 6)) continue;
		snprintf(p, sizeof p, "/sys/class/block/%s/uevent", e->d_name);
		if (!(f = fopen(p, "r"))) continue;
		while (fgets(line, sizeof line, f)) {
			line[strcspn(line, "\n")] = 0;
			if (!strncmp(line, "PARTNAME=", 9) && !strcmp(line+9, want)) hit = 1;
			if (!strncmp(line, "MAJOR=", 6)) ma = atoi(line+6);
			if (!strncmp(line, "MINOR=", 6)) mi = atoi(line+6);
		}
		fclose(f);
		if (hit && ma >= 0) {
			snprintf(out, n, "/dev/%s", e->d_name);
			if (mknod(out, S_IFBLK|0600, makedev(ma, mi)) && errno != EEXIST) continue;
			closedir(d); return 0;
		}
	}
	closedir(d); return -1;
}

int main(void)
{
	char dev[300];
	mkp("/proc"); mkp("/sys"); mkp("/dev"); mkp("/newroot");
	if (mount("proc","/proc","proc",0,0)) die("mount proc");
	if (mount("sysfs","/sys","sysfs",0,0)) die("mount sys");
	if (mount("devtmpfs","/dev","devtmpfs",0,0)) die("mount dev");
	// The kernel only opens /dev/console for PID 1 if the initramfs contains it; ours does not (cpio built without root),
	// so fds 0-2 are closed and every dprintf(2,..) below would vanish. Open it now so errors reach fbcon/serial.
	{ int c = open("/dev/console", O_RDWR); if (c >= 0) { dup2(c,0); dup2(c,1); dup2(c,2); if (c > 2) close(c); } }

	int ok = 0;
	for (int i = 0; i < 240 && !ok; i++) {          // up to ~60 s for eMMC probe
		if (!find_part("userdata", dev, sizeof dev)) ok = 1; else usleep(250000);
	}
	if (!ok) die("userdata partition not found (is sdhci-msm built in?)");
	dprintf(2, "initramfs: userdata = %s\n", dev);
	if (mount(dev, "/newroot", "ext4", 0, 0)) die("mount userdata (ext4?)");

	// Safety rescue: if ufw was left enabled without rules, all incoming TCP (SSH) is blocked.
	{
		int fd = open("/newroot/etc/ufw/ufw.conf", O_RDWR);
		if (fd >= 0) {
			char buf[512];
			ssize_t nr = read(fd, buf, sizeof(buf) - 1);
			if (nr > 0) {
				buf[nr] = '\0';
				char *p = strstr(buf, "ENABLED=yes");
				if (p) {
					p[8] = 'n'; p[9] = 'o'; p[10] = ' ';
					lseek(fd, 0, SEEK_SET);
					write(fd, buf, nr);
				}
			}
			close(fd);
		}
	}

	mkp("/newroot/proc"); mkp("/newroot/sys"); mkp("/newroot/dev");
	if (mount("/proc","/newroot/proc",0,MS_MOVE,0)) die("move proc");
	if (mount("/sys","/newroot/sys",0,MS_MOVE,0)) die("move sys");
	if (mount("/dev","/newroot/dev",0,MS_MOVE,0)) die("move dev");
	if (chdir("/newroot")) die("chdir");
	if (mount(".","/",0,MS_MOVE,0)) die("move root");
	if (chroot(".")) die("chroot");
	execl("/sbin/init","init",(char*)0);
	die("exec /sbin/init");
}
