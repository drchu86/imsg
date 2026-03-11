# Go Integration Specification for `imsg`

This document defines the interface and architecture for building a Go-based automation layer (e.g., customer support bot) using `imsg` as the underlying macOS iMessage/SMS bridge.

## 1. Architecture Overview

The system follows a "Sidecar" pattern:
- **Backend (Go):** The "Brain." Handles business logic, customer filtering, AI generation, and state management.
- **Bridge (Swift/imsg):** The "Driver." Handles macOS-specific SQLite access, AppleScript execution, and TCC permissions.

The Go process spawns `imsg rpc` as a sub-process and communicates via **JSON-RPC 2.0** over `stdin` (requests) and `stdout` (responses and notifications).

## 2. Recommended Go Project Structure

```text
imsg-bot/
├── bin/            # Contains the compiled 'imsg' binary
├── cmd/
│   └── bot/        # Main entry point for your Go service
├── internal/
│   ├── bridge/     # Logic to manage the imsg process and JSON-RPC
│   ├── logic/      # Your customer-specific filtering and response logic
│   └── models/     # Go struct definitions for RPC payloads
├── Makefile        # Automation for building both Go and Swift
└── config.json     # Whitelist of phone numbers and group IDs
```

## 3. Communication Protocol

### 3.1 Transport

- One JSON object per line on `stdout` (newline-delimited JSON).
- Requests are sent to `imsg` `stdin`, one JSON object per line.
- Responses and notifications are read from `imsg` `stdout`.
- Distinguish responses from notifications: responses always have an `"id"` field; notifications never do.

Requests can be pipelined — you do not need to wait for a response before sending the next request. Match responses to requests by `"id"`.

### 3.2 Initialization

1. Start `imsg rpc` (optionally with `--verbose` for debug logging to stderr).
2. Send a `watch.subscribe` request to start receiving real-time messages.
3. Track the last received message `id` (rowid) in durable storage so you can pass `since_rowid` on reconnect.

### 3.3 Incoming Message (Notification)

`imsg` pushes this to `stdout` whenever a new message arrives on an active subscription.

```json
{
  "jsonrpc": "2.0",
  "method": "message",
  "params": {
    "subscription": 1,
    "message": {
      "id": 123,
      "chat_id": 5,
      "guid": "iMessage;-;+19182379858",
      "sender": "+19182379858",
      "is_from_me": false,
      "text": "How do I reset my password?",
      "service": "imessage",
      "created_at": "2024-03-02T12:00:00Z",
      "chat_identifier": "iMessage;-;+19182379858",
      "chat_guid": "iMessage;-;+19182379858",
      "chat_name": "",
      "participants": ["+19182379858"],
      "is_group": false,
      "attachments": [],
      "reactions": []
    }
  }
}
```

**Full message field reference:**

| Field | Type | Description |
|---|---|---|
| `id` | int64 | SQLite rowid — use as `since_rowid` for reconnection |
| `chat_id` | int64 | Internal chat ID |
| `guid` | string | Unique message GUID |
| `sender` | string | Sender handle (phone/email), empty if `is_from_me` |
| `is_from_me` | bool | True if you sent this message |
| `text` | string | Message body |
| `service` | string | `"imessage"`, `"sms"`, or `"rcs"` |
| `created_at` | string | ISO 8601 timestamp |
| `chat_identifier` | string | Chat identifier string |
| `chat_guid` | string | Chat GUID |
| `chat_name` | string | Group chat name, empty for DMs |
| `participants` | []string | All participant handles in the chat |
| `is_group` | bool | True if this is a group chat |
| `reply_to_guid` | string | GUID of the message being replied to (omitted if not a reply) |
| `attachments` | []object | Attachment metadata (only populated when `attachments: true`) |
| `reactions` | []object | Reactions (only populated when `attachments: true`) |

### 3.4 Subscription Error Notification

If the watcher encounters an error, it pushes an error notification. The subscription is dead at this point — re-subscribe.

