// Gold Trade Logger.
// Signs in with email and password, opens and closes trades (with chart screenshots),
// lists open and closed ones, and shows one trade's details with both screenshots,
// where a trade can also be edited (to fix a typo) or deleted.
// A switch picks which account to show, with a headline of totals for each one,
// a stats panel per account (including rules followed vs broken), a CSV download of closed trades,
// and a settings form holds starting balances, today's rate, the ADX threshold and the minimum risk:reward.
// USD/ZAR rates are looked up automatically: today's rate, and each close date's rate.
// All data lives in Supabase, so the phone and laptop see the same trades and settings.

// ---- Supabase connection ----
// Both values come from Supabase: Project Settings > API Keys (and Data API for the URL).
// The publishable (anon) key is meant to be public. Row Level Security on the
// database is what keeps your data private. NEVER put the secret / service_role key here.
const SUPABASE_URL = 'https://artzjxpgdoswwipwvpek.supabase.co';
const SUPABASE_KEY = 'sb_publishable_F1DB_pMD6GWtHHhOxjUS8Q_KPTtzLaN';

// ---- Page elements ----
const el = (id) => document.getElementById(id);
const messageBox = el('message');
const signedOutSection = el('signed-out');
const signedInSection = el('signed-in');
const openForm = el('open-form');
const openTradesList = el('open-trades-list');
const closeSection = el('close-section');
const closeForm = el('close-form');
const historyList = el('history-list');
const headlineBox = el('headline');
const statsBox = el('stats');
const settingsForm = el('settings-form');

// The message stays in view at the top while you scroll. Tap it to hide it.
// A finished message (not an error, and not "Saving…") also hides itself after a few seconds.
let messageTimer = null;

function showMessage(text, isError = false) {
  clearTimeout(messageTimer);
  messageBox.textContent = text;
  messageBox.classList.toggle('error', isError);
  messageBox.hidden = !text;
  if (text && !isError && !text.endsWith('…')) {
    messageTimer = setTimeout(() => { messageBox.hidden = true; }, 5000);
  }
}

messageBox.addEventListener('click', () => {
  clearTimeout(messageTimer);
  messageBox.hidden = true;
});

// ---- Stop with a friendly warning if the keys haven't been pasted in yet ----
if (SUPABASE_URL.startsWith('PASTE_')) {
  showMessage('Setup needed: paste your Supabase URL and publishable key into app.js.', true);
  throw new Error('Supabase keys missing in app.js');
}

const db = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

// ---- Signed in or out: show the right section ----
// Starts as "unknown" (undefined), so the first report always draws the page, signed in or out.
let currentUserId;

function render(session) {
  const userId = session ? session.user.id : null;
  // Supabase also reports routine sign-in refreshes. Ignore those so a half-filled form isn't wiped.
  if (userId === currentUserId) return;
  currentUserId = userId;

  signedOutSection.hidden = Boolean(userId);
  signedInSection.hidden = !userId;
  el('tabs').hidden = !userId;
  openTradesList.innerHTML = '';
  historyList.innerHTML = '';
  headlineBox.innerHTML = '';
  statsBox.innerHTML = '';
  openTrades = [];
  closedTrades = [];
  settings = emptySettings();
  hideCloseForm();
  hideDetail();
  showExportStatus('');
  if (userId) {
    el('user-email').textContent = session.user.email;
    openForm.reset();
    setToNow(openedAtInput);
    selectLastUsedAccount();
    selectRememberedView();
    resetSettingsForm();
    loadSettings();
    loadLists();
  }
}

db.auth.onAuthStateChange((_event, session) => render(session));

// ---- Sign in, create account, sign out ----
el('sign-in-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  showMessage('Signing in…');
  const { error } = await db.auth.signInWithPassword({
    email: el('email').value.trim(),
    password: el('password').value,
  });
  showMessage(error ? error.message : '', Boolean(error));
});

el('sign-up-button').addEventListener('click', async () => {
  const form = el('sign-in-form');
  if (!form.reportValidity()) return;
  showMessage('Creating account…');
  const { data, error } = await db.auth.signUp({
    email: el('email').value.trim(),
    password: el('password').value,
    options: { emailRedirectTo: window.location.origin + window.location.pathname },
  });
  if (error) return showMessage(error.message, true);
  if (!data.session) {
    showMessage('Check your email and click the confirmation link, then sign in here.');
  } else {
    showMessage('');
  }
});

el('sign-out-button').addEventListener('click', async () => {
  await db.auth.signOut();
  showMessage('Signed out.');
});

// ---- Formatting helpers ----
const ACCOUNT_NAMES = { daily: 'Daily Demo', backtest: 'Backtest' };

const usd = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' });

// Profit and loss always shows its sign: +$25.00 or -$25.00.
const signedUsd = new Intl.NumberFormat('en-US', {
  style: 'currency', currency: 'USD', signDisplay: 'exceptZero',
});

// "R" is always South African Rand, written like +R1,850.00 or -R1,850.00.
const twoDecimals = new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
function signOf(amount) {
  return amount > 0 ? '+' : amount < 0 ? '-' : '';
}
function signedZar(amount) {
  return `${signOf(amount)}R${twoDecimals.format(Math.abs(amount))}`;
}

// % return, e.g. +1.25% or -0.40%.
const signedPercent = new Intl.NumberFormat('en-US', {
  style: 'percent', minimumFractionDigits: 2, maximumFractionDigits: 2, signDisplay: 'exceptZero',
});

// Rounds to whole cents, with halves going away from zero (the way money is usually rounded).
function toCents(amount) {
  return Math.sign(amount) * Math.round(Math.abs(amount) * 100);
}

// The result in units of risk, e.g. +1.50× risk.
function formatTimesRisk(value) {
  return `${signOf(value)}${twoDecimals.format(Math.abs(value))}× risk`;
}

