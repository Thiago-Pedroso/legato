> [!NOTE]
> This build is not notarized by Apple yet, so macOS will not open it the first time.
>
> 1. Unzip it and move Legato to Applications.
> 2. Open it. When macOS refuses, go to System Settings, Privacy & Security, and click **Open Anyway** next to the message about Legato.
>
> The build also has no stable signature, so after each update macOS asks again for the Microphone and Accessibility permissions. If Legato stops reacting to the dictation key, remove it from System Settings, Privacy & Security, Accessibility, and add it again.
>
> Building from source with `make signing` avoids both, as the README explains.