```json
{
  "jsonrpc": "2.0",
  "method": "error",
  "params": {
    "subscription": 1,
    "error": { "message": "..." }
  }
}
```

## 4. RPC Methods

### `watch.subscribe`

Start receiving real-time message notifications.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "method": "watch.subscribe",
  "params": {
    "attachments": true,
    "chat_id": 5,
    "since_rowid": 122,
    "participants": ["+19182379858"],
    "start": "2024-01-01T00:00:00Z",
    "end": "2024-12-31T23:59:59Z"
  },
  "id": 1
}
```

All params are optional.

| Param | Type | Description |
|---|---|---|
| `attachments` | bool | Include attachment and reaction metadata in notifications |
| `chat_id` | int64 | Scope the stream to a single chat |
| `since_rowid` | int64 | Only emit messages with rowid > this value (use for reconnection) |
| `participants` | []string | Filter to messages from these handles |
| `start` | string | ISO 8601 lower bound on `created_at` |
| `end` | string | ISO 8601 upper bound on `created_at` |

**Response:**
```json
{ "jsonrpc": "2.0", "id": 1, "result": { "subscription": 1 } }
```

The `subscription` ID is referenced in all subsequent notifications and is required for `watch.unsubscribe`.

---

### `watch.unsubscribe`

Cancel an active subscription.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "method": "watch.unsubscribe",
  "params": { "subscription": 1 },
  "id": 2
}
```

**Response:**
```json
{ "jsonrpc": "2.0", "id": 2, "result": { "ok": true } }
```

---

### `send`

Send a message. Target either a specific chat (`chat_id`, `chat_identifier`, or `chat_guid`) **or** a direct recipient (`to`) — not both.

**Request (reply to a chat by ID):**
```json
{
  "jsonrpc": "2.0",
  "method": "send",
  "params": {
    "chat_id": 5,
    "text": "Hello! You can reset your password at example.com/reset.",
    "service": "auto"
  },
  "id": 3
}
```

**Request (send to a phone number directly):**
```json
{
  "jsonrpc": "2.0",
  "method": "send",
  "params": {
    "to": "+19182379858",
    "text": "Hey!",
    "service": "auto",
    "region": "US"
  },
  "id": 4
}
```

| Param | Type | Description |
|---|---|---|
| `chat_id` | int64 | Target chat by internal ID (mutually exclusive with `to`) |
| `chat_identifier` | string | Target chat by identifier string (mutually exclusive with `to`) |
| `chat_guid` | string | Target chat by GUID (mutually exclusive with `to`) |
| `to` | string | Direct recipient phone/email (mutually exclusive with `chat_*`) |
| `text` | string | Message body (required if `file` is omitted) |
| `file` | string | Absolute path to attachment file (required if `text` is omitted) |
| `service` | string | `"auto"`, `"imessage"`, `"sms"`, or `"rcs"` (default: `"auto"`) |
| `region` | string | Phone region code for normalization (default: `"US"`) |

**Service values:**
- `"auto"` — Checks conversation history to pick the right service; falls back iMessage → SMS.
- `"imessage"` — Force iMessage.
- `"sms"` — Force SMS.
- `"rcs"` — Force RCS (treated same as SMS in AppleScript).

**Response:**
```json
{ "jsonrpc": "2.0", "id": 3, "result": { "ok": true } }
```

---

### `chats.list`

List recent conversations.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "method": "chats.list",
  "params": { "limit": 20 },
  "id": 5
}
```

| Param | Type | Description |
|---|---|---|
| `limit` | int | Max chats to return (default: 20) |

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "result": {
    "chats": [
      {
        "id": 5,
        "identifier": "iMessage;-;+19182379858",
        "guid": "iMessage;-;+19182379858",
        "name": "",
        "service": "iMessage",
        "last_message_at": "2024-03-02T12:00:00Z",
        "participants": ["+19182379858"],
        "is_group": false
      }
    ]
  }
}
```

---

