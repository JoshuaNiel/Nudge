// receive-reply Edge Function
//
// Twilio inbound webhook — fires when a friend replies to a consent or nudge SMS.
// Configure in Twilio Console → Phone Numbers → your number →
//   Messaging → "A message comes in" → Webhook → POST → this function's URL
//
// Routing logic:
//   1. If the sender has any PENDING friend rows → treat as a consent reply
//        YES  → set status = accepted, push "<name> accepted" to each app user (best-effort)
//        NO   → delete the row (social preference, not regulatory)
//        STOP → set status = blocked (Twilio regulatory compliance)
//   2. Otherwise → treat as a nudge reply
//        Find the SINGLE most recent open nudge sent to this phone number (across all app users)
//        Update that nudge with the reply
//        Send APNs push + optional SMS to the app user who owns it

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import {
  NO_KEYWORDS,
  STOP_KEYWORDS,
  YES_KEYWORDS,
  parseFormBody,
  sendSms,
  validateTwilioSignature,
} from '../_shared/twilio.ts';
import { sendApnsPush } from '../_shared/apns.ts';

// Pre-canned messages sent to the app user when the friend picks option 1 or 2.
// These are written from the friend's voice.
const ENCOURAGEMENT_MESSAGE =
  "You're stronger than the algorithm! I believe in you, now get off your phone and go do something that will make you happy!";
const SHAME_MESSAGE =
  '4 hours a day is 25% of your waking hours. Do you really want to waste another day of your life accomplishing nothing?';

Deno.serve(async (req) => {
  try {
    const params = await parseFormBody(req);

    // --- Reconstruct the public URL Twilio signed ---
    // Behind Supabase's proxy, req.url arrives with http:// (not https) and with
    // the /functions/v1 prefix stripped. The host in req.url is correct though —
    // the host header is the internal runtime host, not the project host.
    // Twilio signs the exact public URL it POST-ed to, so we rebuild it by
    // taking the host from req.url, the scheme from x-forwarded-proto, and
    // prepending the stripped /functions/v1 prefix back onto the path.
    const parsed = new URL(req.url);
    const proto = req.headers.get('x-forwarded-proto') ?? 'https';
    const webhookUrl = `${proto}://${parsed.host}/functions/v1${parsed.pathname}`;

    // --- Validate Twilio signature ---
    // Rejects any request that didn't come from Twilio.
    const valid = await validateTwilioSignature(req, params, webhookUrl);
    if (!valid) {
      console.warn('[receive-reply] Invalid Twilio signature — rejected');
      return twilioXml('<Response/>');
    }

    const fromPhone = params['From'];
    const replyBody = (params['Body'] ?? '').trim();
    const keyword = replyBody.toLowerCase().split(/\s+/)[0];

    if (!fromPhone || !replyBody) {
      return twilioXml('<Response/>');
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!supabaseUrl || !serviceKey) {
      console.error(
        '[receive-reply] Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY'
      );
      return twilioXml('<Response/>');
    }

    const db = createClient(supabaseUrl, serviceKey);

    // --- Look up all friend rows for this phone number (pending + accepted) ---
    const { data: friends } = await db
      .from('friend')
      .select('id, user_id, friend_name, status')
      .eq('friend_phone_number', fromPhone)
      .in('status', ['pending', 'accepted']);

    if (!friends || friends.length === 0) {
      console.log(`[receive-reply] No friend found for ${fromPhone}`);
      return twilioXml('<Response/>');
    }

    const pendingFriends = friends.filter((f) => f.status === 'pending');
    const acceptedFriends = friends.filter((f) => f.status === 'accepted');

    if (pendingFriends.length > 0) {
      // Consent reply — applies to all pending rows for this number
      await handleConsentReply(
        db,
        pendingFriends,
        acceptedFriends,
        keyword,
        fromPhone
      );
    } else if (acceptedFriends.length > 0) {
      if (STOP_KEYWORDS.has(keyword)) {
        await handleStop(db, acceptedFriends, fromPhone);
      } else {
        await handleNudgeReply(db, acceptedFriends, replyBody);
      }
    }

    return twilioXml('<Response/>');
  } catch (err) {
    console.error('[receive-reply] Unexpected error:', err);
    // Always return 200 to Twilio — a non-200 causes Twilio to retry indefinitely
    return twilioXml('<Response/>');
  }
});

