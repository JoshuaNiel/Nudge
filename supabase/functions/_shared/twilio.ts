// Shared Twilio helpers for Nudge Edge Functions.

/** Send an SMS via Twilio. Throws on non-2xx response. */
export async function sendSms(to: string, body: string): Promise<void> {
  const accountSid = Deno.env.get('TWILIO_ACCOUNT_SID')!;
  const authToken = Deno.env.get('TWILIO_AUTH_TOKEN')!;
  const messagingServiceSid = Deno.env.get('TWILIO_MESSAGING_SERVICE_SID')!;

  const url = `https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Messages.json`;
  const credentials = btoa(`${accountSid}:${authToken}`);

  const res = await fetch(url, {
    method: 'POST',
    headers: {
      Authorization: `Basic ${credentials}`,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams({
      To: to,
      MessagingServiceSid: messagingServiceSid,
      Body: body,
    }).toString(),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Twilio SMS failed (${res.status}): ${text}`);
  }
}

/**
 * Validate a Twilio inbound webhook signature.
 * Returns true if the request is legitimately from Twilio.
 *
 * Algorithm: HMAC-SHA1 of (url + sorted params concatenated), compared to
 * the base64-encoded X-Twilio-Signature header.
 */
export async function validateTwilioSignature(
  req: Request,
  params: Record<string, string>,
  url?: string
): Promise<boolean> {
  const signature = req.headers.get('X-Twilio-Signature');
  if (!signature) return false;

  const authToken = Deno.env.get('TWILIO_AUTH_TOKEN')!;

  // Build the string-to-sign: URL + sorted param key/values.
  // url should be the exact public URL Twilio used when sending the webhook —
  // req.url is unreliable behind Supabase's proxy (wrong scheme, stripped path prefix).
  const sortedKeys = Object.keys(params).sort();
  let str = url ?? req.url;
  for (const key of sortedKeys) {
    str += key + (params[key] ?? '');
  }

  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(authToken),
    { name: 'HMAC', hash: 'SHA-1' },
    false,
    ['sign']
  );
  const sigBytes = await crypto.subtle.sign('HMAC', key, encoder.encode(str));
  const expected = btoa(String.fromCharCode(...new Uint8Array(sigBytes)));

  return expected === signature;
}

/** Parse application/x-www-form-urlencoded body into a plain object. */
export async function parseFormBody(
  req: Request
): Promise<Record<string, string>> {
  const text = await req.text();
  const params: Record<string, string> = {};
  for (const [key, value] of new URLSearchParams(text)) {
    params[key] = value;
  }
  return params;
}

/** Keywords Twilio treats as STOP opt-outs (case-insensitive). */
export const STOP_KEYWORDS = new Set([
  'stop',
  'stopall',
  'unsubscribe',
  'cancel',
  'end',
  'quit',
]);

/** Keywords Twilio treats as consent acceptance. */
export const YES_KEYWORDS = new Set(['yes', 'y']);

/** Keywords Twilio treats as consent rejection. */
export const NO_KEYWORDS = new Set(['no', 'n']);
