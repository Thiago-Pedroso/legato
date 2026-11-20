---
description: Scan project folders for names and jargon and queue them as Legato vocabulary suggestions
argument-hint: [folder ...]
---

Build vocabulary suggestions for Legato, the dictation app, from the folders the user works in.
Folders to scan: $ARGUMENTS (if none were given, use the current working directory).

The Legato binary is at `/Applications/Legato.app/Contents/MacOS/Legato`. Call it `legato` below.
Nothing here changes the user's vocabulary: suggestions wait in the app until the user accepts them.

1. Run `legato vocab candidates <folders>`. It reads prose files (README, docs, notes) and commit
   subjects, and prints a JSON list of capitalized names, acronyms and mixed-case words with a count
   and an example line. Words already in the user's vocabulary are left out.

2. Curate the list. Keep what a person would say out loud while dictating: names of people,
   companies, products, projects, tools, and acronyms they use as words. Drop code identifiers,
   file names, heading words, and anything that is ordinary Portuguese or English. You may add a
   term the scan missed if the examples make clear it matters. Aim for the 20 to 40 that matter most.

3. Run `legato vocab probe "Term One" "Term Two" ...` with the curated terms. It speaks each term
   with the Mac's synthetic voices, transcribes it with the user's speech model, and prints JSON with
   `ok` (the model got it right) and `heard` (what it wrote instead). Terms with `ok: true` need no
   help and must not be suggested.

4. For the terms that were missed, add a short `note` in the user's language saying what the term is
   ("empresa cliente", "ferramenta de deploy"). Then pipe the JSON array (same shape as the probe
   output, plus `note`) into `legato vocab suggest --source "<folder names>"`.

5. Tell the user how many suggestions are waiting and that they can review them in Legato,
   Settings, Vocabulary. Mention that the test used synthetic voices, so their own pronunciation
   may differ.
