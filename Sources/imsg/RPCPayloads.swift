import Foundation
import IMsgCore

func chatPayload(
  id: Int64,
  identifier: String,
  guid: String,
  name: String,
  service: String,
  lastMessageAt: Date,
  participants: [String]
) -> [String: Any] {
  return [
    "id": id,
    "identifier": identifier,
    "guid": guid,
    "name": name,
    "service": service,
    "last_message_at": CLIISO8601.format(lastMessageAt),
    "participants": participants,
    "is_group": isGroupHandle(identifier: identifier, guid: guid),
  ]
}

func messagePayload(
  message: Message,
  chatInfo: ChatInfo?,
  participants: [String],
  attachments: [AttachmentMeta],
  reactions: [Reaction]
) throws -> [String: Any] {
  let identifier = chatInfo?.identifier ?? ""
  let guid = chatInfo?.guid ?? ""
  let name = chatInfo?.name ?? ""
  let core = MessagePayload(message: message, attachments: attachments, reactions: reactions)
  var payload = try core.asDictionary()
  payload["chat_identifier"] = identifier
  payload["chat_guid"] = guid
  payload["chat_name"] = name
  payload["participants"] = participants
  payload["is_group"] = isGroupHandle(identifier: identifier, guid: guid)
  payload["is_sent"] = message.isSent
  payload["is_delivered"] = message.isDelivered
  payload["is_read"] = message.isRead
  payload["error"] = message.errorCode
  payload["item_type"] = message.itemType
  payload["was_downgraded"] = message.wasDowngraded
  payload["is_spam"] = message.isSpam
  if let dateDelivered = message.dateDelivered {
    payload["date_delivered"] = CLIISO8601.format(dateDelivered)
  }
  if let dateRead = message.dateRead {
    payload["date_read"] = CLIISO8601.format(dateRead)
  }
  if let dateEdited = message.dateEdited {
    payload["date_edited"] = CLIISO8601.format(dateEdited)
  }
  if let groupTitle = message.groupTitle {
    payload["group_title"] = groupTitle
  }
  if message.itemType != 0 {
    payload["group_action_type"] = message.groupActionType
  }
  if let effectId = message.expressiveSendStyleId {
    payload["expressive_send_style_id"] = effectId
  }
  if let balloonId = message.balloonBundleId {
    payload["balloon_bundle_id"] = balloonId
  }
  if let threadGuid = message.threadOriginatorGuid {
    payload["thread_originator_guid"] = threadGuid
  }
  if let subject = message.subject {
    payload["subject"] = subject
  }
  return payload
}

func attachmentPayload(_ meta: AttachmentMeta) -> [String: Any] {
  return [
    "filename": meta.filename,
    "transfer_name": meta.transferName,
    "uti": meta.uti,
    "mime_type": meta.mimeType,
    "total_bytes": meta.totalBytes,
    "is_sticker": meta.isSticker,
    "original_path": meta.originalPath,
    "missing": meta.missing,
    "transfer_state": meta.transferState,
  ]
}

func reactionPayload(_ reaction: Reaction) -> [String: Any] {
  return [
    "id": reaction.rowID,
    "type": reaction.reactionType.name,
    "emoji": reaction.reactionType.emoji,
    "sender": reaction.sender,
    "is_from_me": reaction.isFromMe,
    "created_at": CLIISO8601.format(reaction.date),
  ]
}

func isGroupHandle(identifier: String, guid: String) -> Bool {
  return guid.contains(";+;") || identifier.contains(";+;")
}

func stringParam(_ value: Any?) -> String? {
  if let value = value as? String { return value }
  if let number = value as? NSNumber { return number.stringValue }
  return nil
}

func intParam(_ value: Any?) -> Int? {
  if let value = value as? Int { return value }
  if let value = value as? NSNumber { return value.intValue }
  if let value = value as? String { return Int(value) }
  return nil
}

func int64Param(_ value: Any?) -> Int64? {
  if let value = value as? Int64 { return value }
  if let value = value as? Int { return Int64(value) }
  if let value = value as? NSNumber { return value.int64Value }
  if let value = value as? String { return Int64(value) }
  return nil
}

func boolParam(_ value: Any?) -> Bool? {
  if let value = value as? Bool { return value }
  if let value = value as? NSNumber { return value.boolValue }
  if let value = value as? String {
    if value == "true" { return true }
    if value == "false" { return false }
  }
  return nil
}

func int64ArrayParam(_ value: Any?) -> [Int64] {
  if let list = value as? [Any] {
    return list.compactMap { int64Param($0) }
  }
  return []
}

func stringArrayParam(_ value: Any?) -> [String] {
  if let list = value as? [String] { return list }
  if let list = value as? [Any] {
    return list.compactMap { stringParam($0) }
  }
  if let str = value as? String {
    return
      str
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
  return []
}
