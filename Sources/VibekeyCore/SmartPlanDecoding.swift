import Foundation
import CoreFoundation

/// Validates the small, locally pinned tool schemas before Codable can discard
/// unknown properties. This is not a general remote JSON Schema interpreter.
enum SmartPlanDecoding {
    static func decode<Response: Decodable>(_ data: Data, response: Response.Type, schema: [String:Any]) throws -> Response {
        guard data.count <= 64 * 1024, let value=try? JSONSerialization.jsonObject(with:data) else {throw SmartModelError.invalidResponse}
        try validate(value,schema:schema)
        guard let result=try? JSONDecoder().decode(response,from:data) else {throw SmartModelError.invalidResponse};return result
    }
    private static func validate(_ value:Any,schema:[String:Any]) throws {
        let types=(schema["type"] as? [String]) ?? (schema["type"] as? String).map{[$0]} ?? []
        if value is NSNull {guard types.contains("null") else {throw SmartModelError.invalidResponse};return}
        if types.contains("object") {
            guard let object=value as? [String:Any],let properties=schema["properties"] as? [String:Any],schema["additionalProperties"] as? Bool == false else {throw SmartModelError.invalidResponse}
            let required=Set(schema["required"] as? [String] ?? [])
            guard required.isSubset(of:Set(object.keys)),Set(object.keys).isSubset(of:Set(properties.keys)) else {throw SmartModelError.invalidResponse}
            for (key,child) in object {
                guard let childSchema=properties[key] as? [String:Any] else {throw SmartModelError.invalidResponse}
                // Preserve the existing Codable contract: explicit null for a
                // known optional field is equivalent to omitting that field.
                if child is NSNull,!required.contains(key) {continue}
                try validate(child,schema:childSchema)
            }
        } else if types.contains("array") {
            guard let array=value as? [Any],let item=schema["items"] as? [String:Any],array.count <= (schema["maxItems"] as? Int ?? Int.max),array.count >= (schema["minItems"] as? Int ?? 0) else {throw SmartModelError.invalidResponse}
            for child in array {try validate(child,schema:item)}
        } else if types.contains("string") {
            guard let string=value as? String else {throw SmartModelError.invalidResponse}
            if let allowed=schema["enum"] as? [String],!allowed.contains(string) {throw SmartModelError.invalidResponse}
        } else if types.contains("integer") || types.contains("number") {
            guard let number=value as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),number.doubleValue.isFinite else {throw SmartModelError.invalidResponse}
            if types.contains("integer"),number.doubleValue.rounded(.towardZero) != number.doubleValue {throw SmartModelError.invalidResponse}
        } else if types.contains("boolean") {
            guard let number=value as? NSNumber,CFGetTypeID(number) == CFBooleanGetTypeID() else {throw SmartModelError.invalidResponse}
        } else {throw SmartModelError.invalidResponse}
    }
}
