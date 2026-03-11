# `imsg serve` — HTTP Server

`imsg serve` runs a long-lived localhost HTTP server that any process can talk to over plain HTTP. It exposes the same capabilities as `imsg rpc` (chats, history, send, watch) but without requiring a subprocess spawn per client.

`imsg rpc` remains functional but is deprecated.

---

## Launching

```bash
# defaults: 127.0.0.1:3939
imsg serve

# custom port
imsg serve --port 8080

# custom bind address (loopback only — do not expose externally)
imsg serve --host 127.0.0.1 --port 3939

# custom database path
imsg serve --db ~/Library/Messages/chat.db

# with bearer token auth
IMSG_HTTP_TOKEN=your-secret-token imsg serve
```

The server prints a startup line and runs until interrupted (Ctrl-C or SIGTERM):

```
imsg serve: listening on http://127.0.0.1:3939/v1
```

---

## Running as a launchd Agent (always-on)

Create `~/Library/LaunchAgents/com.imsg.serve.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.imsg.serve</string>

  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/imsg</string>
    <string>serve</string>
    <string>--port</string>
    <string>3939</string>
  </array>

  <key>EnvironmentVariables</key>
  <dict>
    <key>IMSG_HTTP_TOKEN</key>
    <string>your-secret-token</string>
  </dict>

  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>

  <key>StandardOutPath</key>
  <string>/tmp/imsg-serve.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/imsg-serve.log</string>
</dict>
</plist>
```

Load it:

```bash
launchctl load ~/Library/LaunchAgents/com.imsg.serve.plist

# check it started
launchctl list | grep imsg
curl http://127.0.0.1:3939/v1/healthz
```

Unload:

```bash
launchctl unload ~/Library/LaunchAgents/com.imsg.serve.plist
```

> **Full Disk Access required.** The user running `imsg serve` must have Full Disk Access granted in System Settings → Privacy & Security → Full Disk Access. This is the same requirement as `imsg rpc`.

---

## Bearer Token Auth

Auth is **optional** but recommended when other local processes share the machine.

Set `IMSG_HTTP_TOKEN` in the environment before starting the server. If the variable is absent, all requests are accepted without authentication. If it is set, every request must include:

```
Authorization: Bearer <token>
```

Missing or incorrect tokens get a `401` response:

```json
{ "error": { "code": "UNAUTHORIZED", "message": "Invalid or missing token" } }
```

### Where to store the token

**For manual use**, export it in your shell profile (`~/.zshrc` / `~/.bashrc`):

```bash
export IMSG_HTTP_TOKEN="$(openssl rand -hex 32)"
```

**For launchd**, put it in the `EnvironmentVariables` dict of the plist (shown above). Do not commit the plist with the token in it — use a separate file or a secrets manager.

**For Go / other daemons**, read the token from an env var or a local secrets file at startup and pass it as the `Authorization` header on every request.

---

## Base URL

```
http://127.0.0.1:3939/v1
```

All endpoints live under `/v1`. The server only binds to `127.0.0.1` by default — it is not reachable from other machines.

---

## Endpoints

### `GET /v1/healthz`

Returns server status, version, and uptime. No auth required even when a token is configured (useful for health checks).

```bash
curl http://127.0.0.1:3939/v1/healthz
```

```json
{ "ok": true, "version": "0.4.1", "uptime_seconds": 42 }
```

---

### `GET /v1/chats?limit=N`

Lists recent conversations, ordered by most recent message.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `limit` | int | 20 | Max chats to return |

```bash
curl http://127.0.0.1:3939/v1/chats?limit=5
```

```json
{
  "chats": [
    {
      "id": 4392,
      "identifier": "+15551234567",
      "guid": "any;-;+15551234567",
      "name": "",
      "service": "iMessage",
      "last_message_at": "2026-03-03T19:13:12.596Z",
      "participants": ["+15551234567"],
      "is_group": false
    }
  ]
}
```