// A date as the "YYYY-MM-DDTHH:MM" text a datetime-local box expects, in local time.
function toLocalInputValue(date) {
  const pad = (n) => String(n).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` +
    `T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

function formatWhen(isoText) {
  return new Date(isoText).toLocaleString(undefined, {
    day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit',
  });
}

// ---- Official USD/ZAR rates ----
// The European Central Bank's daily reference rate, from the free Frankfurter service
// (no account or key needed). There's one rate per working day, published around 5pm SA time.
// Weekends and holidays get the last working day's rate.
const RATE_SERVICE = 'https://api.frankfurter.dev/v1/';

// Looks up the rate for 'latest' or a 'YYYY-MM-DD' day.
// Returns { rate, date }, where date is the day the rate is really from, or null if it fails.
async function fetchUsdZar(day) {
  try {
    const response = await fetch(`${RATE_SERVICE}${day}?from=USD&to=ZAR`,
      { signal: AbortSignal.timeout(8000) });
    if (!response.ok) return null;
    const data = await response.json();
    const rate = data.rates && Number(data.rates.ZAR);
    // Rates are kept to 4 decimal places, like the rate boxes and the database.
    return rate > 0 ? { rate: Number(rate.toFixed(4)), date: data.date } : null;
  } catch {
    return null;
  }
}

// A 'YYYY-MM-DD' day as e.g. "16 Oct 2026".
function formatDay(day) {
  return new Date(`${day}T00:00`).toLocaleDateString(undefined,
    { day: 'numeric', month: 'short', year: 'numeric' });
}

// ---- Date and time boxes that default to now ----
const openedAtInput = el('opened-at');
const closedAtInput = el('closed-at');

// "Opened at" and "Closed at" default to now. Once you change one by hand
// (e.g. a backtest date), it's left alone.
function setToNow(input) {
  input.value = toLocalInputValue(new Date());
  delete input.dataset.edited;
}
for (const input of [openedAtInput, closedAtInput]) {
  input.addEventListener('input', () => { input.dataset.edited = 'yes'; });
}

// When you come back to the app (e.g. switch back to it on the phone), keep "now" current
// and fetch any trades opened or closed on the other device.
document.addEventListener('visibilitychange', () => {
  if (document.hidden || signedInSection.hidden) return;
  if (!openedAtInput.dataset.edited) setToNow(openedAtInput);
  if (!closeSection.hidden && !closedAtInput.dataset.edited) {
    setToNow(closedAtInput);
    // "Now" may be a new day, so look up that day's rate (unless you typed one).
    fillCloseRate();
  }
  loadSettings();
  loadLists();
});

function loadLists() {
  loadOpenTrades();
  loadHistory();
}

// ---- Screenshots ----
// Images go to a private Supabase Storage bucket, in a folder named after your user id.
// The trade row only keeps the file's path (e.g. "abc-123/f00d.jpg").
const SCREENSHOT_BUCKET = 'screenshots';
// Phone photos can be 4000+ pixels wide and several MB. 1920 pixels on the longest
// side keeps chart text readable at a fraction of the size.
const MAX_IMAGE_SIDE = 1920;
const JPEG_QUALITY = 0.85;

// Shrinks a chosen image in the browser and returns it as a JPEG.
async function shrinkImage(file) {
  const image = new Image();
  const fileUrl = URL.createObjectURL(file);
  try {
    image.src = fileUrl;
    await image.decode();
  } catch {
    throw new Error('That file could not be read as an image. Please use a JPG or PNG.');
  } finally {
    URL.revokeObjectURL(fileUrl);
  }

  const scale = Math.min(1, MAX_IMAGE_SIDE / Math.max(image.naturalWidth, image.naturalHeight));
  const canvas = document.createElement('canvas');
  canvas.width = Math.round(image.naturalWidth * scale);
  canvas.height = Math.round(image.naturalHeight * scale);
  const context = canvas.getContext('2d');
  // JPEGs can't be see-through, so fill with white first (otherwise clear areas turn black).
  context.fillStyle = '#fff';
  context.fillRect(0, 0, canvas.width, canvas.height);
  context.drawImage(image, 0, 0, canvas.width, canvas.height);

  return new Promise((resolve, reject) => {
    canvas.toBlob((blob) => (blob ? resolve(blob) : reject(new Error('Could not shrink the image.'))),
      'image/jpeg', JPEG_QUALITY);
  });
}

// Shrinks and uploads the image chosen in a file box, and returns its storage path.
// Returns null if no image was chosen.
async function uploadScreenshot(fileInput) {
  const file = fileInput.files[0];
  if (!file) return null;
  showMessage('Shrinking and uploading the screenshot…');
  const jpeg = await shrinkImage(file);
  const path = `${currentUserId}/${crypto.randomUUID()}.jpg`;
  const { error } = await db.storage
    .from(SCREENSHOT_BUCKET)
    .upload(path, jpeg, { contentType: 'image/jpeg', upsert: false });
  if (error) throw new Error('Could not upload the screenshot: ' + error.message);
  return path;
}

// ---- Open a trade ----

// The account defaults to the one on your most recently saved trade, from either device.
async function selectLastUsedAccount() {
  const { data, error } = await db
    .from('trades')
    .select('account')
    .order('created_at', { ascending: false })
    .limit(1);
  const account = !error && data.length > 0 ? data[0].account : 'daily';
  // If you already tapped an account while this was loading, keep your choice.
  if (!openForm.elements.account.value) openForm.elements.account.value = account;
}

// After saving, clear the form but keep the account you just used.
function resetOpenForm() {
  const account = openForm.elements.account.value;
  openForm.reset();
  setToNow(openedAtInput);
  openForm.elements.account.value = account;
}

openForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  const adxText = el('adx').value;
  const trade = {
    account: openForm.elements.account.value,
    opened_at: new Date(openedAtInput.value).toISOString(),
    direction: openForm.elements.direction.value,
    risk_usd: Number(el('risk-usd').value),
    adx: adxText === '' ? null : Number(adxText),
    check_h1_bias: el('check-h1-bias').checked,
    check_m15_flip: el('check-m15-flip').checked,
    check_adx: el('check-adx').checked,
    check_rr: el('check-rr').checked,
  };

  // Turn the button off while saving so a double tap can't log the trade twice.
  const button = el('open-button');
  button.disabled = true;
  try {
    // The screenshot goes up first, so the trade can store where it is.
    trade.open_screenshot_path = await uploadScreenshot(el('open-screenshot'));
  } catch (uploadError) {
    button.disabled = false;
    return showMessage(uploadError.message + ' The trade was not saved yet.', true);
  }
  showMessage('Saving…');
  // user_id is filled in by the database from whoever is signed in.
  const { error } = await db.from('trades').insert(trade);
  button.disabled = false;
  if (error) return showMessage('Could not save: ' + error.message, true);

  showMessage(`Trade opened on ${ACCOUNT_NAMES[trade.account]}.`);
  resetOpenForm();
  loadLists();
});

// ---- Pieces shared by both lists ----
// The four checklist tick-boxes, with short names for the detail view and the CSV file.
// The fourth uses the minimum risk:reward from Settings, e.g. "Risk:reward at least 1:2".
function checklist() {
  return [
    ['check_h1_bias', '1H Supertrend matches direction'],
    ['check_m15_flip', '15m Supertrend flipped to match'],
    ['check_adx', 'ADX above threshold'],
    ['check_rr', `Risk:reward at least 1:${Number(settings.min_rr)}`],
  ];
}

// Rule 4 was "the stop is placed at the planned distance" until Task 11 went live.
// Trades saved before then keep that tick, so their Details view says what it meant.
const RULE_4_CHANGED_AT = new Date('2026-10-21T22:45:39+02:00');

function hasOldRule4(trade) {
  return new Date(trade.created_at) < RULE_4_CHANGED_AT;
}

function followedRules(trade) {
  return trade.check_h1_bias && trade.check_m15_flip && trade.check_adx && trade.check_rr;
}

function rulesBadge(trade) {
  const badge = document.createElement('span');
  badge.className = followedRules(trade) ? 'rules ok' : 'rules broken';
  badge.textContent = followedRules(trade) ? 'Rules followed' : 'Rule break';
  return badge;
}

function directionName(trade) {
  return trade.direction === 'buy' ? 'Buy' : 'Sell';
}

