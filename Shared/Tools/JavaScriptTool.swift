import FoundationModels
import JavaScriptCore
import Foundation

/// Executes JavaScript code using JavaScriptCore.
struct JavaScriptTool: Tool {
    private static let definition = AppToolID.codeInterpreter.definition

    var name: String { Self.definition.displayName }
    var description: String { Self.definition.description }
    var parameters: GenerationSchema { Self.definition.generationSchema() }

    @Generable
    struct Arguments {
        var code: String
    }

    func call(arguments: Arguments) async throws -> [String] {
        Self.run(code: arguments.code)
    }

    static func run(code: String) -> [String] {
        let name = definition.displayName
        ToolExecutionTracker.begin(toolName: name, arguments: ["code": code])
        defer { ToolExecutionTracker.end(toolName: name, arguments: ["code": code]) }
        return execute(code)
    }

    private static func execute(_ code: String) -> [String] {
        let context = JSContext()!

        var consoleOutput: [String] = []
        let consoleLog: @convention(block) (JSValue) -> Void = { message in
            consoleOutput.append(message.toString())
        }
        context.setObject(consoleLog, forKeyedSubscript: "consoleLog" as NSString)

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

        context.exceptionHandler = { _, exception in
            print("JavaScript Error: \(exception?.toString() ?? "Unknown error")")
        }

        let result = context.evaluateScript(code)

        if let exception = context.exception {
            let errorMessage = """
            JavaScript execution failed with error:
            \(exception.toString() ?? "Unknown error")

            Code executed:
            ```javascript
            \(code)
            ```
            """
            return [errorMessage]
        }

        var output = ""

        if !consoleOutput.isEmpty {
            for line in consoleOutput {
                output += "\(line)\n"
            }
            output += "\n"
        }

        if let result, !result.isUndefined {
            if result.isObject {
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

        if output.isEmpty {
            output = "undefined"
        }

        return [output]
    }
}
