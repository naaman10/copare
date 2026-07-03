# Copare iOS

Native SwiftUI app for co-parenting group messaging.

## Requirements

- Xcode 16+ (Xcode 26 recommended for Liquid Glass)
- iOS 26+ simulator or device
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Copare API running locally or deployed on Render

## Setup

```bash
# 1. Configure endpoints
cp Config/Secrets.xcconfig.example Config/Secrets.xcconfig
# Edit NEON_AUTH_BASE_URL, API_BASE_URL, WS_BASE_URL

# 2. Generate Xcode project
xcodegen generate

# 3. Open in Xcode
open Copare.xcodeproj
```

### Local API

The simulator can reach your Mac's API at `http://localhost:3000`. Start the API first:

```bash
cd ../api && npm run dev
```

For a **physical device**, replace `localhost` with your Mac's LAN IP in `Secrets.xcconfig`.

### Neon Auth trusted origin

Native sign-up/sign-in sends `Origin: copare://` (configured as `AUTH_ORIGIN` in `Secrets.xcconfig`). Add this to **Neon Console → Auth → Trusted domains / origins** if sign-up fails with an origin error.

## Design

The UI uses a **Fundio-inspired warm palette** (soft canvas, coral accent, rounded cards) combined with **Liquid Glass** system materials on iOS 26 (`.glassEffect`, `.glassProminent` buttons, native glass tab bar).

Design tokens and components live in `Copare/Design/`:

| File | Purpose |
|------|---------|
| `CopareTheme` | Colors, spacing, radii |
| `CopareBackground` | Warm gradient canvas |
| `CopareCard` | Glass content cards |
| `CopareField` | Styled text inputs |
| `CoparePrimaryButton` | Glass prominent actions |

## Architecture

| Layer | Purpose |
|-------|---------|
| `AuthService` | Neon Auth sign-up / sign-in, JWT via Keychain |
| `CopareAPI` | REST client for `/v1/*` endpoints |
| `WebSocketManager` | Real-time `message.new` events |
| `AppState` | Session + service wiring |

## App flow

1. **Sign up / Sign in** — Neon Auth
2. **Create group** — you become Parent A
3. **Invite members** — Parent B + 2 mediators (token shown until email delivery exists)
4. **Accept invitation** — Profile tab, paste token
5. **Conversations** — available once all 4 members join (group becomes `active`)
6. **Chat** — send messages, receive WebSocket updates

## Bundle ID

`com.copare.app` — matches APNs config in `render.yaml`.

## Next steps

- [ ] Deep links for invitation tokens (`copare://invite/<token>`)
- [ ] Push notification registration (`POST /v1/devices`)
- [ ] Profile avatars and display names from `profiles` table
- [ ] Production `Secrets.xcconfig` pointing at Render