// ─── Consent reply ─────────────────────────────────────────────────────────

async function handleConsentReply(
  db: ReturnType<typeof createClient>,
  pendingFriends: Array<{
    id: number;
    user_id: string;
    friend_name: string;
    status: string;
  }>,
  acceptedFriends: Array<{
    id: number;
    user_id: string;
    friend_name: string;
    status: string;
  }>,
  keyword: string,
  fromPhone: string
) {
  if (STOP_KEYWORDS.has(keyword)) {
    // STOP applies to all rows — pending and accepted
    await handleStop(db, [...pendingFriends, ...acceptedFriends], fromPhone);
    return;
  }

  if (YES_KEYWORDS.has(keyword)) {
    const ids = pendingFriends.map((f) => f.id);
    const { data: acceptedRows, error: acceptError } = await db
      .from('friend')
      .update({ status: 'accepted' })
      .in('id', ids)
      .select('id, user_id, friend_name');

    if (acceptError) {
      console.error(
        `[receive-reply] Failed to accept friend ids=${ids}:`,
        acceptError
      );
    } else {
      console.log(`[receive-reply] Consent accepted for friend ids=${ids}`);
      // Only after the update succeeded, and only for the rows it actually changed.
      await notifyFriendAccepted(db, (acceptedRows ?? []) as FriendRow[]);
    }

    // Look up the app user's first name to personalise the thank-you.
    // If multiple users added this number, use the first one's name.
    const userId = pendingFriends[0].user_id;
    const { data: profile } = await db
      .from('profile')
      .select('first_name')
      .eq('user_id', userId)
      .single();
    const firstName = profile?.first_name ?? 'your friend';

    await sendSms(
      fromPhone,
      `Thanks for helping ${firstName} with their screen time goals! ` +
        `I'll text you when they need a little encouragement. Reply STOP at any time to opt out.`
    );
  } else if (NO_KEYWORDS.has(keyword)) {
    const ids = pendingFriends.map((f) => f.id);
    await db.from('friend').delete().in('id', ids);
    console.log(`[receive-reply] Consent declined — deleted friend ids=${ids}`);

    await sendSms(
      fromPhone,
      `No worries! Your number has been removed and you won't receive any more messages from us.`
    );
  } else {
    // Unrecognised reply — ask for clarification
    await sendSms(
      fromPhone,
      "Sorry, I didn't understand your reply. Please reply yes to allow messages or no to decline."
    );
    console.log(
      `[receive-reply] Unrecognised consent reply from ${fromPhone}: "${keyword}"`
    );
  }
}

// One phone number can be a pending friend of several app users: each accepted row's
// owner gets their own push. Best-effort — never throws, so a push failure can't affect
// the status update (already committed) or the thank-you SMS that follows.
async function notifyFriendAccepted(
  db: ReturnType<typeof createClient>,
  acceptedRows: FriendRow[]
) {
  try {
    const results = await Promise.allSettled(
      acceptedRows.map((row) =>
        pushToUser(
          db,
          row.user_id,
          `${row.friend_name} accepted`,
          `${row.friend_name} agreed to be your Nudge friend. ` +
            `They'll get a text when you need a nudge.`,
          { type: 'friend_accepted', friend_id: row.id }
        )
      )
    );
    results.forEach((result, i) => {
      if (result.status === 'rejected') {
        console.error(
          `[receive-reply] Friend-accepted push failed for friend id=${acceptedRows[i].id}:`,
          result.reason
        );
      }
    });
  } catch (err) {
    console.error('[receive-reply] Friend-accepted push failed:', err);
  }
}

// ─── STOP / opt-out ────────────────────────────────────────────────────────

async function handleStop(
  db: ReturnType<typeof createClient>,
  friends: Array<{ id: number }>,
  fromPhone: string
) {
  const ids = friends.map((f) => f.id);
  await db.from('friend').update({ status: 'blocked' }).in('id', ids);
  console.log(
    `[receive-reply] STOP from ${fromPhone} — blocked friend ids=${ids}`
  );
}

// ─── Nudge reply ───────────────────────────────────────────────────────────

