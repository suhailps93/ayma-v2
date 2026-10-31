const { test, before, after, beforeEach } = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const {
  initializeTestEnvironment, assertSucceeds, assertFails,
} = require('@firebase/rules-unit-testing');
const { Timestamp, doc, setDoc, updateDoc, serverTimestamp } = require('firebase/firestore');

let env;
const ADULT = Timestamp.fromDate(new Date('1990-05-05T12:00:00Z'));
const MINOR = Timestamp.fromDate(new Date(Date.now() - 10 * 365.25 * 864e5));

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-ayma',
    firestore: { rules: fs.readFileSync(path.join(__dirname, '../../firestore.rules'), 'utf8') },
  });
});
after(() => env.cleanup());
beforeEach(() => env.clearFirestore());

const seed = (data) => env.withSecurityRulesDisabled((c) =>
  setDoc(doc(c.firestore(), 'users/u1/profile/main'), data));
const mine = () => doc(env.authenticatedContext('u1').firestore(), 'users/u1/profile/main');
const toggle = { ai_avatar_enabled: false, updated_at: serverTimestamp() };

test('AI Avatar toggle succeeds with an adult birthdate', async () => {
  await seed({ birthdate: ADULT, ai_avatar_enabled: true });
  await assertSucceeds(updateDoc(mine(), toggle));
});

test('AI Avatar toggle succeeds with no birthdate', async () => {
  await seed({ name: 'x', ai_avatar_enabled: true });
  await assertSucceeds(updateDoc(mine(), toggle));
});

test('AI Avatar toggle succeeds when the stored birthdate is not a timestamp', async () => {
  await seed({ birthdate: '1990-05-05', ai_avatar_enabled: true });
  await assertSucceeds(updateDoc(mine(), toggle));
});

test('accent colour write succeeds', async () => {
  await seed({ birthdate: ADULT });
  await assertSucceeds(updateDoc(mine(), { ayma_accent_color: '#112233', updated_at: serverTimestamp() }));
});

test('setting an under-18 birthdate is still denied', async () => {
  await seed({ birthdate: ADULT });
  await assertFails(updateDoc(mine(), { birthdate: MINOR, updated_at: serverTimestamp() }));
});

test('adding an under-18 birthdate to a doc without one is denied', async () => {
  await seed({ name: 'x' });
  await assertFails(updateDoc(mine(), { birthdate: MINOR }));
});

test('creating a profile with an under-18 birthdate is denied', async () => {
  await assertFails(setDoc(mine(), { birthdate: MINOR }));
});

test('backend-only fields stay unwritable', async () => {
  await seed({ birthdate: ADULT });
  await assertFails(updateDoc(mine(), { photos: ['x'] }));
});

test('other users cannot write', async () => {
  await seed({ birthdate: ADULT });
  const other = doc(env.authenticatedContext('u2').firestore(), 'users/u1/profile/main');
  await assertFails(updateDoc(other, toggle));
});
