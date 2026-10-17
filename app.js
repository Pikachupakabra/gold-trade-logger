// Gold Trade Logger.
// Signs in with email and password, opens and closes trades, and lists open and closed ones.
// All data lives in Supabase, so the phone and laptop see the same trades.

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

function showMessage(text, isError = false) {
  messageBox.textContent = text;
  messageBox.classList.toggle('error', isError);
  messageBox.hidden = !text;
}

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
  openTradesList.innerHTML = '';
  historyList.innerHTML = '';
  hideCloseForm();
  if (userId) {
    el('user-email').textContent = session.user.email;
    openForm.reset();
    setToNow(openedAtInput);
    selectLastUsedAccount();
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
  if (!closeSection.hidden && !closedAtInput.dataset.edited) setToNow(closedAtInput);
  loadLists();
});

function loadLists() {
  loadOpenTrades();
  loadHistory();
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
    check_stop: el('check-stop').checked,
  };

  // Turn the button off while saving so a double tap can't log the trade twice.
  const button = el('open-button');
  button.disabled = true;
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
function followedRules(trade) {
  return trade.check_h1_bias && trade.check_m15_flip && trade.check_adx && trade.check_stop;
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

// ---- Open trades list ----

async function loadOpenTrades() {
  const { data, error } = await db
    .from('trades')
    .select('id, account, opened_at, direction, risk_usd, adx, check_h1_bias, check_m15_flip, check_adx, check_stop')
    .is('closed_at', null)
    .order('opened_at', { ascending: false });
  if (error) return showMessage('Could not load trades: ' + error.message, true);

  openTradesList.innerHTML = '';
  if (data.length === 0) {
    openTradesList.innerHTML = '<li class="empty">No open trades.</li>';
    return;
  }
  for (const trade of data) {
    const item = document.createElement('li');

    const headline = document.createElement('strong');
    headline.textContent = `${directionName(trade)} · risk ${usd.format(trade.risk_usd)}`;

    const details = document.createElement('small');
    const parts = [ACCOUNT_NAMES[trade.account], formatWhen(trade.opened_at)];
    if (trade.adx !== null) parts.push(`ADX ${trade.adx}`);
    details.textContent = parts.join(' · ');

    const closeButton = document.createElement('button');
    closeButton.type = 'button';
    closeButton.className = 'small';
    closeButton.textContent = 'Close trade';
    closeButton.addEventListener('click', () => showCloseForm(trade));

    item.append(headline, ' ', rulesBadge(trade), document.createElement('br'), details,
      document.createElement('br'), closeButton);
    openTradesList.appendChild(item);
  }
}

el('refresh-button').addEventListener('click', () => {
  showMessage('');
  loadLists();
});

// ---- Close a trade ----
// The trade the close form is filled in for, or null when the form is hidden.
let tradeBeingClosed = null;

function showCloseForm(trade) {
  tradeBeingClosed = trade;
  closeForm.reset();
  setToNow(closedAtInput);
  el('close-summary').textContent = `${directionName(trade)} · risk ${usd.format(trade.risk_usd)} · ` +
    `${ACCOUNT_NAMES[trade.account]} · opened ${formatWhen(trade.opened_at)}`;
  closeSection.hidden = false;
  closeSection.scrollIntoView({ behavior: 'smooth', block: 'start' });
  fillLastRate(trade.account);
}

function hideCloseForm() {
  tradeBeingClosed = null;
  closeSection.hidden = true;
}

el('cancel-close-button').addEventListener('click', hideCloseForm);

// The rate box starts with the rate from this account's latest closed trade (by close date),
// so a backtest trade gets a rate from around its own historic date.
async function fillLastRate(account) {
  const rateInput = el('usdzar-rate');
  const { data, error } = await db
    .from('trades')
    .select('usdzar_rate')
    .eq('account', account)
    .not('closed_at', 'is', null)
    .order('closed_at', { ascending: false })
    .limit(1);
  // If you already typed a rate while this was loading, keep yours.
  if (!error && data.length > 0 && rateInput.value === '') rateInput.value = data[0].usdzar_rate;
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
async function loadHistory() {
  const { data, error } = await db
    .from('trades')
    .select('id, account, direction, risk_usd, check_h1_bias, check_m15_flip, check_adx, check_stop, ' +
      'closed_at, pnl_usd, usdzar_rate, mistake_tag, lesson')
    .not('closed_at', 'is', null)
    .order('closed_at', { ascending: false });
  if (error) return showMessage('Could not load history: ' + error.message, true);

  historyList.innerHTML = '';
  if (data.length === 0) {
    historyList.innerHTML = '<li class="empty">No closed trades yet.</li>';
    return;
  }
  for (const trade of data) {
    const pnlUsd = Number(trade.pnl_usd);
    const rate = Number(trade.usdzar_rate);
    // Worked out here, never typed in (see "Calculated, not typed" in the spec).
    const pnlZar = pnlUsd * rate;
    const timesRisk = pnlUsd / Number(trade.risk_usd);

    const item = document.createElement('li');

    const headline = document.createElement('strong');
    headline.className = pnlUsd > 0 ? 'win' : pnlUsd < 0 ? 'loss' : '';
    headline.textContent = `${directionName(trade)} · ${signedUsd.format(pnlUsd)} · ${signedZar(pnlZar)}`;

    const result = document.createElement('span');
    result.textContent = `${formatTimesRisk(timesRisk)} · risk ${usd.format(trade.risk_usd)} · USD/ZAR ${rate}`;

    const details = document.createElement('small');
    details.textContent = `${ACCOUNT_NAMES[trade.account]} · closed ${formatWhen(trade.closed_at)}`;

    item.append(headline, ' ', rulesBadge(trade), document.createElement('br'), result,
      document.createElement('br'), details);

    if (trade.mistake_tag || trade.lesson) {
      const notes = document.createElement('small');
      notes.textContent = [trade.mistake_tag && `Mistake: ${trade.mistake_tag}`, trade.lesson]
        .filter(Boolean).join(' · ');
      item.append(document.createElement('br'), notes);
    }
    historyList.appendChild(item);
  }
}
