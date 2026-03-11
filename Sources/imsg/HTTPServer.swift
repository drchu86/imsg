import Foundation
import Hummingbird
import IMsgCore

struct HTTPServer {
  let store: MessageStore
  let host: String
  let port: Int
  let token: String?
  let startTime: Date

  init(store: MessageStore, host: String, port: Int, token: String?) {
    self.store = store
    self.host = host
    self.port = port
    self.token = token
    self.startTime = Date()
  }

  func run() async throws {
    let store = self.store
    let startTime = self.startTime

    let router = Router()
    let v1 = router.group("v1")

    if let token {
      v1.add(middleware: BearerAuthMiddleware(token: token))
    }

    // GET /v1/healthz
    v1.get("healthz") { _, _ -> Response in
      jsonResponse([
        "ok": true,
        "version": IMsgVersion.current,
        "uptime_seconds": Int(-startTime.timeIntervalSinceNow),
      ])
    }

    // GET /v1/chats?limit=N
    v1.get("chats") { request, _ -> Response in
      let limitStr = request.uri.queryParameters["limit"].map(String.init)
      let limit = limitStr.flatMap(Int.init) ?? 20
      let cache = ChatCache(store: store)
      do {
        let chats = try store.listChats(limit: max(limit, 1))
        var payloads: [[String: Any]] = []
        for chat in chats {
          let info = try await cache.info(chatID: chat.id)
          let participants = try await cache.participants(chatID: chat.id)
          payloads.append(chatPayload(
            id: chat.id,
            identifier: info?.identifier ?? chat.identifier,
            guid: info?.guid ?? "",
            name: (info?.name.isEmpty == false ? info?.name : nil) ?? chat.name,
            service: info?.service ?? chat.service,
            lastMessageAt: chat.lastMessageAt,
            participants: participants
          ))
        }
        return jsonResponse(["chats": payloads])
      } catch {
        return httpErrorResponse(for: error)
      }
    }

    // POST /v1/messages/history
    v1.post("messages/history") { request, _ -> Response in
      var req = request
      let buf = try await req.collectBody(upTo: 1024 * 1024)
      guard
        let json = try? JSONSerialization.jsonObject(
          with: Data(buf.readableBytesView)) as? [String: Any]
      else {
        return errorResponse(.badRequest, code: "INVALID_JSON", message: "Invalid JSON body")
      }
      guard let chatID = int64Param(json["chat_id"]) else {
        return errorResponse(
          .badRequest, code: "INVALID_ARGUMENT", message: "chat_id is required")
      }
      let limit = intParam(json["limit"]) ?? 50
      let participants = stringArrayParam(json["participants"])
      let startISO = stringParam(json["start"])
      let endISO = stringParam(json["end"])
      let sinceRowID = int64Param(json["since_rowid"])
      let includeAttachments = boolParam(json["attachments"]) ?? false
      do {
        let filter = try MessageFilter.fromISO(
          participants: participants, startISO: startISO, endISO: endISO,
          sinceRowID: sinceRowID)
        let cache = ChatCache(store: store)
        let messages = try store.messages(chatID: chatID, limit: max(limit, 1), filter: filter)
        var payloads: [[String: Any]] = []
        for message in messages {
          let payload = try await buildMessagePayload(
            store: store, cache: cache, message: message,
            includeAttachments: includeAttachments)
          payloads.append(payload)
        }
        return jsonResponse(["messages": payloads])
      } catch {
        return httpErrorResponse(for: error)
      }
    }

    // POST /v1/messages/send
    v1.post("messages/send") { request, _ -> Response in
      var req = request
      let buf = try await req.collectBody(upTo: 1024 * 1024)
      guard
        let json = try? JSONSerialization.jsonObject(
          with: Data(buf.readableBytesView)) as? [String: Any]
      else {
        return errorResponse(.badRequest, code: "INVALID_JSON", message: "Invalid JSON body")
      }
      let text = stringParam(json["text"]) ?? ""
      let file = stringParam(json["file"]) ?? ""
      let serviceRaw = stringParam(json["service"]) ?? "auto"
      guard let service = MessageService(rawValue: serviceRaw) else {
        return errorResponse(.badRequest, code: "INVALID_ARGUMENT", message: "invalid service")
      }
      let region = stringParam(json["region"]) ?? "US"
      let chatID = int64Param(json["chat_id"])
      let chatIdentifier = stringParam(json["chat_identifier"]) ?? ""
      let chatGUID = stringParam(json["chat_guid"]) ?? ""
      let hasChatTarget = chatID != nil || !chatIdentifier.isEmpty || !chatGUID.isEmpty
      let recipient = stringParam(json["to"]) ?? ""
      if hasChatTarget && !recipient.isEmpty {
        return errorResponse(
          .badRequest, code: "INVALID_ARGUMENT", message: "use to or chat_*; not both")
      }
      if !hasChatTarget && recipient.isEmpty {
        return errorResponse(
          .badRequest, code: "INVALID_ARGUMENT", message: "to is required for direct sends")
      }
      if text.isEmpty && file.isEmpty {
        return errorResponse(
          .badRequest, code: "INVALID_ARGUMENT", message: "text or file is required")
      }
      do {
        var resolvedChatIdentifier = chatIdentifier
        var resolvedChatGUID = chatGUID
        if let chatID {
          let cache = ChatCache(store: store)
          guard let info = try await cache.info(chatID: chatID) else {
            return errorResponse(
              .badRequest, code: "INVALID_ARGUMENT", message: "unknown chat_id \(chatID)")
          }
          resolvedChatIdentifier = info.identifier
          resolvedChatGUID = info.guid
        }
        if hasChatTarget && resolvedChatIdentifier.isEmpty && resolvedChatGUID.isEmpty {
          return errorResponse(
            .badRequest, code: "INVALID_ARGUMENT", message: "missing chat identifier or guid")
        }
        let sinceRowID = (try? store.maxRowID()) ?? 0
        try MessageSender().send(
          MessageSendOptions(
            recipient: recipient,
            text: text,
            attachmentPath: file,
            service: service,
            region: region,
            chatIdentifier: resolvedChatIdentifier,
            chatGUID: resolvedChatGUID
          ))
        return jsonResponse(["ok": true, "since_rowid": sinceRowID])
      } catch {
        return httpErrorResponse(for: error)
      }
    }

    // GET /v1/handles/:id
    v1.get("handles/:id") { _, context -> Response in
      let raw = try context.parameters.require("id")
      let handleID = raw.removingPercentEncoding ?? raw
      do {
        if let info = try store.handleInfo(id: handleID) {
          return jsonResponse([
            "id": info.id,
            "service": info.service,
            "country": info.country ?? "",
            "uncanonicalized_id": info.uncanonicalizedId ?? "",
          ])
        }
        return errorResponse(
          .notFound, code: "NOT_FOUND", message: "handle not found: \(handleID)")
      } catch {
        return httpErrorResponse(for: error)
      }
    }

    // GET /v1/watch/stream (SSE)
    v1.get("watch/stream") { request, _ -> Response in
      let qp = request.uri.queryParameters
      let chatID = qp["chat_id"].flatMap { Int64($0) }
      let sinceRowID = qp["since_rowid"].flatMap { Int64($0) }
      let participantsRaw = qp["participants"].map(String.init) ?? ""
      let participants =
        participantsRaw.isEmpty
        ? []
        : participantsRaw.split(separator: ",")
          .map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty }
      let startISO = qp["start"].map(String.init)
      let endISO = qp["end"].map(String.init)
      let includeAttachments = qp["attachments"].map { $0 == "true" } ?? false

      let filter: MessageFilter
      do {
        filter = try MessageFilter.fromISO(
          participants: participants, startISO: startISO, endISO: endISO)
      } catch {
        return errorResponse(
          .badRequest, code: "INVALID_ARGUMENT", message: error.localizedDescription)
      }

      let cache = ChatCache(store: store)
      let watcher = MessageWatcher(store: store)
      let config = MessageWatcherConfiguration()
      let watchStream = watcher.stream(chatID: chatID, sinceRowID: sinceRowID, configuration: config)
      let (byteStream, continuation) = AsyncStream<ByteBuffer>.makeStream()

      let messageTask = Task {
        await withTaskCancellationHandler {
          defer { continuation.finish() }
          do {
            for try await message in watchStream {
              if Task.isCancelled { return }
              if !filter.allows(message) { continue }
              if let payload = try? await buildMessagePayload(
                store: store, cache: cache, message: message,
                includeAttachments: includeAttachments),
                let json = try? JSONSerialization.data(withJSONObject: ["message": payload]),
                let jsonStr = String(data: json, encoding: .utf8)
              {
                continuation.yield(sseEvent("message", data: jsonStr))
              }
            }
          } catch {
            if let data = try? JSONSerialization.data(
              withJSONObject: ["message": error.localizedDescription]),
              let jsonStr = String(data: data, encoding: .utf8)
            {
              continuation.yield(sseEvent("error", data: jsonStr))
            }
          }
        } onCancel: {
          continuation.finish()
        }
      }

      let heartbeatTask = Task {
        while !Task.isCancelled {
          do {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            continuation.yield(sseEvent("heartbeat", data: "{}"))
          } catch {
            return
          }
        }
      }

      continuation.onTermination = { _ in
        messageTask.cancel()
        heartbeatTask.cancel()
      }

      var headers = HTTPFields()
      headers[.contentType] = "text/event-stream"
      headers[.cacheControl] = "no-cache"
      return Response(
        status: .ok,
        headers: headers,
        body: ResponseBody(asyncSequence: byteStream))
    }

