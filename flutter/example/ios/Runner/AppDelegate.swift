import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    // RunnerTests host: lib/main.dart asks this and then skips Clikgate.configure (the plugin's unit tests
    // expect an unconfigured SDK). Example-only; the plugin itself behaves the same under XCTest.
    if let messenger = registrar(forPlugin: "ExampleHost")?.messenger() {
      let isUnitTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
      FlutterMethodChannel(name: "com.clikgate.example/host", binaryMessenger: messenger).setMethodCallHandler { call, result in
        result(call.method == "isUnitTestHost" ? isUnitTestHost : FlutterMethodNotImplemented)
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
