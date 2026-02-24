# OpenClaw Civic Stack — Concrete Implementation Plan

## Ecosystem Map

| App | Stack | SSO State | Beckn/UCP | Auth Type | Gaps |
|-----|-------|-----------|-----------|-----------|------|
| aadhaar-chain | Next.js 15 + FastAPI + Solana | IS the SSO provider | N/A | Wallet (Phantom) | feat-012–018 pending (routes, Solana programs) |
| ondc-seller | React + Vite + TS | SSO-001→SSO-005 implemented | Missing Beckn adapter | aadharcha.in cookie SSO | No Beckn layer, 4 unit test files pending |
| ondc-buyer | React + Vite + TS | SSO-001→SSO-005 implemented | Missing Beckn adapter | aadharcha.in cookie SSO | node_modules/dist committed, No Beckn layer |
| flatwatch | FastAPI + Next.js | Mock only (MOCK_USERS) | N/A | Email/password POC | Auth not wired to aadhaar-chain SSO |

---

## Phase 1 — Harden aadhaar-chain SSO API (BLOCKER for all others)

### Problem
feat-012 (verification routes), feat-013 (identity + transaction routes), feat-014 (credentials routes) are all `pending`.
The SSO endpoints ondc-seller/buyer call (`/api/auth/login`, `/api/auth/validate`, `/api/auth/me`, `/api/auth/logout`) are NOT in `gateway/app/routes.py` — only identity/verification routes exist.
In-memory dicts used for dev — no persistence.

### Fixes

1. *Add SSO auth routes to gateway* (`gateway/app/routes.py`):
   - `POST /api/auth/login` — accept `{ wallet_address, signature }`, verify Solana wallet signature, issue `aadharcha_session` cookie (JWT, env-driven secret)
   - `GET  /api/auth/validate` — read `aadharcha_session` cookie, return `{ valid, user: SSOUser }`
   - `GET  /api/auth/me` — return full user profile from verified session
   - `POST /api/auth/logout` — clear `aadharcha_session` cookie

2. *Add Pydantic models* (`gateway/app/models.py`):
   ```python
   class SSOUser(BaseModel):
       wallet_address: str
       pda_address: Optional[str]
       created_at: int

   class SessionValidationResponse(BaseModel):
       valid: bool
       user: Optional[SSOUser]
   ```

3. *Replace in-memory dicts with SQLite/PostgreSQL* via SQLAlchemy for persistence across restarts

4. *Fix env config* (`gateway/config.py`):
   - Add `JWT_SECRET` (replace any hardcoded dev secret)
   - Add `CORS_ORIGINS` list (include ondc-seller, ondc-buyer, flatwatch origins)
   - Add `SOLANA_CLUSTER` (devnet/mainnet)

5. *Remove venv from git* — `gateway/venv/` is committed, add to `.gitignore` and BFG-clean

6. *Complete feat-012–014* — verification, identity, credentials routes with real persistence

7. *Integration tests*:
   ```
   POST /api/auth/login → 200 + Set-Cookie: aadharcha_session
   GET  /api/auth/validate (with cookie) → { valid: true, user: {...} }
   GET  /api/auth/validate (no cookie) → { valid: false }
   GET  /api/auth/me → 200 SSOUser
   POST /api/auth/logout → 200 + clears cookie
   ```

### Files to change
- `gateway/app/routes.py` — add auth router
- `gateway/app/models.py` — add SSOUser, SessionValidationResponse
- `gateway/config.py` — JWT_SECRET, CORS_ORIGINS env vars
- `gateway/requirements.txt` — add python-jose, httpx, sqlalchemy
- `.gitignore` — add venv/
- `frontend/lib/api.ts` — replace hardcoded `localhost:8000` with `NEXT_PUBLIC_API_URL`

---

## Phase 2 — Wire flatwatch to aadhaar-chain SSO

### Problem
`backend/app/auth.py` uses:
- Hardcoded `SECRET_KEY = "flatwatch-dev-secret-key-change-in-production"`
- `MOCK_USERS` in-memory dict with `authenticate_user` that accepts any password
- `validate_sso_session` already exists and calls `IDENTITY_URL/api/auth/validate` via httpx — but `IDENTITY_URL` is not set in env and defaults to nothing

### Fixes

1. *Wire `validate_sso_session` properly*:
   ```python
   # backend/app/auth.py
   IDENTITY_URL = os.getenv("AADHAAR_CHAIN_URL", "https://aadharcha.in")
   
   async def validate_sso_session(session_cookie: str) -> Optional[SSOValidationResponse]:
       async with httpx.AsyncClient() as client:
           resp = await client.get(
               f"{IDENTITY_URL}/api/auth/validate",
               cookies={"aadharcha_session": session_cookie},
               timeout=10.0
           )
           if resp.status_code == 200:
               return SSOValidationResponse(**resp.json())
       return None
   ```

2. *Replace email/password login with wallet SSO*:
   - Remove `LoginRequest` (email + password)
   - Add `WalletLoginRequest(wallet_address, signature)`
   - On login: proxy to `AADHAAR_CHAIN_URL/api/auth/login`, forward `aadharcha_session` cookie back to client

