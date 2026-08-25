// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula
//
// The first thing that runs, and the only thing that can notice a version of
// this app which never runs at all.
//
// The app already puts itself back when a new version starts and fails: three
// launches that never reach a working window and the previous bundle returns.
// That is the app's own code doing it, so it cannot cover the one failure that
// matters most -- a binary the system refuses to load. Nothing of ours runs
// then, nothing counts the attempt, and the person is left with an application
// that does nothing when opened and no way back.
//
// So the bundle's executable is this: plain C, linked against libSystem and
// nothing else, which records that a launch was attempted and hands over to the
// real binary. The app clears the record once it has a window up. Three
// attempts with no window between them, and the kept-aside bundle is put back
// before the fourth.
//
// It cannot fail in the way it exists to catch: it has no framework to load, no
// Swift runtime, and no library of ours. If this will not run, the Mac has
// bigger problems than an update.

#include <errno.h>
#include <fcntl.h>
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <sys/wait.h>
#include <unistd.h>

// Three, matching what the app itself allows before putting the old one back.
#define ATTEMPTS_ALLOWED 3

static int join(char *out, size_t size, const char *a, const char *b) {
  int written = snprintf(out, size, "%s%s", a, b);
  return written > 0 && (size_t)written < size;
}

// ~/Library/Application Support/<bundle name>, where the app keeps the copy it
// set aside and where the count of attempts lives beside it.
static int support_directory(char *out, size_t size, const char *bundle_name) {
  const char *home = getenv("HOME");
  if (home == NULL || *home == '\0') return 0;
  int written = snprintf(out, size, "%s/Library/Application Support/%s", home, bundle_name);
  return written > 0 && (size_t)written < size;
}

static long attempts_so_far(const char *path) {
  FILE *file = fopen(path, "r");
  if (file == NULL) return 0;
  long count = 0;
  if (fscanf(file, "%ld", &count) != 1) count = 0;
  fclose(file);
  return count < 0 ? 0 : count;
}

static void record_attempt(const char *path, long count) {
  FILE *file = fopen(path, "w");
  if (file == NULL) return;
  fprintf(file, "%ld\n", count);
  fclose(file);
}

