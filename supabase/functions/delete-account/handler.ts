// Request handling for delete-account, kept free of Supabase/Deno globals so it can be
// unit-tested with fake dependencies (see index.ts for the real wiring).
//
// Security contract:
// - POST only.
// - The caller is identified ONLY by their own JWT (validated against the Auth server).
// - The request body and query string are never read: a caller can delete exactly one
//   account — their own — and there is no parameter that could name anyone else.
// - Failures return a generic message; details go to the function logs only.

export interface DeleteAccountDeps {
  /** Validates the bearer JWT with the Auth server. Returns the user id, or null if invalid. */
  getUserId(jwt: string): Promise<string | null>;
  /** Hard-deletes the auth user (all public.* rows cascade from auth.users). Throws on failure. */
  deleteUser(userId: string): Promise<void>;
  /** Logging sink; defaults to console in production. */
  logError(message: string, detail?: unknown): void;
  logInfo(message: string): void;
}

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

  let userId: string | null;
  try {
    userId = await deps.getUserId(match[1]);
  } catch (err) {
    deps.logError('[delete-account] getUser threw', err);
    userId = null;
  }
  if (!userId) {
    return jsonError('Unauthorized', 401);
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
