import CryptoKit
import Darwin
import Foundation
import Security
import UserNotifications

enum NativeSignInStatus: String, Codable {
  case success
  case done
  case failed
  case unknown
  case waitingFirstUnlock
  case running
}

struct NativeBackgroundResult: Codable, Equatable {
  let resultId: UUID
  let credentialInstanceId: String
  let day: String
  let occurredAt: Date
  let status: NativeSignInStatus
  let title: String
  let detail: String
  let errorKind: String?

  static func make(
    _ status: NativeSignInStatus,
    now: Date,
    credentialInstanceId: String = "",
    errorKind: String? = nil
  ) -> NativeBackgroundResult {
    let copy: (String, String) = switch status {
    case .success: ("签到成功", "已完成今日签到。")
    case .done: ("今日已签到", "已跳过重复提交。")
    case .failed: ("签到失败", "后台签到未完成，请打开应用查看详情。")
    case .unknown: ("结果待确认", "已避免重复提交，请打开应用同步签到状态。")
    case .waitingFirstUnlock: ("等待首次解锁", "设备重启后请先解锁一次，快捷指令才能读取本机凭据。")
    case .running: ("已有任务执行中", "未发起重复签到请求。")
    }
    return NativeBackgroundResult(
      resultId: UUID(),
      credentialInstanceId: credentialInstanceId,
      day: NativeBackgroundResult.dayKey(now),
      occurredAt: now,
      status: status,
      title: copy.0,
      detail: copy.1,
      errorKind: errorKind
    )
  }

  static func dayKey(_ value: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: value)
  }

  func withCredentialInstanceIfMissing(_ instanceId: String?) -> NativeBackgroundResult {
    guard credentialInstanceId.isEmpty,
          let instanceId,
          !instanceId.isEmpty else { return self }
    return NativeBackgroundResult(
      resultId: resultId,
      credentialInstanceId: instanceId,
      day: day,
      occurredAt: occurredAt,
      status: status,
      title: title,
      detail: detail,
      errorKind: errorKind
    )
  }

  func methodMap() -> [String: Any] {
    let formatter = ISO8601DateFormatter()
    return [
      "resultId": resultId.uuidString,
      "credentialInstanceId": credentialInstanceId,
      "day": day,
      "occurredAt": formatter.string(from: occurredAt),
      "status": status.rawValue,
      "title": title,
      "detail": detail,
      "errorKind": errorKind as Any,
    ]
  }
}

enum NativeBackgroundSettings {
  private static let activeCredentialInstanceKey = "maoguai.nativeBackgroundCredentialInstance.v1"
  private static let notificationsEnabledKey = "maoguai.nativeBackgroundNotificationsEnabled.v1"

  static var activeCredentialInstanceId: String? {
    UserDefaults.standard.string(forKey: activeCredentialInstanceKey)
  }

  static func setActiveCredentialInstance(_ instanceId: String?) {
    guard let instanceId, !instanceId.isEmpty else {
      UserDefaults.standard.removeObject(forKey: activeCredentialInstanceKey)
      return
    }
    UserDefaults.standard.set(instanceId, forKey: activeCredentialInstanceKey)
  }

  static var notificationsEnabled: Bool {
    UserDefaults.standard.bool(forKey: notificationsEnabledKey)
  }

  static func setNotificationsEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: notificationsEnabledKey)
  }
}

enum NativeBackgroundNotifications {
  static func deliver(_ result: NativeBackgroundResult) async {
    guard NativeBackgroundSettings.notificationsEnabled else { return }
    let content = UNMutableNotificationContent()
    content.title = result.title
    content.body = result.detail
    content.sound = .default
    let request = UNNotificationRequest(
      identifier: "maoguai.background.\(result.resultId.uuidString)",
      content: content,
      trigger: nil
    )
    try? await UNUserNotificationCenter.current().add(request)
  }
}

struct NativeConnectionCheck: Codable, Equatable {
  let title: String
  let detail: String
}

struct NativeCredentials: Equatable {
  let username: String
  let password: String
  let instanceId: String
}

struct NativeSession: Codable, Equatable {
  let token: String
  let uid: String
  let cookies: [String: String]
  let userAgent: String
  let generation: Int?
  let credentialInstanceId: String?