// The Rand value and × risk of a closed trade.
// Worked out here, never typed in (see "Calculated, not typed" in the spec).
function closedResult(trade) {
  const pnlUsd = Number(trade.pnl_usd);
  const rate = Number(trade.usdzar_rate);
  return { pnlUsd, rate, pnlZar: pnlUsd * rate, timesRisk: pnlUsd / Number(trade.risk_usd) };
}

function detailsButton(trade) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'small secondary';
  button.textContent = 'Details';
  button.addEventListener('click', () => showDetail(trade.id));
  return button;
}

// A new element with a class, holding the given text and elements.
function part(tag, className, ...children) {
  const element = document.createElement(tag);
  element.className = className;
  element.append(...children);
  return element;
}

// "Buy" or "Sell" with the rules badge beside it, the start of each trade in the lists.
function tradeTitle(trade) {
  return part('span', 'trade-title', directionName(trade), rulesBadge(trade));
}

// The text for an empty list, e.g. "No open trades on Backtest."
function emptyListItem(text) {
  const view = selectedView();
  const item = document.createElement('li');
  item.className = 'empty';
  item.textContent = view === 'both' ? `${text}.` : `${text} on ${ACCOUNT_NAMES[view]}.`;
  return item;
}

// ---- Open trades list ----
// Every open trade, from both accounts. The switch decides which ones are drawn.
let openTrades = [];

async function loadOpenTrades() {
  const { data, error } = await db
    .from('trades')
    .select('id, account, opened_at, direction, risk_usd, adx, check_h1_bias, check_m15_flip, check_adx, check_rr')
    .is('closed_at', null)
    .order('opened_at', { ascending: false });
  if (error) return showMessage('Could not load trades: ' + error.message, true);
  openTrades = data;
  renderOpenTrades();
}

function renderOpenTrades() {
  const shown = openTrades.filter(isInView);
  openTradesList.innerHTML = '';
  if (shown.length === 0) {
    openTradesList.appendChild(emptyListItem('No open trades'));
    return;
  }
  for (const trade of shown) {
    const parts = [ACCOUNT_NAMES[trade.account], formatWhen(trade.opened_at)];
    if (trade.adx !== null) parts.push(`ADX ${trade.adx}`);

    const closeButton = document.createElement('button');
    closeButton.type = 'button';
    closeButton.className = 'small';
    closeButton.textContent = 'Close trade';
    closeButton.addEventListener('click', () => showCloseForm(trade));

    openTradesList.appendChild(part('li', '',
      part('div', 'trade-row', tradeTitle(trade), part('span', 'trade-line', `Risk ${usd.format(trade.risk_usd)}`)),
      part('div', 'trade-meta', parts.join(' · ')),
      part('div', 'trade-actions', closeButton, detailsButton(trade)),
    ));
  }
}

el('refresh-button').addEventListener('click', () => {
  showMessage('');
  loadSettings();
  loadLists();
});

// ---- Close a trade ----
// The trade the close form is filled in for, or null when the form is hidden.
let tradeBeingClosed = null;

function showCloseSummary(trade) {
  el('close-summary').textContent = `${directionName(trade)} · risk ${usd.format(trade.risk_usd)} · ` +
    `${ACCOUNT_NAMES[trade.account]} · opened ${formatWhen(trade.opened_at)}`;
}

function showCloseForm(trade) {
  tradeBeingClosed = trade;
  closeForm.reset();
  setToNow(closedAtInput);
  delete closeRateInput.dataset.edited;
  showCloseSummary(trade);
  closeSection.hidden = false;
  closeSection.scrollIntoView({ behavior: 'smooth', block: 'start' });
  fillCloseRate();
}

function hideCloseForm() {
  tradeBeingClosed = null;
  closeSection.hidden = true;
  el('usdzar-rate-note').textContent = '';
}

el('cancel-close-button').addEventListener('click', hideCloseForm);

// The rate box starts with the official rate for the close date, so a backtest trade
// gets the rate from its own historic date. Changing the close date looks it up again.
// Once you type in the rate box yourself, it's left alone.
const closeRateInput = el('usdzar-rate');
const closeRateNote = el('usdzar-rate-note');
// Counts lookups, so a slow answer for an earlier close date is ignored.
let closeRateLookup = 0;
let closeRateTimer = null;

closeRateInput.addEventListener('input', () => {
  closeRateInput.dataset.edited = 'yes';
  closeRateNote.textContent = '';
});

// Waits until you stop changing the date (typing a year sends several changes) before looking up.
closedAtInput.addEventListener('input', () => {
  clearTimeout(closeRateTimer);
  closeRateTimer = setTimeout(fillCloseRate, 600);
});

async function fillCloseRate() {
  clearTimeout(closeRateTimer);
  const trade = tradeBeingClosed;
  // The datetime box holds local time, so its first 10 characters are the local day.
  const day = closedAtInput.value.slice(0, 10);
  if (!trade || closeRateInput.dataset.edited || !/^\d{4}-\d{2}-\d{2}$/.test(day)) return;
  const lookup = ++closeRateLookup;
  closeRateNote.textContent = 'Looking up the official rate…';

  const official = await fetchUsdZar(day);
  // Stop if you typed a rate, changed the date, or closed the form while this was loading.
  const stillWanted = () => lookup === closeRateLookup && tradeBeingClosed === trade &&
    !closeRateInput.dataset.edited;
  if (!stillWanted()) return;
  if (official) {
    closeRateInput.value = official.rate;
    closeRateNote.textContent = official.date === day
      ? `Official rate for ${formatDay(day)}.`
      : `Official rate for ${formatDay(official.date)}, the latest one available for ${formatDay(day)}.`;
    return;
  }

  // The lookup failed (e.g. no internet), so use the rate from this account's latest closed trade.
  const { data, error } = await db
    .from('trades')
    .select('usdzar_rate')
    .eq('account', trade.account)
    .not('closed_at', 'is', null)
    .order('closed_at', { ascending: false })
    .limit(1);
  if (!stillWanted()) return;
  if (!error && data.length > 0) {
    closeRateInput.value = Number(data[0].usdzar_rate);
    closeRateNote.textContent = "Couldn't look up the official rate, so this is the rate from your " +
      'last closed trade on this account. Check it before saving.';
  } else {
    closeRateInput.value = '';
    closeRateNote.textContent = "Couldn't look up the official rate. Please type it in.";
  }
}

closeForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  const trade = tradeBeingClosed;
  const closedAt = new Date(closedAtInput.value);
  if (closedAt < new Date(trade.opened_at)) {
    return showMessage('The close time is before the open time. Please check the date.', true);
  }
  const closing = {
    closed_at: closedAt.toISOString(),
    pnl_usd: Number(el('pnl-usd').value),
    usdzar_rate: Number(el('usdzar-rate').value),
    mistake_tag: el('mistake-tag').value || null,
    lesson: el('lesson').value.trim() || null,
  };

  // Turn the button off while saving so a double tap can't send it twice.
  const button = el('close-button');
  button.disabled = true;
  try {
    closing.close_screenshot_path = await uploadScreenshot(el('close-screenshot'));
  } catch (uploadError) {
    button.disabled = false;
    return showMessage(uploadError.message + ' The trade is still open.', true);
  }
  showMessage('Saving…');
  // Only close it if it's still open, in case it was already closed on the other device.
  const { data, error } = await db
    .from('trades')
    .update(closing)
    .eq('id', trade.id)
    .is('closed_at', null)
    .select('id');
  button.disabled = false;
  if (error) return showMessage('Could not save: ' + error.message, true);

  hideCloseForm();
  if (data.length === 0) {
    showMessage('That trade was already closed, maybe on your other device.', true);
  } else {
    showMessage(`Trade closed: ${signedUsd.format(closing.pnl_usd)}.`);
  }
  loadLists();
});

// ---- History (closed trades) ----
// Every closed trade, from both accounts. Used by History, the headline and the stats.
let closedTrades = [];

async function loadHistory() {
  const { data, error } = await db
    .from('trades')
    .select('id, account, direction, risk_usd, check_h1_bias, check_m15_flip, check_adx, check_rr, ' +
      'closed_at, pnl_usd, usdzar_rate, mistake_tag, lesson')
    .not('closed_at', 'is', null)
    .order('closed_at', { ascending: false });
  if (error) return showMessage('Could not load history: ' + error.message, true);
  closedTrades = data;
  renderHistory();
  renderHeadline();
  renderStats();
}

function renderHistory() {
  const shown = closedTrades.filter(isInView);
  historyList.innerHTML = '';
  if (shown.length === 0) {
    historyList.appendChild(emptyListItem('No closed trades yet'));
    return;
  }
  for (const trade of shown) {
    const { pnlUsd, rate, pnlZar, timesRisk } = closedResult(trade);

    const resultClass = pnlUsd > 0 ? 'win' : pnlUsd < 0 ? 'loss' : '';

    const item = part('li', '',
      part('div', 'trade-row', tradeTitle(trade),
        part('span', `trade-amount ${resultClass}`, signedUsd.format(pnlUsd))),
      part('div', 'trade-row',
        part('span', 'trade-line', `${formatTimesRisk(timesRisk)} · risk ${usd.format(trade.risk_usd)}`),
        part('span', `trade-line ${resultClass}`, signedZar(pnlZar))),
      part('div', 'trade-meta',
        `${ACCOUNT_NAMES[trade.account]} · closed ${formatWhen(trade.closed_at)} · USD/ZAR ${rate}`),
    );

    if (trade.mistake_tag || trade.lesson) {
      item.append(part('div', 'trade-meta',
        [trade.mistake_tag && `Mistake: ${trade.mistake_tag}`, trade.lesson].filter(Boolean).join(' · ')));
    }
    item.append(part('div', 'trade-actions', detailsButton(trade)));
    historyList.appendChild(item);
  }
}

// ---- CSV export (closed trades, for Excel or Google Sheets) ----
// Exports the account the switch shows (or both), one row per closed trade, oldest first.
// The file is laid out the way Excel expects on South African settings: values split by
// semicolons, and a comma as the decimal point (e.g. -25,5). Tested on the owner's laptop:
// with commas between values, Excel put each whole trade into a single cell.
const exportButton = el('export-button');

function updateExportButton() {
  const view = selectedView();
  exportButton.textContent = view === 'both'
    ? 'Download CSV (both accounts)'
    : `Download CSV (${ACCOUNT_NAMES[view]})`;
}

// Rounds to a number of decimal places, with halves going away from zero.
function roundTo(value, places) {
  const factor = 10 ** places;
  return Math.sign(value) * Math.round(Math.abs(value) * factor) / factor;
}

// A number with a comma as the decimal point and no thousands separator, e.g. -1234,5.
// An empty value (null) stays an empty cell.
function csvNumber(value) {
  return value === null ? '' : String(value).replace('.', ',');
}

