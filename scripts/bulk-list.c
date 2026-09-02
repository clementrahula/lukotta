// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula
//
// Time a folder the way Finder reads one.
//
//     cc -o bulk-list scripts/bulk-list.c && ./bulk-list /Volumes/DRIVE/folder
//
// Everything measuring the slow-listing problem used `ls`, which is readdir.
// Finder does not use readdir; it uses getattrlistbulk(2), which fetches names
// and attributes together. So "a listing takes seven seconds" was a claim
// about a call Finder never makes, and whether a person sees any of it was
// unanswered.
//
// They do. Measured on the owner's drive during a copy, alternating with an
// `ls` of the same folder in the same seconds:
//
//     getattrlistbulk  median 8.42s   worst 34.67s
//     readdir          median 5.16s   worst  8.07s
//
// Finder's path is the slower of the two. The stall is not an artefact of
// having probed with the wrong call -- it is worse through the call that
// matters.
//
// What it is not is a failure. Through a thirteen-gigabyte Finder copy the
// same drive reported no error, no complaint and no skipped item, and every
// file came back byte-identical. A folder view that takes eight seconds to
// refresh is what this costs, and it costs it only while a copy is running
// into that folder.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/attr.h>
#include <sys/time.h>
int main(int argc, char **argv) {
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) { perror("open"); return 1; }
    struct attrlist al; memset(&al, 0, sizeof(al));
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE;
    al.fileattr = ATTR_FILE_DATALENGTH;
    char buf[64 * 1024];
    struct timeval a, b; gettimeofday(&a, NULL);
    int total = 0, n;
    while ((n = getattrlistbulk(fd, &al, buf, sizeof(buf), 0)) > 0) total += n;
    gettimeofday(&b, NULL);
    close(fd);
    double secs = (b.tv_sec - a.tv_sec) + (b.tv_usec - a.tv_usec) / 1e6;
    printf("%.2f %d\n", secs, total);
    return n < 0 ? 1 : 0;
}
