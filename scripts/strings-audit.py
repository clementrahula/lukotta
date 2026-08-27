#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Build the pack a different model audits the update interface with.

    ./scripts/strings-audit.py [--out DIR] [--zip]

Sparkle carries 35 localisations and this application has 37. The nine it does
not ship -- and Simplified Chinese, which it files under a different name --
were drafted here rather than by anybody who speaks them, and a draft nobody
has read is exactly the prose this project does not ship.

These are worse to get wrong than a changelog. A changelog is read once; this
is the dialog that asks somebody whether to install something, and a word that
lands wrongly there is a word that stops them updating.

Each language gets one file, English beside draft, numbered, so a finding can
name a line. The glossary is the application's own, built from
translations/context/terms.json rather than written again here.

The result is advisory. It proposes; it does not decide.
"""
import argparse
import json
import pathlib
import shutil
import sys

HERE = pathlib.Path(__file__).resolve().parent.parent
SOURCE = HERE / "translations" / "sparkle"
ENGLISH = "_english.json"

# What each is, so a reader who has never seen Sparkle knows where the words
# land. Keyed by a fragment of the English.
WHERE = [
    ("is now available", "The alert offering an update. The most-read string here."),
    ("has been downloaded", "The alert once the download is finished."),
    ("An error occurred", "A failure alert. Plain, not alarming."),
    ("is currently the newest", "Shown when the reader checked and there was nothing."),
    ("automatically check", "The question asked once, on first run."),
    ("system profile", "The panel explaining what would be sent. Nothing is sent."),
    ("CPU", "A row label in that panel. Terse; it sits in a narrow column."),
    ("macOS version", "Refused because the Mac is too old or too new."),
    ("Applications folder", "Instructions to move the app. Names a real folder."),
]


def glossary(terms_path):
    """terms.json as prose, because that file is shaped for a program."""
    data = json.loads(terms_path.read_text())
    out = ["# Words that are not free to translate", "",
           "The application's own rules. The update dialogs and the interface "
           "behind them are read by the same person in the same minute and "
           "must not disagree about what anything is called.", ""]
    out += ["| Policy | What it means |", "| --- | --- |"]
    for name, meaning in data.get("policies", {}).items():
        out.append(f"| **{name}** | {meaning} |")
    out.append("")
    by_policy = {}
    for entry in data.get("terms", []):
        by_policy.setdefault(entry.get("policy", "?"), []).append(entry)
    for policy, entries in by_policy.items():
        out += [f"## {policy}", ""]
        for entry in entries:
            reason = entry.get("reason", "")
            out.append(f"- **{entry['term']}** — {reason}" if reason
                       else f"- **{entry['term']}**")
        out.append("")
    verify = data.get("apple_terms_to_verify")
    if verify:
        out += ["## Check these against the reader's own Mac", "",
                "Where macOS is offered in this language these must read as "
                "Apple writes them: the reader is looking at that screen "
                "while reading the sentence.", ""]
        out += [f"- {t}" for t in verify]
        out.append("")
    return "\n".join(out)


def where(text):
    for fragment, note in WHERE:
        if fragment in text:
            return note
    return ""


def sheet(lang, english, drafts, drafted):
    """One language, English beside draft, numbered so a finding can point."""
    out = [f"# {lang} — Sparkle's update interface", "",
           f"{len(drafts)} of {len(english)} strings. Any not here fall back "
           f"to English one string at a time.", "",
           "`%@`, `%1$@`, `%2$@`, `%3$@` are substituted at runtime with the "
           "application's name, a version number or a size. They must survive "
           "translation. Their **order may change** to suit the language — "
           "that is what the numbered forms are for — but none may be dropped "
           "or invented.", "", "---", ""]
    for i, key in enumerate(sorted(drafts), 1):
        note = where(english[key])
        source = "drafted here" if key in drafted else "Sparkle's own"
        out += [f"### {i} — {source}",
                "",
                f"- **English:** {english[key]}"]
        if note:
            out.append(f"- **Where:** {note}")
        out += [f"- **{lang}:** {drafts[key]}", ""]
    return "\n".join(out) + "\n"


PROMPT = """# Audit the update interface of {name}, in {count} languages

You are reading draft translations of the dialogs this application shows when
it offers, downloads and installs an update. They were drafted by a language
model, not by anyone who speaks these languages, and they have not been
reviewed. That is what you are for.

Nothing you write is applied automatically. Every proposal is read again by the
maintainer and weighed against the translation already in the application.

## Why these matter more than they look

This is the dialog that asks somebody whether to install something on their own
computer. A word that lands wrongly here does not merely read badly: it makes
the reader distrust the thing asking, and they stop updating. Several of these
strings are the only sentence some users will ever read in their own language
from this application.

They also sit beside the application's own interface, which is already
translated and already in front of the reader. The two must not disagree about
what anything is called.

## What to look for, in this order

1. **A format specifier is missing or invented.** `%@`, `%1$@`, `%2$@`, `%3$@`
   are replaced at runtime by the application's name, a version, or a size.
   Their order may change to suit the language — that is what the numbered
   forms are for — but a dropped one is a crash or a blank where a version
   should be, and an invented one is a crash.
2. **It says something the English does not.** Especially anything that
   changes what the reader is agreeing to: which thing is being installed,
   whether it is optional, whether something will restart.
3. **A term that is not free to translate has been translated**, or one that
   must follow Apple's own macOS wording does not. `glossary.md` says which is
   which. Names of real interface elements — the Applications folder, System
   Settings, Privacy & Security — must read exactly as that language's macOS
   writes them, because the reader is looking at that screen.