// Text is wrapped in quotes when it holds a separator, quote or line break.
// Text starting with = + - or @ gets an apostrophe in front, so Excel shows it as typed
// instead of trying to work it out as a formula (e.g. a lesson like "-wait for the close").
function csvText(text) {
  if (text === null || text === '') return '';
  let value = /^[=+\-@]/.test(text) ? `'${text}` : text;
  if (/[;",\r\n]/.test(value)) value = `"${value.replace(/"/g, '""')}"`;
  return value;
}

// A date and time as the spreadsheet should read it, e.g. 2026-10-17 14:30 (this device's local time).
function csvWhen(isoText) {
  return toLocalInputValue(new Date(isoText)).replace('T', ' ');
}

const yesNo = (value) => (value ? 'Yes' : 'No');

// Each column: its heading, and how to fill it in for one trade.
// Worked out at download time, so the risk:reward heading uses the saved N.
const csvColumns = () => [
  ['Account', (trade) => csvText(ACCOUNT_NAMES[trade.account])],
  ['Opened', (trade) => csvWhen(trade.opened_at)],
  ['Closed', (trade) => csvWhen(trade.closed_at)],
  ['Direction', (trade) => csvText(directionName(trade))],
  ['Risk (USD)', (trade) => csvNumber(Number(trade.risk_usd))],
  ['ADX', (trade) => csvNumber(trade.adx === null ? null : Number(trade.adx))],
  ...checklist().map(([field, name]) => [name, (trade) => yesNo(trade[field])]),
  ['Rules followed', (trade) => yesNo(followedRules(trade))],
  ['P&L (USD)', (trade) => csvNumber(Number(trade.pnl_usd))],
  ['USD/ZAR rate', (trade) => csvNumber(Number(trade.usdzar_rate))],
  // Rounded to the cent, the same as History shows it.
  ['P&L (ZAR)', (trade) => csvNumber(toCents(closedResult(trade).pnlZar) / 100)],
  // Four decimal places, so averages worked out in the spreadsheet match the app's stats.
  ['× risk', (trade) => csvNumber(roundTo(closedResult(trade).timesRisk, 4))],
  ['Win', (trade) => yesNo(Number(trade.pnl_usd) > 0)],
  ['Mistake', (trade) => csvText(trade.mistake_tag)],
  ['Lesson', (trade) => csvText(trade.lesson)],
];

// The whole file as text: a heading row, then one row per trade.
function buildCsv(trades) {
  const columns = csvColumns();
  const rows = [columns.map(([heading]) => csvText(heading))];
  for (const trade of trades) rows.push(columns.map(([, value]) => value(trade)));
  return rows.map((cells) => cells.join(';')).join('\r\n') + '\r\n';
}

// Hands the text to the browser as a file to save.
function downloadFile(fileName, text) {
  // The invisible mark at the start (a "byte order mark") tells Excel the file is UTF-8,
  // so characters like × show properly.
  const blob = new Blob(['﻿' + text], { type: 'text/csv;charset=utf-8' });
  const link = document.createElement('a');
  link.href = URL.createObjectURL(blob);
  link.download = fileName;
  document.body.appendChild(link);
  link.click();
  link.remove();
  // Give the browser a moment to start the download before letting go of the file.
  setTimeout(() => URL.revokeObjectURL(link.href), 10000);
}

// The button is far down the page, so its messages show right under it.
function showExportStatus(text, isError = false) {
  const status = el('export-status');
  status.textContent = text;
  status.classList.toggle('error', isError);
  status.hidden = !text;
}

exportButton.addEventListener('click', async () => {
  const view = selectedView();
  exportButton.disabled = true;
  showExportStatus('Preparing the file…');
  // Fetched fresh, so trades closed on your other device since the page loaded are included.
  let query = db
    .from('trades')
    .select('account, opened_at, direction, risk_usd, adx, check_h1_bias, check_m15_flip, check_adx, ' +
      'check_rr, closed_at, pnl_usd, usdzar_rate, mistake_tag, lesson')
    .not('closed_at', 'is', null)
    .order('closed_at', { ascending: true });
  if (view !== 'both') query = query.eq('account', view);
  const { data, error } = await query;
  exportButton.disabled = false;
  if (error) return showExportStatus('Could not export: ' + error.message, true);

  if (data.length === 0) {
    const where = view === 'both' ? '' : ` on ${ACCOUNT_NAMES[view]}`;
    return showExportStatus(`No closed trades to export${where}.`, true);
  }
  const today = toLocalInputValue(new Date()).slice(0, 10);
  const fileName = `gold-trades-${view === 'both' ? 'both-accounts' : view}-${today}.csv`;
  downloadFile(fileName, buildCsv(data));
  const count = data.length === 1 ? '1 closed trade' : `${data.length} closed trades`;
  showExportStatus(`Downloaded ${fileName} (${count}).`);
});

// ---- Account switch: Daily Demo, Backtest or Both ----
// Remembered on this device only, so the phone and laptop can each show a different account.
const VIEW_STORAGE_KEY = 'gold-trade-logger:view';
const viewInputs = document.querySelectorAll('input[name="view"]');

function selectedView() {
  const checked = document.querySelector('input[name="view"]:checked');
  return checked ? checked.value : 'both';
}

function isInView(trade) {
  const view = selectedView();
  return view === 'both' || trade.account === view;
}

function selectRememberedView() {
  let view = 'both';
  try {
    view = localStorage.getItem(VIEW_STORAGE_KEY) || 'both';
  } catch {
    // Some private browsing modes block storage. Just show both.
  }
  for (const input of viewInputs) input.checked = input.value === view;
  if (!document.querySelector('input[name="view"]:checked')) viewInputs[viewInputs.length - 1].checked = true;
  updateExportButton();
}

for (const input of viewInputs) {
  input.addEventListener('change', () => {
    try {
      localStorage.setItem(VIEW_STORAGE_KEY, selectedView());
    } catch {
      // Not remembered, but the switch still works.
    }
    renderOpenTrades();
    renderHistory();
    renderHeadline();
    renderStats();
    updateExportButton();
    showExportStatus('');
  });
}

// ---- Headline: totals for each account shown ----

// One account's totals from its closed trades. Only maths here, no page changes.
// Dollars and Rand are added up in whole cents, and each trade's Rand value is rounded
// to the cent first, so the totals match adding up the values shown in History.
function headlineTotals(trades, startBalance, todayRate) {
  let usdCents = 0;
  let zarCents = 0;
  for (const trade of trades) {
    const { pnlUsd, pnlZar } = closedResult(trade);
    usdCents += toCents(pnlUsd);
    zarCents += toCents(pnlZar);
  }
  const totalUsd = usdCents / 100;
  return {
    count: trades.length,
    totalUsd,
    zarAtCloseRates: zarCents / 100,
    // Empty (null) until the setting it needs has been filled in.
    zarAtTodayRate: todayRate ? totalUsd * todayRate : null,
    returnFraction: startBalance ? totalUsd / startBalance : null,
  };
}

function renderHeadline() {
  const view = selectedView();
  const accounts = view === 'both' ? ['daily', 'backtest'] : [view];
  const todayRate = settings.usdzar_today === null ? null : Number(settings.usdzar_today);

  headlineBox.innerHTML = '';
  for (const account of accounts) {
    const balance = settings[`start_balance_${account}`];
    const startBalance = balance === null ? null : Number(balance);
    const totals = headlineTotals(closedTrades.filter((trade) => trade.account === account),
      startBalance, todayRate);

    // A small grey label, a big value, and an optional note under it.
    const tile = (label, value, note = '', className = '', valueClass = '') => part('div', `tile ${className}`,
      part('span', 'tile-label', label),
      part('span', `tile-value ${valueClass}`, value),
      ...(note ? [part('span', 'tile-note', note)] : []));

    const resultClass = totals.totalUsd > 0 ? 'win' : totals.totalUsd < 0 ? 'loss' : '';
    const count = totals.count === 1 ? '1 closed trade' : `${totals.count} closed trades`;
    const tiles = part('div', 'tiles',
      tile('Total P&L', signedUsd.format(totals.totalUsd), `From ${count}`, 'main', resultClass),
      tile('Rand at close-date rates', signedZar(totals.zarAtCloseRates), "Each trade's own rate"),
      totals.zarAtTodayRate === null
        ? tile("Rand at today's rate", '—', "Set today's rate in Settings")
        : tile("Rand at today's rate", signedZar(totals.zarAtTodayRate), `USD/ZAR ${todayRate}`),
      totals.returnFraction === null
        ? tile('% return', '—', 'Set a starting balance in Settings')
        : tile('% return', signedPercent.format(totals.returnFraction), `On ${usd.format(startBalance)}`),
    );

    headlineBox.appendChild(part('div', 'headline-card',
      part('h3', '', ACCOUNT_NAMES[account]),
      tiles,
      part('p', 'note', "Open trades aren't counted.")));
  }
}

// ---- Stats: one card per account shown ----
// Each card is a table with three columns: all closed trades, then rules followed
// against rule break, so the comparison sits side by side.

// Win rate, e.g. 58.3%.
const percentOneDecimal = new Intl.NumberFormat('en-US', {
  style: 'percent', minimumFractionDigits: 1, maximumFractionDigits: 1,
});

// The stats for one group of closed trades, worked out as the spec's "Stat definitions" say.
// Only maths here, no page changes. A value is null when there's nothing to work it out from.
function groupStats(trades) {
  const winTimesRisk = [];
  const lossTimesRisk = [];
  let sumTimesRisk = 0;
  let winCents = 0;
  let lossCents = 0;
  for (const trade of trades) {
    const { pnlUsd, timesRisk } = closedResult(trade);
    sumTimesRisk += timesRisk;
    // A win is P&L above zero. A loss is P&L below zero. A trade at exactly $0 is neither,
    // but it still counts as a closed trade.
    if (pnlUsd > 0) {
      winTimesRisk.push(timesRisk);
      winCents += toCents(pnlUsd);
    } else if (pnlUsd < 0) {
      lossTimesRisk.push(Math.abs(timesRisk));
      lossCents += Math.abs(toCents(pnlUsd));
    }
  }

  const count = trades.length;
  const wins = winTimesRisk.length;
  const losses = lossTimesRisk.length;
  const average = (values) => (values.length === 0 ? 0 : values.reduce((a, b) => a + b, 0) / values.length);
  const winRate = count === 0 ? null : wins / count;
  const lossRate = count === 0 ? null : losses / count;

  return {
    count,
    wins,
    losses,
    winRate,
    averageTimesRisk: count === 0 ? null : sumTimesRisk / count,
    // (win rate × average winning × risk) − (loss rate × average losing × risk, as a positive number)
    expectancy: count === 0 ? null : winRate * average(winTimesRisk) - lossRate * average(lossTimesRisk),
    // Winning dollars ÷ losing dollars. Shown as "—" until there's a loss.
    profitFactor: losses === 0 ? null : winCents / lossCents,
  };
}

// A × risk value without the words, for the table, e.g. +0.45 or -1.00.
function formatTimesRiskNumber(value) {
  return `${signOf(value)}${twoDecimals.format(Math.abs(value))}`;
}

function renderStats() {
  const view = selectedView();
  const accounts = view === 'both' ? ['daily', 'backtest'] : [view];

  statsBox.innerHTML = '';
  for (const account of accounts) {
    const trades = closedTrades.filter((trade) => trade.account === account);
    const card = document.createElement('div');
    card.className = 'stats-card';

    const title = document.createElement('h3');
    title.textContent = ACCOUNT_NAMES[account];
    card.appendChild(title);

    if (trades.length === 0) {
      const empty = document.createElement('p');
      empty.className = 'note';
      empty.textContent = 'No closed trades yet.';
      card.appendChild(empty);
      statsBox.appendChild(card);
      continue;
    }

    const all = groupStats(trades);
    const followed = groupStats(trades.filter(followedRules));
    const broken = groupStats(trades.filter((trade) => !followedRules(trade)));
    const groups = [all, followed, broken];

    const ruleBreaks = document.createElement('p');
    ruleBreaks.textContent = `Rule breaks: ${broken.count} of ${all.count} closed trades.`;
    card.appendChild(ruleBreaks);

    // Each row: its name, and how to show one group's value (null shows as "—").
    const rows = [
      ['Closed trades', (stats) => String(stats.count)],
      ['Wins', (stats) => String(stats.wins)],
      ['Losses', (stats) => String(stats.losses)],
      ['Win rate', (stats) => stats.winRate === null ? '—' : percentOneDecimal.format(stats.winRate)],
      ['Average × risk', (stats) => stats.averageTimesRisk === null ? '—' : formatTimesRiskNumber(stats.averageTimesRisk)],
      ['Expectancy (× risk)', (stats) => stats.expectancy === null ? '—' : formatTimesRiskNumber(stats.expectancy)],
      ['Profit factor', (stats) => stats.profitFactor === null ? '—' : twoDecimals.format(stats.profitFactor)],
    ];

    const table = document.createElement('table');
    table.className = 'stats-table';
    const headRow = table.createTHead().insertRow();
    for (const name of ['', 'All', 'Rules followed', 'Rule break']) {
      const cell = document.createElement('th');
      cell.scope = 'col';
      cell.textContent = name;
      headRow.appendChild(cell);
    }
    const body = table.createTBody();
    for (const [name, show] of rows) {
      const row = body.insertRow();
      const nameCell = document.createElement('th');
      nameCell.scope = 'row';
      nameCell.textContent = name;
      row.appendChild(nameCell);
      for (const stats of groups) row.insertCell().textContent = show(stats);
    }
    // On a narrow phone the table can scroll sideways instead of squashing.
    const scroller = document.createElement('div');
    scroller.className = 'table-scroll';
    scroller.appendChild(table);
    card.appendChild(scroller);

    const note = document.createElement('p');
    note.className = 'note';
    note.textContent = "Open trades aren't counted. A trade at exactly $0 is neither a win nor a loss.";
    card.appendChild(note);

    statsBox.appendChild(card);
  }
}

// ---- Settings ----
// Kept in the settings table (one row for you), so both devices share them.
const DEFAULT_ADX_THRESHOLD = 20;
const DEFAULT_MIN_RR = 2;
let settings = emptySettings();

// Before anything is saved: no balances or rate yet, and the spec's defaults for ADX and risk:reward.
function emptySettings() {
  return {
    start_balance_daily: null,
    start_balance_backtest: null,
    usdzar_today: null,
    adx_threshold: DEFAULT_ADX_THRESHOLD,
    min_rr: DEFAULT_MIN_RR,
  };
}

async function loadSettings() {
  const { data, error } = await db
    .from('settings')
    .select('start_balance_daily, start_balance_backtest, usdzar_today, adx_threshold, min_rr')
    .maybeSingle();
  if (error) return showMessage('Could not load settings: ' + error.message, true);
  settings = data || emptySettings();
  fillSettingsForm();
  showChecklistSettings();
  renderHeadline();
  updateTodayRate();
}

// Each time settings load (opening the app, coming back to it, or Refresh), today's rate is
// looked up and saved if it has changed. A rate you typed is replaced here too.
async function updateTodayRate() {
  const userId = currentUserId;
  const note = el('usdzar-today-note');
  const latest = await fetchUsdZar('latest');
  if (currentUserId !== userId) return;
  if (!latest) {
    note.textContent = "Couldn't look up today's rate just now, so this is the last saved one.";
    return;
  }
  if (Number(settings.usdzar_today) !== latest.rate) {
    // Only this one column is sent, so the other settings stay as they are.
    // If there's no settings row yet, this creates it (ADX threshold and risk:reward get their defaults).
    const { error } = await db.from('settings').upsert({ user_id: userId, usdzar_today: latest.rate });
    if (currentUserId !== userId) return;
    if (error) {
      note.textContent = "Couldn't save today's rate: " + error.message;
      return;
    }
    settings = { ...settings, usdzar_today: latest.rate };
    fillSettingsForm();
    renderHeadline();
  }
  note.textContent = `Official rate for ${formatDay(latest.date)}, updated automatically.`;
}

// Shows the settings in the entry checklist, e.g. "ADX is above the threshold (20)."
// and "Risk:reward is at least 1:2." (on the open form and the edit form).
function showChecklistSettings() {
  el('adx-threshold-text').textContent = String(Number(settings.adx_threshold));
  for (const text of document.querySelectorAll('.min-rr-text')) {
    text.textContent = String(Number(settings.min_rr));
  }
}

const settingsFields = {
  start_balance_daily: el('start-balance-daily'),
  start_balance_backtest: el('start-balance-backtest'),
  usdzar_today: el('usdzar-today'),
  adx_threshold: el('adx-threshold'),
  min_rr: el('min-rr'),
};

function resetSettingsForm() {
  settingsForm.reset();
  delete settingsForm.dataset.edited;
  el('usdzar-today-note').textContent = '';
  showSettingsStatus('');
  fillSettingsForm();
}

// Puts the saved settings in the form, unless you're halfway through changing them.
function fillSettingsForm() {
  if (settingsForm.dataset.edited) return;
  for (const [field, input] of Object.entries(settingsFields)) {
    input.value = settings[field] === null ? '' : Number(settings[field]);
  }
}

settingsForm.addEventListener('input', () => { settingsForm.dataset.edited = 'yes'; });

// The form is at the bottom of the page, so its messages show right under the button.
function showSettingsStatus(text, isError = false) {
  const status = el('settings-status');
  status.textContent = text;
  status.classList.toggle('error', isError);
  status.hidden = !text;
}

settingsForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  const numberOrNull = (input) => (input.value === '' ? null : Number(input.value));
  const changes = {
    start_balance_daily: numberOrNull(settingsFields.start_balance_daily),
    start_balance_backtest: numberOrNull(settingsFields.start_balance_backtest),
    usdzar_today: numberOrNull(settingsFields.usdzar_today),
    adx_threshold: Number(settingsFields.adx_threshold.value),
    min_rr: Number(settingsFields.min_rr.value),
  };

  const button = el('settings-button');
  button.disabled = true;
  showSettingsStatus('Saving…');
  // "upsert" creates your settings row the first time, and updates it after that.
  const { error } = await db.from('settings').upsert({ user_id: currentUserId, ...changes });
  button.disabled = false;
  if (error) return showSettingsStatus('Could not save: ' + error.message, true);

  settings = changes;
  delete settingsForm.dataset.edited;
  showChecklistSettings();
  renderHeadline();
  showSettingsStatus('Settings saved.');
});

// ---- Trade detail (with both screenshots) ----
const detailDialog = el('detail-dialog');
// The trade the detail view is showing, so a slow answer for an earlier tap is ignored.
let detailTradeId = null;
// The whole trade once it has loaded, for the Edit and Delete buttons.
let detailTrade = null;

async function showDetail(tradeId) {
  detailTradeId = tradeId;
  detailTrade = null;
  hideEditForm();
  el('detail-actions').hidden = true;
  showDetailMessage('');
  el('detail-title').textContent = 'Loading…';
  el('detail-status').textContent = '';
  el('detail-fields').innerHTML = '';
  el('open-shot').innerHTML = '';
  el('close-shot').innerHTML = '';
  if (!detailDialog.open) detailDialog.showModal();

  // Fetch the trade fresh, in case it was closed on your other device since the list loaded.
  const { data: trade, error } = await db.from('trades').select('*').eq('id', tradeId).single();
  if (detailTradeId !== tradeId) return;
  if (error) {
    el('detail-title').textContent = 'Could not load this trade';
    el('detail-status').textContent = error.message;
    return;
  }

  // The bucket is private, so each image needs a signed link. These last one hour.
  const paths = [trade.open_screenshot_path, trade.close_screenshot_path].filter(Boolean);
  const links = {};
  if (paths.length > 0) {
    const { data: signed, error: linkError } = await db.storage
      .from(SCREENSHOT_BUCKET)
      .createSignedUrls(paths, 60 * 60);
    if (detailTradeId !== tradeId) return;
    if (!linkError) {
      for (const item of signed) if (!item.error) links[item.path] = item.signedUrl;
    }
  }
  renderDetail(trade, links);
}

// Fills in the detail view. "links" maps a screenshot's storage path to a link that shows it.
function renderDetail(trade, links) {
  const closed = trade.closed_at !== null;
  const rows = [
    ['Account', ACCOUNT_NAMES[trade.account]],
    ['Opened', formatWhen(trade.opened_at)],
    ['Risk', usd.format(trade.risk_usd)],
    ['ADX', trade.adx === null ? '—' : String(trade.adx)],
    ...checklist().map(([field, name]) => {
      const tick = trade[field] ? '✓ Yes' : '✗ No';
      if (field === 'check_rr' && hasOldRule4(trade)) {
        return ['Stop at planned distance', `${tick} (the old rule 4, before risk:reward replaced it on 21 Oct 2026)`];
      }
      return [name, tick];
    }),
  ];

  if (closed) {
    const { pnlUsd, rate, pnlZar, timesRisk } = closedResult(trade);
    el('detail-title').textContent = `${directionName(trade)} · ${signedUsd.format(pnlUsd)}`;
    el('detail-title').className = pnlUsd > 0 ? 'win' : pnlUsd < 0 ? 'loss' : '';
    rows.push(
      ['Closed', formatWhen(trade.closed_at)],
      ['P&L', `${signedUsd.format(pnlUsd)} · ${signedZar(pnlZar)}`],
      ['Result', formatTimesRisk(timesRisk)],
      ['USD/ZAR rate', String(rate)],
      ['Mistake', trade.mistake_tag || 'None'],
      ['Lesson', trade.lesson || '—'],
    );
  } else {
    el('detail-title').textContent = `${directionName(trade)} · still open`;
    el('detail-title').className = '';
  }

  el('detail-status').replaceChildren(rulesBadge(trade));

  const list = el('detail-fields');
  list.innerHTML = '';
  for (const [name, value] of rows) {
    const term = document.createElement('dt');
    term.textContent = name;
    const description = document.createElement('dd');
    description.textContent = value;
    list.append(term, description);
  }

  showShot(el('open-shot'), trade.open_screenshot_path, links, 'No screenshot at open.');
  showShot(el('close-shot'), trade.close_screenshot_path, links,
    closed ? 'No screenshot at close.' : 'Not closed yet.');

  detailTrade = trade;
  el('detail-actions').hidden = false;
}

// Messages inside the detail view (the page's message box would be hidden behind it).
function showDetailMessage(text, isError = false) {
  const status = el('detail-message');
  status.textContent = text;
  status.classList.toggle('error', isError);
  status.hidden = !text;
}

function showShot(box, path, links, emptyText) {
  box.innerHTML = '';
  if (!path || !links[path]) {
    const note = document.createElement('p');
    note.className = 'empty';
    note.textContent = path ? 'Could not load this screenshot.' : emptyText;
    box.appendChild(note);
    return;
  }
  // Tap the image to open it full size, e.g. to zoom in on a phone.
  const link = document.createElement('a');
  link.href = links[path];
  link.target = '_blank';
  link.rel = 'noopener';
  const image = document.createElement('img');
  image.src = links[path];
  image.alt = 'Chart screenshot';
  link.appendChild(image);
  box.appendChild(link);
}

function hideDetail() {
  if (detailDialog.open) detailDialog.close();
}

el('detail-back-button').addEventListener('click', hideDetail);
// Runs however the view is closed (Back button, or the Esc key on a laptop).
detailDialog.addEventListener('close', () => {
  detailTradeId = null;
  detailTrade = null;
});

// ---- Edit a trade (from its detail view) ----
// Every typed field can be fixed. × risk and Rand are worked out from the saved values
// each time they're shown, so they update by themselves after an edit.
// This form is the only place a closed trade's USD/ZAR rate can change.
const editForm = el('edit-form');
const editCloseFields = el('edit-close-fields');

const EDIT_CHECKBOXES = {
  check_h1_bias: el('edit-check-h1-bias'),
  check_m15_flip: el('edit-check-m15-flip'),
  check_adx: el('edit-check-adx'),
  check_rr: el('edit-check-rr'),
};

function showEditForm() {
  const trade = detailTrade;
  const closed = trade.closed_at !== null;
  editForm.reset();
  editForm.elements['edit-account'].value = trade.account;
  el('edit-opened-at').value = toLocalInputValue(new Date(trade.opened_at));
  editForm.elements['edit-direction'].value = trade.direction;
  el('edit-risk-usd').value = Number(trade.risk_usd);
  el('edit-adx').value = trade.adx === null ? '' : Number(trade.adx);
  for (const [field, box] of Object.entries(EDIT_CHECKBOXES)) box.checked = trade[field];

  // An open trade has no close values yet. Switching the boxes off means they aren't
  // required and aren't saved.
  editCloseFields.hidden = !closed;
  editCloseFields.disabled = !closed;
  if (closed) {
    el('edit-closed-at').value = toLocalInputValue(new Date(trade.closed_at));
    el('edit-pnl-usd').value = Number(trade.pnl_usd);
    el('edit-usdzar-rate').value = Number(trade.usdzar_rate);
    el('edit-mistake-tag').value = trade.mistake_tag || '';
    el('edit-lesson').value = trade.lesson || '';
  }

  showDetailMessage('');
  el('detail-view').hidden = true;
  editForm.hidden = false;
  detailDialog.scrollTop = 0;
}

function hideEditForm() {
  editForm.hidden = true;
  el('detail-view').hidden = false;
}

el('edit-button').addEventListener('click', showEditForm);

el('cancel-edit-button').addEventListener('click', () => {
  hideEditForm();
  showDetailMessage('');
});

editForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  const trade = detailTrade;
  const closed = trade.closed_at !== null;
  const adxText = el('edit-adx').value;
  const changes = {
    account: editForm.elements['edit-account'].value,
    opened_at: new Date(el('edit-opened-at').value).toISOString(),
    direction: editForm.elements['edit-direction'].value,
    risk_usd: Number(el('edit-risk-usd').value),
    adx: adxText === '' ? null : Number(adxText),
  };
  for (const [field, box] of Object.entries(EDIT_CHECKBOXES)) changes[field] = box.checked;

  if (closed) {
    const closedAt = new Date(el('edit-closed-at').value);
    if (closedAt < new Date(changes.opened_at)) {
      return showDetailMessage('The close time is before the open time. Please check the dates.', true);
    }
    Object.assign(changes, {
      closed_at: closedAt.toISOString(),
      pnl_usd: Number(el('edit-pnl-usd').value),
      usdzar_rate: Number(el('edit-usdzar-rate').value),
      mistake_tag: el('edit-mistake-tag').value || null,
      lesson: el('edit-lesson').value.trim() || null,
    });
  }

  const button = el('save-edit-button');
  button.disabled = true;
  showDetailMessage('Saving…');
  // Only save if the trade is still open (or still closed) as it was when you tapped Edit,
  // in case it was closed or deleted on your other device in the meantime.
  let query = db.from('trades').update(changes).eq('id', trade.id);
  query = closed ? query.not('closed_at', 'is', null) : query.is('closed_at', null);
  const { data, error } = await query.select('id');
  button.disabled = false;
  if (error) return showDetailMessage('Could not save: ' + error.message, true);
  if (data.length === 0) {
    return showDetailMessage('Not saved: this trade was changed or deleted on your other device. ' +
      'Tap Back and open it again.', true);
  }

  // If the close form is open for this trade, show its new details there too.
  if (tradeBeingClosed && tradeBeingClosed.id === trade.id) {
    Object.assign(tradeBeingClosed, changes);
    showCloseSummary(tradeBeingClosed);
  }
  loadLists();
  // Reload the detail view from the database, so it shows exactly what was saved.
  await showDetail(trade.id);
  if (detailTradeId === trade.id) showDetailMessage('Changes saved.');
});

// ---- Delete a trade (from its detail view) ----

// A short date for the "Are you sure?" question, e.g. "17 Oct", with the year if it isn't this year.
function shortDate(isoText) {
  const date = new Date(isoText);
  const options = { day: 'numeric', month: 'short' };
  if (date.getFullYear() !== new Date().getFullYear()) options.year = 'numeric';
  return date.toLocaleDateString(undefined, options);
}

// Names the trade, so you can tell which one is about to go, e.g.
// "Delete Buy · -$25.00 on 17 Oct (Daily Demo)?"
function deleteQuestion(trade) {
  const what = trade.closed_at !== null
    ? `${directionName(trade)} · ${signedUsd.format(Number(trade.pnl_usd))} on ${shortDate(trade.closed_at)}`
    : `open ${directionName(trade)} · risk ${usd.format(trade.risk_usd)} from ${shortDate(trade.opened_at)}`;
  return `Delete ${what} (${ACCOUNT_NAMES[trade.account]})?\n\n` +
    "Its screenshots are deleted too. This can't be undone.";
}

el('delete-button').addEventListener('click', async () => {
  const trade = detailTrade;
  if (!trade || !window.confirm(deleteQuestion(trade))) return;

  const button = el('delete-button');
  button.disabled = true;
  showDetailMessage('Deleting…');
  // The database sends back the deleted row, so we know exactly which screenshots it had.
  const { data, error } = await db
    .from('trades')
    .delete()
    .eq('id', trade.id)
    .select('open_screenshot_path, close_screenshot_path');
  button.disabled = false;
  if (error) return showDetailMessage('Could not delete: ' + error.message, true);
  if (data.length === 0) {
    return showDetailMessage('Nothing was deleted. It may already be gone (deleted on your other device). ' +
      'Tap Back and refresh.', true);
  }

  if (tradeBeingClosed && tradeBeingClosed.id === trade.id) hideCloseForm();
  hideDetail();
  loadLists();

  // Then the screenshots. Storage reports each file it removed, so a missing one shows here.
  const paths = [data[0].open_screenshot_path, data[0].close_screenshot_path].filter(Boolean);
  if (paths.length > 0) {
    const { data: removed, error: removeError } = await db.storage.from(SCREENSHOT_BUCKET).remove(paths);
    if (removeError || removed.length < paths.length) {
      return showMessage('The trade was deleted, but its screenshots could not all be removed from storage' +
        (removeError ? ': ' + removeError.message : '.'), true);
    }
  }
  showMessage('Trade deleted' + (paths.length > 0 ? ', with its screenshots.' : '.'));
});

// ---- Tabs: underline the part of the page you're looking at ----
const tabLinks = document.querySelectorAll('#tabs a');

function markTab(sectionId) {
  for (const link of tabLinks) link.classList.toggle('active', link.getAttribute('href') === `#${sectionId}`);
}

// Whichever section crosses a line about a third of the way down the screen counts as "here".
const tabWatcher = new IntersectionObserver((entries) => {
  for (const entry of entries) if (entry.isIntersecting) markTab(entry.target.id);
}, { rootMargin: '-30% 0px -65% 0px' });

for (const link of tabLinks) {
  tabWatcher.observe(el(link.getAttribute('href').slice(1)));
  link.addEventListener('click', () => markTab(link.getAttribute('href').slice(1)));
}
