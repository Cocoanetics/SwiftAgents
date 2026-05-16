import Foundation

/// Represents a list of models returned by the Google AI API.
public struct GoogleModelListResponse: Codable {
    /// The array of models
    public let models: [GoogleModel]

    /// Token for retrieving the next page of results
    public let nextPageToken: String?
}

// extension GoogleModelListResponse: ModelListResponse {
//    public var object: String {
//        "list"
//    }
//    
//    public var data: [Model] {
//        models
//    }
// } 
