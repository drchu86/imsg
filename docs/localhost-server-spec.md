# Localhost Server Specification for `imsg`

Status: Draft

Owner: `imsg` maintainers

Last updated: 2026-03-03

## 1. Purpose

Define the architecture and API for a localhost-only server that replaces the current stdin/stdout `imsg rpc` interface while preserving all existing capabilities:

- List chats
- Fetch message history
- Subscribe to live message events
- Send outbound messages (text and attachments)
- Query handle metadata

This document is transport-agnostic with concrete profiles for:

- Plain JSON over HTTP (REST-style)
- JSON-RPC 2.0 over HTTP
- Optional gRPC (future phase)

## 2. Scope

In scope:

- Replace `imsg rpc` stdio transport with a long-running localhost server
- Preserve current business behavior from `IMsgCore`
- Maintain feature parity with current RPC methods
- Provide a migration path for existing Go integrations

Out of scope (initial phases):

- Remote network exposure beyond localhost
- Multi-tenant auth or internet-facing hardening
- iCloud/web relay features
- macOS launchd packaging details (may be documented separately)

## 3. Design Goals

- Local-first: bind only to loopback (`127.0.0.1` and/or `::1`)
- Compatibility: map 1:1 with current RPC semantics and payload shapes where practical
- Incremental migration: support existing clients during transition
- Reliability: reconnectable live streams using `since_rowid`
- Observability: predictable errors and structured logs
- Safety: no unintended DB writes; preserve read-only behavior for message retrieval

## 4. Non-Goals

- No public API stability guarantees in v1 (internal homelab use)
- No cross-host clustering
- No bypass of macOS TCC constraints (Full Disk Access, Automation)

## 5. Current Baseline

Current architecture uses:

- Transport: newline-delimited JSON over stdin/stdout (`imsg rpc`)
- Protocol: JSON-RPC 2.0 semantics
- Core logic: `IMsgCore` (`MessageStore`, `MessageWatcher`, `MessageSender`)

Key implementation references:

- `Sources/imsg/RPCServer.swift`
- `Sources/imsg/RPCPayloads.swift`
- `Sources/IMsgCore/*`

## 6. Target Architecture

### 6.1 Components

- `TransportServer` (new): accepts HTTP requests on localhost
- `MessageService` (new/refactor): transport-independent application service layer
- `IMsgCore` (existing): DB access, watch stream, send logic
- `SubscriptionManager` (new): manages live stream sessions/subscriptions

### 6.2 Request Flow

1. Client calls localhost endpoint
2. Transport decodes request and validates payload
3. Service layer executes operation via `IMsgCore`
4. Transport encodes success/error response
5. For watch streams, server emits events until disconnect/cancel

### 6.3 Concurrency Model

- Per-request task execution using Swift concurrency
- Shared subscription registry protected by actor or lock
- Each live stream uses cancellable task tied to client connection

## 7. Transport Profiles

## 7.1 Profile A (Recommended): REST JSON + SSE

Use plain JSON over HTTP for request/response operations and Server-Sent Events (SSE) for live watch events.

Pros:

- Simplest client integration (Go, curl, browser tooling)
- No protobuf/toolchain overhead
- Easy debugging with standard HTTP tools

Cons:

- SSE is unidirectional; control operations remain separate HTTP calls

## 7.2 Profile B: JSON-RPC 2.0 over HTTP

Expose a single endpoint (`POST /rpc`) with method dispatch preserving existing RPC method names.

Pros:

- Minimal client-side migration from stdio RPC
- Existing method semantics remain intact

Cons:

- Less idiomatic HTTP API surface
- Streaming still needs SSE/WebSocket side-channel

## 7.3 Profile C (Optional Future): gRPC

Expose protobuf-defined unary RPCs and server-streaming for watch.

Pros:

- Strongly typed contracts and code generation
- Built-in streaming model

Cons:

- More moving parts and operational complexity
- Higher friction for quick scripting and ad-hoc debugging

Recommendation:

