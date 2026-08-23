# Reviewing a translation

Everything needed to judge a translation is in this folder and its siblings.
Nothing here refers to the source code, and none of it has to be read in a
particular order.

## What is where

| File | What it holds |
| --- | --- |
| `../en.json` | The canonical English. Every other file is a translation of this one. |
| `../<language>.json` | One language. The same keys as English, and the same plural categories that language actually has. |
| `strings.json` | One entry per English string: which screens it appears on, what it means, and what each placeholder carries. |
| `screens.json` | Every screen and sheet in the app: when it is shown, what it is for, and the tone it is written in. |
| `terms.json` | Words that are not free to translate, and the reason for each. |

## How a translation file is shaped

```json
{
  "plurals": { "<English key>": { "en": {"one": "…", "other": "…"},
                                  "de": {"one": "…", "other": "…"} } },
  "strings": { "<English key>": "<the translation>" }
}
```

The key is the English string itself. A string carrying a count lives under
`plurals` instead, with one form per category that language has — English has
two, Russian has four, Arabic has six, Japanese has one. Getting the set of
categories wrong is a bug, not a style choice.

## The rules a translation is judged by

1. **English is canonical.** Where a translation and the English disagree about
   meaning, the English is right and the translation is wrong. It has been read
   line by line; assume every word in it is deliberate.
2. **Placeholders survive.** `%@` and `%lld` must all be present, and where a
   string has more than one, the translation must use the positional form
   (`%1$@`, `%2$@`) if the order changes. A missing placeholder is a crash
   waiting to happen; a reordered one without positions puts the wrong value in
   the wrong place.
3. **A sentence naming a button uses the button's own words.** If the interface
   calls the button *Neu starten*, the sentence telling somebody to click it
   says *Neu starten* and not a synonym.
4. **Apple's words for Apple's things.** Panes, folders and features belong to
   macOS, and the reader is looking at their own Mac while they read. Use the
   words their Mac uses — and where macOS is not offered in this language,
   leave those names in English, because that is what their Mac shows. See
   `terms.json`.
5. **Format and product names are never translated**, in any script: NTFS,
   BitLocker, LUKS, qcow2, VMDK, Finder, macOS.
6. **Tone.** Nothing here scolds, apologises, or exclaims. A failure states what
   happened. An instruction says what to do. There are no exclamation marks in
   the English and there should be none in a translation.
7. **Length.** These are labels in a window 580 to 640 points wide. A
   translation twice the length of the English will be cut off. Where the
   English is a fragment without a full stop, the translation is too.

## What to report

For each string that should change: the key, the current translation, the
proposed one, and which rule above it breaks. Where a string is right but
awkward, say so separately — that is worth knowing and is not the same finding.
