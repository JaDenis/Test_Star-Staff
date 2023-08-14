import Foundation

final class RequestBuilder {
    
    private static let defaultHeaders = [
        "Content-Type" : "application/json"
    ]
    
    static func buildSimpleRequest(url: String) -> URLRequest? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = defaultHeaders
        return request
    }
}
