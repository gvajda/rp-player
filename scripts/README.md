# scripts

## make-app.sh — local `.app` wrapper

Builds an unsigned local `.app` for development testing (notifications, hog mode, etc.).

```
./scripts/make-app.sh [debug|release]   # default: release
```

Output: `build/RP Player.app`. Run with `open "build/RP Player.app"` or move to `/Applications/`.

PR 13 will replace this with a CI-built artifact.

### One-time setup: self-signed certificate (required for notifications)

`UNUserNotificationCenter.requestAuthorization` returns
`UNErrorDomain Code=1 "Notifications are not allowed for this application"`
when the app is ad-hoc signed (the default). The notification daemon
(`usernoted`) requires a **stable code-signing identity** before it will
register the bundle and show the permission prompt.

Create a self-signed cert named `RP Player Dev` once. The script auto-detects
it on next build.

1. Open **Keychain Access** (`open -a "Keychain Access"`).
2. Menu: **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Settings:
   - **Name:** `RP Player Dev`
   - **Identity Type:** `Self Signed Root`
   - **Certificate Type:** `Code Signing`
   - **Let me override defaults:** unchecked (defaults are fine)
4. Click **Create**, then **Done**.

Verify:

```bash
security find-identity -v -p codesigning | grep "RP Player Dev"
```

Should print something like:
```
1) ABCD...EFGH "RP Player Dev"
```

Now rebuild the app:

```bash
./scripts/make-app.sh
```

The script's `==> codesign` step should print `using identity: RP Player Dev`
instead of `using ad-hoc`. Move the rebuilt `.app` to `/Applications/` and
launch — the notification prompt should now appear on first request.

### Reset notification state for testing

If notification permission state is cached as denied or never-prompted:

```bash
tccutil reset All com.gvajda.rpplayer
killall NotificationCenter
killall usernoted 2>/dev/null
```

Then relaunch the `.app`.
