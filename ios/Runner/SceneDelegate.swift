import UIKit
import Flutter

// SceneDelegate standard Flutter — ne pas modifier
// La gestion de scènes multiples est déléguée à FlutterAppDelegate
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    // Laisser Flutter gérer la fenêtre principale via AppDelegate
    guard let _ = (scene as? UIWindowScene) else { return }
  }
}
