// Unit tests for the delete-account request handler (no network, no Supabase).
// Run: deno test supabase/functions/delete-account/handler.test.ts

import { assertEquals } from 'jsr:@std/assert@1';
import {
  checkRecentPasswordSignIn,
  decodeJwtPayload,
  DeleteAccountDeps,
  handleDeleteAccount,
} from './handler.ts';

const USER_ID = '11111111-1111-1111-1111-111111111111';

/** Fixed "now" for every test: 2026-11-23T12:00:00Z. */
const NOW_SECONDS = 1_795_435_200;
const NOW_MS = NOW_SECONDS * 1000;

/** Claims of a token minted by a password sign-in `secondsAgo` seconds before NOW. */
function passwordClaims(secondsAgo = 10): Record<string, unknown> {
  return {
    sub: USER_ID,
    amr: [{ method: 'password', timestamp: NOW_SECONDS - secondsAgo }],
  };
}

function fakeDeps(
  overrides: Partial<DeleteAccountDeps> = {},
  claims: Record<string, unknown> | null = passwordClaims()
) {
  const calls = {
    getUserId: [] as string[],
    decodeClaims: [] as string[],
    deleteUser: [] as string[],
    errors: [] as string[],
    infos: [] as string[],
  };
  const deps: DeleteAccountDeps = {
    getUserId: async (jwt) => {
      calls.getUserId.push(jwt);
      return jwt === 'valid' ? USER_ID : null;
    },
    decodeClaims: (jwt) => {
      calls.decodeClaims.push(jwt);
      return claims;
    },
    now: () => NOW_MS,
    deleteUser: async (id) => {
      calls.deleteUser.push(id);
    },
    logError: (m) => calls.errors.push(m),
    logInfo: (m) => calls.infos.push(m),
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

// --- Recent password sign-in (amr) — spec section C, layer 2 ---

async function deleteWithClaims(claims: Record<string, unknown> | null) {
  const { deps, calls } = fakeDeps({}, claims);
  const res = await handleDeleteAccount(post({ Authorization: 'Bearer valid' }), deps);
  return { res, calls };
}

async function assertReauthRequired(claims: Record<string, unknown> | null, reason: string) {
  const { res, calls } = await deleteWithClaims(claims);
  assertEquals(res.status, 403);
  assertEquals(res.headers.get('Content-Type'), 'application/json');
  assertEquals(await res.json(), { error: 'reauth_required' });
  assertEquals(calls.deleteUser.length, 0);
  // The reason is logged (not returned to the client).
  assertEquals(calls.infos.length, 1);
  assertEquals(calls.infos[0].includes(reason), true, calls.infos[0]);
}

Deno.test('recent password amr → 204, deletes the caller', async () => {
  const { res, calls } = await deleteWithClaims(passwordClaims(10));
  assertEquals(res.status, 204);
  assertEquals(calls.deleteUser, [USER_ID]);
});

Deno.test('password amr exactly 300 s old → still accepted', async () => {
  const { res, calls } = await deleteWithClaims(passwordClaims(300));
  assertEquals(res.status, 204);
  assertEquals(calls.deleteUser, [USER_ID]);
});

Deno.test('old password amr (301 s) → 403 reauth_required, nothing deleted', async () => {
  await assertReauthRequired(passwordClaims(301), 'too old');
});

Deno.test('very old password amr (a day) → 403 reauth_required', async () => {
  await assertReauthRequired(passwordClaims(86_400), 'too old');
});

Deno.test('missing amr → 403 reauth_required', async () => {
  await assertReauthRequired({ sub: USER_ID }, 'missing amr');
});

Deno.test('empty amr array → 403 reauth_required', async () => {
  await assertReauthRequired({ sub: USER_ID, amr: [] }, 'missing amr');
});

Deno.test('non-array amr → 403 reauth_required', async () => {
  await assertReauthRequired({ sub: USER_ID, amr: 'password' }, 'missing amr');
});

Deno.test('undecodable claims (null) → 403 reauth_required', async () => {
  await assertReauthRequired(null, 'missing amr');
});

Deno.test('decodeClaims throwing → 403 reauth_required, nothing deleted', async () => {
  const { deps, calls } = fakeDeps({
    decodeClaims: () => {
      throw new Error('bad token');
    },
  });
  const res = await handleDeleteAccount(post({ Authorization: 'Bearer valid' }), deps);
  assertEquals(res.status, 403);
  assertEquals(await res.json(), { error: 'reauth_required' });
  assertEquals(calls.deleteUser.length, 0);
});

Deno.test('only non-password amr methods (recent) → 403 reauth_required', async () => {
  await assertReauthRequired(
    {
      sub: USER_ID,
      amr: [
        { method: 'otp', timestamp: NOW_SECONDS - 5 },
        { method: 'oauth', timestamp: NOW_SECONDS - 5 },
        { method: 'token_refresh', timestamp: NOW_SECONDS - 5 },
      ],
    },
    'no password entry'
  );
});

Deno.test('password entry with a non-numeric timestamp → 403 reauth_required', async () => {
  await assertReauthRequired(
    { sub: USER_ID, amr: [{ method: 'password', timestamp: String(NOW_SECONDS) }] },
    'no password entry'
  );
});

Deno.test('recent password entry among other methods → 204', async () => {
  const { res, calls } = await deleteWithClaims({
    sub: USER_ID,
    amr: [
      { method: 'otp', timestamp: NOW_SECONDS - 10_000 },
      { method: 'password', timestamp: NOW_SECONDS - 30 },
    ],
  });
  assertEquals(res.status, 204);
  assertEquals(calls.deleteUser, [USER_ID]);
});

Deno.test('future password timestamp within 60 s skew → OK', async () => {
  const { res, calls } = await deleteWithClaims(passwordClaims(-60));
  assertEquals(res.status, 204);
  assertEquals(calls.deleteUser, [USER_ID]);
});

Deno.test('future password timestamp beyond skew (61 s) → 403 reauth_required', async () => {
  await assertReauthRequired(passwordClaims(-61), 'clock skew');
});

Deno.test('amr is checked only after the JWT is validated', async () => {
  const { deps, calls } = fakeDeps();
  const res = await handleDeleteAccount(post({ Authorization: 'Bearer forged' }), deps);
  assertEquals(res.status, 401);
  assertEquals(calls.decodeClaims.length, 0);
  assertEquals(calls.deleteUser.length, 0);
});

Deno.test('claims are decoded from the same bearer token that was validated', async () => {
  const { deps, calls } = fakeDeps();
  await handleDeleteAccount(post({ Authorization: 'Bearer valid' }), deps);
  assertEquals(calls.getUserId, ['valid']);
  assertEquals(calls.decodeClaims, ['valid']);
});

Deno.test('checkRecentPasswordSignIn returns null for a recent password sign-in', () => {
  assertEquals(checkRecentPasswordSignIn(passwordClaims(0), NOW_MS), null);
});

// --- decodeJwtPayload ---

function base64url(json: unknown): string {
  const bytes = new TextEncoder().encode(JSON.stringify(json));
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

Deno.test('decodeJwtPayload reads a base64url payload (incl. non-ASCII)', () => {
  const payload = { sub: USER_ID, name: 'Zoë ~~~?', amr: [{ method: 'password', timestamp: 1 }] };
  const jwt = `${base64url({ alg: 'ES256' })}.${base64url(payload)}.sig`;
  assertEquals(decodeJwtPayload(jwt), payload);
});

Deno.test('decodeJwtPayload returns null for malformed tokens', () => {
  assertEquals(decodeJwtPayload('valid'), null);
  assertEquals(decodeJwtPayload('a.b'), null);
  assertEquals(decodeJwtPayload('a.!!!.c'), null);
  assertEquals(decodeJwtPayload(`a.${base64url([1, 2])}.c`), null);
  assertEquals(decodeJwtPayload(`a.${base64url('str')}.c`), null);
});
