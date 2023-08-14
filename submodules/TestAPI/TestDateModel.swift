import Foundation

struct TestDateModel: Decodable {
    
    let datetime: String
    let timezone: String
    let unixtime: Int32
    
    enum CodingKeys: String, CodingKey {
        case datetime
        case timezone
        case unixtime
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.datetime = try container.decode(String.self, forKey: .datetime)
        self.timezone = try container.decode(String.self, forKey: .timezone)
        self.unixtime = try container.decode(Int32.self, forKey: .unixtime)
    }
}