async function handleNudgeReply(
  db: ReturnType<typeof createClient>,
  acceptedFriends: Array<{ id: number; user_id: string; friend_name: string }>,
  replyBody: string
) {
  // Find the single most recent open nudge across all app users who have this
  // person as a friend. A reply goes to the one app user who most recently
  // nudged them — not to everyone who has them as a friend.
  const friendIds = acceptedFriends.map((f) => f.id);

  const { data: nudge } = await db
    .from('nudge')
    .select('id, friend_id')
    .in('friend_id', friendIds)
    .eq('status', 'sent_to_friend')
    .order('sent_timestamp', { ascending: false })
    .limit(1)
    .single();

  if (!nudge) {
    console.log(
      `[receive-reply] No open nudge for any friend with this number — ignoring`
    );
    return;
  }

  const friend = acceptedFriends.find((f) => f.id === nudge.friend_id);
  if (!friend) return;

  // Resolve the friend's reply into a type + the message to deliver to the app user.
  // "1" → encouragement (pre-canned), "2" → shame (pre-canned), anything else → custom
  let nudgeType: string;
  let deliveredMessage: string;

  if (replyBody === '1') {
    nudgeType = 'encouragement';
    deliveredMessage = ENCOURAGEMENT_MESSAGE;
  } else if (replyBody === '2') {
    nudgeType = 'shame';
    deliveredMessage = SHAME_MESSAGE;
  } else {
    nudgeType = 'custom';
    deliveredMessage = replyBody;
  }

  await db
    .from('nudge')
    .update({
      friend_reply: deliveredMessage,
      type: nudgeType,
      status: 'replied',
    })
    .eq('id', nudge.id);

  console.log(
    `[receive-reply] Nudge id=${nudge.id} → type=${nudgeType}, message="${deliveredMessage}"`
  );

  await deliverReplyToAppUser(db, friend, nudge.id, deliveredMessage);
}

// ─── Delivery ──────────────────────────────────────────────────────────────

async function deliverReplyToAppUser(
  db: ReturnType<typeof createClient>,
  friend: { id: number; user_id: string; friend_name: string },
  nudgeId: number,
  replyBody: string
) {
  // APNs push to all of the app user's registered devices
  await pushToUser(
    db,
    friend.user_id,
    `Message from ${friend.friend_name}`,
    replyBody,
    { nudge_id: nudgeId }
  );

  // SMS to the app user's own phone if they have one set in profile
  const { data: profile } = await db
    .from('profile')
    .select('phone_number')
    .eq('user_id', friend.user_id)
    .single();

  if (profile?.phone_number) {
    const smsBody = `${friend.friend_name} replied: "${replyBody}"`;
    await sendSms(profile.phone_number, smsBody).catch((err) =>
      console.error('[receive-reply] SMS to app user failed:', err)
    );
  }

  // Mark delivery complete
  await db
    .from('nudge')
    .update({ status: 'reply_delivered' })
    .eq('id', nudgeId);
}

// ─── Push ──────────────────────────────────────────────────────────────────

type FriendRow = { id: number; user_id: string; friend_name: string };

// Sends one APNs alert to every registered device of an app user. `data` is spread at
// the top level of the payload beside `aps` (see _shared/apns.ts). Each device is
// best-effort: a failed send is logged and the others still go out.
async function pushToUser(
  db: ReturnType<typeof createClient>,
  userId: string,
  title: string,
  body: string,
  data: Record<string, unknown>
): Promise<void> {
  const { data: tokens, error } = await db
    .from('device_tokens')
    .select('token')
    .eq('user_id', userId)
    .eq('platform', 'apns');

  if (error) {
    console.error(
      `[receive-reply] Device token lookup failed for user ${userId}:`,
      error
    );
    return;
  }
  if (!tokens || tokens.length === 0) return;

  await Promise.allSettled(
    tokens.map((row: { token: string }) =>
      sendApnsPush(row.token, title, body, data).catch((err) =>
        console.error(
          `[receive-reply] APNs push failed for token ${row.token}:`,
          err
        )
      )
    )
  );
}

// ─── Helpers ───────────────────────────────────────────────────────────────

function twilioXml(xml: string): Response {
  return new Response(xml, {
    status: 200,
    headers: { 'Content-Type': 'text/xml' },
  });
}
