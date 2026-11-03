const { test, before, after, beforeEach } = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const {
  initializeTestEnvironment, assertSucceeds, assertFails,
} = require('@firebase/rules-unit-testing');
const { doc, setDoc, serverTimestamp } = require('firebase/firestore');

// users/{uid}/app_commands security rules (§5.6 / §11.2b). The backend owns
// `pending` and `tour_state` via the Admin SDK (rules bypassed); the client is
// allowed to write ONLY the `ack` doc (nav/command acks) and the `tour_event`
// doc (the Ayma-driven tour's tap signal). Regression for the founder/Scout bug
// (2026-11-03): the tour tap write to `tour_event` was denied by rules and
// silently swallowed, so `advance_guided_tour` hung ~110s then errored.
let env;

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-ayma',
    firestore: {
      rules: fs.readFileSync(path.join(__dirname, '../../firestore.rules'), 'utf8'),
    },
  });
});
after(() => env.cleanup());
beforeEach(() => env.clearFirestore());

const cmd = (uid, id) =>
  doc(env.authenticatedContext(uid).firestore(), `users/${uid}/app_commands/${id}`);

test('owner may write the ack doc', async () => {
  await assertSucceeds(
    setDoc(cmd('u1', 'ack'), { id: 'x', ok: true, ts: serverTimestamp() }));
});

test('owner may write the tour_event doc (the tour tap signal)', async () => {
  await assertSucceeds(
    setDoc(cmd('u1', 'tour_event'), { index: 1, event: 'tapped', ts: serverTimestamp() }));
});

test('owner may write a tour_event stop', async () => {
  await assertSucceeds(
    setDoc(cmd('u1', 'tour_event'), { index: 2, event: 'stop', ts: serverTimestamp() }));
});

test('owner still cannot write the backend-only pending doc', async () => {
  await assertFails(
    setDoc(cmd('u1', 'pending'), { action: 'navigate', id: 'x' }));
});

test('owner still cannot write the backend-only tour_state doc', async () => {
  await assertFails(
    setDoc(cmd('u1', 'tour_state'), { index: 1, active: true }));
});

test('another user cannot write my tour_event', async () => {
  const other = doc(
    env.authenticatedContext('u2').firestore(), 'users/u1/app_commands/tour_event');
  await assertFails(setDoc(other, { index: 1, event: 'tapped' }));
});