4. **The register is wrong for a system dialog.** These should read as the
   operating system reads: plain, unexcited, neither chatty nor stiff. Note
   especially where a language distinguishes formal and familiar address and
   the draft has chosen against the platform's convention.
5. **Plain error.** Grammar, agreement, case, orthography, spacing, quotation
   marks, punctuation the language does not use.

Two things to leave alone. Do not propose a change because you would have
phrased it differently — a defensible translation that is not your preference
is not a fault. And do not propose changes to the English; it is Sparkle's own
and cannot be changed here.

## What to hand back

Markdown. One section per language, in this shape, and nothing else:

    ## et — Estonian

    ### String 14 — terminology — high confidence
    - **Draft:** <the draft line, copied exactly, unaltered>
    - **Proposed:** <the full replacement>
    - **Why:** <why the draft is wrong, in one or two sentences. Name the rule,
      the grammatical fact, the glossary entry, or the macOS convention.
      "It reads better" is not a reason and will be discarded.>

    ### String 31 — ...

    No further findings.

Rules for that:

- **Every finding carries a Why.** One without a reason cannot be weighed and
  will be thrown away unread. This is the whole point of the exercise.
- **String N** is the number in that language's file. Always give it.
- **Category** is one of: placeholder, meaning, terminology, register,
  grammar.
- **Confidence** is high, medium or low. Use low honestly — a guess marked
  high costs more than a guess marked low.
- Copy the draft **exactly**, so it can be found and replaced mechanically.
- A language with nothing wrong gets its heading and `No findings.` Say that
  rather than inventing something to fill the space.
- If you do not know a language well enough to judge it, write
  `Not assessed — insufficient competence.` That is a useful answer. A
  confident wrong one is worse than none, because it will be believed.

## Two kinds of string, and both are in scope

Each string is labelled **drafted here** or **Sparkle's own**.

**Drafted here** was written by a language model for this application. Assume
nothing about it.

**Sparkle's own** came from the update framework upstream. Do not assume it is
correct because it shipped. Four were already found wrong without looking for
them: Finnish said `pävitys` for `päivitys` and used a plural where the English
was singular; Arabic had one string cut off mid-word and another never
translated at all. Those four have been replaced and are now labelled as
drafted. There may be more, and finding them is as useful as anything else
here.

## What is in this pack

- `<language>/strings.md` — one file per language, English beside the
  translation, numbered, each labelled with where it came from. This is what
  you are auditing.
- `glossary.md` — the words that are not free to translate, and the rule for
  each. Generated from the application's own term list.
- `english/_source.json` — all {total} English strings as Sparkle ships them,
  if you want to see one in full.

Languages in this pack: {languages}.
"""

NAMES = {
    "ar": "Arabic", "bg": "Bulgarian", "cs": "Czech", "da": "Danish",
    "de": "German", "el": "Greek", "es": "Spanish", "et": "Estonian",
    "fi": "Finnish", "fil": "Filipino", "fr": "French", "he": "Hebrew",
    "hi": "Hindi", "hr": "Croatian", "hu": "Hungarian", "id": "Indonesian",
    "it": "Italian", "ja": "Japanese", "ko": "Korean", "lt": "Lithuanian",
    "lv": "Latvian", "ms": "Malay", "nb": "Norwegian Bokmål", "nl": "Dutch",
    "pl": "Polish", "pt-PT": "Portuguese (Portugal)", "ro": "Romanian",
    "ru": "Russian", "sl": "Slovenian", "sq": "Albanian", "sv": "Swedish",
    "th": "Thai", "tr": "Turkish", "uk": "Ukrainian", "vi": "Vietnamese",
    "zh-Hans": "Chinese (Simplified)",
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=None)
    ap.add_argument("--zip", action="store_true")
    ap.add_argument("--name", default="Lukotta")
    args = ap.parse_args()

    english = json.loads((SOURCE / ENGLISH).read_text())
    provenance = json.loads(
        (SOURCE / "_provenance.json").read_text())["languages"]
    langs = sorted(p.stem for p in SOURCE.glob("*.json")
                   if not p.stem.startswith("_"))
    if not langs:
        sys.exit("error: no drafts in translations/sparkle/")

    out = pathlib.Path(args.out) if args.out else HERE / "dist" / "strings-audit"
    if out.exists():
        shutil.rmtree(out)
    (out / "english").mkdir(parents=True)

    shutil.copyfile(SOURCE / ENGLISH, out / "english" / "_source.json")
    (out / "glossary.md").write_text(
        glossary(HERE / "translations" / "context" / "terms.json"))

    for lang in langs:
        drafts = json.loads((SOURCE / f"{lang}.json").read_text())
        drafted = set(provenance.get(lang, {}).get("drafted", []))
        (out / lang).mkdir(parents=True, exist_ok=True)
        (out / lang / "strings.md").write_text(
            sheet(lang, english, drafts, drafted))

    described = ", ".join(f"{l} ({NAMES.get(l, l)})" for l in langs)
    (out / "PROMPT.md").write_text(PROMPT.format(
        name=args.name, count=len(langs), total=len(english),
        languages=described))

    print(f"  {out}")
    print(f"    {len(langs)} languages, {len(english)} English strings")
    if args.zip:
        archive = shutil.make_archive(str(out), "zip", root_dir=out.parent,
                                      base_dir=out.name)
        size = pathlib.Path(archive).stat().st_size
        print(f"    {pathlib.Path(archive).name} ({size / 1024:.0f} KB)")


if __name__ == "__main__":
    main()
