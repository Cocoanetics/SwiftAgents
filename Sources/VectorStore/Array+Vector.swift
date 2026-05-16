//
//  Array+Vector.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 16.04.24.
//

import Foundation
import Providers

// The vector math is pure-Swift so this file (and everything that uses
// it — LocalVectorStore, the OpenAI / Ollama EmbeddingProvider bridge
// files) is universal. Embedding vectors are typically 384–4096 dims;
// a tight loop over `Double` is fine at that size. The earlier
// Accelerate / `vDSP_*` implementation was an Apple-only speedup, not
// a correctness requirement — drop it so Linux / Windows / Android
// consumers can use embeddings via the OpenAI or Ollama HTTP APIs.

public extension Sequence<Double> {
    /// Computes the Euclidean norm (magnitude) of a vector.
    ///
    /// - Returns: The magnitude of the vector, calculated as the square root of the sum of the squares of the elements.
    func magnitude() -> Double {
        sqrt(reduce(0.0) { $0 + $1 * $1 })
    }

    /// Converts a vector to its unit vector form.
    ///
    /// This function normalizes the vector to a unit vector by dividing each element by the vector's magnitude.
    /// Returns `nil` if the vector's magnitude is zero, and returns an empty array if the input is an empty array.
    ///
    /// - Returns: A unit vector of the original vector or nil if the magnitude is zero.
    func unitVector() -> Vector? {
        let array = Array(self)
        if array.isEmpty {
            return []
        }
        let mag = array.magnitude()
        guard mag != 0 else {
            return nil
        }
        return array.map { $0 / mag }
    }

    /// Calculates the cosine similarity between two vectors.
    ///
    /// Cosine similarity measures the cosine of the angle between two vectors in the multidimensional space.
    /// Both vectors must have the same number of elements; otherwise, 0 is returned.
    ///
    /// - Parameter otherVector: The other vector to which the cosine similarity will be calculated.
    /// - Returns: The cosine similarity value ranging from -1 to 1, where 1 means the vectors are identical in
    /// orientation.
    func cosineSimilarity(to otherVector: Vector) -> Double {
        let array = Array(self)
        guard array.count == otherVector.count, !array.isEmpty, !otherVector.isEmpty else {
            return 0
        }
        let myMagnitude = array.magnitude()
        let otherMagnitude = otherVector.magnitude()
        if myMagnitude == 0 || otherMagnitude == 0 {
            return 0
        }
        let dot = zip(array, otherVector).reduce(0.0) { $0 + $1.0 * $1.1 }
        return dot / (myMagnitude * otherMagnitude)
    }

    /// Computes cosine similarity for unit vectors.
    ///
    /// When dealing with unit vectors (vectors of magnitude 1), the cosine similarity simplifies to just the dot
    /// product.
    /// This method assumes both vectors are unit vectors and are of the same length.
    ///
    /// - Parameter otherUnitVector: Another unit vector to compare with.
    /// - Returns: The cosine similarity value, or 0 if the vectors are not of the same length.
    func cosineSimilarityForUnitVector(to otherUnitVector: Vector) -> Double {
        let array = Array(self)
        guard array.count == otherUnitVector.count else {
            return 0
        }
        return zip(array, otherUnitVector).reduce(0.0) { $0 + $1.0 * $1.1 }
    }

    /// Calculates the Euclidean distance between this vector and another vector.
    ///
    /// Euclidean distance is the "straight line" distance between two points in Euclidean space.
    /// Both vectors must have the same number of elements; otherwise, the maximum possible double value is returned to
    /// indicate error.
    ///
    /// - Parameter otherVector: The vector to which the Euclidean distance will be calculated.
    /// - Returns: The Euclidean distance between the two vectors.
    func euclideanDistance(to otherVector: Vector) -> Double {
        let array = Array(self)
        guard array.count == otherVector.count else {
            return .greatestFiniteMagnitude
        }
        let sumOfSquares = zip(array, otherVector).reduce(0.0) { accumulator, pair in
            let difference = pair.0 - pair.1
            return accumulator + difference * difference
        }
        return sqrt(sumOfSquares)
    }
}

public extension [Vector] {
    /// Computes the element-wise average of multiple vectors contained within an array.
    ///
    /// This function returns a single vector that is the element-wise average of all vectors contained in the array.
    /// All vectors must have the same number of elements; otherwise, `nil` is returned.
    ///
    /// - Returns: A vector representing the element-wise average of all contained vectors, or nil if vectors have
    /// different lengths or the array is empty.
    func averageVector() -> Vector? {
        guard let sum = sumVector() else {
            return nil
        }
        let divisor = Double(count)
        return sum.map { $0 / divisor }
    }

    /// Computes the unit vector of the element-wise average of multiple vectors.
    ///
    /// This function first computes the average vector using `averageVector()` and then normalizes it.
    /// - Returns: A unit vector of the average vector, or nil if the average vector cannot be normalized.
    func averageUnitVector() -> Vector? {
        guard let avgVector = averageVector() else {
            return nil
        }
        return avgVector.unitVector()
    }

    /// Sums all vectors contained within the array.
    ///
    /// This function returns a single vector that is the sum of all vectors contained in the array.
    /// All vectors must have the same number of elements; otherwise, `nil` is returned.
    ///
    /// - Returns: A vector representing the sum of all contained vectors, or nil if vectors have different lengths or
    /// the array is empty.
    func sumVector() -> Vector? {
        guard !isEmpty, let firstLength = first?.count else {
            return nil
        }
        guard allSatisfy({ $0.count == firstLength }) else {
            return nil
        }
        if count == 1 {
            return first
        }
        var result = Vector(repeating: 0.0, count: firstLength)
        for vector in self {
            for index in 0 ..< firstLength {
                result[index] += vector[index]
            }
        }
        return result
    }

    /// Sums all vectors and normalizes the result to create a unit vector.
    ///
    /// This function first computes the sum of all vectors using `sumVectors()` and then normalizes it.
    /// - Returns: A unit vector of the summed vector, or nil if the sum vector cannot be normalized.
    func sumUnitVector() -> Vector? {
        guard let sumVector = sumVector() else {
            return nil
        }
        return sumVector.unitVector()
    }
}