### `messages.history`

Fetch message history for a chat.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "method": "messages.history",
  "params": {
    "chat_id": 5,
    "limit": 50,
    "attachments": false,
    "start": "2024-01-01T00:00:00Z",
    "end": "2024-12-31T23:59:59Z",
    "participants": ["+19182379858"]
  },
  "id": 6
}
```

| Param | Type | Description |
|---|---|---|
| `chat_id` | int64 | **Required.** Chat to fetch history for |
| `limit` | int | Max messages to return (default: 50) |
| `attachments` | bool | Include attachment and reaction metadata |
| `start` | string | ISO 8601 lower bound |
| `end` | string | ISO 8601 upper bound |
| `participants` | []string | Filter to messages from these handles |

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 6,
  "result": { "messages": [ /* same shape as message notification payload */ ] }
}
```

---

### `handles.info`

Look up metadata for a phone/email handle. Useful for determining which service a contact uses before sending.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "method": "handles.info",
  "params": { "id": "+19182379858" },
  "id": 7
}
```

**Response (found):**
```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "result": {
    "id": "+19182379858",
    "service": "iMessage",
    "country": "us",
    "uncanonicalized_id": "+1 (918) 237-9858"
  }
}
```

**Response (not found):**
```json
{ "jsonrpc": "2.0", "id": 7, "result": null }
```

## 5. Key Go Logic Requirements

### A. The "Is From Me" Check

**CRITICAL:** Always check `message.is_from_me`. If `true`, your Go code **must ignore it** to prevent an infinite loop where the bot responds to itself.

### B. Filtering Whitelist

Implement a filter that checks the `sender` (phone/email) or `chat_id` against a whitelist before processing.

```go
func shouldProcess(msg Message) bool {
    if msg.IsFromMe { return false }
    return whitelist[msg.Sender] || whitelist[strconv.FormatInt(msg.ChatID, 10)]
}
```

Use `is_group` to apply different logic for group chats vs. direct messages.

### C. Error Handling & Recovery

If the `imsg` process exits (e.g., Mac goes to sleep, binary is updated), the Go service should:

1. Detect the pipe closure.
2. Log the event.
3. Restart the `imsg rpc` process.
4. Re-send `watch.subscribe` with `since_rowid` set to the last message `id` you received.

**Tracking `since_rowid`:** Persist the last received `message.id` (SQLite rowid) to disk or a DB so that after a crash or restart you can resume without missing messages or reprocessing old ones.

```go
// On each message received:
lastRowID = message.ID
persist(lastRowID)

// On reconnect:
subscribe(sinceRowID: loadPersistedRowID())
```

Also handle subscription error notifications (method `"error"`) from `imsg` itself — these indicate the watcher died without the process exiting, and you should re-subscribe.

### D. Request ID Management

Use a monotonically incrementing integer for request `"id"` fields. Keep a map of pending request IDs to response channels so goroutines can block waiting for their specific response while notifications are routed separately.

```go
// Routing rule: if line has "id" and ("result" or "error") → response
// If line has "method" and no "id" → notification
```

## 6. Subprocess Lifecycle Management

The Go daemon is responsible for starting, monitoring, and cleanly stopping the `imsg rpc` process.

### 6.1 Starting the Process

Use `os/exec` to spawn `imsg rpc` with stdin/stdout pipes wired up for JSON-RPC. Place the binary in `bin/imsg` relative to your daemon's working directory.

```go
func (b *Bridge) start(ctx context.Context) error {
    cmd := exec.Command("bin/imsg", "rpc")

    // Put imsg in its own process group so a kill signal
    // can be sent to the group without affecting the Go daemon.
    cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

    stdinPipe, err := cmd.StdinPipe()
    if err != nil {
        return err
    }
    stdoutPipe, err := cmd.StdoutPipe()
    if err != nil {
        return err
    }
    // Let imsg stderr pass through to your daemon's stderr for visibility.
    cmd.Stderr = os.Stderr

    if err := cmd.Start(); err != nil {
        return err
    }

    b.cmd    = cmd
    b.stdin  = stdinPipe
    b.stdout = bufio.NewScanner(stdoutPipe)
    return nil
}
```

### 6.2 The Read Loop (Goroutine)

Run a goroutine that continuously reads lines from `imsg` stdout and routes them as either responses or notifications.

```go
func (b *Bridge) readLoop(ctx context.Context) {
    for b.stdout.Scan() {
        line := b.stdout.Text()
        b.route(line) // parse JSON, dispatch to pending response or notification handler
    }
    // stdout closed — process exited or pipe broke
    b.exitCh <- struct{}{}
}
```

Start it after `cmd.Start()`:
```go
go b.readLoop(ctx)
```

### 6.3 Graceful Shutdown

Wire your daemon to OS signals using `signal.NotifyContext`. When the context is cancelled (SIGINT or SIGTERM received), signal the child process and wait for it to exit.

```go
func main() {
    ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
    defer stop()

    bridge := NewBridge()
    bridge.start(ctx)
    go bridge.readLoop(ctx)
    bridge.subscribe()

    // Run until signal
    <-ctx.Done()

    bridge.shutdown()
}

