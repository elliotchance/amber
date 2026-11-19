#include <sys/stat.h>
#include <sys/time.h>

// amber_stat fills in the size, modified time (in nanoseconds since the UNIX
// epoch) and preferred block size of path, without following symbolic links. It returns 0 on success.
static int amber_stat(const char *path, long long *size, long long *mtime_ns, long long *blksize) {
	struct stat st;
	if (lstat(path, &st) != 0) {
		return -1;
	}
	*size = (long long)st.st_size;
#ifdef __APPLE__
	*mtime_ns = (long long)st.st_mtimespec.tv_sec * 1000000000LL + st.st_mtimespec.tv_nsec;
#else
	*mtime_ns = (long long)st.st_mtim.tv_sec * 1000000000LL + st.st_mtim.tv_nsec;
#endif
	*blksize = (long long)st.st_blksize;
	return 0;
}

// amber_set_mtime sets the access and modified times of path to mtime_us
// (microseconds since the UNIX epoch). It returns 0 on success.
static int amber_set_mtime(const char *path, long long mtime_us) {
	long long secs = mtime_us / 1000000;
	long long usecs = mtime_us % 1000000;
	if (usecs < 0) {
		secs--;
		usecs += 1000000;
	}
	struct timeval times[2];
	times[0].tv_sec = secs;
	times[0].tv_usec = usecs;
	times[1] = times[0];
	return utimes(path, times);
}

#include <time.h>

// amber_local_to_unix converts a local date and time to seconds since the UNIX
// epoch, using the local time zone's daylight saving rules for that date.
static long long amber_local_to_unix(int year, int month, int day, int hour, int minute, int second) {
	struct tm tm = {0};
	tm.tm_year = year - 1900;
	tm.tm_mon = month - 1;
	tm.tm_mday = day;
	tm.tm_hour = hour;
	tm.tm_min = minute;
	tm.tm_sec = second;
	tm.tm_isdst = -1;
	return (long long)mktime(&tm);
}
