// Request handling for delete-account, kept free of Supabase/Deno globals so it can be
// unit-tested with fake dependencies (see index.ts for the real wiring).
//
// Security contract (docs/specs/account-deletion.md, sections B + C):
// - POST only.
// - The caller is identified ONLY by their own JWT (validated against the Auth server).
// - The JWT must record a RECENT password sign-in: its `amr` claim needs an entry
//   `{ method: "password", timestamp }` no older than REAUTH_MAX_AGE_SECONDS (and no more
//   than REAUTH_FUTURE_SKEW_SECONDS in the future). Otherwise 403 `reauth_required` and
//   nothing is deleted. The app re-authenticates with the password right before calling,
//   so a stolen-but-valid older token (or a refresh-only session) cannot delete the account.
// - The request body and query string are never read: a caller can delete exactly one
//   account — their own — and there is no parameter that could name anyone else.
// - Failures return a generic message; details go to the function logs only.

export interface DeleteAccountDeps {
  /** Validates the bearer JWT with the Auth server. Returns the user id, or null if invalid. */
  getUserId(jwt: string): Promise<string | null>;
  /**
   * Returns the payload claims of a JWT that `getUserId` has ALREADY validated, or null if it
   * can't be decoded. Called only after validation, so it need not verify the signature
   * (production uses `decodeJwtPayload`).
   */
  decodeClaims(jwt: string): Record<string, unknown> | null;
  /** Current time in Unix milliseconds (production: `Date.now`). */
  now(): number;
  /** Hard-deletes the auth user (all public.* rows cascade from auth.users). Throws on failure. */
  deleteUser(userId: string): Promise<void>;
  /** Logging sink; defaults to console in production. */
  logError(message: string, detail?: unknown): void;
  logInfo(message: string): void;
}

/** A password sign-in older than this (seconds) requires re-authentication. */
export const REAUTH_MAX_AGE_SECONDS = 300;
/** Tolerated clock skew (seconds) for an `amr` timestamp slightly in the future. */
export const REAUTH_FUTURE_SKEW_SECONDS = 60;

const BEARER = /^Bearer\s+(\S+)$/i;

export async function handleDeleteAccount(
  req: Request,
  deps: DeleteAccountDeps
): Promise<Response> {
  if (req.method !== 'POST') {
    return jsonError('Method not allowed', 405, { Allow: 'POST' });
  }

  const match = BEARER.exec(req.headers.get('Authorization') ?? '');
  if (!match) {
    return jsonError('Unauthorized', 401);
  }
  const jwt = match[1];

  let userId: string | null;
  try {
    userId = await deps.getUserId(jwt);
  } catch (err) {
    deps.logError('[delete-account] getUser threw', err);
    userId = null;
  }
  if (!userId) {
    return jsonError('Unauthorized', 401);
  }

  // The token is authentic (getUser above); now require that it records a recent password
  // sign-in. Fail closed: any decoding problem counts as "no recent sign-in".
  let claims: Record<string, unknown> | null;
  try {
    claims = deps.decodeClaims(jwt);
  } catch {
    claims = null;
  }
  const reauthFailure = checkRecentPasswordSignIn(claims, deps.now());
  if (reauthFailure) {
    deps.logInfo(`[delete-account] reauth required for user ${userId}: ${reauthFailure}`);
    return jsonError('reauth_required', 403);
  }

  try {
    await deps.deleteUser(userId);
  } catch (err) {
    deps.logError(`[delete-account] deleteUser failed for user ${userId}`, err);
    return jsonError('Account deletion failed', 500);
  }

  deps.logInfo(`[delete-account] deleted user ${userId}`);
  return new Response(null, { status: 204 });
}

/**
 * Returns null when `claims.amr` contains a password sign-in within
 * [now - REAUTH_MAX_AGE_SECONDS, now + REAUTH_FUTURE_SKEW_SECONDS], otherwise a short
 * reason for the logs. `amr` is Supabase's array of `{ method, timestamp }` (Unix seconds).
 */
export function checkRecentPasswordSignIn(
  claims: Record<string, unknown> | null,
  nowMs: number
): string | null {
  const amr = claims?.amr;
  if (!Array.isArray(amr) || amr.length === 0) {
    return 'missing amr claim';
  }

  const passwordTimestamps = amr
    .filter(
      (entry): entry is { method: unknown; timestamp: unknown } =>
        typeof entry === 'object' && entry !== null && (entry as { method?: unknown }).method === 'password'
    )
    .map((entry) => entry.timestamp)
    .filter((ts): ts is number => typeof ts === 'number' && Number.isFinite(ts));
  if (passwordTimestamps.length === 0) {
    return 'no password entry with a numeric timestamp in amr';
  }

  const nowSeconds = nowMs / 1000;
  const isRecent = passwordTimestamps.some(
    (ts) =>
      ts >= nowSeconds - REAUTH_MAX_AGE_SECONDS && ts <= nowSeconds + REAUTH_FUTURE_SKEW_SECONDS
  );
  if (isRecent) return null;

  const newest = Math.max(...passwordTimestamps);
  return newest > nowSeconds
    ? `password sign-in timestamp ${newest} is beyond the allowed clock skew`
    : `password sign-in too old (${Math.round(nowSeconds - newest)} s ago)`;
}

/**
 * Decodes a JWT's payload WITHOUT verifying its signature. Use only on a token that has
 * already been validated (here: by `auth.getUser(jwt)`). Returns null if malformed.
 */
export function decodeJwtPayload(jwt: string): Record<string, unknown> | null {
  const parts = jwt.split('.');
  if (parts.length !== 3) return null;
  try {
    const base64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
    const bytes = Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
    const payload: unknown = JSON.parse(new TextDecoder().decode(bytes));
    if (typeof payload !== 'object' || payload === null || Array.isArray(payload)) return null;
    return payload as Record<string, unknown>;
  } catch {
    return null;
  }
}

export function jsonError(
  message: string,
  status: number,
  extraHeaders: Record<string, string> = {}
): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { 'Content-Type': 'application/json', ...extraHeaders },
  });
}
