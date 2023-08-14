import Foundation
import SwiftSignalKit

enum RequestError: Error {
    case unknownError
    case connectionError
    case authorizationError
    case invalidRequest
    case notFound
    case invalidResponse
    case serverError
    case serverUnavailable
    case parseError
}

enum HTTPMethod: String {
    case options = "OPTIONS"
    case get     = "GET"
    case head    = "HEAD"
    case post    = "POST"
    case put     = "PUT"
    case patch   = "PATCH"
    case delete  = "DELETE"
    case trace   = "TRACE"
    case connect = "CONNECT"
}

protocol APIService {
    func fetchCurrentDate() -> Signal<Int32, NoError>
}

final class TestAPIManager: APIService {
    let dateUrl = "http://worldtimeapi.org/api/timezone/Europe/Moscow"
    
    func fetchCurrentDate() -> Signal<Int32, NoError> {
        return Signal { [weak self] subscriber in
            guard let strongSelf = self else { return ActionDisposable {} }
            strongSelf.executeRequest(url: strongSelf.dateUrl, completion: { data, error in
                guard let data = data,
                      error == nil else { return }
                do {
                    let parsedResult = try JSONDecoder().decode(DateModel.self, from: data)
                    print("current date: \(parsedResult.datetime)")
                    subscriber.putNext(parsedResult.unixtime)
                    subscriber.putCompletion()
                }
                catch let parseJSONError {
                    print("error: \(parseJSONError)")
                }
            })
            return ActionDisposable {}
        }
    }
}

private extension TestAPIManager {
    func executeRequest(url: String, completion: @escaping (Data?, Error?) -> Void) {
        
        guard let urlRequest = RequestBuilder.buildSimpleRequest(url: url) else {
            completion(nil, RequestError.invalidRequest)
            return
        }
        
        performRequest(request: urlRequest) { [weak self] data, response, error in
            guard let self = self else { return }
            self.handleNetworkResponse(data: data, response: response, error: error, completion: completion)
        }
    }
    
    func performRequest(request: URLRequest,
                        completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        let dataTask = URLSession.shared.dataTask(with: request, completionHandler: completion)
        dataTask.resume()
    }
    
    func handleNetworkResponse(data: Data?, response: URLResponse?, error: Error?, completion: @escaping (Data?, Error?) -> Void) {
        if let error = error {
            print(error)
            completion(nil, RequestError.connectionError)
        } else if let data = data,
                  let response = response as? HTTPURLResponse {
            switch response.statusCode {
            case 200:
                completion(data, nil)
            case 400...499:
                completion(nil, RequestError.authorizationError)
            case 500...599:
                completion(nil, RequestError.serverError)
            default:
                completion(nil, RequestError.unknownError)
                break
            }
        } else {
            completion(nil, RequestError.unknownError)
        }
    }
}
