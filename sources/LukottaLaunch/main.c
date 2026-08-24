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
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
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

  // "Lukotta.app" -> "Lukotta"
  char bundle_copy[PATH_MAX];
  strncpy(bundle_copy, bundle, sizeof(bundle_copy) - 1);
  bundle_copy[sizeof(bundle_copy) - 1] = '\0';
  char *bundle_name = basename(bundle_copy);
  char *dot = strrchr(bundle_name, '.');
  if (dot != NULL && strcmp(dot, ".app") == 0) *dot = '\0';

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
    if (count >= ATTEMPTS_ALLOWED && exists(kept_aside)) {
      // This version has been opened three times and has never got as far as
      // saying it was working. Whatever is wrong with it, the previous one ran.
      if (restore(kept_aside, bundle)) {
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
