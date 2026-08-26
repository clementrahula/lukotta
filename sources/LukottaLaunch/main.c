// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula
//
// Watches an update land, and puts the previous version back if the one that
// arrived will not start.
//
// The app already undoes an update that starts and never gets as far as a
// window: three such launches and the kept-aside bundle returns. What its own
// code cannot cover is a binary the system refuses to load -- a framework that
// did not come across, an architecture this Mac cannot run. Nothing of ours
// runs then, so nothing notices, and the person is left with an application
// that does nothing when opened and no way back.
//
// This is what notices. The app starts it, detached, as it hands over to
// Sparkle's installer; it outlives the app, waits for the swap, and asks the
// version that arrived to prove it starts. `--verify-launch` reaches `main`
// and exits, which is the whole question: a binary that will not load never
// gets there.
//
// It cannot fail in the way it exists to catch: plain C against libSystem, no
// framework to load, no Swift runtime, nothing of ours. If this will not run,
// the Mac has bigger problems than an update.
//
// It is deliberately not the bundle's executable. It used to be, handing over
// with execv, and macOS will not give a menu bar item to a process whose
// running image is not the executable the bundle declares -- the item was
// created, registered, and never laid out, at x = -1 and no width. A launcher
// in front of the app buys this much and costs that, so it stands beside the
// app instead of in front of it.
//
//   update-check <bundle path> <the build number being replaced>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

// How long to wait for the installer to put the new version in place. Sparkle
// asks the app to quit, replaces the bundle and relaunches, which is seconds;
// this is long enough for a slow disk and short enough that a watcher left
// behind by an update that never happened does not sit there for an afternoon.
#define SWAP_WAIT_SECONDS 180
#define POLL_MICROSECONDS 500000

static int join(char *out, size_t size, const char *a, const char *b) {
  int written = snprintf(out, size, "%s%s", a, b);
  return written > 0 && (size_t)written < size;
}

// ~/Library/Application Support/<bundle name>, where the app keeps the copy it
// set aside.
static int support_directory(char *out, size_t size, const char *bundle_name) {
  const char *home = getenv("HOME");
  if (home == NULL || *home == '\0') return 0;
  int written = snprintf(out, size, "%s/Library/Application Support/%s", home, bundle_name);
  return written > 0 && (size_t)written < size;
}

