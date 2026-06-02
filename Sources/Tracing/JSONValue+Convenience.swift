import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import JSONValue

public extension JSONValue {
    /// Read a value out of a `.object(...)` by key. Returns nil for non-objects.
    subscript(key: String) -> JSONValue? {
        dictionaryValue?[key]
    }

    /// Read a value out of an `.array(...)` by index. Returns nil for non-arrays
    /// or out-of-bounds indices.
    subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }

    init(_ value: [String: Any]) {
        self = .object(value.mapValues(JSONValue.init(jsonObject:)))
    }

    init(_ value: [Any]) {
        self = .array(value.map(JSONValue.init(jsonObject:)))
    }

    init(_ value: any Encodable) {
        if let jsonValue = value as? JSONValue {
            self = jsonValue
            return
        }

        do {
            self = try JSONValue(encoding: value)
        } catch {
            assertionFailure("Failed to encode \(type(of: value)) as JSONValue: \(error)")
            self = .string(String(describing: value))
        }
    }

    init(_ value: (any Encodable)?) {
        guard let value else {
            self = .null
            return
        }

        self.init(value)
    }

    init(jsonObject value: Any?) {
        switch value {
            case nil, is NSNull:
                self = .null
            case let jsonValue as JSONValue:
                self = jsonValue
            case let bool as Bool:
                self = .bool(bool)
            case let int as Int:
                self = .integer(int)
            case let int8 as Int8:
                self = .integer(Int(int8))
            case let int16 as Int16:
                self = .integer(Int(int16))
            case let int32 as Int32:
                self = .integer(Int(int32))
            case let int64 as Int64:
                self = Int(exactly: int64).map(JSONValue.integer) ?? .double(Double(int64))
            case let uint as UInt:
                self = .unsignedInteger(uint)
            case let uint8 as UInt8:
                self = .unsignedInteger(UInt(uint8))
            case let uint16 as UInt16:
                self = .unsignedInteger(UInt(uint16))
            case let uint32 as UInt32:
                self = .unsignedInteger(UInt(uint32))
            case let uint64 as UInt64:
                self = UInt(exactly: uint64).map(JSONValue.unsignedInteger) ?? .double(Double(uint64))
            case let float as Float:
                self = .double(Double(float))
            case let double as Double:
                self = .double(double)
            case let number as NSNumber:
                #if canImport(Darwin)
                // On Apple platforms, `Bool` bridges to `NSNumber` via
                // `CFBoolean`; the earlier `case let bool as Bool` only
                // catches it sometimes, so re-check via the CFTypeID.
                // `CFGetTypeID` / `CFBooleanGetTypeID` aren't exposed
                // through swift-corelibs-foundation's `CoreFoundation`,
                // so gate on Darwin instead. On Linux the earlier
                // `bool as Bool` branch always wins for actual booleans.
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    self = .bool(number.boolValue)
                    break
                }
                #endif
                if let int = Int(exactly: number.int64Value), number.doubleValue == Double(int) {
                    self = .integer(int)
                } else if let uint = UInt(exactly: number.uint64Value), number.doubleValue == Double(uint) {
                    self = .unsignedInteger(uint)
                } else {
                    self = .double(number.doubleValue)
                }
            case let string as String:
                self = .string(string)
            case let array as [Any]:
                self = .array(array.map(JSONValue.init(jsonObject:)))
            case let object as [String: Any]:
                self = .object(object.mapValues(JSONValue.init(jsonObject:)))
            default:
                assertionFailure("Unsupported JSON object value: \(String(describing: value))")
                self = .string(String(describing: value))
        }
    }
}

public extension [String: JSONValue] {
    init(jsonObject value: [String: Any]) {
        self = value.mapValues(JSONValue.init(jsonObject:))
    }
}
