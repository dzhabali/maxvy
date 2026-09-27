/* life-store.js — замена Firebase для Ваджра-трекера: те же вызовы (firebase.auth / firestore compat),
 * но данные на своём сервере life.maxdzhabali.com/vajra/api (personal_apps.py). Вход — общий с Life (cookie).
 *
 * Что поддержано (ровно то, что использует vajra-tracker.html):
 *   firebase.initializeApp · firebase.auth(): onAuthStateChanged, signOut (+ заглушки входа/регистрации)
 *   firebase.firestore(): enablePersistence · collection('users').doc(uid).collection('days')
 *     .doc(d): get(), set({slots}, {merge}), onSnapshot(cb) — опрос раз в 20 с + при возврате в приложение/сеть
 *     .get() — все дни;  .where(documentId,'>=',a).where(documentId,'<',b).get() — диапазон
 *   firebase.firestore.FieldValue.serverTimestamp() · FieldPath.documentId()
 * Слияние по слотам делает сервер (то же mergeSlots) — клики с разных устройств не теряются.
 * Без сети: снимок приходит «из кэша» (пустой, hasPendingWrites) — приложение работает на своём
 * localStorage-зеркале, а при возврате сети следующий опрос сольёт и допишет на сервер.
 */
(function () {
  const API = '/vajra/api/';
  const USER_KEY = 'life_user';
  const LOGIN = '/chronicle/login?next=/vajra/';

  async function call(method, path, body) {
    const r = await fetch(API + path, {
      method, credentials: 'same-origin', cache: 'no-store',
      headers: body ? { 'Content-Type': 'application/json' } : {},
      body: body ? JSON.stringify(body) : undefined,
    });
    if (r.status === 401) { location.href = LOGIN; throw new Error('нужен вход'); }
    if (!r.ok) throw new Error('сервер: ' + r.status);
    return r.json();
  }
  const ts = iso => iso ? { toDate: () => new Date(iso) } : null;
  const docSnap = (id, rec, meta) => ({
    id, exists: !!(rec && rec.exists !== false), metadata: Object.assign({ hasPendingWrites: false, fromCache: false }, meta || {}),
    data: () => rec ? { slots: rec.slots || [], updatedAt: ts(rec.updatedAt) } : undefined,
  });
  const querySnap = obj => {
    const docs = Object.keys(obj).sort().map(k => docSnap(k, Object.assign({ exists: true }, obj[k])));
    return { docs, size: docs.length, empty: !docs.length, forEach: fn => docs.forEach(fn) };
  };

  function dayRef(d) {
    return {
      id: d,
      get: async () => docSnap(d, await call('GET', 'days/' + d)),
      set: async data => { await call('PUT', 'days/' + d, { slots: data.slots || [] }); },
      onSnapshot(cb, onErr) {
        let alive = true, busy = false;
        const tick = async () => {
          if (!alive || busy) return;
          busy = true;
          try { const rec = await call('GET', 'days/' + d); if (alive) await cb(docSnap(d, rec)); }
          catch (e) { if (alive) await cb(docSnap(d, null, { hasPendingWrites: true, fromCache: true })); }
          finally { busy = false; }
        };
        tick();
        const iv = setInterval(() => { if (document.visibilityState === 'visible') tick(); }, 20000);
        const vis = () => { if (document.visibilityState === 'visible') tick(); };
        document.addEventListener('visibilitychange', vis);
        addEventListener('online', tick);
        return () => { alive = false; clearInterval(iv); document.removeEventListener('visibilitychange', vis); removeEventListener('online', tick); };
      },
    };
  }

  function daysCollection(where) {
    return {
      doc: dayRef,
      where(field, op, val) {
        const w = Object.assign({}, where);
        if (op === '>=') w.from = val; else if (op === '<') w.to = val;
        return daysCollection(w);
      },
      get: async () => {
        const q = new URLSearchParams();
        if (where && where.from) q.set('from', where.from);
        if (where && where.to) q.set('to', where.to);
        return querySnap(await call('GET', 'days' + (q.toString() ? '?' + q : '')));
      },
    };
  }

  const db = {
    enablePersistence: () => Promise.resolve(),
    collection: () => ({ doc: () => ({ collection: () => daysCollection({}) }) }),
  };

  let user = null;
  try { user = JSON.parse(localStorage.getItem(USER_KEY) || 'null'); } catch (e) { user = null; }
  const listeners = [];
  const auth = {
    get currentUser() { return user; },
    onAuthStateChanged(cb) {
      listeners.push(cb);
      if (user) setTimeout(() => cb(user), 0);                 // без сети — работаем под последним входом
      call('GET', 'me').then(u => {
        const was = user && user.uid;
        user = u;
        try { localStorage.setItem(USER_KEY, JSON.stringify(u)); } catch (e) {}
        if (was !== u.uid) listeners.forEach(f => f(user));
      }).catch(() => {});
      return () => {};
    },
    signOut: async () => { try { localStorage.removeItem(USER_KEY); } catch (e) {} location.href = LOGIN; },
    signInWithEmailAndPassword: async () => { location.href = LOGIN; },
    createUserWithEmailAndPassword: async () => { throw new Error('Вход — общий с Life'); },
    sendPasswordResetEmail: async () => { throw new Error('Пароль — от Life'); },
  };

  const firestore = () => db;
  firestore.FieldValue = { serverTimestamp: () => null };
  firestore.FieldPath = { documentId: () => '__name__' };
  window.firebase = { initializeApp: () => ({}), auth: () => auth, firestore };
})();
