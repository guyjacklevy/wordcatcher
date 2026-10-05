import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// The publishable key is safe in a web page; Row Level Security keeps each account's words private.
const SUPABASE_URL = 'https://aceyqtcljidnfzesqyjq.supabase.co';
const SUPABASE_KEY = 'sb_publishable_XvYDHMwoBOU4gF-SzKRIIg_gZMzeSYb';
const sb = createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false },
});

// Days until the next review at each step. "Knew it" climbs one step; "Didn't know" goes back to the first.
const LADDER = [1, 3, 7, 14, 30, 60, 120];
const KNOWN_AFTER_DAYS = 30;
const MAX_PER_SESSION = 40;

const $ = (id) => document.getElementById(id);
const state = {
  email: '',
  words: [],
  filter: 'all',
  query: '',
  open: new Set(),
  view: 'signin',
  queue: [],
  index: 0,
  knew: 0,
  flipped: false,
};

// ─── dates ───

function localDay(offset = 0) {
  const d = new Date();
  d.setDate(d.getDate() + offset);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function shortDate(iso) {
  const d = new Date(iso);
  const key = localDayOf(d);
  if (key === localDay(0)) return 'Today';
  if (key === localDay(-1)) return 'Yesterday';
  return d.toLocaleDateString('en', { month: 'short', day: 'numeric' });
}

function localDayOf(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function dayLabel(day) {
  if (day === localDay(1)) return 'Tomorrow';
  const [y, m, dd] = day.split('-').map(Number);
  return new Date(y, m - 1, dd).toLocaleDateString('en', { weekday: 'short', month: 'short', day: 'numeric' });
}

// ─── small DOM helpers ───

function el(tag, props = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (value === undefined || value === null || value === false) continue;
    if (key === 'class') node.className = value;
    else if (key === 'text') node.textContent = value;
    else if (key.startsWith('on')) node.addEventListener(key.slice(2), value);
    else node.setAttribute(key, value === true ? '' : value);
  }
  for (const child of children.flat()) {
    if (child !== null && child !== undefined && child !== false) node.append(child);
  }
  return node;
}

/** The sentence as text, with the marked phrase wrapped in <mark>. */
function highlighted(sentence, ...phrases) {
  const fragment = document.createDocumentFragment();
  const lower = sentence.toLowerCase();
  for (const phrase of phrases) {
    if (!phrase) continue;
    const at = lower.indexOf(phrase.toLowerCase());
    if (at === -1) continue;
    // Mark the whole word: "leverage" inside "leveraged" highlights "leveraged".
    let end = at + phrase.length;
    while (end < sentence.length && /[\p{L}'’-]/u.test(sentence[end])) end += 1;
    fragment.append(sentence.slice(0, at), el('mark', { text: sentence.slice(at, end) }), sentence.slice(end));
    return fragment;
  }
  fragment.append(sentence);
  return fragment;
}

/** A one-line excerpt that starts shortly before the marked word, so the mark stays visible. */
function excerpt(sentence, ...phrases) {
  const lower = sentence.toLowerCase();
  const at = phrases.filter(Boolean).map((p) => lower.indexOf(p.toLowerCase())).find((i) => i >= 0) ?? -1;
  if (at <= 24) return sentence;
  const cut = sentence.lastIndexOf(' ', at - 12);
  return `…${sentence.slice(cut > 0 ? cut + 1 : at)}`;
}

function icon(paths, size = 18) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  for (const [k, v] of Object.entries({ width: size, height: size, viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', 'stroke-width': 2, 'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'aria-hidden': 'true' })) {
    svg.setAttribute(k, v);
  }
  for (const d of paths) {
    const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    path.setAttribute('d', d);
    svg.append(path);
  }
  return svg;
}
const SPEAKER = ['M11 5 6 9H2v6h4l5 4V5z', 'M15.5 8.5a5 5 0 0 1 0 7', 'M19 5a10 10 0 0 1 0 14'];
const CHEVRON = ['m6 9 6 6 6-6'];

function speak(text) {
  if (!('speechSynthesis' in window)) return;
  window.speechSynthesis.cancel();
  const utterance = new SpeechSynthesisUtterance(text);
  utterance.lang = 'en-US';
  utterance.rate = 0.9;
  window.speechSynthesis.speak(utterance);
}

let toastTimer;
function toast(message) {
  const node = $('toast');
  node.textContent = message;
  node.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { node.hidden = true; }, 3500);
}

function showView(name) {
  state.view = name;
  for (const view of ['signin', 'words', 'review']) $(`view-${view}`).hidden = view !== name;
  window.scrollTo(0, 0);
}

// ─── word helpers ───

/** The sentence to learn from: the latest one you met it in, or Claude's example. */
function contextFor(word) {
  const met = word.encounters.find((e) => e.sentence);
  if (met) {
    return {
      sentence: met.sentence,
      marks: [met.marked, word.lemma],
      source: `From ${met.app || 'your Mac'} · ${shortDate(met.created_at)}`,
      meaningHere: met.meaning_here || '',
      fromExample: false,
    };
  }
  return { sentence: word.example, marks: [word.lemma], source: 'Example sentence', meaningHere: '', fromExample: true };
}

function metaFor(word) {
  const last = word.encounters[0];
  const parts = [last?.app || 'Mac', shortDate(last?.created_at || word.created_at)];
  if (word.encounters.length > 1) parts.push(`seen ${word.encounters.length}×`);
  return parts.join(' · ');
}

const STATUS_LABEL = { new: 'New', learning: 'Learning', known: 'Known' };
const isDue = (word) => word.due_on <= localDay(0);

// ─── sign in ───

function showSignIn() {
  $('form-email').hidden = false;
  $('form-code').hidden = true;
  $('signin-error').hidden = true;
  showView('signin');
}

function signInError(message) {
  $('signin-error').textContent = message;
  $('signin-error').hidden = !message;
}

async function sendCode(event) {
  event.preventDefault();
  const email = $('input-email').value.trim().toLowerCase();
  if (!email) return;
  const button = event.submitter;
  button.disabled = true;
  signInError('');
  const { error } = await sb.auth.signInWithOtp({ email, options: { shouldCreateUser: true } });
  button.disabled = false;
  if (error) {
    signInError(error.message.includes('rate') ? 'Too many codes asked for. Wait a few minutes and try again.' : error.message);
    return;
  }
  state.email = email;
  $('code-hint').textContent = `We emailed a code to ${email}. It can take a minute to arrive.`;
  $('form-email').hidden = true;
  $('form-code').hidden = false;
  $('input-code').value = '';
  $('input-code').focus();
}

async function verifyCode(event) {
  event.preventDefault();
  const token = $('input-code').value.replace(/\D/g, '');
  if (!token) return;
  const button = event.submitter;
  button.disabled = true;
  signInError('');
  const { error } = await sb.auth.verifyOtp({ email: state.email, token, type: 'email' });
  button.disabled = false;
  if (error) {
    signInError('That code didn’t work. Check the latest email, or ask for a new code.');
    return;
  }
  await openWords();
}

// ─── my words ───

async function openWords() {
  showView('words');
  await loadWords();
}

async function loadWords() {
  const { data, error } = await sb
    .from('words')
    .select('id, lemma, part_of_speech, ipa, hebrew, meaning, example, status, step, due_on, reviews, lapses, created_at, encounters(id, marked, sentence, meaning_here, app, created_at)')
    .order('created_at', { ascending: false });
  if (error) {
    toast('Couldn’t load your words. Check your connection.');
    return;
  }
  state.words = data.map((word) => ({
    ...word,
    encounters: (word.encounters || []).sort((a, b) => b.created_at.localeCompare(a.created_at)),
  }));
  renderWords();
}

function renderWords() {
  const words = state.words;
  const due = words.filter(isDue);

  $('words-summary').textContent = words.length === 0
    ? 'Nothing saved yet'
    : `${words.length} ${words.length === 1 ? 'word' : 'words'} · ${due.length} to review today`;

  const cta = $('btn-start');
  if (due.length > 0) {
    cta.disabled = false;
    $('cta-title').textContent = 'Start today’s review';
    const count = Math.min(due.length, MAX_PER_SESSION);
    $('cta-sub').textContent = `${count} ${count === 1 ? 'word' : 'words'} · about ${Math.max(1, Math.round(count * 0.5))} min`;
  } else {
    cta.disabled = true;
    $('cta-title').textContent = 'Nothing to review today';
    const upcoming = words.map((w) => w.due_on).filter((d) => d > localDay(0)).sort()[0];
    $('cta-sub').textContent = upcoming
      ? `Next: ${dayLabel(upcoming)} · ${words.filter((w) => w.due_on === upcoming).length} words`
      : 'Mark words on your Mac to start';
  }

  // Filters
  const counts = { all: words.length, new: 0, learning: 0, known: 0 };
  for (const word of words) counts[word.status] += 1;
  $('filters').replaceChildren(...['all', 'new', 'learning', 'known'].map((id) => el('button', {
    type: 'button',
    class: 'chip',
    'aria-pressed': String(state.filter === id),
    text: `${id === 'all' ? 'All' : STATUS_LABEL[id]} ${counts[id]}`,
    onclick: () => { state.filter = id; renderWords(); },
  })));

  // List
  const q = state.query.trim().toLowerCase();
  const shown = words.filter((w) => (state.filter === 'all' || w.status === state.filter)
    && (!q || w.lemma.toLowerCase().includes(q) || w.hebrew.includes(q)));
  $('word-list').replaceChildren(...shown.map(wordRow));

  const empty = $('words-empty');
  if (words.length === 0) {
    empty.textContent = 'On your Mac, select a word in any app and press ⌃⌥T. It shows up here.';
    empty.hidden = false;
  } else if (shown.length === 0) {
    empty.textContent = 'No words match.';
    empty.hidden = false;
  } else {
    empty.hidden = true;
  }
}

function wordRow(word) {
  const open = state.open.has(word.id);
  const ctx = contextFor(word);
  const detailsId = `details-${word.id}`;

  const toggle = el('button', {
    type: 'button',
    class: 'word-toggle',
    'aria-expanded': String(open),
    'aria-controls': detailsId,
    onclick: () => {
      if (state.open.has(word.id)) state.open.delete(word.id); else state.open.add(word.id);
      renderWords();
    },
  },
  el('span', { class: 'word-main' },
    el('span', { class: 'word-title' },
      el('b', { text: word.lemma }),
      el('span', { class: `pill pill-${word.status}`, text: STATUS_LABEL[word.status] })),
    el('span', { class: 'snippet' }, highlighted(excerpt(ctx.sentence, ...ctx.marks), ...ctx.marks)),
    el('span', { class: 'meta', text: metaFor(word) })),
  el('span', { class: 'word-side' },
    el('span', { class: 'hebrew', dir: 'rtl', lang: 'he', text: word.hebrew }),
    el('span', { class: 'chevron' }, icon(CHEVRON, 18))));

  const item = el('li', { class: 'word', 'data-open': String(open) }, toggle);
  if (open) item.append(wordDetails(word, detailsId));
  return item;
}

function wordDetails(word, id) {
  const sentences = word.encounters.filter((e) => e.sentence);
  return el('div', { class: 'word-details', id },
    el('div', { class: 'detail-head' },
      el('div', {},
        el('div', { class: 'muted small', text: [word.part_of_speech, word.ipa].filter(Boolean).join(' · ') })),
      el('button', { type: 'button', class: 'icon-btn icon-btn-brand', 'aria-label': `Say ${word.lemma}`, onclick: () => speak(word.lemma) }, icon(SPEAKER, 20))),
    el('div', { class: 'detail-block' },
      el('span', { class: 'label', text: 'Meaning' }),
      el('p', { text: word.meaning })),
    sentences.length > 0 && el('div', { class: 'detail-block' },
      el('span', { class: 'label', text: sentences.length === 1 ? 'Where you met it' : `Where you met it (${sentences.length}×)` }),
      ...sentences.map((e) => el('div', {},
        el('p', { class: 'detail-sentence' }, highlighted(e.sentence, e.marked, word.lemma)),
        el('span', { class: 'meta', text: `${e.app || 'Mac'} · ${shortDate(e.created_at)}${e.meaning_here ? ` · ${e.meaning_here}` : ''}` })))),
    word.example && el('div', { class: 'detail-block' },
      el('span', { class: 'label', text: 'Example' }),
      el('p', { class: 'sentence-italic', text: word.example })),
    el('button', { type: 'button', class: 'btn-remove', onclick: () => removeWord(word) }, 'Remove word'));
}

async function removeWord(word) {
  if (!window.confirm(`Remove “${word.lemma}” from your words?`)) return;
  const { error } = await sb.from('words').delete().eq('id', word.id);
  if (error) {
    toast('Couldn’t remove it. Check your connection.');
    return;
  }
  state.words = state.words.filter((w) => w.id !== word.id);
  state.open.delete(word.id);
  renderWords();
}

// ─── review ───

function startReview() {
  state.queue = state.words
    .filter(isDue)
    .sort((a, b) => a.due_on.localeCompare(b.due_on) || a.created_at.localeCompare(b.created_at))
    .slice(0, MAX_PER_SESSION);
  if (state.queue.length === 0) return;
  state.index = 0;
  state.knew = 0;
  state.flipped = false;
  showView('review');
  renderCard();
}

function currentWord() {
  return state.queue[state.index];
}

function renderCard() {
  const total = state.queue.length;
  const done = state.index >= total;
  $('review-front').hidden = done || state.flipped;
  $('review-back').hidden = done || !state.flipped;
  $('review-done').hidden = !done;
  $('progress-bar').style.width = `${Math.round(((done ? total : state.index + (state.flipped ? 0.5 : 0)) / total) * 100)}%`;
  $('review-position').textContent = done ? 'Done' : `${state.index + 1} of ${total}`;

  if (done) {
    renderDone();
    return;
  }

  const word = currentWord();
  const ctx = contextFor(word);
  if (!state.flipped) {
    $('front-source').textContent = ctx.source;
    $('front-sentence').replaceChildren(highlighted(ctx.sentence, ...ctx.marks));
    $('front-prompt').textContent = ctx.fromExample ? `What does “${word.lemma}” mean?` : `What does “${word.lemma}” mean here?`;
    return;
  }

  $('back-source').textContent = ctx.source;
  $('back-sentence').replaceChildren(highlighted(ctx.sentence, ...ctx.marks));
  $('back-hebrew').textContent = word.hebrew;
  $('back-lemma').textContent = word.lemma;
  $('back-pos').textContent = word.part_of_speech;
  $('back-ipa').textContent = word.ipa;
  $('back-meaning').textContent = ctx.meaningHere ? `${word.meaning} Here: ${ctx.meaningHere}` : word.meaning;
  $('back-example').textContent = word.example;
  $('back-example').parentElement.hidden = !word.example || ctx.fromExample;
  const nextStep = Math.min(word.step + 1, LADDER.length - 1);
  $('knew-sub').textContent = `back in ${LADDER[nextStep]} days`;
}

async function answer(knew) {
  const word = currentWord();
  if (!word) return;
  const step = knew ? Math.min(word.step + 1, LADDER.length - 1) : 0;
  const days = LADDER[step];
  const update = {
    step,
    due_on: localDay(days),
    status: days >= KNOWN_AFTER_DAYS ? 'known' : 'learning',
    reviews: word.reviews + 1,
    lapses: word.lapses + (knew ? 0 : 1),
    last_reviewed_at: new Date().toISOString(),
  };
  Object.assign(word, update);
  if (knew) state.knew += 1;
  state.index += 1;
  state.flipped = false;
  renderCard();

  const [saved, logged] = await Promise.all([
    sb.from('words').update(update).eq('id', word.id),
    sb.from('reviews').insert({ word_id: word.id, knew }),
  ]);
  if (saved.error || logged.error) toast('Couldn’t save that answer. Check your connection.');
}

function renderDone() {
  const total = state.queue.length;
  const missed = total - state.knew;
  let text = `You knew ${state.knew} of ${total}. `;
  if (missed === 0) text += 'Perfect round. These words come back in a few days.';
  else if (missed === 1) text += 'The one you missed comes back tomorrow.';
  else text += `The ${missed} you missed come back tomorrow.`;
  $('done-text').textContent = text;

  const upcoming = state.words.map((w) => w.due_on).filter((d) => d > localDay(0)).sort()[0];
  $('done-next').textContent = upcoming
    ? `${dayLabel(upcoming)} · ${state.words.filter((w) => w.due_on === upcoming).length} words`
    : '—';
  $('done-total').textContent = `${state.words.length} words`;
}

// ─── wiring ───

function wire() {
  $('form-email').addEventListener('submit', sendCode);
  $('form-code').addEventListener('submit', verifyCode);
  $('btn-other-email').addEventListener('click', showSignIn);
  $('btn-start').addEventListener('click', startReview);
  $('input-search').addEventListener('input', (e) => { state.query = e.target.value; renderWords(); });
  $('btn-close-review').addEventListener('click', () => { showView('words'); renderWords(); });
  $('btn-done').addEventListener('click', () => { showView('words'); renderWords(); });
  $('btn-flip').addEventListener('click', () => { state.flipped = true; renderCard(); });
  $('btn-knew').addEventListener('click', () => answer(true));
  $('btn-forgot').addEventListener('click', () => answer(false));
  for (const button of document.querySelectorAll('[data-speak]')) {
    button.addEventListener('click', () => { const word = currentWord(); if (word) speak(word.lemma); });
  }
  $('btn-menu').addEventListener('click', async () => {
    const { data } = await sb.auth.getUser();
    if (window.confirm(`Signed in as ${data.user?.email ?? 'you'}.\n\nSign out?`)) await sb.auth.signOut();
  });

  sb.auth.onAuthStateChange((event) => {
    if (event === 'SIGNED_OUT') { state.words = []; showSignIn(); }
  });

  // New words from the Mac show up when you come back to the app.
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && state.view === 'words') loadWords();
  });
}

async function boot() {
  wire();
  const { data } = await sb.auth.getSession();
  if (data.session) await openWords();
  else showSignIn();
}

boot();

// Local preview only: lets the dev tools render views with sample data.
if (['localhost', '127.0.0.1'].includes(location.hostname)) {
  window.__wc = { state, renderWords, startReview, showView, renderCard };
}
