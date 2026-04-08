# Social Layer

Design for friend connections, shame nudges, and encouragement messages.

---

## Overview

The social layer allows users to connect with friends, see when they're overusing their phone, and send shame or encouragement nudges. This is an opt-in feature.

---

## Friend Connections

### Data Model
See `database.md` — `friends` table with `requesterId`, `addresseeId`, `status`.

### Flow

> TODO: Design the full friend request flow before Phase 6.
> - How does a user find friends? By email? Username? QR code?
> - How is a friend request delivered to the recipient? Push notification? In-app only?
> - What does the friend list UI look like?
> - Can a user see a friend's usage data? If so, how much — total daily time only, or per-app?

### Privacy Considerations

> TODO: Define what data is visible between friends.
> - Does the recipient explicitly consent to sharing usage data when accepting a request?
> - Can a user hide specific apps from friends?
> - Is usage data shared in real-time (Supabase Realtime) or on a delay?

---

## Nudges

A nudge is a shame or encouragement message sent from one user to another.

### Shame Nudge
Sent when a friend has been on their phone too long. Intent is lighthearted accountability.

> TODO: Define trigger conditions.
> - Manual only (user decides to nudge), or can it be automated (auto-nudge when friend exceeds X hours)?
> - If automated, how does the sender's app know the friend's usage? Via Supabase query against the friend's usage rows?

### Encouragement Reply
A reply to a shame nudge — positive reinforcement.

> TODO: Define reply flow.
> - Is a reply always in response to a nudge, or can encouragements be sent independently?
> - Is there a message history / thread view, or just one-off messages?

### Delivery
Push notifications via APNs. See `notifications.md` for the proposed delivery flow.

---

## Supabase Realtime

> TODO: Determine where Supabase Realtime is used in the social layer.
> - Real-time delivery of nudges when the app is open (as opposed to relying on push when backgrounded)?
> - Live friend list showing who is currently over their limit?

---

## Open Questions

> TODO: Answer before Phase 6 (Social Layer):
> - Friend discovery mechanism — email lookup requires storing/querying emails carefully (privacy)
> - How much of a friend's usage data is shared, and does the friend consent explicitly at request time?
> - Is there a rate limit on nudges to prevent spam?
> - How do device tokens get stored and rotated (users may have multiple devices)?
