import FoundationModels
import WeatherKit
import CoreLocation

struct WeatherTool: Tool {
  let name = "getWeather"
  let description = "Retrieve the latest weather information for a city"

  private let weatherService = WeatherService.shared

  @Generable
  struct Arguments {
      @Guide(description: "The city to get weather information for")
      var city: String
  }

  struct Forecast: Encodable {
      var city: String
      var temperature: Int
      var condition: String
      var humidity: Int
      var windSpeed: Double
  }

  func call(arguments: Arguments) async throws -> [String] {
      do {
          // Create a geocoder to convert city name to coordinates
          let geocoder = CLGeocoder()
          
          // Get coordinates for the city
          let locations = try await geocoder.geocodeAddressString(arguments.city)
          guard let location = locations.first?.location else {
              throw NSError(domain: "WeatherTool", code: 1, userInfo: [
                  NSLocalizedDescriptionKey: "Could not find location for city: \(arguments.city). Please check the city name and try again."
              ])
          }
          
          // Get weather data using WeatherKit
          let weather = try await weatherService.weather(for: location)
          let currentWeather = weather.currentWeather
          
          // Create forecast with real data
          let forecast = """
              Current forecast for \(arguments.city):
              Temperature: \(Int(round(currentWeather.temperature.value)))°\(currentWeather.temperature.unit.symbol)
              Condition: \(currentWeather.condition.description)
              Humidity: \(Int(round(currentWeather.humidity * 100)))%
              Wind Speed: \(String(format: "%.1f", currentWeather.wind.speed.value)) \(currentWeather.wind.speed.unit.symbol)
              """
          
          return [forecast]
      } catch {
          // Provide more specific error handling
          if error.localizedDescription.contains("WDSJWTAuthenticator") {
              throw NSError(domain: "WeatherTool", code: 2, userInfo: [
                  NSLocalizedDescriptionKey: "Weather service authentication failed. Please check your WeatherKit entitlements and make sure you have proper permissions enabled."
              ])
          } else if error.localizedDescription.contains("network") || error.localizedDescription.contains("offline") {
              throw NSError(domain: "WeatherTool", code: 3, userInfo: [
                  NSLocalizedDescriptionKey: "Network connection failed. Please check your internet connection and try again."
              ])
          } else {
              throw NSError(domain: "WeatherTool", code: 4, userInfo: [
                  NSLocalizedDescriptionKey: "Weather lookup failed: \(error.localizedDescription)"
              ])
          }
      }
  }
}

/// A wrapper specifically for WeatherTool that handles errors gracefully
struct SafeWeatherTool: Tool {
    let name = "getWeather"
    let description = "Retrieve the latest weather information for a city"
    
    private let weatherTool = WeatherTool()
    
    @Generable
    struct Arguments {
        @Guide(description: "The city to get weather information for")
        var city: String
    }
    
    func call(arguments: Arguments) async throws -> [String] {
        do {
            // Try to call the weather tool with the same arguments
            let weatherArgs = WeatherTool.Arguments(city: arguments.city)
            return try await weatherTool.call(arguments: weatherArgs)
        } catch {
            // If the tool fails, return a graceful error response
            let errorMessage = """
            I encountered an issue while trying to retrieve weather information: \(error.localizedDescription)
            
            This might be due to:
            - WeatherKit authentication issues
            - Network connectivity problems  
            - Missing WeatherKit entitlements
            - Weather service temporarily unavailable
            
            You can try checking the weather using other apps or websites in the meantime.
            """
            
            return [errorMessage]
        }
    }
}
