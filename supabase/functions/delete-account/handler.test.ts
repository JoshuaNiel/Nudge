// Unit tests for the delete-account request handler (no network, no Supabase).
// Run: deno test supabase/functions/delete-account/handler.test.ts

import { assertEquals } from 'jsr:@std/assert@1';
import { DeleteAccountDeps, handleDeleteAccount } from './handler.ts';

const USER_ID = '11111111-1111-1111-1111-111111111111';

function fakeDeps(overrides: Partial<DeleteAccountDeps> = {}) {
  const calls = { getUserId: [] as string[], deleteUser: [] as string[], errors: [] as string[] };
  const deps: DeleteAccountDeps = {
    getUserId: async (jwt) => {
      calls.getUserId.push(jwt);
      return jwt === 'valid' ? USER_ID : null;
    },
    deleteUser: async (id) => {
      calls.deleteUser.push(id);
    },
    logError: (m) => calls.errors.push(m),
    logInfo: () => {},
    ...overrides,
  };
  return { deps, calls };
}

function post(headers: Record<string, string> = {}, body?: string) {
  return new Request('https://x.test/delete-account', { method: 'POST', headers, body });
}

Deno.test('rejects non-POST with 405', async () => {
  const { deps, calls } = fakeDeps();
  for (const method of ['GET', 'PUT', 'DELETE', 'OPTIONS']) {
    const res = await handleDeleteAccount(new Request('https://x.test', { method }), deps);
    assertEquals(res.status, 405);
    assertEquals(res.headers.get('Allow'), 'POST');
  }
  assertEquals(calls.deleteUser.length, 0);
});

Deno.test('missing Authorization → 401, nothing deleted', async () => {
  const { deps, calls } = fakeDeps();
  const res = await handleDeleteAccount(post(), deps);
  assertEquals(res.status, 401);
  assertEquals(calls.getUserId.length, 0);
  assertEquals(calls.deleteUser.length, 0);
});

Deno.test('non-Bearer Authorization → 401', async () => {
  const { deps, calls } = fakeDeps();
  const res = await handleDeleteAccount(post({ Authorization: 'Basic abc' }), deps);
  assertEquals(res.status, 401);
  assertEquals(calls.deleteUser.length, 0);
});

Deno.test('invalid JWT → 401, nothing deleted', async () => {
  const { deps, calls } = fakeDeps();
  const res = await handleDeleteAccount(post({ Authorization: 'Bearer forged' }), deps);
  assertEquals(res.status, 401);
  assertEquals(calls.deleteUser.length, 0);
});

Deno.test('getUser throwing → 401', async () => {
  const { deps, calls } = fakeDeps({
    getUserId: () => Promise.reject(new Error('auth down')),
  });
  const res = await handleDeleteAccount(post({ Authorization: 'Bearer valid' }), deps);
  assertEquals(res.status, 401);
  assertEquals(calls.deleteUser.length, 0);
});

Deno.test('valid JWT → deletes only the caller, 204, empty body', async () => {
  const { deps, calls } = fakeDeps();
  const res = await handleDeleteAccount(post({ Authorization: 'Bearer valid' }), deps);
  assertEquals(res.status, 204);
  assertEquals(await res.text(), '');
  assertEquals(calls.deleteUser, [USER_ID]);
});

Deno.test('body naming another user is ignored', async () => {
  const { deps, calls } = fakeDeps();
  const res = await handleDeleteAccount(
    post(
      { Authorization: 'Bearer valid', 'Content-Type': 'application/json' },
      JSON.stringify({ user_id: '22222222-2222-2222-2222-222222222222' })
    ),
    deps
  );
  assertEquals(res.status, 204);
  assertEquals(calls.deleteUser, [USER_ID]);
});

Deno.test('deleteUser failure → 500 with generic message, details only in logs', async () => {
  const { deps, calls } = fakeDeps({
    deleteUser: () => Promise.reject(new Error('fk violation on secret_table')),
  });
  const res = await handleDeleteAccount(post({ Authorization: 'Bearer valid' }), deps);
  assertEquals(res.status, 500);
  assertEquals(await res.json(), { error: 'Account deletion failed' });
  assertEquals(calls.errors.length, 1);
});
