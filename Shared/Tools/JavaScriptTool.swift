import FoundationModels
import JavaScriptCore
import Foundation

/// A tool that executes JavaScript code using JavaScriptCore
struct _JavaScriptTool: Tool {
    let name = "executeJavaScript"
    let description = "Execute JavaScript code and return the result"
    
    @Generable
    struct Arguments {
        @Guide(description: "The JavaScript code to execute")
        var code: String
    }
    
    func call(arguments: Arguments) async throws -> ToolOutput {
        do {
            // Create a new JavaScript context for each execution
            let context = JSContext()!
            
            // Set up console.log functionality
            var consoleOutput: [String] = []
            let consoleLog: @convention(block) (JSValue) -> Void = { message in
                consoleOutput.append(message.toString())
            }
            context.setObject(consoleLog, forKeyedSubscript: "consoleLog" as NSString)
            
            // Inject console object
            context.evaluateScript("""
                var console = {
                    log: function() {
                        var args = Array.prototype.slice.call(arguments);
                        var message = args.map(function(arg) {
                            if (typeof arg === 'object') {
                                return JSON.stringify(arg, null, 2);
                            }
                            return String(arg);
                        }).join(' ');
                        consoleLog(message);
                    }
                };
            """)
            
            // Set up error handling
            context.exceptionHandler = { context, exception in
                print("JavaScript Error: \(exception?.toString() ?? "Unknown error")")
            }
            
            // Execute the user's code
            let result = context.evaluateScript(arguments.code)
            
            // Check for exceptions
            if let exception = context.exception {
                let errorMessage = """
                JavaScript execution failed with error:
                \(exception.toString() ?? "Unknown error")
                
                Code executed:
                ```javascript
                \(arguments.code)
                ```
                """
                return ToolOutput(errorMessage)
            }
            
            // Format the output
            var output = ""
            
            // Add console output if any
            if !consoleOutput.isEmpty {
                for line in consoleOutput {
                    output += "\(line)\n"
                }
                output += "\n"
            }
            
            // Add return value if it exists and is not undefined
            if let result = result, !result.isUndefined {
                if result.isObject {
                    // Try to stringify objects
                    let stringify = context.evaluateScript("JSON.stringify")
                    if let stringified = stringify?.call(withArguments: [result, NSNull(), 2]) {
                        output += stringified.toString()
                    } else {
                        output += result.toString()
                    }
                } else {
                    output += result.toString()
                }
            }
            
            // If no output, indicate successful execution
            if output.isEmpty {
                output = "undefined"
            }
            
            return ToolOutput(output)
            
        } catch {
            throw NSError(
                domain: "JavaScriptTool", 
                code: 1, 
                userInfo: [NSLocalizedDescriptionKey: "Failed to execute JavaScript: \(error.localizedDescription)"]
            )
        }
    }
}

/// Safe wrapper for JavaScript tool that handles errors gracefully
struct JavaScriptTool: Tool {
    let name = "Code Interpreter"
    let description = "Assist the user by executing JavaScript code to perform advanced calculations, data analysis, web requests, etc. Console logs are not currently displayed at this time, so you should return necessary values instead."
    
    private let jsTool = _JavaScriptTool()
    
    @Generable
    struct Arguments {
        @Guide(description: "The JavaScript code to execute")
        var code: String
    }
    
    func call(arguments: Arguments) async throws -> ToolOutput {
        do {
            let jsArgs = _JavaScriptTool.Arguments(code: arguments.code)
            return try await jsTool.call(arguments: jsArgs)
        } catch {
            return ToolOutput(error.localizedDescription)
        }
    }
} 