3. *Replace hardcoded JWT secret*:
   ```python
   SECRET_KEY = os.getenv("JWT_SECRET")
   if not SECRET_KEY:
       raise RuntimeError("JWT_SECRET env var required")
   ```

4. *Frontend flatwatch*: add `WalletProvider` (identical to ondc-seller's `src/providers/WalletProvider.tsx`), remove email/password login page, add wallet connect button

5. *Add env vars to flatwatch*:
   ```
   AADHAAR_CHAIN_URL=https://aadharcha.in
   JWT_SECRET=<strong-random-secret>
   ```

6. *Tests*:
   - Mock `httpx` call to `AADHAAR_CHAIN_URL/api/auth/validate` in existing test suite
   - Confirm `test_auth.py` passes with SSO mock

### Files to change
- `backend/app/auth.py` — wire SSO, remove mock, fix secret
- `backend/app/config.py` — add AADHAAR_CHAIN_URL, JWT_SECRET
- `backend/requirements.txt` — confirm httpx present
- `frontend/src/lib/auth.tsx` — swap email/password for wallet SSO
- `frontend/src/app/page.tsx` — add WalletProvider wrapper
- `frontend/src/providers/WalletProvider.tsx` — create (copy from ondc-seller)

---

## Phase 3 — Add Beckn Protocol Layer (ondc-seller + ondc-buyer)

### Problem
Both portals have full UI (catalog, cart, checkout, orders) but no Beckn protocol implementation. ONDC mandates the Beckn lifecycle: `search → on_search → select → on_select → init → on_init → confirm → on_confirm → status → on_status → cancel → on_cancel`.

### Fixes — ondc-seller

1. *Create `src/lib/beckn.ts`*:
   ```typescript
   const BECKN_GATEWAY = import.meta.env.VITE_BECKN_GATEWAY_URL;
   
   export const becknClient = {
     onSearch(catalogItems: CatalogItem[]): BecknResponse  // respond to buyer search
     onSelect(order: Order): BecknResponse                 // confirm item selection
     onInit(order: Order): BecknResponse                   // send quote + payment terms
     onConfirm(order: Order): BecknResponse                // confirm order
     onStatus(orderId: string): BecknStatusResponse        // return order status
     onCancel(orderId: string): BecknResponse              // handle cancellation
   }
   ```

2. *Wire to existing pages*:
   - `CatalogPage.tsx` → calls `becknClient.onSearch` to register catalog
   - `OrdersPage.tsx` → calls `becknClient.onStatus` to sync ONDC status
   - `OrderDetailPage.tsx` → `becknClient.onConfirm` / `onCancel`

3. *Add env var*: `VITE_BECKN_GATEWAY_URL=https://gateway.ondc.org` (sandbox)

### Fixes — ondc-buyer

1. *Create `src/lib/beckn.ts`* (buyer side):
   ```typescript
   export const becknClient = {
     search(query: string, location: Location): Promise<BecknSearchResponse>
     select(item: Item, providerId: string): Promise<BecknSelectResponse>
     init(cart: Cart, billing: BillingInfo): Promise<BecknInitResponse>
     confirm(order: Order, payment: PaymentInfo): Promise<BecknConfirmResponse>
     status(orderId: string): Promise<BecknStatusResponse>
     cancel(orderId: string, reason: string): Promise<BecknCancelResponse>
   }
   ```

2. *Wire to existing pages*:
   - `SearchPage.tsx` + `useSearchStream.ts` → `becknClient.search`
   - `CartPage.tsx` → `becknClient.select` + `becknClient.init`
   - `CheckoutPage.tsx` → `becknClient.confirm`
   - `OrderDetailPage.tsx` → `becknClient.status` / `cancel`

3. *Fix git hygiene*:
   ```bash
   # Remove node_modules and dist from history
   echo "node_modules/" >> .gitignore
   echo "dist/" >> .gitignore
   git rm -r --cached node_modules/ dist/
   git commit -m "fix: remove node_modules and dist from tracking"
   ```

4. *Add env var*: `VITE_BECKN_GATEWAY_URL=https://gateway.ondc.org`

### UCP Layer (both portals)
- UCP (Google Universal Commerce Protocol) sits on top of Beckn — maps UCP product schema to Beckn catalog items
- Add `src/lib/ucp.ts` with UCP → Beckn schema adapter once Beckn layer is stable

---

## Phase 4 — Extract @openclaw/identity-sdk

### Problem
`WalletProvider.tsx` is copy-pasted across ondc-seller, ondc-buyer, and will be added to flatwatch. SSO axios interceptor logic is duplicated between ondc-seller and ondc-buyer. No single source of truth.

### Fix

1. *Create new repo*: `openclaw-gurusharan/identity-sdk`

2. *Package contents*:
   ```
   src/
     providers/WalletProvider.tsx     (Solana wallet adapter setup)
     hooks/useAuth.ts                 (validateSession, getCurrentUser, logout)
     lib/ssoClient.ts                 (axios instance with SSO interceptors)
     types/index.ts                   (SSOUser, SessionValidationResponse, LoginResult)
     index.ts                         (barrel export)
   ```

3. *Publish to GitHub Packages*:
   ```json
   // package.json
   { "name": "@openclaw/identity-sdk", "version": "1.0.0" }
   ```

4. *Consumer migration* (ondc-seller, ondc-buyer, flatwatch frontend):
   ```typescript
   // Before (each app has its own copy)
   import { WalletProvider } from '../providers/WalletProvider'
   import { validateSession } from '../lib/api'
   
   // After
   import { WalletProvider, useAuth } from '@openclaw/identity-sdk'
   ```

5. *Remove duplicated files* from each consumer after SDK adoption

---

## Phase 5 — Solana Programs (aadhaar-chain feat-015–017)

### Problem
feat-015 (Solana service layer), feat-016 (Identity Core DID registry program), feat-017 (Credential Vault program) are all `pending`. Without these, the blockchain is not actually used — identity is only stored in-memory.

### Fix

1. *feat-015 — Solana service layer* (`gateway/app/solana_service.py`):
   ```python
   from solders.keypair import Keypair
   from anchorpy import Program, Provider, Wallet
   
   class SolanaService:
       async def create_identity_pda(wallet_address: str, commitment: str) -> str
       async def get_identity(wallet_address: str) -> Optional[Identity]
       async def issue_credential(subject: str, claims: dict) -> str
       async def revoke_credential(credential_id: str) -> bool
   ```

2. *feat-016 — Identity Core program* (Anchor/Rust):
   - PDA structure: `[b"identity", wallet_pubkey]`
   - Fields: did, owner, commitment, verification_bitmap, created_at
   - Instructions: `create_identity`, `update_identity`, `verify_document`

3. *feat-017 — Credential Vault program* (Anchor/Rust):
   - PDA structure: `[b"credential", subject_pubkey, credential_type]`
   - Instructions: `issue_credential`, `revoke_credential`, `verify_credential`

4. Wire `gateway/app/routes.py` identity endpoints to `SolanaService` (replacing in-memory dicts)

---

## Phase 6 — Brand360 Monitors Ecosystem

### Fix
- Add 4 brand configs to Brand360: aadhaar-chain, ondc-seller, ondc-buyer, flatwatch
- Track LLM mentions of product names across ChatGPT, Perplexity, Gemini
- Wire `promptlog` as shared observability — all LLM calls across apps log to promptlog
- Content gaps in Brand360 feed back to product backlog

---

## Execution Order & Dependencies

```
Phase 1 (aadhaar-chain SSO API)
  └─► Phase 2 (flatwatch SSO wiring)     ← blocked until /api/auth/validate is live
  └─► Phase 3 (Beckn layer)              ← parallel, independent of SSO completeness
  └─► Phase 4 (identity-sdk)             ← parallel, needs Phase 1 types finalized
        └─► Phase 5 (Solana programs)    ← blocked until gateway routes stable
              └─► Phase 6 (Brand360)     ← last, after apps are production-ready
```

## Issue Tracker

| # | Issue | Repo | Fix | Priority |
|---|-------|------|-----|----------|
| I-01 | SSO auth routes missing from gateway | aadhaar-chain | Add /api/auth/* routes | P0 |
| I-02 | In-memory storage (verifications, identities dicts) | aadhaar-chain | SQLAlchemy + SQLite/PG | P0 |
| I-03 | venv/ committed to git | aadhaar-chain | .gitignore + BFG clean | P1 |
| I-04 | localhost:8000 hardcoded in frontend/lib/api.ts | aadhaar-chain | NEXT_PUBLIC_API_URL env | P1 |
| I-05 | flatwatch auth uses MOCK_USERS, hardcoded JWT secret | flatwatch | Wire validate_sso_session, env JWT_SECRET | P0 |
| I-06 | AADHAAR_CHAIN_URL not set in flatwatch | flatwatch | Add env var + config.py | P0 |
| I-07 | No Beckn protocol adapter | ondc-seller | Create src/lib/beckn.ts | P0 |
| I-08 | No Beckn protocol adapter | ondc-buyer | Create src/lib/beckn.ts | P0 |
| I-09 | node_modules/ + dist/ committed to git | ondc-buyer | .gitignore + git rm --cached | P1 |
| I-10 | WalletProvider copy-pasted across 3 repos | all | @openclaw/identity-sdk package | P2 |
| I-11 | feat-012–014 pending (routes with persistence) | aadhaar-chain | Implement + integrate SQLAlchemy | P0 |
| I-12 | feat-015–017 pending (Solana programs) | aadhaar-chain | Anchor programs + service layer | P1 |
| I-13 | flatwatch frontend has no WalletProvider | flatwatch | Add WalletProvider, remove email/pw login | P1 |
| I-14 | VITE_BECKN_GATEWAY_URL not set | ondc-seller/buyer | Add env var, wire to ONDC sandbox | P1 |
