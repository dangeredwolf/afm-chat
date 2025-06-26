import FoundationModels
import CoreLocation
import Foundation
import ObjectiveC

/// Location manager delegate for handling permission requests and location updates
private class LocationPermissionDelegate: NSObject, CLLocationManagerDelegate {
    let completion: (Result<ToolOutput, Error>) -> Void
    let requestPreciseLocation: Bool
    private var hasCompleted = false
    
    init(requestPreciseLocation: Bool, completion: @escaping (Result<ToolOutput, Error>) -> Void) {
        self.requestPreciseLocation = requestPreciseLocation
        self.completion = completion
        super.init()
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Prevent multiple completions
        guard !hasCompleted else { return }
        
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            // Permission granted, now request location
            manager.requestLocation()
        case .denied, .restricted:
            hasCompleted = true
            completion(.failure(NSError(
                domain: "LocationTool",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Location access denied. Please enable location services in Settings > Privacy & Security > Location Services."]
            )))
        case .notDetermined:
            // Still waiting for user response - this should not happen after requestWhenInUseAuthorization
            // but if it does, we'll set a timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self = self, !self.hasCompleted else { return }
                self.hasCompleted = true
                self.completion(.failure(NSError(
                    domain: "LocationTool",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Location permission request timed out. Please try again."]
                )))
            }
        @unknown default:
            hasCompleted = true
            completion(.failure(NSError(
                domain: "LocationTool",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Unknown location authorization status."]
            )))
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !hasCompleted else { return }
        guard let location = locations.last else {
            hasCompleted = true
            completion(.failure(NSError(
                domain: "LocationTool",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "No location data received."]
            )))
            return
        }
        
        hasCompleted = true
        Task {
            let output = await formatLocationOutput(location: location, requestPreciseLocation: requestPreciseLocation)
            completion(.success(ToolOutput(output)))
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard !hasCompleted else { return }
        hasCompleted = true
        
        let errorMessage: String
        
        if let clError = error as? CLError {
            switch clError.code {
            case .locationUnknown:
                errorMessage = "Unable to determine location. Please try again."
            case .denied:
                errorMessage = "Location access denied. Please enable location services in Settings."
            case .network:
                errorMessage = "Network error while trying to get location. Please check your connection."
            case .geocodeFoundNoResult:
                errorMessage = "No location data available."
            case .geocodeCanceled:
                errorMessage = "Location request was canceled."
            default:
                errorMessage = "Location error: \(clError.localizedDescription)"
            }
        } else {
            errorMessage = "Failed to get location: \(error.localizedDescription)"
        }
        
        completion(.failure(NSError(
            domain: "LocationTool",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: errorMessage]
        )))
    }
    
    private func formatLocationOutput(location: CLLocation, requestPreciseLocation: Bool) async -> String {
        let accuracyLevel = location.horizontalAccuracy > 1000 ? " (coarse location for privacy)" : ""
        var output = """
        Current Location:
        Latitude: \(location.coordinate.latitude)
        Longitude: \(location.coordinate.longitude)
        Accuracy: ±\(String(format: "%.0f", location.horizontalAccuracy))m\(accuracyLevel)
        """
        
        if location.altitude != 0 {
            output += "\nAltitude: \(String(format: "%.0f", location.altitude))m"
        }
        
        if requestPreciseLocation {
            // Add timestamp
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
            output += "\nTimestamp: \(formatter.string(from: location.timestamp))"
            
            // Try to get address information
            do {
                let geocoder = CLGeocoder()
                let placemarks = try await geocoder.reverseGeocodeLocation(location)
                
                if let placemark = placemarks.first {
                    output += "\n\nAddress Details:"
                    
                    if let name = placemark.name {
                        output += "\nLocation: \(name)"
                    }
                    
                    if let street = placemark.thoroughfare {
                        output += "\nStreet: \(street)"
                    }
                    
                    if let city = placemark.locality {
                        output += "\nCity: \(city)"
                    }
                    
                    if let state = placemark.administrativeArea {
                        output += "\nState/Province: \(state)"
                    }
                    
                    if let country = placemark.country {
                        output += "\nCountry: \(country)"
                    }
                    
                    if let postalCode = placemark.postalCode {
                        output += "\nPostal Code: \(postalCode)"
                    }
                    
                    if let timeZone = placemark.timeZone {
                        output += "\nTime Zone: \(timeZone.identifier)"
                    }
                }
            } catch {
                output += "\n\nNote: Could not retrieve address details: \(error.localizedDescription)"
            }
        }
        
        return output
    }
}

/// Location manager delegate for handling location updates when permission is already granted
private class LocationDelegate: NSObject, CLLocationManagerDelegate {
    let completion: (Result<ToolOutput, Error>) -> Void
    let requestPreciseLocation: Bool
    
