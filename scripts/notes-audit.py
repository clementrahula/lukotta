#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Build the pack a different model audits a release's translated notes with.

    ./scripts/notes-audit.py <version> [--out dist/notes-audit] [--zip]

The English notes for a release are written, de-slopped and approved by hand.
The translations of them are drafted, and a draft nobody who speaks the
language has read is exactly the kind of prose this project does not ship. So
each one goes out to be read by a different model before it is published.

What that reader is given is deliberately small: this version's English notes,
this version's draft in one language, and the glossary that says which words
are not free to translate. Not the previous releases -- a term that has to be
consistent across versions belongs in the glossary, and if it is not there,
that is the thing to fix rather than something to infer from history.

The result is advisory. It proposes; it does not decide. Every proposal has to
carry its reason, because a change nobody can weigh is a change nobody can
accept, and these are then read again against the translation already there.

The release channel only. A pre-release's notes stay in English.
"""
import argparse
import json
import pathlib
import shutil
import sys

HERE = pathlib.Path(__file__).resolve().parent.parent


def glossary(terms_path):
    """terms.json as prose, because that file is shaped for a program."""
    data = json.loads(terms_path.read_text())
    out = ["# Words that are not free to translate", "",
           "These are the application's own rules, and the notes follow them.",
           "The interface and the release notes are read by the same person, "
           "often in the same minute, and must not disagree about what "
           "anything is called.", ""]

    policies = data.get("policies", {})
    out += ["| Policy | What it means |", "| --- | --- |"]
    for name, meaning in policies.items():
        out.append(f"| **{name}** | {meaning} |")
    out.append("")

    by_policy = {}
    for entry in data.get("terms", []):
        by_policy.setdefault(entry.get("policy", "?"), []).append(entry)

    for policy, entries in by_policy.items():
        out.append(f"## {policy}")
        out.append("")
        for entry in entries:
            reason = entry.get("reason", "")
            out.append(f"- **{entry['term']}** — {reason}" if reason
                       else f"- **{entry['term']}**")
        out.append("")

    verify = data.get("apple_terms_to_verify")
    if verify:
        out += ["## Check these against the reader's own Mac", "",
                "Where macOS is offered in this language, these must read as "
                "Apple writes them, because the reader is looking at that "
                "screen while reading this sentence.", ""]
        out += [f"- {t}" for t in verify]
        out.append("")
    return "\n".join(out)


PROMPT = """# Audit the translated release notes for {name} {version}

You are reading {count} draft translations of one short changelog. Your job is
to find what is wrong with them and say why. You are not being asked to
approve anything, and nothing you write is applied automatically: every
proposal you make is read again by the maintainer and weighed against the
translation already in place.

## What these notes are

Two or three sentences that appear in two places: the panel Sparkle shows when
it offers an update, and the body of the release on GitHub. The reader is
someone who already uses the application and wants to know what changed. They
are not a developer, and they did not ask for detail.

The English has already been written, cut back and approved. Treat it as
settled: do not propose changes to it. It is here so you can judge whether a
translation says the same thing.

## What to look for, in this order

1. **It says something the English does not.** A translation that adds a
   claim, drops a qualification, or reverses a meaning. This matters more than
   everything below it put together.
2. **A term that is not free to translate has been translated** — or a term
   that should follow Apple's own macOS wording does not. `glossary.md` says
   which is which.
3. **A format specifier is missing, altered, or reordered wrongly.** `%1$@`
   and `%@` must survive. A lost one is a crash or a wrong number in front of
   somebody.
4. **It does not read like the language.** Calques, English word order, a
   register that is stiffer or chattier than the English. Say what a person
   writing that language would have written.
5. **Plain error.** Grammar, agreement, case, orthography, punctuation the
   language does not use.

Do not propose a change because you would have phrased it differently. A
defensible translation that is not your preference is not a fault, and saying
so wastes the maintainer's time. If a draft is sound, say it is sound.

## What to hand back

