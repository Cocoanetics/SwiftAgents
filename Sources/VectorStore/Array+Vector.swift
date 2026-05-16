//
//  Array+Vector.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 16.04.24.
//

#if canImport(Accelerate)

import Accelerate
import Foundation
import Providers

public extension Sequence<Double> {
    /// Computes the Euclidean norm (magnitude) of a vector.
    ///
    /// - Returns: The magnitude of the vector, calculated as the square root of the sum of the squares of the elements.
    func magnitude() -> Double {
        var result = 0.0
        let array = Array(self)
        vDSP_svesqD(array, 1, &result, vDSP_Length(array.count))
        return sqrt(result)
    }

    /// Converts a vector to its unit vector form.
    ///
    /// This function normalizes the vector to a unit vector by dividing each element by the vector's magnitude.
    /// Returns `nil` if the vector's magnitude is zero, and returns an empty array if the input is an empty array.
    ///
    /// - Returns: A unit vector of the original vector or nil if the magnitude is zero.
    func unitVector() -> Vector? {
        let array = Array(self)

        // Handle the empty array case explicitly
        if array.isEmpty {
            return []
        }

        let mag = array.magnitude()

        guard mag != 0 else {
            return nil
        }

        var normalized = Vector(repeating: 0.0, count: array.count)
        vDSP_vsdivD(array, 1, [mag], &normalized, 1, vDSP_Length(array.count))

        return normalized
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

        // Check for zero magnitude to avoid division by zero
        if myMagnitude == 0 || otherMagnitude == 0 {
            return 0
        }

        var result = 0.0
        vDSP_dotprD(array, 1, otherVector, 1, &result, vDSP_Length(array.count))
        return result / (myMagnitude * otherMagnitude)
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

        var result = 0.0
        vDSP_dotprD(array, 1, otherUnitVector, 1, &result, vDSP_Length(array.count))
        return result
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

        var differences = Vector(repeating: 0.0, count: array.count)
        vDSP_vsubD(otherVector, 1, array, 1, &differences, 1, vDSP_Length(array.count))

        var squaredDifferences = Vector(repeating: 0.0, count: array.count)
        vDSP_vsqD(differences, 1, &squaredDifferences, 1, vDSP_Length(array.count))

        var sumOfSquaredDifferences = 0.0
        vDSP_sveD(squaredDifferences, 1, &sumOfSquaredDifferences, vDSP_Length(array.count))

        return sqrt(sumOfSquaredDifferences)
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
        guard !isEmpty, let firstLength = first?.count else {
            return nil
        }

        // Ensure all vectors are of the same length
        guard allSatisfy({ $0.count == firstLength }) else {
            return nil
        }

        if self.count == 1 {
            return first
        }

        var result = Vector(repeating: 0.0, count: firstLength)
        var count = 0.0

        for vector in self {
            var tempResult = Vector(repeating: 0.0, count: firstLength)
            vDSP_vaddD(result, 1, vector, 1, &tempResult, 1, vDSP_Length(firstLength))
            result = tempResult
            count += 1
        }

        // Average the result by dividing each element by the count of vectors
        if count > 0 {
            vDSP_vsdivD(result, 1, [count], &result, 1, vDSP_Length(firstLength))
        }

        return result
    }

    /// Computes the unit vector of the element-wise average of multiple vectors.
    ///
    /// This function first computes the average vector using `averageVector()` and then normalizes it.
    /// - Returns: A unit vector of the average vector, or nil if the average vector cannot be normalized.
    func averageUnitVector() -> Vector? {
        guard let avgVector = averageVector() else {
            return nil
        }

        // Normalize the average vector to get the unit vector
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

        // Ensure all vectors are of the same length
        guard allSatisfy({ $0.count == firstLength }) else {
            return nil
        }

        if count == 1 {
            return first
        }

        var result = Vector(repeating: 0.0, count: firstLength)

        for vector in self {
            // Use Accelerate to add vectors directly
            vDSP_vaddD(result, 1, vector, 1, &result, 1, vDSP_Length(firstLength))
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

        // Normalize the sum vector to get the unit vector
        return sumVector.unitVector()
    }
}

#endif
