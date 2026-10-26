import Foundation

/// The GATT service the FliBuddy FAP publishes (plan, Technical Details).
/// No pairing: the characteristics need no encryption by default.
public enum FliBuddyGATT {
    /// The service, also advertised so a scan can filter on it.
    public static let service = UUID(uuidString: "51C07E84-E37E-4D52-AC6D-B2003116F506")!
    /// Host → Flipper: write with or without response, up to 243 bytes.
    public static let rx = UUID(uuidString: "D250A7B1-D301-43F6-928E-BF2CA5D115BD")!
    /// Flipper → host: notify, up to 243 bytes.
    public static let tx = UUID(uuidString: "C3AB2366-401D-482C-9002-B0A046C2A4E4")!
    /// The company id the FAP puts in its scan response's manufacturer data,
    /// 0xFFFF (reserved for tests), followed by the Flipper's name.
    public static let companyID: UInt16 = 0xFFFF

    /// The Flipper's name in manufacturer data (company id little-endian,
    /// then the name, as `CBAdvertisementDataManufacturerDataKey` holds it);
    /// nil for another company, no name or a name that is not UTF-8.
    public static func name(manufacturerData data: Data?) -> String? {
        guard let data, data.count > 2 else { return nil }
        let bytes = [UInt8](data)
        guard UInt16(bytes[0]) | UInt16(bytes[1]) << 8 == companyID else { return nil }
        return String(bytes: bytes[2...], encoding: .utf8)
    }

    /// The name a scan shows. The advertisement has no room for the name
    /// (flipper/src/ble_wire.h), so before the GAP name is known it comes
    /// from the scan response's manufacturer data.
    public static func displayName(peripheralName: String?, localName: String?, manufacturerData: Data?) -> String {
        peripheralName ?? localName ?? name(manufacturerData: manufacturerData) ?? "Flipper"
    }
}
