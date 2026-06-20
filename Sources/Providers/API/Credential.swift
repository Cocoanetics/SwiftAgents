import Foundation

/// Applies authentication to an outgoing `URLRequest`.
///
/// This is the seam the ``API`` base class uses to authorize requests. When an
/// ``API``'s ``API/credential`` is set, the request builder calls
/// ``authorize(_:)`` instead of attaching the default `apiKey` bearer header —
/// so a provider can be authenticated with anything from a plain API key to an
/// OAuth token that needs extra routing headers, without subclassing.
public protocol RequestAuthorizing: Sendable {
    /// Attach authentication headers to `request` in place.
    func authorize(_ request: inout URLRequest)
}

/// A ready-made ``RequestAuthorizing`` for the common single-header auth shapes
/// used by the built-in providers.
///
/// Providers whose auth needs additional headers (OAuth beta flags,
/// account-routing ids, …) supply their own ``RequestAuthorizing`` conformer
/// instead of stuffing them into a header bag here.
public enum Credential: RequestAuthorizing, Sendable {
    /// `Authorization: Bearer <token>` — OpenAI API keys and OAuth bearer tokens.
    case bearer(String)

    /// `x-api-key: <key>` — Anthropic API keys.
    case apiKey(String)

    /// `x-goog-api-key: <key>` — Google (Gemini) API keys.
    case googleAPIKey(String)

    public func authorize(_ request: inout URLRequest) {
        switch self {
            case .bearer(let token):
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            case .apiKey(let key):
                request.setValue(key, forHTTPHeaderField: "x-api-key")
            case .googleAPIKey(let key):
                request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
    }
}