  init(
    token: String,
    uid: String,
    cookies: [String: String],
    userAgent: String = NativeProtocol.userAgent,
    generation: Int? = nil,
    credentialInstanceId: String? = nil
  ) {
    self.token = token
    self.uid = uid
    self.cookies = cookies
    self.userAgent = userAgent
    self.generation = generation
    self.credentialInstanceId = credentialInstanceId
  }
}

enum NativeSecureStoreError: Error {
  case firstUnlockRequired
  case unavailable
  case malformed
}

protocol NativeSecureStore {
  func readCredentials() throws -> NativeCredentials
  func readSession() throws -> NativeSession?
  func saveSession(_ session: NativeSession) throws
}

final class NativeKeychainSecureStore: NativeSecureStore {
  private static let service = "flutter_secure_storage_service"
  private static let revision = "maoguai-2550505-v1"

  func readCredentials() throws -> NativeCredentials {
    guard let username = try read("signin_username")?.trimmingCharacters(in: .whitespacesAndNewlines),
          let password = try read("signin_password"),
          let instanceId = try read("signin_credential_instance")?.trimmingCharacters(in: .whitespacesAndNewlines),
          try read("signin_protocol_revision") == Self.revision,
          !username.isEmpty, !password.isEmpty, !instanceId.isEmpty else {
      throw NativeSecureStoreError.unavailable
    }
    return NativeCredentials(username: username, password: password, instanceId: instanceId)
  }

  func readSession() throws -> NativeSession? {
    guard let encoded = try read("signin_session_v2") else { return nil }
    guard let session = try? JSONDecoder().decode(NativeSession.self, from: Data(encoded.utf8)),
          !session.token.isEmpty, !session.uid.isEmpty else {
      throw NativeSecureStoreError.malformed
    }
    return session
  }

  func saveSession(_ session: NativeSession) throws {
    let data = try JSONEncoder().encode(session)
    try write(String(decoding: data, as: UTF8.self), account: "signin_session_v2")
  }

  private func read(_ account: String) throws -> String? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.service,
      kSecAttrAccount: account,
      kSecAttrSynchronizable: false,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var output: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &output)
    if status == errSecItemNotFound { return nil }
    if status == errSecInteractionNotAllowed { throw NativeSecureStoreError.firstUnlockRequired }
    guard status == errSecSuccess, let data = output as? Data,
          let value = String(data: data, encoding: .utf8) else {
      throw NativeSecureStoreError.unavailable
    }
    return value
  }

  private func write(_ value: String, account: String) throws {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.service,
      kSecAttrAccount: account,
      kSecAttrSynchronizable: false,
    ]
    let values: [CFString: Any] = [
      kSecValueData: Data(value.utf8),
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let update = SecItemUpdate(query as CFDictionary, values as CFDictionary)
    if update == errSecSuccess { return }
    if update != errSecItemNotFound { throw NativeSecureStoreError.unavailable }
    var create = query
    values.forEach { create[$0.key] = $0.value }
    let added = SecItemAdd(create as CFDictionary, nil)
    guard added == errSecSuccess else { throw NativeSecureStoreError.unavailable }
  }
}

final class NativeExecutionLock {
  private let url: URL
  private var descriptor: Int32 = -1

  init(url: URL) { self.url = url }

  convenience init() {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    self.init(url: root.appendingPathComponent("maoguai-signin.lock"))
  }

  deinit { unlock() }

  func tryLock() -> Bool {
    guard descriptor == -1 else { return false }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let opened = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard opened >= 0 else { return false }
    guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
      close(opened)
      return false
    }
    descriptor = opened
    return true
  }

  func unlock() {
    guard descriptor >= 0 else { return }
    flock(descriptor, LOCK_UN)
    close(descriptor)
    descriptor = -1
  }
}

final class NativeResultInbox {
  static let shared = NativeResultInbox(defaults: .standard)

  private let defaults: UserDefaults
  private let key = "maoguai.nativeBackgroundResults.v1"

  init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  func append(_ result: NativeBackgroundResult) throws {
    var values = try readPending()
    guard !values.contains(where: { $0.resultId == result.resultId }) else { return }
    values.append(result)
    try write(values)
  }

  func readPending() throws -> [NativeBackgroundResult] {
    guard let data = defaults.data(forKey: key) else { return [] }
    do {
      return try JSONDecoder().decode([NativeBackgroundResult].self, from: data)
    } catch {
      throw NativeSecureStoreError.malformed
    }
  }