    Swift.print("imsg serve: listening on http://\(host):\(port)/v1")
    let app = Application(
      router: router,
      configuration: .init(address: .hostname(host, port: port))
    )
    try await app.runService()
  }
}

// MARK: - Bearer Auth Middleware

private struct BearerAuthMiddleware<Context: RequestContext>: RouterMiddleware {
  let token: String

  func handle(
    _ request: Request,
    context: Context,
    next: (Request, Context) async throws -> Response
  ) async throws -> Response {
    guard let auth = request.headers[.authorization],
      auth == "Bearer \(token)"
    else {
      return errorResponse(.unauthorized, code: "UNAUTHORIZED", message: "Invalid or missing token")
    }
    return try await next(request, context)
  }
}

// MARK: - Response Helpers

private func jsonResponse(_ object: Any) -> Response {
  guard let data = try? JSONSerialization.data(withJSONObject: object) else {
    return errorResponse(
      .internalServerError, code: "INTERNAL", message: "JSON serialization failed")
  }
  var headers = HTTPFields()
  headers[.contentType] = "application/json"
  var buffer = ByteBuffer()
  buffer.writeBytes(data)
  return Response(status: .ok, headers: headers, body: ResponseBody(byteBuffer: buffer))
}

private func errorResponse(
  _ status: HTTPResponse.Status, code: String, message: String
) -> Response {
  let body =
    "{\"error\":{\"code\":\"\(jsonEscape(code))\",\"message\":\"\(jsonEscape(message))\"}}"
  var headers = HTTPFields()
  headers[.contentType] = "application/json"
  var buffer = ByteBuffer()
  buffer.writeString(body)
  return Response(status: status, headers: headers, body: ResponseBody(byteBuffer: buffer))
}

