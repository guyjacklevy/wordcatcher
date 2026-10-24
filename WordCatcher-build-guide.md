# Word Catcher: build guide

## For you (the person who got this file)

Word Catcher is a small Mac app for Hebrew speakers who read and write English. You select text anywhere on your Mac and press one shortcut, **Control + Option + T**:

- **An English word you don't know:** you get the Hebrew and what it means in your sentence. It's saved to your word list.
- **A whole English sentence:** you get it in Hebrew, and you can tap the words you want to save.
- **Writing, but you only know the word in Hebrew?** Type it in Hebrew inside your English sentence. You get the English that fits, and **Use it** puts it into your text.
- **A sentence you wrote in Hebrew:** you get it in natural English.
- **English you wrote:** you get a smoother, correct version, with what changed and why.

**What you need:**
- A Mac with an Apple chip (M1 or newer), on macOS 14 or later.
- **Claude Code**. The Code tab in the Claude desktop app works.
- A **Claude API key** from console.anthropic.com. API use is billed separately from a Claude subscription, and each lookup costs a fraction of a cent.

**How to build it:**
1. Make an empty folder, for example `~/Desktop/WordCatcher`.
2. Open Claude Code in that folder.
3. Attach this file and write: **"Build the app described in this file."**
4. Claude will ask you to do a few things only you can do: allow Accessibility for the app, and paste your API key into the app's own window. Never paste the key into the chat.

---

## Instructions for Claude

You are building **Word Catcher**, a personal macOS menu-bar app, for the user above. Everything below comes from a working version. Follow the decisions and the "Gotchas" so you don't rediscover them. Write user-facing text in plain, simple English, because the user is learning English.

**Scope:**
- Build **Part 1** (the Mac app) completely.
- **Part 2** (phone review with sync) is optional. It needs the user's own Supabase and Vercel accounts. Ask the user before starting it.

### 1. Project setup

- Use a Swift Package (`swift-tools-version:5.9`, `platforms: [.macOS(.v14)]`) with one executable target. Xcode isn't needed; the Command Line Tools are enough.
  - Tools-version 5.9 keeps Swift 5 language mode and avoids Swift 6 strict-concurrency errors.
- `scripts/build-app.sh`:
  - Run `swift build -c release`.
  - Assemble `dist/WordCatcher.app` with `Contents/MacOS/WordCatcher` and `Contents/Info.plist`. Set `CFBundleIdentifier`, `CFBundleExecutable`, `LSUIElement=true` (menu-bar only, no Dock icon) and `LSMinimumSystemVersion 14.0`.
  - Sign it ad-hoc with a stable designated requirement:
    `codesign --force --sign - --identifier <bundle id> --requirements '=designated => identifier "<bundle id>"' dist/WordCatcher.app`
- `scripts/install.sh`: build, quit the running copy (`pkill -x WordCatcher`), copy the app to `~/Applications/WordCatcher.app`, delete the `dist` copy (keep one copy only), then `open` it.
- `main.swift`:
  - Wrap startup in `MainActor.assumeIsolated { … }`.
  - Set the activation policy to `.accessory`.
  - Keep the app delegate alive with `withExtendedLifetime(delegate) { app.run() }`. `NSApplication.delegate` is weak, and a release build can free it otherwise.

### 2. Menu bar and shortcut

