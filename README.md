# Copare

Co-parenting messaging app with mediated group chat.

## Repository layout

```text
copare/
├── api/                 Hono API (REST + WebSocket) — deploy to Render
├── migrations/          Postgres schema + RLS policies (Neon)
├── render.yaml            Render Blueprint (API + notification worker)
└── ios/                   Native iOS app (SwiftUI + XcodeGen)
```

## Architecture

- **Neon Postgres** — data, permanent message archive, RLS for Data API reads
- **Neon Auth** — sign-up/login; issues JWTs validated by the API
- **Render Web Service** — `copare-api` (REST + WebSocket)
- **Render Background Worker** — `copare-notifications` (APNs outbox)

## Prerequisites

1. Neon project with **Auth** and **Data API** enabled on your branch
2. Node.js 20+
3. Render account (Starter plan for production)

## Local setup

```bash
# 1. Configure environment
cp api/.env.example api/.env
# Edit DATABASE_URL and NEON_AUTH_BASE_URL

# 2. Install and run migrations (requires Neon Auth enabled first)
cd api && npm install
npm run migrate

# 3. Start API
npm run dev
```

API runs at `http://localhost:3000`. Health check: `GET /health`.

## API overview

All `/v1/*` routes require `Authorization: Bearer <neon-auth-jwt>`.

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/v1/groups` | Create group (Parent A) |
| `GET` | `/v1/groups` | List user's groups |
| `POST` | `/v1/groups/:id/invitations` | Invite co-parent or mediator |
| `POST` | `/v1/groups/invitations/:token/accept` | Accept invitation |
| `GET` | `/v1/groups/:id/conversations` | List conversations |
| `POST` | `/v1/groups/:id/conversations` | Create conversation |
| `GET` | `/v1/conversations/:id/messages` | Message history |
| `POST` | `/v1/conversations/:id/messages` | Send message |
| `PUT` | `/v1/conversations/:id/read` | Mark read |
| `POST` | `/v1/messages/:id/delivered` | Mark delivered |
| `POST` | `/v1/devices` | Register APNs token |
| `WS` | `/ws?token=<jwt>` | Real-time events |

### WebSocket events

```json
{ "type": "message.new", "conversationId": "...", "message": { } }
{ "type": "message.delivered", "messageId": "...", "userId": "...", "at": "..." }
{ "type": "message.read", "messageId": "...", "userId": "...", "at": "..." }
```

## Deploy to Render

1. Push repo to GitHub
2. Render Dashboard → **New Blueprint** → select repo
3. Set secrets when prompted:
   - `DATABASE_URL` — Neon pooled connection string
   - `NEON_AUTH_BASE_URL` — from Neon Console → Auth
4. Run migrations against production `DATABASE_URL`:
   ```bash
   DATABASE_URL=... npm run migrate
   ```
5. Update `region` in `render.yaml` to match your Neon AWS region

## iOS app

See [`ios/README.md`](ios/README.md) for Xcode setup.

```bash
cd ios
cp Config/Secrets.xcconfig.example Config/Secrets.xcconfig
xcodegen generate
open Copare.xcodeproj
```

## iOS integration notes

- Auth: call Neon Auth REST endpoints directly; store JWT in Keychain
- API base URL: `https://copare-api.onrender.com/v1`
- WebSocket: `wss://copare-api.onrender.com/ws?token=<jwt>`
- Optional reads: Neon Data API with same JWT + RLS policies in `002_rls_policies.sql`

## Next steps

- [ ] Invitation email delivery + deep links
- [ ] APNs integration in notification worker
- [ ] Redis pub/sub when scaling API beyond one instance