    init(requestPreciseLocation: Bool, completion: @escaping (Result<ToolOutput, Error>) -> Void) {
        self.requestPreciseLocation = requestPreciseLocation
        self.completion = completion
        super.init()
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            completion(.failure(NSError(
                domain: "LocationTool",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "No location data received."]
            )))
            return
        }
        
        Task {
            let output = await formatLocationOutput(location: location, requestPreciseLocation: requestPreciseLocation)
            completion(.success(ToolOutput(output)))
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let errorMessage: String
        
        if let clError = error as? CLError {
            switch clError.code {
            case .locationUnknown:
                errorMessage = "Unable to determine location. Please try again."
            case .denied:
                errorMessage = "Location access denied. Please enable location services in Settings."
            case .network:
                errorMessage = "Network error while trying to get location. Please check your connection."
            case .geocodeFoundNoResult:
                errorMessage = "No location data available."
            case .geocodeCanceled:
                errorMessage = "Location request was canceled."
            default:
                errorMessage = "Location error: \(clError.localizedDescription)"
            }
        } else {
            errorMessage = "Failed to get location: \(error.localizedDescription)"
        }
        
        completion(.failure(NSError(
            domain: "LocationTool",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: errorMessage]
        )))
    }
    
    private func formatLocationOutput(location: CLLocation, requestPreciseLocation: Bool) async -> String {
        let accuracyLevel = location.horizontalAccuracy > 1000 ? " (coarse location for privacy)" : ""
        var output = """
        Current Location:
        Latitude: \(location.coordinate.latitude)
        Longitude: \(location.coordinate.longitude)
        Accuracy: ±\(String(format: "%.0f", location.horizontalAccuracy))m\(accuracyLevel)
        """
        
        if location.altitude != 0 {
            output += "\nAltitude: \(String(format: "%.0f", location.altitude))m"
        }
        
        if requestPreciseLocation {
            // Add timestamp
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
            output += "\nTimestamp: \(formatter.string(from: location.timestamp))"
            
            // Try to get address information
            do {
                let geocoder = CLGeocoder()
                let placemarks = try await geocoder.reverseGeocodeLocation(location)
                
                if let placemark = placemarks.first {
                    output += "\n\nAddress Details:"
                    
                    if let name = placemark.name {
                        output += "\nLocation: \(name)"
                    }
                    
                    if let street = placemark.thoroughfare {
                        output += "\nStreet: \(street)"
                    }
                    
                    if let city = placemark.locality {
                        output += "\nCity: \(city)"
                    }
                    
                    if let state = placemark.administrativeArea {
                        output += "\nState/Province: \(state)"
                    }
                    
                    if let country = placemark.country {
                        output += "\nCountry: \(country)"
                    }
                    
                    if let postalCode = placemark.postalCode {
                        output += "\nPostal Code: \(postalCode)"
                    }
                    
                    if let timeZone = placemark.timeZone {
                        output += "\nTime Zone: \(timeZone.identifier)"
                    }
                }
            } catch {
                output += "\n\nNote: Could not retrieve address details: \(error.localizedDescription)"
            }
        }
        
        return output
    }
}

/// A tool that provides the user's current location information
struct _LocationTool: Tool {
    let name = "Location"
    let description = "Get the user's current location"
    @Generable
    struct Arguments {
        @Guide(description: "Request precise location with detailed address information. Only request this if you absolutely need to know the user's exact location.")
        var requestPreciseLocation: Bool = false
    }
    
    func call(arguments: Arguments) async throws -> ToolOutput {
        let locationManager = CLLocationManager()
        
        // Check location authorization status
        let authStatus = locationManager.authorizationStatus
        
        switch authStatus {
        case .notDetermined:
            // Request permission and then get location
            return try await requestPermissionAndGetLocation(locationManager: locationManager, requestPreciseLocation: arguments.requestPreciseLocation)
        case .denied, .restricted:
            throw NSError(
                domain: "LocationTool",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Location access denied. Instruct the user to enable location services in iOS settings."]
            )
        case .authorizedWhenInUse, .authorizedAlways:
            // Permission already granted, get location directly
            return try await getCurrentLocation(locationManager: locationManager, requestPreciseLocation: arguments.requestPreciseLocation)
        @unknown default:
            throw NSError(
                domain: "LocationTool",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Unknown location authorization status."]
            )
        }
    }
    
    private func requestPermissionAndGetLocation(locationManager: CLLocationManager, requestPreciseLocation: Bool) async throws -> ToolOutput {
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = LocationPermissionDelegate(requestPreciseLocation: requestPreciseLocation) { result in
                continuation.resume(with: result)
            }
            
            locationManager.delegate = delegate
            
            // Set accuracy based on precision preference
            if requestPreciseLocation {
                locationManager.desiredAccuracy = kCLLocationAccuracyBest
            } else {
                // Use coarse location for privacy - approximately 1-3 km accuracy
                locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
            }
            
            // Store delegate reference to keep it alive
            objc_setAssociatedObject(locationManager, "delegate_ref", delegate, .OBJC_ASSOCIATION_RETAIN)
            
            // Request permission first
            locationManager.requestWhenInUseAuthorization()
        }
    }
    
    private func getCurrentLocation(locationManager: CLLocationManager, requestPreciseLocation: Bool) async throws -> ToolOutput {
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = LocationDelegate(requestPreciseLocation: requestPreciseLocation) { result in
                continuation.resume(with: result)
            }
            
            locationManager.delegate = delegate
            
            // Set accuracy based on precision preference
            if requestPreciseLocation {
                locationManager.desiredAccuracy = kCLLocationAccuracyBest
            } else {
                // Use coarse location for privacy - approximately 1-3 km accuracy
                locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
            }
            
            // Store delegate reference to keep it alive
            objc_setAssociatedObject(locationManager, "delegate_ref", delegate, .OBJC_ASSOCIATION_RETAIN)
            
            locationManager.requestLocation()
        }
    }
}

/// Safe wrapper for Location tool that handles errors gracefully
struct LocationTool: Tool {
    let name = "Location"
    let description = "Get the user's current location coordinates and optionally detailed address information"
    
    private let locationTool = _LocationTool()
    
    @Generable
    struct Arguments {
        @Guide(description: "Whether to request precise location with detailed address information. If false, uses coarse location for privacy.")
        var requestPreciseLocation: Bool = false
    }
    
    func call(arguments: Arguments) async throws -> ToolOutput {
        do {
            let locationArgs = _LocationTool.Arguments(requestPreciseLocation: arguments.requestPreciseLocation)
            return try await locationTool.call(arguments: locationArgs)
        } catch {
            return ToolOutput(error.localizedDescription)
        }
    }
} 
