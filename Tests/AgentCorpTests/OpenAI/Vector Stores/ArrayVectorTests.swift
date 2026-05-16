import Foundation
import Testing
@testable import AgentCorp

struct ArrayVectorTests {
	@Test("Magnitude calculations")
	func magnitude() {
		#expect(Vector().magnitude() == 0)
		#expect(Vector([3.0]).magnitude() == 3)
		#expect(Vector([3.0, 4.0]).magnitude() == 5)
		#expect(Vector([-3.0, -4.0]).magnitude() == 5)
		#expect(Vector([-3.0, 4.0]).magnitude() == 5)
	}
	
	@Test("Unit vector normalization")
	func unitVectors() {
		#expect(Vector().unitVector()?.isEmpty == true)
		#expect(Vector([0.0, 0.0, 0.0]).unitVector() == nil)
		#expect(Vector([5.0]).unitVector() == [1])
		
		let typical = Vector([3.0, 4.0]).unitVector()
		if let typical {
			#expect(typical.count == 2)
			#expect(abs(typical[0] - 0.6) < 0.001)
			#expect(abs(typical[1] - 0.8) < 0.001)
		} else {
			Issue.record("Expected unit vector for typical values")
		}
		
		let negative = Vector([-3.0, -4.0]).unitVector()
		if let negative {
			#expect(negative.count == 2)
			#expect(abs(negative[0] + 0.6) < 0.001)
			#expect(abs(negative[1] + 0.8) < 0.001)
		} else {
			Issue.record("Expected unit vector for negative values")
		}
	}
	
	@Test("Cosine similarity on raw vectors")
	func cosineSimilarity() {
		#expect(Vector([1.0, 2.0, 3.0]).cosineSimilarity(to: [1.0, 2.0, 3.0]) == 1)
		#expect(Vector([1.0, 0.0]).cosineSimilarity(to: [0.0, 1.0]) == 0)
		#expect(Vector([1.0, 0.0]).cosineSimilarity(to: [-1.0, 0.0]) == -1)
		#expect(Vector([0.0, 0.0]).cosineSimilarity(to: [1.0, 2.0]) == 0)
		#expect(Vector([1.0, 2.0, 3.0]).cosineSimilarity(to: [1.0, 2.0]) == 0)
	}
	
	@Test("Cosine similarity on unit vectors")
	func cosineSimilarityForUnitVectors() {
		let unit = Vector([1.0, 0.0, 0.0]).unitVector()!
		#expect(unit.cosineSimilarityForUnitVector(to: unit) == 1)
		
		let perpendicularA = Vector([1.0, 0.0, 0.0]).unitVector()!
		let perpendicularB = Vector([0.0, 1.0, 0.0]).unitVector()!
		#expect(perpendicularA.cosineSimilarityForUnitVector(to: perpendicularB) == 0)
		
		let oppositeA = Vector([1.0, 0.0]).unitVector()!
		let oppositeB = Vector([-1.0, 0.0]).unitVector()!
		#expect(oppositeA.cosineSimilarityForUnitVector(to: oppositeB) == -1)
		
		let differentLengths = unit.cosineSimilarityForUnitVector(to: Vector([1.0, 0.0]).unitVector()!)
		#expect(differentLengths == 0)
	}
	
	@Test("Euclidean distance")
	func euclideanDistance() {
		#expect(Vector([1.0, 2.0, 3.0]).euclideanDistance(to: [1.0, 2.0, 3.0]) == 0)
		#expect(abs(Vector([1.0, 2.0, 3.0]).euclideanDistance(to: [4.0, 5.0, 6.0]) - sqrt(27)) < 0.0001)
		#expect(abs(Vector([0.0, 0.0, 0.0]).euclideanDistance(to: [1.0, 2.0, 3.0]) - sqrt(14)) < 0.0001)
		#expect(Vector([1.0, 2.0, 3.0]).euclideanDistance(to: [1.0, 2.0]) == .greatestFiniteMagnitude)
		#expect(abs(Vector([-1.0, -2.0, -3.0]).euclideanDistance(to: [-4.0, -5.0, -6.0]) - sqrt(27)) < 0.0001)
	}
}
