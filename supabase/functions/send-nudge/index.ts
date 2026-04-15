// send-nudge Edge Function
//
// Called by the iOS app automatically when a nudge trigger fires
// (time on phone, goal exceeded, daily report — never user-initiated).
//
// The app passes a `report` string summarising the user's situation.
// This function constructs the full SMS (report + numbered reply options),
// sends it to the friend, and inserts a nudge row with type=NULL.
// The friend's reply (handled by receive-reply) sets the final type.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { sendSms } from '../_shared/twilio.ts';
import { REPLY_OPTIONS } from '../_shared/messages.ts';

const DAILY_NUDGE_LIMIT = 10;

Deno.serve(async (req) => {
  try {
    // --- Authenticate the app user ---
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return errorResponse('Missing Authorization header', 401);
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!supabaseUrl || !anonKey || !serviceKey) {
      console.error('[send-nudge] Missing required env vars');
      return errorResponse('Server misconfiguration', 500);
    }

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const {
      data: { user },
      error: authError,
    } = await userClient.auth.getUser();
    if (authError || !user) {
      return errorResponse('Unauthorized', 401);
    }

    const db = createClient(supabaseUrl, serviceKey);

    // --- Parse body ---
    const body = (await req.json()) as { friend_id: number; report: string };
    const { friend_id, report } = body;

    if (!friend_id || !report?.trim()) {
      return errorResponse('friend_id and report are required', 400);
    }

    // --- Validate friend ---
    const { data: friend, error: friendError } = await db
      .from('friend')
      .select('id, friend_phone_number, friend_name, status')
      .eq('id', friend_id)
      .eq('user_id', user.id)
      .single();

    if (friendError || !friend) {
      return errorResponse('Friend not found', 404);
    }
    if (friend.status !== 'accepted') {
      return errorResponse(
        `Friend has not accepted your consent request yet (status: ${friend.status})`,
        403
      );
    }

    // --- Rate limit: max per the user's local day ---
    const { data: profile } = await db
      .from('profile')
      .select('time_zone')
      .eq('user_id', user.id)
      .single();

    const dayStartUtc = startOfLocalDayUtc(profile?.time_zone ?? 'UTC');
    const { count } = await db
      .from('nudge')
      .select('id', { count: 'exact', head: true })
      .eq('friend_id', friend_id)
      .gte('sent_timestamp', dayStartUtc);

    if ((count ?? 0) >= DAILY_NUDGE_LIMIT) {
      return errorResponse(
        `Rate limit: max ${DAILY_NUDGE_LIMIT} nudges per friend per day`,
        429
      );
    }

    // --- Build the SMS ---
    // prompt stores the full text sent to the friend (report + options)
    const prompt = report.trim() + REPLY_OPTIONS;

    // --- Insert nudge row (type is NULL until friend replies) ---
    const { data: nudge, error: insertError } = await db
      .from('nudge')
      .insert({ friend_id, prompt, status: 'sent_to_friend' })
      .select('id')
      .single();

    if (insertError || !nudge) {
      throw new Error(`Failed to insert nudge: ${insertError?.message}`);
    }

    // --- Send SMS ---
    try {
      await sendSms(friend.friend_phone_number, prompt);
    } catch (smsError) {
      await db.from('nudge').update({ status: 'failed' }).eq('id', nudge.id);
      console.error('[send-nudge] SMS failed for nudge', nudge.id, smsError);
      return errorResponse('Failed to send SMS. Please try again.', 502);
    }

    console.log(
      `[send-nudge] Nudge id=${nudge.id} sent to friend id=${friend_id}`
    );

    return new Response(JSON.stringify({ nudge_id: nudge.id }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  } catch (err) {
    console.error('[send-nudge] Unexpected error:', err);
    return errorResponse(String(err), 500);
  }
});

function errorResponse(message: string, status: number): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

/**
 * Returns the UTC ISO string for midnight of the current day in the given
 * IANA timezone. Uses noon UTC offset to avoid DST boundary issues.
 */
function startOfLocalDayUtc(timeZone: string): string {
  const now = new Date();
  const localDate = new Intl.DateTimeFormat('en-CA', { timeZone }).format(now);
  const noonUtc = new Date(`${localDate}T12:00:00Z`);
  const localH = parseInt(
    new Intl.DateTimeFormat('en-US', {
      timeZone,
      hour: '2-digit',
      hour12: false,
    }).format(noonUtc)
  );
  const localM = parseInt(
    new Intl.DateTimeFormat('en-US', {
      timeZone,
      minute: '2-digit',
      hour12: false,
    }).format(noonUtc)
  );
  const offsetMinutes = 12 * 60 - (localH * 60 + localM);
  const midnightUtc = new Date(`${localDate}T00:00:00Z`);
  return new Date(
    midnightUtc.getTime() + offsetMinutes * 60 * 1000
  ).toISOString();
}