  func acknowledge(_ resultIds: Set<UUID>) throws {
    try write(readPending().filter { !resultIds.contains($0.resultId) })
  }

  private func write(_ values: [NativeBackgroundResult]) throws {
    do {
      defaults.set(try JSONEncoder().encode(values), forKey: key)
    } catch {
      throw NativeSecureStoreError.unavailable
    }
  }
}

private enum NativeProtocol {
  static let baseURL = URL(string: "https://2550505.com")!
  static let loginPath = "/auth/login"
  static let statusPath = "/sign/signed"
  static let signPath = "/sign"
  static let userAgent = "Mozilla/5.0 (QingLong; 2550505-sign)"
  static let clientVersion = "0c1c05"
}

private enum NativeProtocolError: Error {
  case authExpired
  case invalidCredentials
  case invalidResponse
  case temporary
  case rejected
  case localStorage
}

final class NativeBackgroundSignInService {
  static let shared = NativeBackgroundSignInService(
    secureStore: NativeKeychainSecureStore(),
    session: NativeBackgroundSignInService.makeSession(),
    executionLock: NativeExecutionLock()
  )

  private let secureStore: NativeSecureStore
  private let session: URLSession
  private let executionLock: NativeExecutionLock

  init(secureStore: NativeSecureStore, session: URLSession, executionLock: NativeExecutionLock) {
    self.secureStore = secureStore
    self.session = session
    self.executionLock = executionLock
  }