Markdown. One section per language, in this shape, and nothing else:

    ## et — Estonian

    ### 1. Terminology — high confidence
    - **Draft:** <the exact sentence from the draft, copied, unaltered>
    - **Proposed:** <the full replacement sentence>
    - **Why:** <why the draft is wrong, in one or two sentences. Name the rule,
      the grammatical fact, or the glossary entry. "It sounds better" is not a
      reason and will be discarded.>

    ### 2. ...

    No further findings.

Rules for that:

- **Every finding carries a Why.** One without a reason cannot be weighed and
  will be thrown away unread.
- **Category** is one of: meaning, terminology, placeholder, register, grammar.
- **Confidence** is high, medium or low. Use low honestly — a guess marked
  high costs more than a guess marked low.
- Copy the draft sentence **exactly**, so it can be found and replaced.
- A language with nothing wrong gets a heading and `No findings.` Say so
  rather than inventing something to fill the space.
- If you do not know a language well enough to judge it, write
  `Not assessed — insufficient competence.` That is a useful answer. A
  confident wrong one is not.

## Do this in as many runs as it takes

Do not try to finish in one pass. Each language is short, but there are many
of them, and a model that sets out to do all of them in one go tends to go
quiet somewhere in the middle and produce nothing usable at all.

So work in runs:

- **Take as many as you need.** Cover a few languages per run, properly,
  rather than all of them badly.
- **Write your findings to a Markdown file at the end of every run**, before
  you run out of room. Name them `findings-01.md`, `findings-02.md`, and so
  on. A run that ends without writing its file is a run that never happened.
- **Finish every file with a `## Where this run stopped` section** naming what
  you covered and what is still untouched, so the next run knows where to
  begin and nothing is quietly skipped.
- **Never stop mid-language.** End at a boundary, or say plainly in that
  section that you stopped part-way through one, and where.

Partial work written down beats complete work that never arrives.

## What is in this pack

- `english/{version}.md` — the approved English. Settled; do not change it.
- `glossary.md` — the words that are not free to translate, and the rule for
  each.
- `<language>/{version}.draft.md` — one draft per language, the thing you are
  auditing. The `<!-- heading: … -->` line is that language's word for
  "Version" and is audited like any other string.
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("version")
    ap.add_argument("--out", default=None)
    ap.add_argument("--zip", action="store_true",
                    help="also write a .zip beside the directory")
    ap.add_argument("--name", default="Lukotta")
    args = ap.parse_args()

    english = HERE / "releases" / f"{args.version}.md"
    if not english.is_file():
        sys.exit(f"error: no {english.relative_to(HERE)} to audit against")

    drafts_dir = HERE / "releases" / "notes" / args.version
    drafts = sorted(drafts_dir.glob("*.md")) if drafts_dir.is_dir() else []
    if not drafts:
        sys.exit(f"error: no drafts in releases/notes/{args.version}/.\n"
                 f"       Draft the translations first; this pack is for "
                 f"auditing them, not for asking somebody else to write them.")

    out = pathlib.Path(args.out) if args.out else HERE / "dist" / f"notes-audit-{args.version}"
    if out.exists():
        shutil.rmtree(out)
    (out / "english").mkdir(parents=True)

    shutil.copyfile(english, out / "english" / f"{args.version}.md")
    (out / "glossary.md").write_text(
        glossary(HERE / "translations" / "context" / "terms.json"))

    languages = []
    for draft in drafts:
        lang = draft.stem
        (out / lang).mkdir(parents=True, exist_ok=True)
        shutil.copyfile(draft, out / lang / f"{args.version}.draft.md")
        languages.append(lang)

    (out / "PROMPT.md").write_text(PROMPT.format(
        name=args.name, version=args.version, count=len(languages)))

    print(f"  {out.relative_to(HERE) if out.is_relative_to(HERE) else out}")
    print(f"    {len(languages)} languages: {', '.join(languages)}")

    if args.zip:
        archive = shutil.make_archive(str(out), "zip", root_dir=out.parent,
                                      base_dir=out.name)
        size = pathlib.Path(archive).stat().st_size
        print(f"    {pathlib.Path(archive).name} ({size / 1024:.0f} KB)")


if __name__ == "__main__":
    main()
