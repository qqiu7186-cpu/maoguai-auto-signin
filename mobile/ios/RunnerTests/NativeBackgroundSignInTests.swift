import Foundation
import XCTest
@testable import Runner

final class NativeBackgroundSignInTests: XCTestCase {
  private let fixedDate = Date(timeIntervalSince1970: 1_789_689_900)

  override func tearDown() {
    StubURLProtocol.reset()
    super.tearDown()
  }

  func testAlreadySignedSkipsSignPost() async {
    StubURLProtocol.responses = [response(json: ["code": 0, "data": ["signed": true]])]
    let service = makeService()

    let result = await service.run(now: fixedDate)

    XCTAssertEqual(result.status, .done)
    XCTAssertEqual(StubURLProtocol.requests.map(\.httpMethod), ["GET"])
    XCTAssertEqual(StubURLProtocol.requests.map(\.url?.path), ["/sign/signed"])
  }

  func testUnknownSignResponseUsesOneReadOnlyConfirmation() async {
    StubURLProtocol.responses = [
      response(json: ["code": 0, "data": ["signed": false]]),
      response(data: Data("not-json".utf8)),
      response(json: ["code": 0, "data": ["signed": true]]),
    ]
    let service = makeService()

    let result = await service.run(now: fixedDate)

    XCTAssertEqual(result.status, .done)
    XCTAssertEqual(
      StubURLProtocol.requests.map(\.url?.path),
      ["/sign/signed", "/sign", "/sign/signed"]
    )
  }

  func testMissingSessionAuthenticatesOnceBeforeReadingStatus() async {
    StubURLProtocol.responses = [
      response(json: ["code": 0, "data": ["token": "new-token", "uid": "40320"]]),
      response(json: ["code": 0, "data": ["signed": true]]),
    ]
    let store = MemoryNativeSecureStore(session: nil)
    let service = makeService(store: store)

    let result = await service.run(now: fixedDate)

    XCTAssertEqual(result.status, .done)
    XCTAssertEqual(StubURLProtocol.requests.map(\.url?.path), ["/auth/login", "/sign/signed"])
    XCTAssertEqual(store.session?.token, "new-token")
  }

  func testConnectionCheckNeverPosts() async {
    StubURLProtocol.responses = [response(json: ["code": 0, "data": ["signed": false]])]

    _ = await makeService().checkConnection(now: fixedDate)

    XCTAssertEqual(StubURLProtocol.requests.map(\.httpMethod), ["GET"])
  }

  func testKeychainLockedBeforeFirstUnlockDoesNotReachNetwork() async {
    let service = makeService(store: MemoryNativeSecureStore(readError: .firstUnlockRequired))

    let result = await service.run(now: fixedDate)

    XCTAssertEqual(result.status, .waitingFirstUnlock)
    XCTAssertTrue(StubURLProtocol.requests.isEmpty)
  }

  func testResultNeverIncludesCredentialOrSessionSecrets() async {
    StubURLProtocol.responses = [response(json: ["code": 0, "data": ["signed": true]])]
    let store = MemoryNativeSecureStore(
      credentials: .init(username: "40320", password: "secret-password", instanceId: "credential-1"),
      session: .init(token: "secret-token", uid: "40320", cookies: ["token": "secret-token"])
    )

    let result = await makeService(store: store).run(now: fixedDate)
    let visible = "\(result.title) \(result.detail)"

    XCTAssertFalse(visible.contains("secret-password"))
    XCTAssertFalse(visible.contains("secret-token"))
  }

  func testInboxRetainsResultUntilFlutterAcknowledgesIt() throws {
    let suite = "NativeBackgroundSignInTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let inbox = NativeResultInbox(defaults: defaults)
    let result = NativeBackgroundResult.make(
      .done,
      now: fixedDate,
      credentialInstanceId: "credential-1"
    )

    try inbox.append(result)
    XCTAssertEqual(try inbox.readPending(), [result])
    try inbox.acknowledge([result.resultId])
    XCTAssertTrue(try inbox.readPending().isEmpty)
  }

  private func makeService(store: MemoryNativeSecureStore = .init()) -> NativeBackgroundSignInService {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return NativeBackgroundSignInService(
      secureStore: store,
      session: URLSession(configuration: configuration),
      executionLock: NativeExecutionLock(url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
    )
  }

  private func response(json: [String: Any]) -> StubURLProtocol.Response {
    let data = try! JSONSerialization.data(withJSONObject: json)
    return response(data: data)
  }

  private func response(data: Data) -> StubURLProtocol.Response {
    .init(statusCode: 200, data: data, headers: ["Content-Type": "application/json"])
  }
}

private final class MemoryNativeSecureStore: NativeSecureStore {
  var credentials: NativeCredentials
  var session: NativeSession?
  let readError: NativeSecureStoreError?

  init(
    credentials: NativeCredentials = .init(username: "40320", password: "password", instanceId: "credential-1"),
    session: NativeSession? = .init(token: "token", uid: "40320", cookies: ["token": "token"]),
    readError: NativeSecureStoreError? = nil
  ) {
    self.credentials = credentials
    self.session = session
    self.readError = readError
  }

  func readCredentials() throws -> NativeCredentials {
    if let readError { throw readError }
    return credentials
  }

  func readSession() throws -> NativeSession? {
    if let readError { throw readError }
    return session
  }

  func saveSession(_ session: NativeSession) throws {
    self.session = session
  }
}

private final class StubURLProtocol: URLProtocol {
  struct Response {
    let statusCode: Int
    let data: Data
    let headers: [String: String]
  }

  nonisolated(unsafe) static var responses = [Response]()
  nonisolated(unsafe) static var requests = [URLRequest]()

  static func reset() {
    responses = []
    requests = []
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.requests.append(request)
    let response = Self.responses.removeFirst()
    let urlResponse = HTTPURLResponse(
      url: request.url!,
      statusCode: response.statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: response.headers
    )!
    client?.urlProtocol(self, didReceive: urlResponse, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: response.data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
