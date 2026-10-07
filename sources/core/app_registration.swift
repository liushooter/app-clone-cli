import CoreServices
import Foundation

enum AppRegistration {
  @discardableResult
  static func refresh(_ app: URL, onEvent: EventHandler = { _ in }) -> Int32 {
    let status = LSRegisterURL(app as CFURL, true)
    if status != 0 {
      onEvent(
        CloneEvent(
          "registration_warning",
          L10n.text(.registrationWarning, String(status))))
    }
    return status
  }
}

public struct RegistrationResult: Encodable, Sendable {
  public let name: String
  public let path: String
  public let status: Int32
}