private func httpErrorResponse(for error: Error) -> Response {
  if let err = error as? IMsgError {
    switch err {
    case .invalidService, .invalidChatTarget, .invalidISODate:
      return errorResponse(
        .badRequest, code: "INVALID_ARGUMENT",
        message: err.errorDescription ?? "invalid params")
    case .permissionDenied:
      return errorResponse(
        .serviceUnavailable, code: "UNAVAILABLE",
        message: err.errorDescription ?? "service unavailable")
    case .appleScriptFailure:
      return errorResponse(
        .internalServerError, code: "INTERNAL",
        message: err.errorDescription ?? "internal error")
    case .invalidReaction:
      return errorResponse(
        .badRequest, code: "INVALID_ARGUMENT",
        message: err.errorDescription ?? "invalid reaction")
    case .chatNotFound:
      return errorResponse(
        .notFound, code: "NOT_FOUND",
        message: err.errorDescription ?? "chat not found")
    }
  }
  return errorResponse(
    .internalServerError, code: "INTERNAL", message: error.localizedDescription)
}

private func sseEvent(_ event: String, data: String) -> ByteBuffer {
  var buffer = ByteBuffer()
  buffer.writeString("event: \(event)\ndata: \(data)\n\n")
  return buffer
}

private func jsonEscape(_ string: String) -> String {
  string
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
    .replacingOccurrences(of: "\n", with: "\\n")
    .replacingOccurrences(of: "\r", with: "\\r")
    .replacingOccurrences(of: "\t", with: "\\t")
}