---

### `POST /v1/messages/history`

Returns messages for a chat, newest first.

```bash
curl -X POST http://127.0.0.1:3939/v1/messages/history \
  -H 'Content-Type: application/json' \
  -d '{"chat_id": 4392, "limit": 10}'
```

**Request body:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `chat_id` | int | yes | Chat row ID (from `/v1/chats`) |
| `limit` | int | no (50) | Max messages |
| `participants` | string[] | no | Filter by sender handle |
| `start` | ISO8601 | no | Earliest date (inclusive) |
| `end` | ISO8601 | no | Latest date (exclusive) |
| `since_rowid` | int | no | Only return messages with row ID > this value |
| `attachments` | bool | no (false) | Include attachment + reaction metadata |

```json
{
  "messages": [
    {
      "id": 641579,
      "chat_id": 4392,
      "guid": "4CBEB06A-2FFF-484A-98C1-B38557722A41",
      "sender": "+15551234567",
      "is_from_me": false,
      "text": "hey",
      "service": "iMessage",
      "created_at": "2026-03-03T19:13:12.596Z",
      "attachments": [],
      "reactions": [],
      "chat_identifier": "+15551234567",
      "chat_guid": "any;-;+15551234567",
      "chat_name": "",
      "participants": ["+15551234567"],
      "is_group": false,

      "is_sent": true,
      "is_delivered": true,
      "is_read": true,
      "error": 0,
      "date_delivered": "2026-03-03T19:13:14.000Z",
      "date_read": "2026-03-03T19:14:02.000Z",

      "item_type": 0,
      "was_downgraded": false,
      "is_spam": false
    }
  ]
}
```

**Message fields reference:**

| Field | Type | Description |
|-------|------|-------------|
| `id` | int | Row ID — use as `since_rowid` for stream reconnect |
| `chat_id` | int | Chat this message belongs to |
| `guid` | string | Apple's internal message identifier |
| `sender` | string | Handle (phone/email). Empty for your own messages — check `is_from_me`. |
| `service` | string | `"iMessage"` or `"SMS"` |
| `is_from_me` | bool | `true` = you sent it |
| `text` | string | Message text content |
| `created_at` | ISO8601 | When the message was created |
| `is_sent` | bool | Left your device |
| `is_delivered` | bool | Confirmed received (iMessage only) |
| `is_read` | bool | Read receipt received (iMessage only) |
| `error` | int | `0` = ok. Non-zero = problem. `is_from_me && !is_delivered && error != 0` = "Not Delivered" |
| `date_delivered` | ISO8601? | When delivered (absent if not yet delivered) |
| `date_read` | ISO8601? | When read (absent if not yet read) |
| `date_edited` | ISO8601? | When the message was edited (absent if never edited) |
| `item_type` | int | `0` = normal message. Non-zero = group system event (join/leave/rename) — filter these out if you only want real messages |
| `group_title` | string? | New group name, present on rename events (`item_type = 2`) |
| `group_action_type` | int? | `0` = member added, `1` = member removed. Present when `item_type != 0` |
| `was_downgraded` | bool | iMessage fell back to SMS |
| `expressive_send_style_id` | string? | Message effect, e.g. `com.apple.MobileSMS.expressivesend.impact` (Slam) |
| `balloon_bundle_id` | string? | iMessage app extension, e.g. `...gamepigeon.ext`, `...PeerPaymentMessagesExtension` |
| `thread_originator_guid` | string? | GUID of the root message in a thread |
| `reply_to_guid` | string? | GUID of the specific message being replied to |
| `subject` | string? | MMS/SMS subject line |
| `is_spam` | bool | Marked as spam |
| `destination_caller_id` | string? | For `is_from_me` messages, the Apple ID / phone number the message was sent from. Useful when the account has multiple numbers. |
| `attachments` | array | Attachment metadata (populated when `attachments=true`) |
| `reactions` | array | Reactions on this message (populated when `attachments=true`) |

