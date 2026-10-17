// Gold Trade Logger.
// Signs in with email and password, opens trades and lists the open ones.
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
  if (userId) {
    el('user-email').textContent = session.user.email;
    openForm.reset();
    setOpenedAtToNow();
    selectLastUsedAccount();
    loadOpenTrades();
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

// ---- Open a trade ----
const openedAtInput = el('opened-at');

// "Opened at" defaults to now. Once you change it by hand (e.g. a backtest date), it's left alone.
function setOpenedAtToNow() {
  openedAtInput.value = toLocalInputValue(new Date());
  delete openedAtInput.dataset.edited;
}
openedAtInput.addEventListener('input', () => { openedAtInput.dataset.edited = 'yes'; });

// When you come back to the app (e.g. switch back to it on the phone), keep "now" current
// and fetch any trades opened on the other device.
document.addEventListener('visibilitychange', () => {
  if (document.hidden || signedInSection.hidden) return;
  if (!openedAtInput.dataset.edited) setOpenedAtToNow();
  loadOpenTrades();
});

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
  setOpenedAtToNow();
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
  loadOpenTrades();
});

// ---- Open trades list ----
function followedRules(trade) {
  return trade.check_h1_bias && trade.check_m15_flip && trade.check_adx && trade.check_stop;
}

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
    headline.textContent = `${trade.direction === 'buy' ? 'Buy' : 'Sell'} · risk ${usd.format(trade.risk_usd)}`;

    const details = document.createElement('small');
    const parts = [ACCOUNT_NAMES[trade.account], formatWhen(trade.opened_at)];
    if (trade.adx !== null) parts.push(`ADX ${trade.adx}`);
    details.textContent = parts.join(' · ');

    const rules = document.createElement('span');
    rules.className = followedRules(trade) ? 'rules ok' : 'rules broken';
    rules.textContent = followedRules(trade) ? 'Rules followed' : 'Rule break';

    item.append(headline, ' ', rules, document.createElement('br'), details);
    openTradesList.appendChild(item);
  }
}

el('refresh-button').addEventListener('click', () => {
  showMessage('');
  loadOpenTrades();
});
