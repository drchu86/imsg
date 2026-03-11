# Localhost Server Implementation Checklist

Status: Draft

Last updated: 2026-03-03

Reference:

- `docs/localhost-server-spec.md`

## 1. Rollout Summary

Goal: replace stdin/stdout `imsg rpc` with a localhost-only server.

Recommended sequence:

1. Internal refactor (service extraction)
2. HTTP JSON endpoints (unary operations)
3. SSE streaming (`watch` replacement)
4. Go client cutover
5. Deprecate and remove stdio RPC

## 2. Phase 0: Internal Refactor (No Behavior Changes)

## 2.1 Service Extraction

- [ ] Create transport-independent service layer (example: `MessageService`)
- [ ] Move method logic from `RPCServer` handlers into service methods:
  - [ ] list chats
  - [ ] fetch history
  - [ ] send message
  - [ ] handle info
  - [ ] watch stream subscription flow
- [ ] Keep payload shaping centralized (`RPCPayloads` or transport-neutral payload module)
- [ ] Preserve existing validation semantics (`to` vs `chat_*`, `text|file` required)

## 2.2 Backward Compatibility

- [ ] Keep `imsg rpc` command working via the new service layer
- [ ] Ensure all existing RPC tests still pass (or are intentionally updated with rationale)

## 2.3 Exit Criteria

- [ ] No external behavior changes to `imsg rpc`
- [ ] Test suite green (or expected known failures documented)
- [ ] No duplicated business logic between transport layers

## 3. Phase 1: Localhost HTTP Server (Unary Endpoints)

## 3.1 New Command Surface

- [ ] Add CLI command (example): `imsg serve`
- [ ] Support flags/env:
  - [ ] host (`127.0.0.1` default)
  - [ ] port (`3939` default)
  - [ ] db path override
  - [ ] optional auth token

## 3.2 HTTP Endpoints (Profile A)

- [ ] `GET /v1/healthz`
- [ ] `GET /v1/chats?limit=N`
- [ ] `POST /v1/messages/history`
- [ ] `POST /v1/messages/send`
- [ ] `GET /v1/handles/{id}`

## 3.3 Error Handling

- [ ] Implement unified error envelope for REST profile
- [ ] Map errors to HTTP status codes:
  - [ ] 400 invalid arguments
  - [ ] 401 auth failures (if token enabled)
  - [ ] 404 not found
  - [ ] 409 conflict
  - [ ] 500 internal
  - [ ] 503 dependency unavailable (DB/TCC)

## 3.4 Localhost Safety

- [ ] Bind to loopback only by default
- [ ] Prevent accidental non-local binding unless explicitly configured
- [ ] Add warning log when non-loopback bind is requested

## 3.5 Exit Criteria

- [ ] All unary endpoints functional and parity-tested against current RPC behavior
- [ ] Curl-level manual tests documented
- [ ] Localhost-only default verified

## 4. Phase 2: Streaming (SSE)

## 4.1 Streaming Endpoint

- [ ] Implement `GET /v1/watch/stream`
- [ ] Support query params:
  - [ ] `chat_id`
  - [ ] `since_rowid`
  - [ ] `participants`
  - [ ] `start` / `end`
  - [ ] `attachments`

## 4.2 Event Model

- [ ] Emit SSE events:
  - [ ] `message`
  - [ ] `error`
  - [ ] `heartbeat`
- [ ] Ensure watcher errors are sent before stream closes
- [ ] Ensure disconnect cancels background tasks cleanly

## 4.3 Reconnect Semantics

- [ ] Confirm client can resume with last seen message `id` as `since_rowid`
- [ ] Confirm no message loss across controlled reconnects

## 4.4 Exit Criteria

- [ ] Streaming stable in long-running test
- [ ] Reconnect scenarios validated
- [ ] No leaked tasks/subscriptions after disconnects

## 5. Phase 3: Compatibility Layer Decision

Choose one:

- [ ] Option A: REST+SSE only (no HTTP JSON-RPC shim)
- [ ] Option B: add `POST /rpc` JSON-RPC compatibility shim

If Option B:

- [ ] Implement method mapping for:
  - [ ] `chats.list`
  - [ ] `messages.history`
  - [ ] `watch.subscribe`
  - [ ] `watch.unsubscribe`
  - [ ] `send`
  - [ ] `handles.info`
- [ ] Document streaming relationship between JSON-RPC calls and SSE endpoint

## 6. Phase 4: Go Client Cutover

## 6.1 Client Changes

- [ ] Replace stdio process RPC transport with HTTP client
- [ ] Add SSE consumer with reconnect/backoff
- [ ] Persist last seen `id` for reconnect (`since_rowid`)

## 6.2 Reliability

- [ ] Backoff policy for server restarts/crashes
- [ ] Idempotent handling for duplicate notifications after reconnect

## 6.3 Exit Criteria

- [ ] End-to-end messaging loop runs via HTTP transport only
- [ ] Stdio RPC no longer required by Go integration

## 7. Phase 5: Deprecation and Removal of `imsg rpc`

## 7.1 Deprecation

- [ ] Mark `imsg rpc` deprecated in docs and CLI help
- [ ] Provide migration instructions with examples

## 7.2 Removal

- [ ] Remove `rpc` command and stdio server implementation
- [ ] Remove obsolete tests/docs
- [ ] Keep payload parity docs for HTTP API

## 7.3 Exit Criteria

- [ ] No runtime dependency on stdio RPC remains
- [ ] All docs point to localhost server transport

## 8. Test Checklist

## 8.1 Unit Tests

- [ ] Request parsing and validation for each endpoint
- [ ] Error mapping tests
- [ ] Service-layer tests independent of transport

## 8.2 Integration Tests

- [ ] History parity (filters, limits, attachments)
- [ ] Send validation parity
- [ ] Handle lookup behavior
- [ ] SSE stream delivery
- [ ] SSE reconnect with `since_rowid`

## 8.3 Manual Verification

- [ ] `curl GET /v1/healthz`
- [ ] `curl GET /v1/chats`
- [ ] `curl POST /v1/messages/history`
- [ ] `curl POST /v1/messages/send`
- [ ] `curl -N GET /v1/watch/stream`
- [ ] Simulate TCC failures and verify actionable errors

## 9. Operational Checklist (Homelab Mac mini)

- [ ] Dedicated macOS user/service account selected
- [ ] Full Disk Access granted to runtime process
- [ ] Automation permission granted for Messages
- [ ] Local firewall rules reviewed
- [ ] launchd/plist setup completed (if always-on)
- [ ] Startup/restart behavior verified
- [ ] Log location and rotation defined

## 10. Done Definition

Project is complete when:

- [ ] HTTP localhost server provides full feature parity
- [ ] Go integration is fully cut over
- [ ] Streaming reliability validated under reconnect scenarios
- [ ] `imsg rpc` removed (or explicitly retained with rationale)
- [ ] Docs are updated and consistent (`rpc.md`, integration docs, README)