**Attachment fields** (each item in `attachments`):

| Field | Type | Description |
|-------|------|-------------|
| `filename` | string | Raw path from the DB (may contain `~`) |
| `original_path` | string | Tilde-expanded absolute path on disk — use this to read the file |
| `transfer_name` | string | Display name (e.g. `photo.jpg`) |
| `mime_type` | string | e.g. `image/jpeg`, `video/mp4` |
| `uti` | string | Apple Uniform Type Identifier, e.g. `public.jpeg` |
| `total_bytes` | int | File size in bytes |
| `is_sticker` | bool | `true` if this is an iMessage sticker |
| `missing` | bool | `true` if the file doesn't exist at `original_path` |
| `transfer_state` | int | `0` = not started, `1` = in progress, `2` = downloaded, `5` = failed |

Only read the file when `missing: false` and `transfer_state: 2`.

**Reaction event fields** (present when `is_reaction=true`):

| Field | Type | Description |
|-------|------|-------------|
| `is_reaction` | bool | `true` if this message is a reaction event (tapback) |
| `reaction_type` | string? | Reaction name: `"love"`, `"like"`, `"dislike"`, `"laugh"`, `"emphasize"`, `"question"` |
| `reaction_emoji` | string? | Emoji for the reaction, e.g. `"❤️"` |
| `is_reaction_add` | bool? | `true` = reaction added, `false` = reaction removed |
| `reacted_to_guid` | string? | GUID of the message that was reacted to |

---

### `POST /v1/messages/send`

Sends a message. Requires Automation permission for Messages.app.

**Direct send** (to a phone number or email):

```bash
curl -X POST http://127.0.0.1:3939/v1/messages/send \
  -H 'Content-Type: application/json' \
  -d '{"to": "+15551234567", "text": "hello", "service": "auto"}'
```

**Chat-targeted send** (reply into an existing chat, required for group chats):

```bash
curl -X POST http://127.0.0.1:3939/v1/messages/send \
  -H 'Content-Type: application/json' \
  -d '{"chat_id": 4392, "text": "hello"}'
```

**Request body:**

| Field | Type | Notes |
|-------|------|-------|
| `to` | string | Recipient handle. Mutually exclusive with `chat_*` fields. |
| `chat_id` | int | Preferred chat target. Use instead of `chat_identifier`/`chat_guid`. |
| `chat_identifier` | string | Fallback chat target. |
| `chat_guid` | string | Fallback chat target. |
| `text` | string | Message text. At least `text` or `file` required. |
| `file` | string | Absolute path to attachment file. |
| `service` | string | `"auto"` (default), `"iMessage"`, or `"SMS"`. |
| `region` | string | Region code for SMS normalization (default `"US"`). |

```json
{ "ok": true, "since_rowid": 641579 }
```