- Status item: the SF Symbol `character.book.closed`. Menu items:
  - Translate selected word (⌃⌥T)
  - My words…
  - Claude API key…
  - Accessibility permission… (opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`)
  - Open at login (a checkmark toggle)
  - Quit
- Global shortcut ⌃⌥T: use Carbon `RegisterEventHotKey` with `kVK_ANSI_T` and `controlKey | optionKey`. Key codes are physical keys, so it also works with the Hebrew keyboard layout.
- Add a minimal **Edit** main menu (Cut, Copy, Paste, Select All). Without it, ⌘V doesn't paste into text fields such as the API key field.
- **Open at login:** on first run call `SMAppService.mainApp.register()` once, and remember that in UserDefaults. After that the menu toggle decides. If the status is `.requiresApproval`, call `SMAppService.openSystemSettingsLoginItems()`.
- **First run:**
  - Call `AXIsProcessTrustedWithOptions` with the prompt option.
  - If no API key is saved, open the API key window.

### 3. API key

- A small window with a `SecureField`, a "Get a key" link to `https://console.anthropic.com/settings/keys`, and Save. Store the key in the login Keychain (generic password).
- Read it **once per launch**, cache it in memory, and show the key window only when the read returns `errSecItemNotFound`.
  - With ad-hoc signing, every rebuild makes macOS ask again for Keychain access ("Always Allow"). If the read is merely blocked, don't treat the key as missing.
  - Tell the user to click **Always Allow** after each rebuild.

### 4. Reading the selection (the hard part)

Read in this order. Stop at the first method that returns non-empty selected text.

1. Get the frontmost app (`NSWorkspace.shared.frontmostApplication`).
   - Create its `AXUIElement` and call `AXUIElementSetMessagingTimeout(axApp, 0.5)`.
   - Set `AXManualAccessibility = true` on it. Electron apps (Claude, Slack, VS Code) only build their accessibility tree when asked.
2. Get the focused element: `kAXFocusedUIElementAttribute`, from the app or from the system-wide element.
3. **Native text:** read `kAXSelectedTextAttribute`. For the sentence, read `kAXValueAttribute` and `kAXSelectedTextRangeAttribute` (a CFRange in UTF-16 units).
   - Find the sentence around that range with `NLTokenizer(unit: .sentence)`. Only use a window of about 800 characters on each side, so huge documents stay fast.
4. **Web content (Chromium, WebKit, Electron):** if there is still no sentence, walk up from the focused element (up to 12 parents) to the first one that has `AXSelectedTextMarkerRange`.
   - Get the start marker with **`AXTextMarkerRangeCopyStartMarker(range as! AXTextMarkerRange)`**. Chromium does **not** answer the parameterized attribute `AXStartTextMarkerForTextMarkerRange`. This was the reason sentences were missing in the Claude app.
   - Then try `AXSentenceTextMarkerRangeForTextMarker`, then `AXParagraphTextMarkerRangeForTextMarker`, each read with `AXStringForTextMarkerRange`.
   - Last resort: `AXUIElementForTextMarker`. Then walk up to 5 parents, collecting the `AXValue` of `AXStaticText` descendants (budget of about 400 nodes, a line break after block roles), and find the sentence containing the selection.
   - Accept a sentence only if it contains the selection and is longer than it.
5. If accessibility found nothing, wait 150 ms and try once more, because the Electron tree may still be building.
6. **Clipboard fallback:**
   - Save every pasteboard item.
   - Wait until ⌃ and ⌥ are released (`CGEventSource.flagsState`), so you don't send ⌃⌥⌘C.
   - Post ⌘C with `CGEvent`, using `flags = .maskCommand`, to `.cgAnnotatedSessionEventTap`.
   - Poll the pasteboard `changeCount` for up to 0.5 s, read the string, then restore the saved pasteboard.
   - In this case there is no sentence.
7. **Is it the user's own writing?** The selection counts as editable if one of these is true:
   - The focused element's role is `AXTextArea`, `AXTextField`, `AXComboBox` or `AXSearchField`.
   - It has a non-nil `AXEditableAncestor`.
   - `AXUIElementIsAttributeSettable(…, kAXValueAttribute)` is true.
8. Keep a small diagnostic log in `~/Library/Logs/WordCatcher.log`: which method worked per app, whether a sentence was found, and whether it was editable. **Never log the user's text.**

### 5. Which card to show

| Selection | Card |
|---|---|
| Contains Hebrew letters (U+0590–U+05FF), and Hebrew letters ≥ Latin letters | **In English**: the whole text translated (compose task, offered words saved only on tap) |
| Contains Hebrew, mostly English | **Say it in English**: fill in the Hebrew words (compose task, auto-saved) |
| English, more than 4 words, in an editable field | **Improve my English** (polish task) |
| English, more than 4 words, not editable | **Sentence in Hebrew** (translate task) above a word picker |
| English, up to 4 words | **Explain** (explain task) |

The last two English cards each have a small link that switches to the other mode, in case the editable guess is wrong.

### 6. Calling Claude

- `POST https://api.anthropic.com/v1/messages` with these headers: `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json`. Use URLSession, because there is no official Swift SDK.
- Body: `model: "claude-haiku-4-5"`, `max_tokens: 16000`, `system`, one user message, and **structured outputs**: `"output_config": {"format": {"type": "json_schema", "schema": …}}`.
  - In every schema object, list all properties in `required` and set `additionalProperties: false`.
- Read the first content block with `type == "text"` and JSON-decode it. If `stop_reason == "refusal"`, show a friendly error.
- With an empty key or a 401, show a card with a button that opens the API key window.

**Explain**
- User message:
  - `Sentence: "<sentence>"` (or `Sentence: (not available)`)
  - then `Marked: "<word>"`
  - For several words: `Marked (explain each one, in this order):` followed by a numbered list.
- Schema: `{items: [{marked, lemma, part_of_speech, ipa, hebrew, meaning, meaning_here, example}]}`, all strings.
- System prompt:

```
You help a native Hebrew speaker who reads English at work learn new vocabulary. They marked a word or phrase in something they were reading. For each marked item, explain it as it is used in that sentence, in simple English a learner understands.

Fields:
- marked: the marked text, exactly as given.
- lemma: the dictionary form ("streamlined" → "streamline"). If the marked text is part of a multi-word expression in this sentence (phrasal verb, idiom, fixed phrase), use the whole expression ("roll this out" → "roll out").
- part_of_speech: noun, verb, adjective, adverb, phrase, or idiom.
- ipa: American pronunciation in IPA, between slashes.
- hebrew: one or two short Hebrew translations that fit this sentence, separated by " · ", without niqqud.
- meaning: a short, simple English definition, at most 12 words.
- meaning_here: what it means in this specific sentence, at most 12 words. Empty string if no sentence was given.
- example: one new, natural example sentence from a work setting.
```

**Compose (Hebrew → English)**
- User message: `Text: "<selection>"`, plus `The sentence it's in: "<sentence>"` when a sentence was found and it differs from the selection.
- Schema: `{template, items: [{hebrew, part_of_speech, choices: [{word, fitted, note, ipa, meaning, example}]}]}`.
- System prompt:

```
You help a native Hebrew speaker write in English at work. When they don't know an English word, they write it in Hebrew inside their English sentence, or write a whole sentence in Hebrew. Find the English that fits their exact sentence: the right meaning, the right tone, and correct grammar (tense, plural, articles, prepositions).

Fields:
- template: the Text rewritten in natural English, with {0}, {1}, … standing exactly where each item's English goes. Keep the user's own English words and style; change only what the replaced words require (for example an article or a preposition next to them). If the Text is only the Hebrew word or words, the template is just "{0}" (or "{0} {1}" and so on), using the surrounding sentence to choose the meaning and form.
- items: one per Hebrew word or phrase, in the order they appear. If the Text is entirely or mostly Hebrew, translate it into the template and make items for the 1 to 3 words or expressions most worth learning.
  - hebrew: the Hebrew exactly as it appears in the Text.
  - part_of_speech: noun, verb, adjective, adverb, phrase, or idiom.
  - choices: 1 to 3 English options, best first. Offer more than one only when another option is genuinely good, with a different tone or nuance.
    - word: the dictionary form ("submit").
    - fitted: the exact form that goes into this sentence ("submitted"), including any article that must change with it.
    - note: when to use it, at most 5 words ("best fit here", "more casual", "formal, for documents").
    - ipa: American pronunciation of the word, in IPA between slashes.
    - meaning: a short, simple English definition, at most 12 words.
    - example: one new, natural example sentence from a work setting.
```

- Build the final text by replacing each `{i}` in the template with the `fitted` form of that item's chosen option. Parse `{` + number + `}` safely, and leave other braces alone.
- If the selection was only part of the sentence, show the whole sentence with the selection replaced, but paste only the replacement.

**Polish (improve my English)**
- User message: `Text:\n<selection>`. Add `\n\nAlso make it <style>.` for the style chips: "more formal", "friendlier and warmer", "shorter and more direct".
- Schema: `{improved, verdict, changes: [{before, after, why}]}`.
- System prompt:

```
You are an editor for a native Hebrew speaker who writes English at work (Slack, email, documents). Improve their text so it reads like a fluent professional wrote it: fix grammar, word choice, and flow.

Keep their meaning, facts, names, and formatting (line breaks, lists, emoji). Keep roughly the same length and tone unless asked otherwise. Don't add new content. If the text is already good, change little or nothing.

Fields:
- improved: the improved text.
- verdict: one short sentence about what you did, in simple English ("Two grammar fixes and a smoother second sentence." or "Already good. One small tweak.").
- changes: up to 5 of the changes most worth learning from, most useful first. Skip trivial ones.
  - before: their words, exactly as written (a few words, not the whole sentence).
  - after: your replacement.
  - why: the reason, in simple English, at most 12 words ("'Discuss' doesn't take 'about'.").
```

- Highlight changed words in the improved text with a word-level LCS diff, done locally. Mark the words of the new text that aren't in the common subsequence, compared in lowercase. Removed words appear in the "What changed" list instead.

**Translate a sentence to Hebrew**
- User message: `English text: "<sentence>"`.
- Schema: `{translation}`.
- System prompt:

```
Translate the English text into natural, fluent Hebrew, the way an Israeli professional would say it. Write the Hebrew in Hebrew letters (א-ת), never transliterated into Latin letters, and without niqqud. Keep the meaning and tone exactly; don't add or drop anything. Keep names, products and code in English.

Example: "Please send me the report by Thursday." → translation: "בבקשה תשלח לי את הדוח עד יום חמישי."

translation: the Hebrew translation only.
```

- **Haiku sometimes answers in Latin transliteration** ("bhor mishpat…"). If the answer has no Hebrew letters, ask once more with this added to the user message: `Write the translation in Hebrew letters (א-ת), not in Latin letters.`
- Run this request alongside the word picker, so tapping words never waits for it.

### 7. The popup

- An `NSPanel` with `[.nonactivatingPanel, .borderless]`, so the user's app keeps focus.
  - Set `level = .popUpMenu`, a clear background, `hasShadow = false` (SwiftUI draws the shadow), `hidesOnDeactivate = false`, and `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]`.
  - Override `canBecomeKey` to return `true`.
  - Host SwiftUI in an `NSHostingView` subclass whose `acceptsFirstMouse` returns `true`, so the first click on a button works.
- **Position:** just below and left of the mouse pointer, kept on screen, and above the pointer if there's no room below. When the content changes, resize to `fittingSize` and keep the top-left corner fixed.
- **Closing:**
  - A click anywhere else (global mouse monitor).
  - Esc: a global key monitor, plus a local one for when the panel is key.
  - The close button.
  - Result cards close by themselves after 12 s unless the pointer is over them.
- **Look:** a 360 pt wide white card with 14 pt corners and a soft shadow, always in light mode. Colors:
  - ink `#15171C`, muted `#5B606B`, lines `#ECEEF2`
  - brand blue `#2346D1`
  - highlight yellow `#FFE066` with border `#C9A400`
  - footer background `#F4F6F9`, saved green `#1E7A46`
- **Cards:**
  - **Explain:**
    - Header: lemma (22 pt semibold), part of speech, IPA, a speaker button (`AVSpeechSynthesizer`, `en-US`, rate × 0.9) and a close button.
    - Below it: "You marked 'X' · saved as 'Y'" when they differ, the Hebrew (26 pt, right-aligned), and "MEANING IN THIS SENTENCE" with meaning plus " Here: " plus meaning_here.
    - Footer: "Saved to your words" with Undo (Undo turns into "Save it").
  - **Word picker:**
    - At the top, the sentence in Hebrew with a Copy link.
    - "Which words don't you know?" with every word as a chip that toggles yellow.
    - A button that reads "Translate N words" (explain task for several words).
  - **Say it in English / In English:**
    - The sentence with the new English highlighted.
    - For each Hebrew word: the Hebrew → option chips, where tapping one swaps it in. Under them, the chosen option's note and meaning, and a speaker button.
    - **Use it** and **Copy**.
  - **Improve my English:**
    - The verdict, then the improved text with changes highlighted (scrollable, up to 220 pt).
    - "WHAT CHANGED": ~~before~~ → **after**, with the reason under each.
    - Chips: More formal · Friendlier · Shorter.
    - **Use it** and **Copy**.
- **Use it (replace the user's text):**
  1. Close the panel first, which gives the keyboard back.
  2. Save the pasteboard, then put the new text on it.
  3. Call `activate()` on the source app (saved when the text was captured) and wait 150 ms.
  4. Post ⌘V.
  5. Wait about 700 ms, then restore the pasteboard. Waiting less risks pasting the old clipboard in Electron apps.

### 8. Saving words

- Keep `~/Library/Application Support/WordCatcher/words.json` with one entry per word:
  - Fields: `id`, `lemma`, `partOfSpeech`, `ipa`, `hebrew`, `meaning`, `example`, `status` (new), `createdAt`, `direction`, `encounters`.
  - `direction` is `"read"`, or `"write"` for words looked up while writing.
  - Each encounter has `marked`, `sentence`, `meaningHere`, `app`, `date`, plus `sourceText` and `sourceMarked` for writing lookups.
- Avoid duplicates by lowercased lemma:
  - Same word, new sentence: add an encounter ("Already in your words · this sentence added (2×)").
  - Same sentence again: just say it's already there.
- Undo removes exactly what that save added.
- A word looked up while writing changes the word's direction to `"write"`.
- **My words** window: a list showing lemma, part of speech, Hebrew, the last sentence, and "app · date · seen N×". The context menu has Say it and Delete.

### 9. Testing

- Build and install, then ask the user to:
  - allow Accessibility
  - paste the API key in the app window
  - click Always Allow on the Keychain prompt
- Test in TextEdit, Chrome, Slack and the Claude desktop app: one word, a whole sentence, English with a Hebrew word inside, a Hebrew sentence, and their own paragraph in a message box. Check the log for which method worked and whether a sentence came through.

---

## Part 2 (optional): phone review with spaced repetition

Ask the user first. This needs their own free Supabase project and a Vercel account, connected to a GitHub repo.

- **Database (Supabase):** three tables, all with Row Level Security `(select auth.uid()) = user_id` and `user_id default auth.uid()`.
  - `words`:
    - Content: `id, user_id, lemma, lemma_key (lowercase, unique per user), part_of_speech, ipa, hebrew, meaning, example`.
    - Status: `status` (new/learning/known), `direction` (read/write).
    - Review schedule: `step int default 0`, `due_on date`, `reviews`, `lapses`, `last_reviewed_at`.
    - Timestamps: `created_at`, `updated_at`.
  - `encounters`: `id, user_id, word_id → words on delete cascade, marked, sentence, meaning_here, app, created_at, source_text, source_marked`.
  - `reviews`: `id, user_id, word_id, knew boolean, reviewed_at`.
- **Sign-in:** email + password, on both the Mac and the phone.
  - The free plan's built-in email doesn't allow editing templates, so emailed one-time codes won't work.
  - Turn off "Confirm email" in the Supabase dashboard.
- **Mac sync:**
  - A "Sync with your phone…" window signs in through `auth/v1/token?grant_type=password`. Store the session in a 0600 file, and refresh it with `grant_type=refresh_token`.
  - Push unsynced words with `POST rest/v1/words?on_conflict=id` and `Prefer: resolution=merge-duplicates`. Include `due_on` (the day after it was saved, in the local day) **only on a word's first push**, so later pushes don't reset its schedule.
  - Push encounters the same way, with `ignore-duplicates`.
  - Rows deleted on the Mac go into a pending-deletes list, deleted on the next sync.
- **Phone app:** a static site with no build step, using supabase-js from esm.sh, hosted on Vercel and added to the iPhone home screen.
  - **My words:** search, filter by New/Learning/Known, and tap a word to see its details.
  - **Daily review:** words with `due_on ≤ today` (local date).
    - Reading words: show the user's own sentence with the word highlighted, and ask "What does X mean here?". The back shows the Hebrew, meaning and example.
    - Writing words (`direction = write`): show what they typed (English with the Hebrew word) and ask "How do you say X in English here?".
    - "Knew it" moves one step up the ladder of `[1, 3, 7, 14, 30, 60, 120]` days. "Didn't know" goes back to 1 day. A word counts as known at 30 days or more.
- **Optional daily reminder (web push):**
  - A service worker for notifications, and a `push_subscriptions` table with time zone, reminder hour and last sent date.
  - An edge function that creates its VAPID keys itself and stores them in a server-only table.
  - A `pg_cron` job every hour that calls the function. The function notifies each device at its local reminder hour, only when words are due.
  - On iPhone this works only from the home-screen app, and permission must be asked right in the tap handler.
