# Auth Flow

Authentication strategy using Supabase Auth.

---

## Mechanism

Supabase Auth handles all credential management. We do not store passwords or manage sessions manually.

> TODO: Decide on auth method(s) before Phase 1.
> - Email + password only?
> - Sign in with Apple (recommended for App Store compliance — Apple requires it if any third-party auth is offered)?
> - Magic link (passwordless email)?

**Note:** If the app uses any third-party login (Google, etc.), Apple requires Sign in with Apple to also be offered. Sign in with Apple is generally recommended for iOS apps regardless.

---

## Session Management

Supabase Swift client handles session persistence automatically via the keychain.

> TODO: Document session lifecycle decisions.
> - What happens on first launch with no session — go straight to onboarding/login?
> - What happens when a session expires mid-use?
> - Is there a "remember me" option or is the session always persisted?

---

## Onboarding Flow

> TODO: Design the onboarding sequence before Phase 1.
> - Sign up → create profile → request Screen Time permission → request notification permission?
> - What is the minimum required to get to the main app (can users skip Screen Time permission and add later)?
> - How is `profiles` row created? (Recommended: Supabase database trigger on `auth.users` insert)

### Recommended Profile Creation Trigger
```sql
create function handle_new_user()
returns trigger as $$
begin
  insert into profiles (user_id)
  values (new.id);
  return new;
end;
$$ language plpgsql security definer;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure handle_new_user();
```

> TODO: Decide what default values `profiles` should have at creation (null timezone? device timezone auto-detected?).

---

## Row Level Security (RLS)

All tables must have RLS enabled. Users should only be able to read and write their own rows.

> TODO: Write RLS policies for each table before Phase 1.

General pattern:
```sql
-- Enable RLS
alter table usage enable row level security;

-- Users can only access their own rows
create policy "Users can manage their own usage"
  on usage for all
  using (auth.uid() = user_id);
```

Special cases to think through:
- `friends` — a user needs to read rows where they are either `requesterId` or `addresseeId`
- `nudges` — a user needs to read rows where they are either `senderId` or `receiverId`
- `app` — should this be readable by all authenticated users? (It's a global registry)
- `app_category` and `app_category_members` — users only see their own categories

> TODO: Write and test all RLS policies before any feature goes to production.

---

## Open Questions

> TODO: Answer before Phase 1 (Foundation):
> - Sign in with Apple required or optional?
> - Auto-detect device timezone on profile creation, or ask user during onboarding?
> - What is the account deletion flow? (Required for App Store — must delete all user data)
