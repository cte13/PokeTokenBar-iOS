import Foundation

/// `loadCodeAssist` 응답에서 **티어 정보만** 뽑아 요약한다(진단 전용).
///
/// 왜 값까지 보나: 응답에 quota 필드가 없었다(#34 실측). 남은 가능성은 티어 `description` 에 한도가
/// 산문으로 적혀 있는 경우다(예: "1,000 requests per day"). 이름·설명은 계정마다 다른 값이 아니라
/// 제품 문구라서 남겨도 개인정보가 아니다.
///
/// 반대로 `cloudaicompanionProject` 는 **계정 식별자**다 — 절대 포함하지 않는다. 이건 주의로 지키는
/// 게 아니라 테스트(`testProjectIdentifierIsNeverIncluded`)로 지킨다.
enum AntigravityTierSummary {
    /// 담아도 되는 필드만 화이트리스트로 고정한다. 새 필드가 응답에 생겨도 자동으로 새어 나가지 않는다.
    private static let allowedFields = ["id", "name", "description"]

    static func describe(_ data: Data, maxFieldLength: Int = 200) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "<JSON 아님>"
        }
        var parts: [String] = []
        for key in ["currentTier", "paidTier"] {
            if let tier = json[key] as? [String: Any] {
                parts.append("\(key)(\(fields(of: tier, maxFieldLength: maxFieldLength)))")
            }
        }
        if let allowed = json["allowedTiers"] as? [[String: Any]] {
            let each = allowed.map { "(\(fields(of: $0, maxFieldLength: maxFieldLength)))" }
            parts.append("allowedTiers[\(allowed.count)]" + each.joined(separator: ""))
        }
        return parts.isEmpty ? "<티어 필드 없음>" : parts.joined(separator: " ")
    }

    private static func fields(of tier: [String: Any], maxFieldLength: Int) -> String {
        allowedFields.compactMap { field -> String? in
            guard let value = tier[field] as? String, !value.isEmpty else { return nil }
            let clipped = value.count > maxFieldLength
                ? String(value.prefix(maxFieldLength)) + "…"
                : value
            return "\(field)=\(clipped.replacingOccurrences(of: "\n", with: " "))"
        }.joined(separator: ",")
    }
}
