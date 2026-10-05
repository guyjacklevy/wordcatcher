# Word Catcher

Mark an English word anywhere on your Mac and get the Hebrew translation and its meaning in that sentence. Every word is saved so you can review it later.

## Use it

1. Select a word in any app (Claude, Slack, Mail, Chrome, a PDF…).
2. Press **⌃⌥T** (Control + Option + T).
3. A card shows the Hebrew translation and what the word means in that sentence. It's saved automatically. Use Undo if you didn't mean it.

If an app won't share the sentence, select the whole sentence instead and press ⌃⌥T. Then tap every word you don't know.

## First run

- **Accessibility permission**: macOS asks for it the first time. Word Catcher needs it to read what you selected. Turn it on in System Settings → Privacy & Security → Accessibility.
- **Claude API key**: paste it in the window that opens (menu bar book icon → Claude API key…). It's stored in your Keychain.

## Phone app (review)

`web/` is the phone app: My words + the daily review with spaced repetition. It's a static site (no build step), deployed on Vercel with root directory `web`. On the phone: open it in Safari → Share → Add to Home Screen, then sign in with the same email as the Mac.

Words sync through Supabase (project `wordcatcher`, id `aceyqtcljidnfzesqyjq`). Each account sees only its own rows (Row Level Security). Sign-in is a 6-digit code sent by email. The Supabase Magic Link and Confirm signup email templates must include `{{ .Token }}`.

On the Mac: menu bar book icon → Sync with your phone… → sign in once. Saved words are pushed automatically.

Daily reminder: in the phone app, turn on "Daily reminder" and pick a time. The `reminders` edge function runs every hour (pg_cron) and sends a web push at each device's local reminder time, only on days with words due. VAPID keys and the cron key live in `app_secrets` (server-only).

## Build

```bash
./scripts/install.sh
```

This builds the app, installs it as `~/Applications/WordCatcher.app` and starts it. It opens at login (menu: Open at login).

Requires the Swift toolchain (Xcode Command Line Tools is enough).

## Where things live

- Saved words: `~/Library/Application Support/WordCatcher/words.json` (the cloud copy is in Supabase)
- Phone sync session: `~/Library/Application Support/WordCatcher/session.json` (readable only by you)
- Diagnostic log (capture method per app, never the text): `~/Library/Logs/WordCatcher.log`
- Claude model: `Translator.model` in `Sources/WordCatcher/Translator.swift`
