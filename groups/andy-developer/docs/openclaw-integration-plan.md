# OpenClaw Platform Integration Plan

## Vision
**Identity → Commerce → Social Impact** - A unified transparency ecosystem.

---

## Phase 1: Foundation (Weeks 1-4)

### 1.1 Shared Authentication Gateway
- Create centralized auth service at `auth.openclaw.io`
- Aadhaar SSO as primary identity provider
- JWT token federation across all Platforms
- Session management with refresh tokens

### 1.2 Unified User Profiles
- Cross-platform user registry
- Role mapping (buyer/seller/admin/society_member)
- KYC status propagation

### 1.3 API Gateway
- Single entry point for all services
- Rate limiting & throttling
- Request routing

---

## Phase 2: Commerce Integration (Weeks 5-8)

### 2.1 ONDC Protocol Enhancement
- Add Aadhaar-linked buyer/seller verification
- Transparent pricing display
- Real-time transaction logging

### 2.2 Escrow & Transparency Ledger
- Smart contract for fund holding
- Multi-party approval workflows

### 2.3 Dispute Resolution Module
- Evidence submission system
- Mediator assignment

---

## Phase 3: Social Impact Layer (Weeks 9-12)

### 3.1 Society Procurement Module
- Bulk purchase workflows
- Budget allocation per society

### 3.2 Welfare Distribution
- Scheme-based item catalogs
- Beneficiary verification

### 3.3 Impact Analytics
- Social good metrics dashboard
- Transparency reports

---

## Phase 4: Cross-Platform Features (Weeks 13-16)

### 4.1 Unified Dashboard
- Single sign-on across all platforms
- Activity feeds from all services

### 4.2 Reporting & Audit
- Cross-platform transaction search

### 4.3 Mobile App
- React Native wrapper
- Offline-first architecture

---

## Current Status

| Repo | Branch | Status |
|------|--------|--------|
| aadhaar-chain | jarvis-push-w1-rerun | ✅ Pushed |
| flatwatch | jarvis-phase2-flatwatch-v2 | ⚠️ Implemented, not pushed |
| ondc-buyer | jarvis-push-w2-rerun | ✅ Pushed |
| ondc-seller | jarvis-phase4-v3 | ⚠️ Implemented, not pushed |

---

## Next Steps

Waiting for workers to connect to dispatch Phase 1.1 Auth Gateway task.
