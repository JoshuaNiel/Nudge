// Shared APNs helper for Nudge Edge Functions.
// Uses token-based auth (ES256 JWT + .p8 key) — no .p12 certificate needed.
// The same .p8 key works for both sandbox and production.

/**
 * Send an APNs push notification to a device.
 * Reads APNS_PRIVATE_KEY, APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID, APNS_SANDBOX from env.
 */
export async function sendApnsPush(
  deviceToken: string,
  title: string,
  body: string,
  data?: Record<string, unknown>
): Promise<void> {
  const privateKeyPem = Deno.env.get("APNS_PRIVATE_KEY")!;
  const keyId = Deno.env.get("APNS_KEY_ID")!;
  const teamId = Deno.env.get("APNS_TEAM_ID")!;
  const bundleId = Deno.env.get("APNS_BUNDLE_ID")!;
  const sandbox = Deno.env.get("APNS_SANDBOX") === "true";

  const jwt = await generateApnsJwt(teamId, keyId, privateKeyPem);

  const host = sandbox
    ? "api.sandbox.push.apple.com"
    : "api.push.apple.com";

  const payload = {
    aps: { alert: { title, body }, sound: "default" },
    ...data,
  };

  const res = await fetch(`https://${host}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${jwt}`,
      "apns-topic": bundleId,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "Content-Type": "application/json",
    },
    body: JSON.stringify(payload),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`APNs failed (${res.status}): ${text}`);
  }
}

/**
 * Generate a short-lived ES256 JWT for APNs token-based auth.
 * The JWT is valid for up to 1 hour; Apple recommends refreshing every 20-30 min.
 * For simplicity we generate one per request — acceptable at this scale.
 */
async function generateApnsJwt(
  teamId: string,
  keyId: string,
  privateKeyPem: string
): Promise<string> {
  // Strip PEM headers and decode base64
  const pemContents = privateKeyPem
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s/g, "");

  const keyData = Uint8Array.from(atob(pemContents), (c) => c.charCodeAt(0));

  const key = await crypto.subtle.importKey(
    "pkcs8",
    keyData,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );

  const header = toBase64url({ alg: "ES256", kid: keyId });
  const claims = toBase64url({
    iss: teamId,
    iat: Math.floor(Date.now() / 1000),
  });

  const message = `${header}.${claims}`;
  const sigBytes = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(message)
  );

  return `${message}.${bytesToBase64url(new Uint8Array(sigBytes))}`;
}

function toBase64url(obj: unknown): string {
  return bytesToBase64url(new TextEncoder().encode(JSON.stringify(obj)));
}

function bytesToBase64url(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
}
