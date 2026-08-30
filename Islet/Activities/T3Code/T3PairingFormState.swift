import Foundation

enum T3PairingFormField: Equatable {
  case pairingLink
}

struct T3PairingSubmission: Equatable {
  fileprivate let id: UInt
  let pairingLink: String
  let allowInsecureHTTP: Bool
}

enum T3PairingCompletion: Equatable {
  case ignored
  case succeeded
  case failed
}

enum T3PairingFormResult: Equatable {
  case success
  case failure(String)
}

/// Keeps the pairing link until the request that used it succeeds. Pairing links contain a
/// short-lived credential, so this type deliberately does not log or format the link.
struct T3PairingFormState {
  var pairingLink = ""
  var allowInsecureHTTP = false
  private(set) var isPairing = false
  var statusMessage: String?
  private(set) var statusSucceeded: Bool?
  private(set) var focusedField: T3PairingFormField?

  private var latestSubmissionID: UInt = 0

  mutating func begin() -> T3PairingSubmission? {
    let link = pairingLink.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !link.isEmpty, !isPairing else { return nil }

    latestSubmissionID &+= 1
    isPairing = true
    statusMessage = nil
    statusSucceeded = nil
    focusedField = nil
    return T3PairingSubmission(
      id: latestSubmissionID, pairingLink: link, allowInsecureHTTP: allowInsecureHTTP)
  }

  @discardableResult
  mutating func finish(
    _ submission: T3PairingSubmission, result: T3PairingFormResult
  ) -> T3PairingCompletion {
    guard isPairing, submission.id == latestSubmissionID else { return .ignored }
    isPairing = false

    switch result {
    case .success:
      // Do not erase text the user entered while the request was in flight.
      if pairingLink.trimmingCharacters(in: .whitespacesAndNewlines) == submission.pairingLink {
        pairingLink = ""
        allowInsecureHTTP = false
      }
      statusMessage = String(localized: "Added T3 Code machine.")
      statusSucceeded = true
      focusedField = nil
      return .succeeded
    case .failure(let message):
      statusMessage = message
      statusSucceeded = false
      focusedField =
        pairingLink.trimmingCharacters(in: .whitespacesAndNewlines) == submission.pairingLink
        ? .pairingLink : nil
      return .failed
    }
  }
}
