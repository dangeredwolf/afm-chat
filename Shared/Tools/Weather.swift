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

  func call(arguments: Arguments) async throws -> ToolOutput {
      // Create a geocoder to convert city name to coordinates
      let geocoder = CLGeocoder()
      
      // Get coordinates for the city
      let locations = try await geocoder.geocodeAddressString(arguments.city)
      guard let location = locations.first?.location else {
          throw NSError(domain: "WeatherTool", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not find location for city: \(arguments.city)"])
      }
      
      // Get weather data using WeatherKit
      let weather = try await weatherService.weather(for: location)
      let currentWeather = weather.currentWeather
      
      // Create forecast with real data
      let forecast = """
          Current forecase for \(arguments.city):
          Temperature: \(Int(round(currentWeather.temperature.value))) \(currentWeather.temperature.unit),
          Condition: \(currentWeather.condition.description),
          Humidity: \(Int(round(currentWeather.humidity * 100))),
          WindSpeed: \(currentWeather.wind.speed.value)
          """;
      
      return ToolOutput(forecast)
  }
}
