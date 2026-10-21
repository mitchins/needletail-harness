import Foundation
import NeedletailCore

/// M2-A A0: lossless `DurableRecord` <-> canonical JSON codec for durable
/// storage (SPEC §9). Foundation-only; the GRDB store (A1) persists these
/// bytes and maps failures to `.integrity` — undecodable rows are NEVER
/// substituted. Encoding is canonical (`sortedKeys`): identical values
/// produce identical bytes, so digests are stable across runs.
///
/// The value graph's Codable conformances live in Core
/// (RecordCodable.swift); `ModelProfile` decodes through its VALIDATING
/// init there, so a corrupted row cannot resurrect a profile with a
/// stale origin.
public enum RecordCodec {

    /// Encode failures propagate as `EncodingError` (the only known source
    /// is a non-finite `JSONValue.number`, which configuration loading
    /// already rejects upstream); decode failures are ALWAYS
    /// `StoreError.integrity` — an undecodable stored row is a store
    /// integrity fault by definition, and is never substituted.
    public static func encode(_ record: DurableRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(record)
    }

    public static func decode(_ data: Data) throws -> DurableRecord {
        do {
            return try JSONDecoder().decode(DurableRecord.self, from: data)
        } catch {
            // Typed failure for the store layer: a corrupted row is an
            // integrity fault, never a partial or substituted value.
            throw StoreError.integrity("record decode failed: \(error)")
        }
    }
}