- Phase 1: Profile A
- Phase 2: add Profile B shim if needed for compatibility
- Phase 3: evaluate gRPC only if typed SDK generation is a priority

## 8. Localhost Security Model

Hard requirements:

- Bind only to loopback interfaces
- Default host: `127.0.0.1`
- Default port: `3939` (configurable)
- Reject non-loopback `Host` values unless explicitly allowed

Recommended safeguards:

- Static bearer token from env (`IMSG_HTTP_TOKEN`) for local process isolation
- Per-request request-id header for traceability
- Rate limits on send endpoint (basic abuse guard)

Explicitly not supported in v1:

- TLS termination in-process
- Public/internet exposure

## 9. API Specification (Profile A)

Base URL:

- `http://127.0.0.1:3939/v1`

Content type:

- Request: `application/json`
- Response: `application/json`

### 9.1 Health

`GET /healthz`

Response 200:

```json
{ "ok": true, "version": "0.0.0", "uptime_seconds": 12 }
```

### 9.2 List Chats

`GET /chats?limit=20`

Response 200:

```json
{
  "chats": [
    {
      "id": 1,
      "identifier": "iMessage;+;chat123",
      "guid": "iMessage;+;chat123",
      "name": "Group Chat",
      "service": "iMessage",
      "last_message_at": "2026-03-03T00:00:00Z",
      "participants": ["+15551234567"],
      "is_group": true
    }
  ]
}
```

### 9.3 Message History

`POST /messages/history`

Request:

```json
{
  "chat_id": 1,
  "limit": 50,
  "participants": ["+15551234567"],
  "start": "2026-01-01T00:00:00Z",
  "end": "2026-02-01T00:00:00Z",
  "attachments": true
}
```

Response 200:

```json
{ "messages": [ { "id": 100, "chat_id": 1, "text": "hello" } ] }
```

### 9.4 Send Message

`POST /messages/send`

Request (direct):

```json
{
  "to": "+15551234567",
  "text": "hello",
  "service": "auto",
  "region": "US"
}
```

Request (chat-targeted):

```json
{
  "chat_id": 1,
  "text": "hello",
  "service": "auto"
}
```

Validation rules:

- Exactly one target mode:
  - direct (`to`), or
  - chat target (`chat_id` or `chat_identifier` or `chat_guid`)
- `text` or `file` is required

Response 200:

```json
{ "ok": true }
```

### 9.5 Handle Metadata

`GET /handles/{id}`

Response 200:

```json
{
  "id": "+15551234567",
  "service": "iMessage",
  "country": "US",
  "uncanonicalized_id": "(555) 123-4567"
}
```

Response 404:

```json
{ "error": { "code": "NOT_FOUND", "message": "handle not found" } }
```

### 9.6 Live Watch Stream (SSE)

`GET /watch/stream?chat_id=1&since_rowid=120&attachments=true`

SSE event types:

- `message`
- `error`
- `heartbeat`

Example stream:

```text
event: message
data: {"subscription":1,"message":{"id":121,"chat_id":1,"text":"hi"}}

event: heartbeat
data: {"ts":"2026-03-03T00:00:05Z"}
```

Behavior:

- Stream starts immediately
- If `since_rowid` provided, only emit messages with rowid greater than it
- On server-side watcher failure, emit `error` then close stream
- Client reconnect strategy uses last seen message `id` as next `since_rowid`

### 9.7 Optional Explicit Subscription Endpoints

If server needs explicit subscription IDs (for parity with existing RPC):

- `POST /watch/subscribe` returns `{ "subscription": n }`
- `POST /watch/unsubscribe` with `{ "subscription": n }`

For pure SSE implementations, these endpoints can be omitted.

## 10. API Specification (Profile B)

Single endpoint:

- `POST /rpc`

Request/response follows JSON-RPC 2.0.

Supported methods (must match existing names initially):

- `chats.list`
- `messages.history`
- `watch.subscribe`
- `watch.unsubscribe`
- `send`
- `handles.info`

Streaming options:

- Keep `watch.subscribe` IDs and deliver events via `/watch/stream?subscription=n`, or
- Return stream URL from `watch.subscribe`

