import Foundation

enum AFMEntitlements {
    private static let privateCloudComputeKey = "com.apple.developer.private-cloud-compute"

    /// Returns whether the signed app includes Apple's PCC entitlement.
    /// Reads the embedded provisioning profile when present (Xcode debug installs).
    /// Store/TestFlight builds omit that file, so we defer to Foundation Models availability checks.
    static var hasPrivateCloudCompute: Bool {
        guard let entitlements = embeddedProvisionEntitlements() else {
            return true
        }
        if let enabled = entitlements[privateCloudComputeKey] as? Bool {
            return enabled
        }
        return entitlements[privateCloudComputeKey] != nil
    }

    private static func embeddedProvisionEntitlements() -> [String: Any]? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let ascii = String(data: data, encoding: .ascii),
              let xmlStart = ascii.range(of: "<?xml"),
              let xmlEnd = ascii.range(of: "</plist>") else {
            return nil
        }

        let plistXML = String(ascii[xmlStart.lowerBound..<xmlEnd.upperBound])
        guard let plistData = plistXML.data(using: .ascii),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else {
            return nil
        }

        return entitlements
    }
}
