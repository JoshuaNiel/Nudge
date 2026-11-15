// delete-account Edge Function
//
// Called by the iOS app from Settings → Delete Account, with the signed-in user's JWT.
// Permanently deletes the caller's auth user; every user-owned public.* table cascades
// from auth.users (see docs/specs/account-deletion.md → Cascade audit), so this one call
// removes the profile, friends (and their nudges), goals, categories, reminders, usage and
// device tokens.
//
// Deployed with --no-verify-jwt (the gateway rejects ES256 user tokens — ADR-050); the
// caller is authenticated in-function via auth.getUser(jwt) instead.
//
// Deploy: supabase functions deploy delete-account --no-verify-jwt

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { handleDeleteAccount, jsonError } from './handler.ts';

Deno.serve(async (req) => {
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !anonKey || !serviceKey) {
    console.error('[delete-account] Missing required env vars');
    return jsonError('Server misconfiguration', 500);
  }

  // No session persistence: each invocation is stateless and must not cache a user.
  const clientOptions = {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  };

  // Anon-key client: used only to validate the caller's JWT with the Auth server.
  const userClient = createClient(supabaseUrl, anonKey, clientOptions);
  // Service-role client: needed for auth.admin. The key never leaves this process.
  const adminClient = createClient(supabaseUrl, serviceKey, clientOptions);

  return handleDeleteAccount(req, {
    async getUserId(jwt) {
      const { data, error } = await userClient.auth.getUser(jwt);
      if (error || !data.user) return null;
      return data.user.id;
    },
    async deleteUser(userId) {
      // Hard delete (shouldSoftDelete = false) so FK cascades actually run.
      const { error } = await adminClient.auth.admin.deleteUser(userId, false);
      if (error) throw error;
    },
    logError: (message, detail) => console.error(message, detail),
    logInfo: (message) => console.log(message),
  });
});
