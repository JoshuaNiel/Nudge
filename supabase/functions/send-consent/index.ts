// send-consent Edge Function
//
// Triggered by a Supabase Database Webhook on INSERT to public.friend.
// Sends a consent SMS to the friend via Twilio so they can accept or decline.
//
// Setup: Supabase Dashboard → Database → Webhooks → Create
//   Table: public.friend | Events: INSERT | Method: POST | URL: this function's URL
//   Add header: Authorization: Bearer <SUPABASE_SERVICE_ROLE_KEY>

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { sendSms } from '../_shared/twilio.ts';

Deno.serve(async (req) => {
  try {
    // --- Validate required env vars up front ---
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!supabaseUrl || !serviceKey) {
      console.error(
        '[send-consent] Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY'
      );
      return new Response('Server misconfiguration', { status: 500 });
    }

    // --- Parse and validate webhook payload ---
    const payload = await req.json();

    if (payload.type !== 'INSERT' || !payload.record) {
      console.log(
        `[send-consent] Ignored — type=${payload.type}, record=${!!payload.record}`
      );
      return new Response('Ignored', { status: 200 });
    }

    const friend = payload.record;
    const { id, user_id, friend_phone_number, status } = friend;

    if (!user_id || !friend_phone_number) {
      console.error(
        '[send-consent] Malformed webhook payload — missing user_id or friend_phone_number',
        friend
      );
      return new Response('Bad payload', { status: 400 });
    }

    if (status !== 'pending') {
      console.log(
        `[send-consent] Ignored — friend id=${id} has status=${status}`
      );
      return new Response('Ignored: not pending', { status: 200 });
    }

    // --- Look up the app user's first name ---
    const supabase = createClient(supabaseUrl, serviceKey);

    const { data: profile, error: profileError } = await supabase
      .from('profile')
      .select('first_name')
      .eq('user_id', user_id)
      .single();

    if (profileError) {
      // Non-fatal: fall back to generic name rather than failing the whole consent send
      console.warn(
        `[send-consent] Could not fetch profile for user_id=${user_id}:`,
        profileError.message
      );
    }

    const firstName = profile?.first_name ?? 'Someone';

    const message =
      `Hey, ${firstName} wants your help being more accountable with their screen time. Can we send you updates on their progress? ` +
      `Reply yes or no. You can opt out at any time`;

    // --- Send the consent SMS ---
    await sendSms(friend_phone_number, message);

    console.log(
      `[send-consent] Consent SMS sent to ${friend_phone_number} for friend id=${id}`
    );

    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  } catch (err) {
    console.error('[send-consent] Error:', err);
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    });
  }
});