## 11. Error Contract

For Profile A, standard error envelope:

```json
{
  "error": {
    "code": "INVALID_ARGUMENT",
    "message": "chat_id is required",
    "details": null
  }
}
```

HTTP mapping:

- `400` invalid payload/validation failures
- `401` missing/invalid auth token (if enabled)
- `404` unknown resource
- `409` conflict (e.g., invalid subscription state)
- `500` internal server error
- `503` dependency unavailable (Messages DB unavailable/permission denied)

Preserve useful detail for known failures (e.g., TCC permission issues) without leaking sensitive local paths unnecessarily.

## 12. Compatibility Matrix

Behavior parity targets with current stdio RPC:

- Same filtering semantics (`participants`, `start`, `end`)
- Same message ordering and `since_rowid` behavior
- Same send validation rules (`to` vs `chat_*`, `text|file` required)
- Same attachment/reaction inclusion toggles

Intentional differences:

- Transport and framing only
- Error shape changes for Profile A (unless strict compatibility mode requested)

## 13. Migration Plan

### Phase 0: Internal Refactor

- Extract method handlers from `RPCServer` into transport-independent service APIs
- Keep stdio RPC functional

### Phase 1: HTTP Server Alpha (localhost)

- Add new command (example): `imsg serve --host 127.0.0.1 --port 3939`
- Implement Profile A endpoints: health, chats, history, send, handles, watch stream
- Add integration tests for request/response and stream reconnect behavior

### Phase 2: Client Cutover

- Update Go bridge to use HTTP/SSE
- Keep stdio RPC as fallback for one release window
- Validate parity in staging/homelab

### Phase 3: Remove stdio RPC

- Mark `imsg rpc` deprecated
- Remove after agreed deprecation period
- Keep payload models stable where possible

## 14. Operational Model (Homelab)

Target deployment:

- macOS host (eventually Mac mini in homelab)
- Server process runs as dedicated user with required TCC permissions
- Bound to loopback only

Process supervision options:

- Manual CLI (`imsg serve`)
- launchd agent (recommended for always-on setup)

Runtime configuration:

- `IMSG_HOST` (default `127.0.0.1`)
- `IMSG_PORT` (default `3939`)
- `IMSG_HTTP_TOKEN` (optional but recommended)
- `IMSG_DB_PATH` (optional override)

## 15. Testing Strategy

Unit tests:

- Request validation
- Endpoint-to-service mapping
- Error mapping

Integration tests:

- End-to-end against in-memory/test SQLite fixtures
- SSE stream delivery and reconnect using `since_rowid`
- Send endpoint with stubbed sender

Manual verification checklist:

- Full Disk Access missing => clear actionable error
- Automation permission missing => clear actionable error
- Watch stream resumes without data loss when reconnecting

## 16. Observability

Structured logs (JSON recommended):

- `ts`, `level`, `request_id`, `endpoint`, `duration_ms`, `status`
- stream lifecycle events: subscribe/connect/disconnect/error

Metrics (optional initially):

- request count/latency by endpoint
- active stream count
- send success/failure count

## 17. Open Decisions

1. Primary profile in v1: Profile A only, or A+B together?
2. Auth for localhost v1: required token or optional token?
3. Stream model: pure SSE connection-per-client, or explicit subscription IDs?
4. Deprecation window length for `imsg rpc`.

## 18. Acceptance Criteria

The stdio RPC replacement is complete when all are true:

- HTTP server supports all current RPC capabilities
- Go integration runs without stdio transport
- Localhost-only binding enforced by default
- Reconnect-safe streaming with `since_rowid` verified
- Documented migration complete and `imsg rpc` deprecation plan approved

## 19. Appendix: Endpoint-to-RPC Mapping

- `GET /chats` -> `chats.list`
- `POST /messages/history` -> `messages.history`
- `POST /messages/send` -> `send`
- `GET /handles/{id}` -> `handles.info`
- `GET /watch/stream` -> `watch.subscribe` + stream notifications