// One string out of Contents/Info.plist, without a plist parser.
//
// The file is a few hundred bytes of XML written by our own build. The key is
// found, then the next <string> after it. Anything unexpected -- a binary
// plist, a missing key, a value too long -- answers no, and every caller here
// reads that as "leave the application alone", which is the safe direction.
//
// `spaces` because the values wanted differ in what they may contain: an
// identifier may not carry a space and an executable called "Drive Unlocker"
// must. Neither may carry a slash, which is the only character that could
// point the result somewhere other than inside the bundle.
static int plist_string(
    const char *contents_dir, const char *key, int spaces, char *out, size_t size) {
  char path[PATH_MAX];
  if (!join(path, sizeof(path), contents_dir, "/Info.plist")) return 0;
  FILE *file = fopen(path, "r");
  if (file == NULL) return 0;

  char text[8192];
  size_t read = fread(text, 1, sizeof(text) - 1, file);
  fclose(file);
  if (read == 0) return 0;
  text[read] = '\0';

  char wanted[128];
  if (snprintf(wanted, sizeof(wanted), "<key>%s</key>", key) >= (int)sizeof(wanted)) return 0;
  const char *found = strstr(text, wanted);
  if (found == NULL) return 0;
  const char *open_tag = strstr(found, "<string>");
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
                  || (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_'
                  || (spaces && c == ' ');
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

static int run_to_completion(const char *program, char *const argv[]) {
  pid_t child = fork();
  if (child < 0) return 0;
  if (child == 0) {
    execv(program, argv);
    _exit(127);
  }
  int status = 0;
  if (waitpid(child, &status, 0) < 0) return 0;
  return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

// Put the kept-aside bundle back where the broken one is.
//
// Everything that moves, moves inside the folder the application is in, so no
// rename crosses a volume: `/Applications` reaches the same disk as a home
// directory through a firmlink, and a rename across one of those is refused.
// The copy that does cross is done by ditto, which copies a signed bundle as a
// signed bundle -- extended attributes, symlinks and all.
//
// The broken one is moved aside rather than written over. ditto merges into
// what is already there, so a version that added a framework, renamed a
// resource or shipped a helper the old one never had would leave those files
// inside the restored bundle -- and a bundle carrying files its signature does
// not cover is one macOS refuses to open. That is a rollback that produces a
// second application that will not start.
//
// And it is moved, not deleted, and moved back if anything fails: there is an
// application in place at every moment of this.
static int restore(const char *kept_aside, const char *bundle) {
  char folder[PATH_MAX];
  strncpy(folder, bundle, sizeof(folder) - 1);
  folder[sizeof(folder) - 1] = '\0';
  char *slash = strrchr(folder, '/');
  if (slash == NULL || slash == folder) return 0;
  *slash = '\0';
  const char *name = slash + 1;

  char coming[PATH_MAX];
  char going[PATH_MAX];
  if (snprintf(coming, sizeof(coming), "%s/.%s.restoring", folder, name)
          >= (int)sizeof(coming)
      || snprintf(going, sizeof(going), "%s/.%s.broken", folder, name)
          >= (int)sizeof(going)) {
    return 0;
  }

  char *const clear_coming[] = { "rm", "-rf", coming, NULL };
  char *const clear_going[] = { "rm", "-rf", going, NULL };
  run_to_completion("/bin/rm", clear_coming);
  run_to_completion("/bin/rm", clear_going);

  char *const copy[] = { "ditto", (char *)kept_aside, coming, NULL };
  if (!run_to_completion("/usr/bin/ditto", copy)) {
    run_to_completion("/bin/rm", clear_coming);
    return 0;
  }
  if (rename(bundle, going) != 0) {
    run_to_completion("/bin/rm", clear_coming);
    return 0;
  }
  if (rename(coming, bundle) != 0) {
    rename(going, bundle);
    run_to_completion("/bin/rm", clear_coming);
    return 0;
  }
  run_to_completion("/bin/rm", clear_going);
  return 1;
}

// Only one of these may restore.
//
// Two updates cannot overlap, but two watchers can: an install postponed until
// a drive is ejected leaves one waiting while the app carries on and starts
// another. Two writers, one application, and what is left is neither version.
//
// O_EXCL is the whole of the lock: whoever creates the file restores, and the
// other leaves the application alone. A stale one from a watcher that died
// mid-copy is ignored after a minute, since a copy takes seconds and a lock
// nobody can clear is an application that never comes back.
#define LOCK_STALE_AFTER 60

static int take_restore_lock(const char *support) {
  char path[PATH_MAX];
  if (!join(path, sizeof(path), support, "/restoring")) return 0;

  struct stat info;
  if (stat(path, &info) == 0) {
    time_t now = time(NULL);
    if (now - info.st_mtime < LOCK_STALE_AFTER) return 0;
    // Stale, so it is cleared -- but two watchers can reach this line
    // together, and the second unlink would take away the lock the first has
    // just made. Only the process whose unlink removed the file it actually
    // looked at goes on to create one, and creation is exclusive, so exactly
    // one wins either way.
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

// Whether the version that arrived can be started at all.
//
// Not "did it draw a window": that is the app's own question, asked over three
// launches, and answering it needs somebody to be looking. This one is
// narrower and is answered in a second. `--verify-launch` reaches `main` and
// exits without raising anything, so a zero here means dyld resolved every
// library and our code ran. A binary the system refuses to load cannot reach
// it.
//
// A bundle this cannot read the executable name out of answers yes. Being
// unsure is not evidence that an update is broken, and undoing one on no
// evidence is the worse mistake.
static int the_new_version_starts(const char *bundle, const char *contents) {
  char executable[256];
  if (!plist_string(contents, "CFBundleExecutable", 1, executable, sizeof(executable))) return 1;

  char path[PATH_MAX];
  if (snprintf(path, sizeof(path), "%s/Contents/MacOS/%s", bundle, executable)
      >= (int)sizeof(path)) {
    return 1;
  }
  if (!exists(path)) return 0;

  char *const argv[] = { path, "--verify-launch", NULL };
  return run_to_completion(path, argv);
}

int main(int argc, char *argv[]) {
  if (argc < 3) {
    fprintf(stderr, "usage: %s <bundle path> <outgoing build>\n", argv[0]);
    return 2;
  }
  const char *bundle = argv[1];
  const char *outgoing = argv[2];

  char contents[PATH_MAX];
  if (!join(contents, sizeof(contents), bundle, "/Contents")) return 1;

  // What this application calls itself, which is its identifier and not the
  // name of the file. Renaming an app in Finder is somebody tidying up; it
  // should not orphan the copy kept aside for putting back.
  char bundle_name[256];
  if (!plist_string(contents, "CFBundleIdentifier", 0, bundle_name, sizeof(bundle_name))) {
    return 1;
  }

  char support[PATH_MAX], kept_aside[PATH_MAX];
  if (!support_directory(support, sizeof(support), bundle_name)) return 1;
  if (snprintf(kept_aside, sizeof(kept_aside), "%s/previous/%s.app", support, bundle_name)
      >= (int)sizeof(kept_aside)) {
    return 1;
  }
  // Nothing to put back, so there is nothing worth watching for. This is what
  // an update whose keep-aside copy failed looks like, and what a stray
  // invocation looks like.
  if (!exists(kept_aside)) return 0;

  // Wait for the swap. The installer runs after the app has quit, so the build
  // number in the bundle is the outgoing one until the moment it is not.
  char build[256];
  int swapped = 0;
  for (long waited = 0; waited < (long)SWAP_WAIT_SECONDS * 1000000L;
       waited += POLL_MICROSECONDS) {
    if (plist_string(contents, "CFBundleVersion", 0, build, sizeof(build))
        && strcmp(build, outgoing) != 0) {
      swapped = 1;
      break;
    }
    usleep(POLL_MICROSECONDS);
  }
  // The update was turned down, or postponed past this watch. What is
  // installed is what was already there.
  if (!swapped) return 0;

  if (the_new_version_starts(bundle, contents)) return 0;

  if (!take_restore_lock(support)) return 0;
  int put_back = restore(kept_aside, bundle);
  release_restore_lock(support);
  if (!put_back) return 1;

  // Open what was put back, so the person ends up looking at an application
  // that works rather than at whatever the failed launch left on screen.
  char *const open_it[] = { "open", "-n", (char *)bundle, NULL };
  run_to_completion("/usr/bin/open", open_it);
  return 0;
}
