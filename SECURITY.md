# Security

Legato hears everything you dictate and can type into any app, so it has two permissions that deserve care: the Microphone and Accessibility. Problems that could expose what people say or let something else act through those permissions are taken seriously.

## Reporting a vulnerability

Please do not open a public issue. Report it privately through GitHub instead: on the repository's Security tab, choose **Report a vulnerability**. Include the Legato version, your macOS version, and the steps to reproduce.

You should hear back within a week. Once a fix is out, the report is credited in the release notes unless you prefer otherwise.

## What counts

Examples of what to report:

- audio, transcripts or history leaving the Mac when the local model is selected and no API is set;
- an API key readable from somewhere other than the Keychain;
- a way for another app or a website to trigger dictation, read the history, or make Legato type text;
- a downloaded model or update being replaced with something else.

Wrong transcriptions, crashes without a security impact, and the macOS warning about the build not being notarized are ordinary issues.

## Supported versions

Only the latest release gets fixes.
