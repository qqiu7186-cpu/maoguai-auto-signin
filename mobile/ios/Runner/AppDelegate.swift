import Flutter
import AppIntents
import UIKit
import workmanager_apple
import Security

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
      KeychainAccessibilityPlugin.register(with: registry.registrar(forPlugin: "KeychainAccessibilityPlugin")!)
      NativeBackgroundPlugin.register(with: registry.registrar(forPlugin: "NativeBackgroundPlugin")!)
    }
    WorkmanagerPlugin.registerBGProcessingTask(
      withIdentifier: "com.qqiu7186.maoguai-signin.daily"
    )
    NotificationSettingsPlugin.register(with: registrar(forPlugin: "NotificationSettingsPlugin")!)
    NativeBackgroundPlugin.register(with: registrar(forPlugin: "NativeBackgroundPlugin")!)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    KeychainAccessibilityPlugin.register(with: engineBridge.pluginRegistry.registrar(forPlugin: "KeychainAccessibilityPlugin")!)
  }
}

@available(iOS 16.0, *)
struct RunSignInShortcutIntent: AppIntent {
  static var title: LocalizedStringResource = "执行签到"
  @available(iOS 26.0, *)
  static var supportedModes: IntentModes { .background }

  func perform() async throws -> some IntentResult {
    let rawResult = await NativeBackgroundSignInService.shared.run(now: Date())
    let result = rawResult.withCredentialInstanceIfMissing(
      NativeBackgroundSettings.activeCredentialInstanceId
    )
    try? NativeResultInbox.shared.append(result)
    await NativeBackgroundNotifications.deliver(result)
    return .result()
  }
}

@available(iOS 16.0, *)
struct SignInAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: RunSignInShortcutIntent(),
      phrases: ["使用 \(.applicationName) 执行签到"],
      shortTitle: "执行签到",
      systemImageName: "checkmark.circle"
    )
  }
}

private final class NativeBackgroundPlugin: NSObject, FlutterPlugin {
  private let executionLock = NativeExecutionLock()

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "maoguai/native_background", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(NativeBackgroundPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "readPendingResults":
      do {
        result(try NativeResultInbox.shared.readPending().map { $0.methodMap() })
      } catch {
        result(FlutterError(code: "result_inbox_unavailable", message: "Unable to read pending results.", details: nil))
      }
    case "acknowledgeResultIds":
      guard let values = call.arguments as? [String] else {
        result(FlutterError(code: "invalid_arguments", message: "Expected result identifiers.", details: nil))
        return
      }
      let ids = Set(values.compactMap(UUID.init(uuidString:)))
      guard ids.count == values.count else {
        result(FlutterError(code: "invalid_arguments", message: "Invalid result identifier.", details: nil))
        return
      }
      do {
        try NativeResultInbox.shared.acknowledge(ids)
        result(nil)
      } catch {
        result(FlutterError(code: "result_inbox_unavailable", message: "Unable to acknowledge pending results.", details: nil))
      }
    case "setNotificationsEnabled":
      guard let enabled = call.arguments as? Bool else {
        result(FlutterError(code: "invalid_arguments", message: "Expected a boolean.", details: nil))
        return
      }
      NativeBackgroundSettings.setNotificationsEnabled(enabled)
      result(nil)
    case "setActiveCredentialInstance":
      if call.arguments == nil {
        NativeBackgroundSettings.setActiveCredentialInstance(nil)
        result(nil)
      } else if let instanceId = call.arguments as? String,
                !instanceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        NativeBackgroundSettings.setActiveCredentialInstance(instanceId)
        result(nil)
      } else {
        result(FlutterError(code: "invalid_arguments", message: "Expected an instance identifier or null.", details: nil))
      }
    case "checkConnection":
      Task {
        let check = await NativeBackgroundSignInService.shared.checkConnection(now: Date())
        result(["title": check.title, "detail": check.detail])
      }
    case "tryAcquireExecutionLock":
      result(executionLock.tryLock())
    case "releaseExecutionLock":
      executionLock.unlock()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

private final class NotificationSettingsPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "maoguai/notification_settings", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(NotificationSettingsPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "openNotificationSettings" else {
      result(FlutterMethodNotImplemented)
      return
    }
    let urlString: String
    if #available(iOS 16.0, *) {
      urlString = UIApplication.openNotificationSettingsURLString
    } else {
      urlString = UIApplication.openSettingsURLString
    }
    guard let url = URL(string: urlString) else {
      result(false)
      return
    }
    DispatchQueue.main.async {
      UIApplication.shared.open(url, options: [:]) { opened in
        result(opened)
      }
    }
  }
}

/// Update legacy entries atomically, without copying credential values through
/// Dart or overwriting a newer login. Register in foreground and worker engines.
private final class KeychainAccessibilityPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "maoguai/keychain_accessibility", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(KeychainAccessibilityPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let allowed = ["signin_username", "signin_password", "signin_credential_instance", "signin_protocol_revision", "signin_session_v2"]
    guard call.method == "migrate", let key = call.arguments as? String, allowed.contains(key) else {
      result(FlutterMethodNotImplemented)
      return
    }
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: "flutter_secure_storage_service",
      kSecAttrAccount: key,
      kSecAttrSynchronizable: false
    ]
    let status = SecItemUpdate(query as CFDictionary, [
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ] as CFDictionary)
    if status == errSecSuccess || status == errSecItemNotFound {
      result(nil)
    } else {
      // Locked legacy entries fail closed until foreground unlock can migrate.
      result(FlutterError(code: "keychain_unavailable", message: "Secure storage is unavailable.", details: nil))
    }
  }
}
