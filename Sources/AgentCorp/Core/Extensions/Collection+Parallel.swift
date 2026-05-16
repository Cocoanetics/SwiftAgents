import Foundation

extension Collection {
    public func concurrentMap<T>(
        _ transform: @escaping (Element) async throws -> T
    ) async throws -> [T] {
        try await withThrowingTaskGroup(of: (Int, T).self) { group in

			// placeholders so that results are assembled in same order
            var results = Array<T?>(repeating: nil, count: self.count)
            
            for (index, element) in self.enumerated() {
                group.addTask {
                    let transformed = try await transform(element)
                    return (index, transformed)
                }
            }
            for try await (index, result) in group {
                results[index] = result
            }
            
            // convert to non-optional
            return results.compactMap { $0 }
        }
    }
}
