# Word Catcher

Mark an English word anywhere on your Mac and get the Hebrew translation and its meaning in that sentence. Every word is saved so you can review it later.

## Use it

1. Select a word in any app (Claude, Slack, Mail, Chrome, a PDF…).
2. Press **⌃⌥T** (Control + Option + T).
3. A card shows the Hebrew translation and what the word means in that sentence. It's saved automatically. Use Undo if you didn't mean it.

Select a whole English sentence and press ⌃⌥T to see it in Hebrew (with Copy), and tap any words you don't know to save them. This also works when an app won't share the sentence around a single word.

### Writing: say it in English

Writing in English but only know a word in Hebrew? Type it in Hebrew inside your sentence ("We need to להגיש the proposal by Friday"), select the sentence and press ⌃⌥T. Word Catcher suggests the English that fits (in the right form, with alternatives and when to use each). **Use it** puts the English into your text; **Copy** puts it on the clipboard. A whole sentence in Hebrew is translated into English too (Use it / Copy); its key words are offered, and saved only if you tap Save. Words you look up this way are reviewed in reverse on the phone: your sentence with the Hebrew word, and you say the English.

### Writing: improve my English

Select English you wrote (in a message box, email or document) and press ⌃⌥T. The card shows an improved version with the changed words highlighted, a short list of what changed and why, and one-tap rewrites: More formal · Friendlier · Shorter. **Use it** replaces your text; **Copy** copies it. Word Catcher decides between improving and translating by whether the selection is in a box you can type in; each card has a link to switch to the other.

## First run

- **Accessibility permission**: macOS asks for it the first time. Word Catcher needs it to read what you selected. Turn it on in System Settings → Privacy & Security → Accessibility.
- **Account**: sign in, or create an account with an invite code (menu bar book icon → Account & phone sync…). The same account works in the phone app.

## Sharing with friends

- Friends download the Mac app at https://wordcatcher-web.vercel.app/download (built by `scripts/release.sh` into `web/downloads/WordCatcher.zip`). It's ad-hoc signed, so the first launch needs System Settings → Privacy & Security → Open Anyway. An Apple Developer ID ($99/year) would remove that step.
- Sign-up is invite-only. Create codes on https://wordcatcher-web.vercel.app/admin (owner account only), which also shows usage and Claude cost per person.
- All Claude calls go through the `ai` edge function with the owner's key (`ANTHROPIC_API_KEY` in Supabase Edge Function secrets). It checks the session, the invite (a `profiles` row) and a daily limit (150 lookups per 24 hours by default), and logs every call in `usage_events` with tokens and cost. Prompts live in that function, so they can change without a new app build.
- The `account` edge function handles invite sign-up, activation, account info and the admin stats/invites.

## Phone app (review)

`web/` is the phone app: My words + the daily review with spaced repetition. It's a static site (no build step), deployed on Vercel with root directory `web`. On the phone: open https://wordcatcher-web.vercel.app in Safari → Share → Add to Home Screen, then sign in with the same email and password as the Mac.

Words sync through Supabase (project `wordcatcher`, id `aceyqtcljidnfzesqyjq`). Each account sees only its own rows (Row Level Security). Sign-in is email + password, the same on the Mac and the phone.

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
- Claude model and prompts: the `ai` edge function in Supabase (Haiku 4.5)
