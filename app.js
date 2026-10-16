// Gold Trade Logger: Task 1 (sync test).
// Signs in with email and password, saves short test notes to Supabase,
// and lists the signed-in user's notes.

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
const notesList = el('notes-list');

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
function render(session) {
  const signedIn = Boolean(session);
  signedOutSection.hidden = signedIn;
  signedInSection.hidden = !signedIn;
  notesList.innerHTML = '';
  if (signedIn) {
    el('user-email').textContent = session.user.email;
    loadNotes();
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

// ---- Notes ----
async function loadNotes() {
  const { data, error } = await db
    .from('notes')
    .select('id, body, created_at')
    .order('created_at', { ascending: false });
  if (error) return showMessage('Could not load notes: ' + error.message, true);

  notesList.innerHTML = '';
  if (data.length === 0) {
    notesList.innerHTML = '<li class="empty">No notes yet.</li>';
    return;
  }
  for (const note of data) {
    const item = document.createElement('li');
    const when = document.createElement('small');
    when.textContent = new Date(note.created_at).toLocaleString();
    item.textContent = note.body + ' ';
    item.appendChild(when);
    notesList.appendChild(item);
  }
}

el('note-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const input = el('note-text');
  const body = input.value.trim();
  if (!body) return;
  // user_id is filled in by the database from whoever is signed in.
  const { error } = await db.from('notes').insert({ body });
  if (error) return showMessage('Could not save: ' + error.message, true);
  input.value = '';
  showMessage('Saved.');
  loadNotes();
});

el('refresh-button').addEventListener('click', () => {
  showMessage('');
  loadNotes();
});
