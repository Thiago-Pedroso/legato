# Contributing to Legato

Thanks for wanting to help. Legato is a small app kept small on purpose, so the best contributions fix something that gets in the way of dictating, or make it more accurate on real speech.

## Reporting a problem

Open an issue with your Mac model, macOS version, the speech engine you use (Settings, Transcription) and what you said versus what came out. If transcription is wrong, say which language you were speaking.

A recording helps more than anything else, but recordings are personal. Legato keeps each dictation in `~/Library/Application Support/Legato/recordings`; attach one only if you are fine with it being public, or record a new one that says the same kind of thing. You can check what the app does with a file before sending it:

```bash
/Applications/Legato.app/Contents/MacOS/Legato --transcribe your-recording.wav
```

For anything that could put other people's privacy or Macs at risk, follow [SECURITY.md](SECURITY.md) instead of opening an issue.

## Before writing code

For anything bigger than a bug fix, open an issue first and describe what you want to change. Some ideas that seem natural, like sending text to a cloud service by default or adding an account, go against what Legato is for, and it is better to find that out before you spend an afternoon on it.

## Building and testing

You need Apple Silicon, macOS 14 or newer and the Xcode Command Line Tools. Xcode is not needed.

```bash
make signing   # once: a local signing identity, so macOS keeps the app's permissions between builds
make test      # unit tests
make run       # builds build/Legato.app and opens it
```

The package has two targets. `LegatoCore` holds the logic that runs without a microphone or a screen: key handling, text processing, vocabulary, history, settings. `Legato` is the app around it. When you change behavior, put the decision in `LegatoCore` where you can, and cover it with a test in `Tests/LegatoCoreTests`.

Changes to transcription quality need numbers, not impressions. Transcribe the same recordings before and after with `--transcribe` and say in the pull request what changed, including sentences that got worse. A change to the vocabulary matching must not alter text that has no vocabulary terms in it.

## Code style

- Follow what the surrounding code does. There is no formatter config, so match the indentation and wrapping of the file you are in.
- Prefer Apple's frameworks and the dependencies already in `Package.swift` over new ones.
- Write comments for the reason behind non-obvious code, not for what the code says.
- User-facing text comes in English and Portuguese, next to the code that shows it: `L.t("Copy", "Copiar")`.

## Commits and pull requests

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org): a type, an optional scope, and a short title in the imperative, around 72 characters, such as `fix(hotkey): end hands-free when the key is released`. The title is usually enough; add a body only when the reason for the change is not obvious from the diff.

Keep each pull request to one change. CI runs the tests on every pull request, and it needs to pass before merging.

By contributing you agree that your work is released under the [MIT License](LICENSE).