  static func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 25
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    return URLSession(configuration: configuration, delegate: NativeNoRedirectDelegate(), delegateQueue: nil)
  }

  func run(now: Date) async -> NativeBackgroundResult {
    guard executionLock.tryLock() else { return .make(.running, now: now) }
    defer { executionLock.unlock() }
    do {
      let credentials = try secureStore.readCredentials()
      var session = try secureStore.readSession()
      if session == nil {
        session = try await authenticate(credentials)
        try secureStore.saveSession(session!)
      }
      do {
        if try await fetchSigned(session!) {
          return .make(.done, now: now, credentialInstanceId: credentials.instanceId)
        }
      } catch NativeProtocolError.authExpired {
        session = try await authenticate(credentials)
        try secureStore.saveSession(session!)
        if try await fetchSigned(session!) {
          return .make(.done, now: now, credentialInstanceId: credentials.instanceId)
        }
      }
      do {
        try await submit(session!)
        return .make(.success, now: now, credentialInstanceId: credentials.instanceId)
      } catch {
        do {
          if try await fetchSigned(session!) {
            return .make(.done, now: now, credentialInstanceId: credentials.instanceId)
          }
        } catch { }
        return .make(resultStatus(for: error), now: now, credentialInstanceId: credentials.instanceId, errorKind: errorKind(for: error))
      }
    } catch NativeSecureStoreError.firstUnlockRequired {
      return .make(.waitingFirstUnlock, now: now, errorKind: "localStorage")
    } catch {
      return .make(resultStatus(for: error), now: now, errorKind: errorKind(for: error))
    }
  }

  func checkConnection(now: Date) async -> NativeConnectionCheck {
    do {
      guard let session = try secureStore.readSession() else {
        return NativeConnectionCheck(title: "需要重新登录", detail: "本机没有可用登录状态。")
      }
      return try await fetchSigned(session)
        ? NativeConnectionCheck(title: "连接正常", detail: "今日已签到。")
        : NativeConnectionCheck(title: "连接正常", detail: "今日待签到。")
    } catch NativeSecureStoreError.firstUnlockRequired {
      return NativeConnectionCheck(title: "等待首次解锁", detail: "设备重启后请先解锁一次。")
    } catch {
      return NativeConnectionCheck(title: "连接检查失败", detail: "未能读取签到状态。")
    }
  }

  private func authenticate(_ credentials: NativeCredentials) async throws -> NativeSession {
    let payload: [String: String] = ["account": credentials.username, "password": credentials.password]
    let response = try await request(method: "POST", path: NativeProtocol.loginPath, payload: payload, session: nil)
    guard response.code == 0 else { throw NativeProtocolError.invalidCredentials }
    guard let token = response.string("token"), !token.isEmpty else { throw NativeProtocolError.invalidResponse }
    let uid = response.string("uid") ?? credentials.username
    guard !uid.isEmpty else { throw NativeProtocolError.invalidResponse }
    return NativeSession(token: token, uid: uid, cookies: ["token": token], credentialInstanceId: credentials.instanceId)
  }

  private func fetchSigned(_ session: NativeSession) async throws -> Bool {
    var lastError: Error?
    for attempt in 0..<3 {
      do {
        let response = try await request(method: "GET", path: NativeProtocol.statusPath, payload: nil, session: session)
        guard response.code == 0 else { throw NativeProtocolError.rejected }
        guard let signed = response.bool("signed") else { throw NativeProtocolError.invalidResponse }
        return signed
      } catch NativeProtocolError.temporary {
        lastError = NativeProtocolError.temporary
        if attempt < 2 { continue }
      }
    }
    throw lastError ?? NativeProtocolError.invalidResponse
  }

  private func submit(_ session: NativeSession) async throws {
    let response = try await request(method: "POST", path: NativeProtocol.signPath, payload: nil, session: session)
    guard response.code == 0 else { throw NativeProtocolError.rejected }
  }

  private func request(
    method: String,
    path: String,
    payload: [String: String]?,
    session: NativeSession?
  ) async throws -> NativeJSONResponse {
    guard [NativeProtocol.loginPath, NativeProtocol.statusPath, NativeProtocol.signPath].contains(path),
          let url = URL(string: path, relativeTo: NativeProtocol.baseURL),
          url.scheme == "https", url.host == NativeProtocol.baseURL.host else {
      throw NativeProtocolError.invalidResponse
    }
    let body: Data?
    if let payload {
      body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    } else {
      body = nil
    }
    let compactBody = body.map { String(decoding: $0, as: UTF8.self) } ?? "undefined"
    let token = session?.token.isEmpty == false ? session!.token : "undefined"
    let hash = SHA256.hash(data: Data((path + compactBody + token).utf8)).map { String(format: "%02x", $0) }.joined()
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    request.timeoutInterval = 15
    request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
    request.setValue(NativeProtocol.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "Authorization")
    request.setValue(NativeProtocol.clientVersion, forHTTPHeaderField: "X-Client-Version")
    request.setValue(hash, forHTTPHeaderField: "hash")
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    if let session, !session.cookies.isEmpty {
      request.setValue(session.cookies.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; "), forHTTPHeaderField: "Cookie")
    }
    let data: Data
    let raw: URLResponse
    do {
      (data, raw) = try await self.session.data(for: request)
    } catch {
      throw NativeProtocolError.temporary
    }
    guard let response = raw as? HTTPURLResponse else { throw NativeProtocolError.invalidResponse }
    if response.statusCode == 401 || response.statusCode == 403 { throw NativeProtocolError.authExpired }
    if response.statusCode == 429 || (500...599).contains(response.statusCode) { throw NativeProtocolError.temporary }
    guard (200...299).contains(response.statusCode), data.count <= 1_048_576 else {
      throw NativeProtocolError.invalidResponse
    }
    guard let object = try? JSONSerialization.jsonObject(with: data), let map = object as? [String: Any] else {
      throw NativeProtocolError.invalidResponse
    }
    return NativeJSONResponse(map)
  }

  private func resultStatus(for error: Error) -> NativeSignInStatus {
    switch error {
    case NativeProtocolError.invalidResponse, NativeProtocolError.temporary: return .unknown
    default: return .failed
    }
  }

  private func errorKind(for error: Error) -> String {
    switch error {
    case NativeProtocolError.authExpired: return "authExpired"
    case NativeProtocolError.invalidCredentials: return "invalidCredentials"
    case NativeProtocolError.temporary: return "networkUnavailable"
    case NativeProtocolError.invalidResponse: return "invalidResponse"
    case is NativeSecureStoreError: return "localStorage"
    default: return "businessRejected"
    }
  }
}

private struct NativeJSONResponse {
  let value: [String: Any]
  init(_ value: [String: Any]) { self.value = value }
  var code: Int? {
    if let value = value["code"] as? Int { return value }
    if let value = value["code"] as? String { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return nil
  }
  func string(_ key: String) -> String? {
    var current: Any? = value
    for _ in 0..<3 {
      guard let map = current as? [String: Any] else { return nil }
      if let value = map[key] as? String, !value.isEmpty { return value }
      current = map["data"]
    }
    return nil
  }
  func bool(_ key: String) -> Bool? {
    if let value = value[key] as? Bool { return value }
    return (value["data"] as? [String: Any])?[key] as? Bool
  }
}

private final class NativeNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
