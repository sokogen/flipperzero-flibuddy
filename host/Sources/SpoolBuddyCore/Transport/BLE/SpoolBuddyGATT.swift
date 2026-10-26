import Foundation

/// The GATT service the SpoolBuddy FAP publishes (plan, Technical Details).
/// No pairing: the characteristics need no encryption by default.
public enum SpoolBuddyGATT {
    /// The service, also advertised so a scan can filter on it.
    public static let service = UUID(uuidString: "51C07E84-E37E-4D52-AC6D-B2003116F506")!
    /// Host → Flipper: write with or without response, up to 243 bytes.
    public static let rx = UUID(uuidString: "D250A7B1-D301-43F6-928E-BF2CA5D115BD")!
    /// Flipper → host: notify, up to 243 bytes.
    public static let tx = UUID(uuidString: "C3AB2366-401D-482C-9002-B0A046C2A4E4")!
}