func (b *Bridge) shutdown() {
    // Graceful: give imsg a chance to clean up
    b.cmd.Process.Signal(syscall.SIGTERM)

    done := make(chan struct{})
    go func() {
        b.cmd.Wait()
        close(done)
    }()

    select {
    case <-done:
        // clean exit
    case <-time.After(5 * time.Second):
        // force kill if it didn't exit in time
        b.cmd.Process.Kill()
        b.cmd.Wait()
    }
}
```

### 6.4 Orphaned Process Risk (SIGKILL)

If the Go daemon is killed with `SIGKILL` (e.g., `kill -9` or an OS-level OOM kill), it cannot run shutdown code, and `imsg rpc` will become an **orphaned process**. It will keep running, holding Full Disk Access permissions, until manually killed or the Mac restarts.

macOS does not support `Pdeathsig` (Linux only), so there is no kernel-level solution. Mitigations:

- **Process group kill on startup:** Using `Setpgid: true` lets a wrapper script or launchd kill the entire process group if the daemon dies unexpectedly.
- **PID file:** Write the `imsg` child PID to a file on start (`bridge.pid`). On daemon startup, check if a stale PID file exists and kill the old process before starting a new one.

```go
// On start: write child PID
os.WriteFile("bridge.pid", []byte(strconv.Itoa(cmd.Process.Pid)), 0644)

// On startup: kill any stale child from a previous crash
if data, err := os.ReadFile("bridge.pid"); err == nil {
    if pid, err := strconv.Atoi(strings.TrimSpace(string(data))); err == nil {
        if proc, err := os.FindProcess(pid); err == nil {
            proc.Signal(syscall.SIGTERM)
        }
    }
    os.Remove("bridge.pid")
}
```

### 6.5 Auto-Restart on Unexpected Exit

The `imsg` process may exit on its own (Mac sleep, binary update, permission revocation). Detect this via the read loop closing and restart automatically.

```go
func (b *Bridge) run(ctx context.Context) {
    for {
        b.start(ctx)
        go b.readLoop(ctx)
        b.subscribe(b.lastRowID) // resume from last seen message

        select {
        case <-ctx.Done():
            b.shutdown()
            return
        case <-b.exitCh:
            // imsg exited unexpectedly — log and restart after a brief pause
            log.Println("imsg exited, restarting in 2s...")
            time.Sleep(2 * time.Second)
        }
    }
}
```

The key is passing `since_rowid: b.lastRowID` on every `watch.subscribe` call so no messages are missed during the gap. Update `b.lastRowID` atomically whenever a message notification is received.

## 7. Security Note

The `imsg` binary must have **Full Disk Access** and **Automation** permissions. Your Go service will inherit these capabilities as long as it is the parent process of `imsg`.
