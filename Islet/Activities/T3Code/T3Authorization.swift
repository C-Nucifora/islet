import Foundation

protocol T3DPoPProofProviding: Sendable {
  func proof(method: String, url: URL, accessToken: String?) async throws -> String
  func keyThumbprint() async throws -> String
  func proofLease() async throws -> any T3DPoPProofProviding
}

extension T3DPoPProofProviding {
  func proofLease() async throws -> any T3DPoPProofProviding { self }
}

enum T3Authorization: Sendable {
  case none
  case bearer(String)
  case dpop(accessToken: String, signer: any T3DPoPProofProviding)
}
