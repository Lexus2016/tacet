import Foundation

/// One HTTP session for every cloud call in the app.
///
/// Creating a session per request throws away the TLS connection and costs a
/// handshake (~100-300 ms) on every dictation. A shared session keeps the
/// connection warm across recognitions, cleanup and the language check.
enum SharedSession {
    static let cloud: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.httpShouldUsePipelining = true
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = SelectionEditLimits.expandedTimeout + 5
        configuration.httpAdditionalHeaders = ["User-Agent": "Tacet/0.1"]
        return URLSession(configuration: configuration)
    }()
}
