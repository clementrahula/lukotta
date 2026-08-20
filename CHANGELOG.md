# Changelog

## 1.7.0

- Drives holding several volumes now open all of them at once. A container with
  LVM inside it could previously not be opened at all.
- Drives are noticed as they are plugged in and pulled out, rather than when the
  window is next refreshed.
- A drive that stops responding is disconnected cleanly instead of leaving macOS
  asking about a server that will never answer.
- Windows drives that Windows left in a hibernated state are retried with a
  driver that can mount them. That retry existed but had never run.
- A password that is refused is described as a refused password rather than as a
  fault in the engine.
- The drive list says whether each drive is locked or open, and keeps a drive's
  details when it opens.
- Software updates, checked daily and installed automatically. Both can be
  turned off in Settings.