Use `since_rowid` to poll for the sent message after delivery: call `POST /v1/messages/history` with `since_rowid` set to this value to fetch messages that arrived after the send (including your own outbound message once it's written to the DB).

---

### `GET /v1/handles/{id}`

Looks up metadata for a phone number or email handle. URL-encode `+` as `%2B`.

```bash
curl http://127.0.0.1:3939/v1/handles/%2B15551234567
```

```json
{
  "id": "+15551234567",
  "service": "iMessage",
  "country": "US",
  "uncanonicalized_id": "(555) 123-4567"
}
```

Returns `404` if the handle has never appeared in the Messages database.

---

### `GET /v1/watch/stream` (SSE)

Opens a persistent Server-Sent Events stream that delivers new messages in real time.

```bash
# watch all incoming messages
curl -N http://127.0.0.1:3939/v1/watch/stream

# watch one chat, starting after a known message
curl -N "http://127.0.0.1:3939/v1/watch/stream?chat_id=4392&since_rowid=641000"
```

**Query parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `chat_id` | int | Limit to one chat |
| `since_rowid` | int | Only emit messages with rowid > this value (use last seen `id` for reconnect) |
| `participants` | string | Comma-separated handles to filter by sender |
| `start` | ISO8601 | Earliest date filter |
| `end` | ISO8601 | Latest date filter |
| `attachments` | bool | Include attachment + reaction metadata in events |

**Event types:**

| Event | When |
|-------|------|
| `message` | A new message arrived |
| `heartbeat` | Sent every 30 seconds to keep the connection alive |
| `error` | Watcher failed; stream closes after this event |

**Stream format:**

```
event: message
data: {"message": {"id": 641580, "chat_id": 4392, "text": "hey", ...}}

event: heartbeat
data: {}

event: error
data: {"message": "permission denied"}
```

**Reconnect pattern:** when your client disconnects (network blip, process restart), reconnect using the `id` of the last message you received as `since_rowid`:

```bash
curl -N "http://127.0.0.1:3939/v1/watch/stream?since_rowid=641580"
```

This guarantees no messages are skipped.

---

## Error Responses

All errors use the same envelope:

```json
{ "error": { "code": "ERROR_CODE", "message": "human readable detail" } }
```

| HTTP status | Code | When |
|-------------|------|------|
| 400 | `INVALID_ARGUMENT` | Missing required field or invalid value |
| 400 | `INVALID_JSON` | Request body is not valid JSON |
| 401 | `UNAUTHORIZED` | Token missing or wrong |
| 404 | `NOT_FOUND` | Handle not found |
| 500 | `INTERNAL` | Unexpected server error |
| 503 | `UNAVAILABLE` | Messages DB inaccessible (Full Disk Access missing) |

---

## Auth Header Example

```bash
TOKEN=your-secret-token

curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:3939/v1/healthz
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:3939/v1/chats?limit=5
curl -N -H "Authorization: Bearer $TOKEN" http://127.0.0.1:3939/v1/watch/stream
```

---

## Go Integration Example

```go
package main

import (
    "bufio"
    "encoding/json"
    "fmt"
    "net/http"
    "strings"
)

const base = "http://127.0.0.1:3939/v1"

func newReq(method, path string, body io.Reader) *http.Request {
    req, _ := http.NewRequest(method, base+path, body)
    req.Header.Set("Authorization", "Bearer "+os.Getenv("IMSG_HTTP_TOKEN"))
    req.Header.Set("Content-Type", "application/json")
    return req
}

// Watch the SSE stream and print each message.
func watchMessages(chatID int, sinceRowID int64) {
    url := fmt.Sprintf("%s/watch/stream?chat_id=%d&since_rowid=%d", base, chatID, sinceRowID)
    req, _ := http.NewRequest("GET", url, nil)
    req.Header.Set("Authorization", "Bearer "+os.Getenv("IMSG_HTTP_TOKEN"))

    resp, err := http.DefaultClient.Do(req)
    if err != nil {
        panic(err)
    }
    defer resp.Body.Close()

    var eventType string
    scanner := bufio.NewScanner(resp.Body)
    for scanner.Scan() {
        line := scanner.Text()
        switch {
        case strings.HasPrefix(line, "event: "):
            eventType = strings.TrimPrefix(line, "event: ")
        case strings.HasPrefix(line, "data: ") && eventType == "message":
            data := strings.TrimPrefix(line, "data: ")
            var payload map[string]any
            json.Unmarshal([]byte(data), &payload)
            fmt.Println(payload)
        }
    }
}
```

---

## Comparison with `imsg rpc`

| | `imsg rpc` | `imsg serve` |
|--|--|--|
| Transport | stdin/stdout | HTTP on localhost |
| Clients | one subprocess at a time | unlimited concurrent clients |
| Languages | Go (easy), others (awkward) | anything with HTTP |
| Reconnect | restart the process | reconnect HTTP, use `since_rowid` |
| Live messages | `watch.subscribe` notification | SSE stream |
| Status | deprecated | current |