// CFBundleIdentifier out of Contents/Info.plist, without a plist parser.
//
// The file is a few hundred bytes of XML written by our own build. The key is
// found, then the next <string> after it. Anything unexpected -- a binary
// plist, a missing key, a value too long -- answers no, and the caller falls
// back to the name on disk, which is what it did before.
static int bundle_identifier(const char *contents_dir, char *out, size_t size) {
  char path[PATH_MAX];
  if (!join(path, sizeof(path), contents_dir, "/Info.plist")) return 0;
  FILE *file = fopen(path, "r");
  if (file == NULL) return 0;

  char text[8192];
  size_t read = fread(text, 1, sizeof(text) - 1, file);
  fclose(file);
  if (read == 0) return 0;
  text[read] = '\0';

  const char *key = strstr(text, "<key>CFBundleIdentifier</key>");
  if (key == NULL) return 0;
  const char *open_tag = strstr(key, "<string>");
  if (open_tag == NULL) return 0;
  open_tag += strlen("<string>");
  const char *close_tag = strstr(open_tag, "</string>");
  if (close_tag == NULL || close_tag <= open_tag) return 0;

  size_t length = (size_t)(close_tag - open_tag);
  if (length == 0 || length >= size) return 0;
  // Nothing that could reach outside the directory it names.
  for (size_t i = 0; i < length; i++) {
    char c = open_tag[i];
    int allowed = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                  || (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_';
    if (!allowed) return 0;
  }
  memcpy(out, open_tag, length);
  out[length] = '\0';
  return 1;
}

static int exists(const char *path) {
  struct stat info;
  return stat(path, &info) == 0;
}

// Put the kept-aside bundle back over this one, with ditto, which copies a
// signed bundle as a signed bundle -- extended attributes, symlinks and all.
static int restore(const char *kept_aside, const char *bundle) {
  pid_t child = fork();
  if (child < 0) return 0;
  if (child == 0) {
    execl("/usr/bin/ditto", "ditto", kept_aside, bundle, (char *)NULL);
    _exit(127);
  }
  int status = 0;
  if (waitpid(child, &status, 0) < 0) return 0;
  return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

// Only one launch may restore.
//
// Two copies opened at the same moment -- a double-click on a Dock icon, or a
// Sparkle relaunch meeting somebody opening the app -- both read the same count
// and both start copying a bundle over the same destination. Two writers, one
// application, and what is left is neither version.
//
// O_EXCL is the whole of the lock: whoever creates the file restores, and the
// other carries on and runs the app that is there. A stale one from a launch
// that died mid-copy is ignored after a minute, since a copy takes seconds and
// a lock nobody can clear is an application that never starts again.
#define LOCK_STALE_AFTER 60

static int take_restore_lock(const char *support) {
  char path[PATH_MAX];
  if (!join(path, sizeof(path), support, "/restoring")) return 0;

  struct stat info;
  if (stat(path, &info) == 0) {
    time_t now = time(NULL);
    if (now - info.st_mtime < LOCK_STALE_AFTER) return 0;
    // Stale, so it is cleared -- but two launches can reach this line together,
    // and the second unlink would take away the lock the first has just made.
    // Only the process whose unlink removed the file it actually looked at goes
    // on to create one, and creation is exclusive, so exactly one wins either
    // way.
    if (unlink(path) != 0) return 0;
  }
  int fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0600);
  if (fd < 0) return 0;
  close(fd);
  return 1;
}

static void release_restore_lock(const char *support) {
  char path[PATH_MAX];
  if (join(path, sizeof(path), support, "/restoring")) unlink(path);
}

int main(int argc, char *argv[]) {
  char self[PATH_MAX];
  if (realpath(argv[0], self) == NULL) {
    fprintf(stderr, "cannot resolve %s: %s\n", argv[0], strerror(errno));
    return 1;
  }

  // .../<name>.app/Contents/MacOS/<name>
  char macos_dir[PATH_MAX], contents[PATH_MAX], bundle[PATH_MAX];
  char copy[PATH_MAX];
  strncpy(copy, self, sizeof(copy) - 1);
  copy[sizeof(copy) - 1] = '\0';
  strncpy(macos_dir, dirname(copy), sizeof(macos_dir) - 1);
  strncpy(copy, macos_dir, sizeof(copy) - 1);
  strncpy(contents, dirname(copy), sizeof(contents) - 1);
  strncpy(copy, contents, sizeof(copy) - 1);
  strncpy(bundle, dirname(copy), sizeof(bundle) - 1);

  // The real binary sits beside this one under a name of its own.
  char real[PATH_MAX];
  if (!join(real, sizeof(real), self, "-app")) return 1;

  // What this application calls itself, which is its identifier and not the
  // name of the file. Renaming an app in Finder is somebody tidying up; it
  // should not orphan the copy kept aside for putting back, the count of
  // launches, or a hundred megabytes of Linux.
  //
  // Read out of Contents/Info.plist by hand: this program links nothing, and a
  // property list read for one string is a scan for one key.
  char bundle_copy[PATH_MAX];
  strncpy(bundle_copy, bundle, sizeof(bundle_copy) - 1);
  bundle_copy[sizeof(bundle_copy) - 1] = '\0';
  char *bundle_name = basename(bundle_copy);
  char *dot = strrchr(bundle_name, '.');
  if (dot != NULL && strcmp(dot, ".app") == 0) *dot = '\0';

  char identifier[256];
  if (bundle_identifier(contents, identifier, sizeof(identifier))) {
    bundle_name = identifier;
  }

  char support[PATH_MAX], attempts_path[PATH_MAX], kept_aside[PATH_MAX];
  int have_support = support_directory(support, sizeof(support), bundle_name);
  if (have_support) {
    have_support = join(attempts_path, sizeof(attempts_path), support, "/launch-attempts");
  }
  if (have_support) {
    char previous[PATH_MAX];
    if (snprintf(previous, sizeof(previous), "%s/previous/%s.app", support, bundle_name) > 0) {
      strncpy(kept_aside, previous, sizeof(kept_aside) - 1);
      kept_aside[sizeof(kept_aside) - 1] = '\0';
    } else {
      have_support = 0;
    }
  }

  if (have_support) {
    long count = attempts_so_far(attempts_path);
    if (count >= ATTEMPTS_ALLOWED && exists(kept_aside) && take_restore_lock(support)) {
      // This version has been opened three times and has never got as far as
      // saying it was working. Whatever is wrong with it, the previous one ran.
      int put_back = restore(kept_aside, bundle);
      release_restore_lock(support);
      if (put_back) {
        record_attempt(attempts_path, 0);
        execv(real, argv);
        // The restored bundle's own executable, if the name differed.
        char restored[PATH_MAX];
        if (join(restored, sizeof(restored), self, "")) execv(restored, argv);
        return 1;
      }
    }
    record_attempt(attempts_path, count + 1);
  }

  execv(real, argv);

  // The real binary is not there, or is not something this Mac can run. That is
  // the same fault, found earlier, so it counts as one of the three.
  fprintf(stderr, "%s: %s\n", real, strerror(errno));
  return 1;
}
