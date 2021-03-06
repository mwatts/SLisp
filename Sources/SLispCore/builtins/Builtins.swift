/*
 
 MIT License
 
 Copyright (c) 2016 Andy Best
 
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 
 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.
 
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.
 
 */

import Foundation

typealias ArithmeticOperationBody = (LispNumber, LispNumber) -> LispNumber
typealias SingleValueArithmeticOperationBody = (LispNumber) -> LispNumber
typealias ArithmeticBooleanOperationBody = (LispNumber, LispNumber) -> Bool
typealias SingleArithmeticBooleanOperationBody = (LispNumber) -> Bool
typealias BooleanOperationBody = (Bool, Bool) -> Bool
typealias SingleBooleanOperationBody = (Bool) -> Bool

extension Dictionary {
    mutating func merge(_ dict: Dictionary<Key,Value>) {
        for (key, value) in dict {
            // If both dictionaries have a value for same key, the value of the other dictionary is used.
           self[key] = value
        }
    }
}

struct BuiltinDef {
    let body: BuiltinBody
    let docstring: String?
}

class Builtins {
    let parser: Parser
    var builtins = [String : BuiltinDef]()
    
    init(parser: Parser) {
        self.parser = parser
    }

    func namespaceName() -> String {
        return "user"
    }
    
    func addBuiltin(_ name: String, docstring: String?, _ body: @escaping BuiltinBody) {
        builtins[name] = BuiltinDef(body: body, docstring: docstring)
    }
    
    func getBuiltins() -> [String: BuiltinDef] {
        return builtins
    }
    
    func loadBuiltinsFromFile(_ path:String) {
        
    }
    
    func checkArgCount(funcName: String, args: [LispType], expectedNumArgs: Int) throws {
        if args.count < expectedNumArgs {
            throw LispError.general(msg: "'\(funcName)' expects \(expectedNumArgs) arguments.")
        }
    }

    func initBuiltins(environment: Environment) -> [String: BuiltinDef] {
        return [:]
    }

    // A generic function for arithmetic operations
    func doArithmeticOperation(_ args: [LispType], environment: Environment, body:ArithmeticOperationBody) throws -> LispType {
        if args.count < 2 {
            throw LispError.runtime(msg: "Operation expects at least 2 arguments")
        }
        
        var numbers: [LispNumber] = []
        
        for arg in args {
            guard case let .number(num) = arg else {
                throw LispError.general(msg: "Invalid argument type: \(String(describing: arg))")
            }
            numbers.append(num)
        }
        
        var val = numbers.first!
        for arg in numbers.dropFirst() {
            val = body(val, arg)
        }
        
        return .number(val)
    }
    
    func doSingleArgArithmeticOperation(_ args: [LispType], name: String, environment: Environment, body:SingleValueArithmeticOperationBody) throws -> LispType {
        if args.count != 1 {
            throw LispError.general(msg: "'\(name)' requires one argument")
        }
        
        let evaluated = try args.map { try parser.eval($0, environment: environment) }
        
        guard case let .number(num) = evaluated[0] else {
            throw LispError.general(msg: "'\(name)' requires a number argument.")
        }
        
        return .number(body(num))
    }
    
    func doSingleArgBooleanArithmeticOperation(_ args: [LispType], name: String, environment: Environment, body:SingleArithmeticBooleanOperationBody) throws -> LispType {
        if args.count != 1 {
            throw LispError.general(msg: "'\(name)' requires one argument")
        }
        
        let evaluated = try args.map { try parser.eval($0, environment: environment) }
        
        guard case let .number(num) = evaluated[0] else {
            throw LispError.general(msg: "'\(name)' requires a number argument.")
        }
        
        return .boolean(body(num))
    }

    func doBooleanArithmeticOperation(_ args: [LispType], environment: Environment, body: ArithmeticBooleanOperationBody) throws -> LispType {
        if args.count < 2 {
            throw LispError.runtime(msg: "Operation expects at least 2 arguments")
        }
        
        var numbers: [LispNumber] = []
        
        for arg in args {
            guard case let .number(num) = arg else {
                throw LispError.general(msg: "Invalid argument type: \(String(describing: arg))")
            }
            numbers.append(num)
        }
        
        let comp = numbers[0]
        
        for arg in numbers.dropFirst() {
            if !body(comp, arg) {
                return .boolean(false)
            }
        }
        
        return .boolean(true)
    }

    func doBooleanOperation(_ args: [LispType], environment: Environment, body:BooleanOperationBody) throws -> LispType {
        var result: Bool = false
        var lastValue: Bool = false
        var firstArg = true
        let evaluated = try args.map { try parser.eval($0, environment: environment) }

        for arg in evaluated {
            guard case let .boolean(b) = arg else {
                throw LispError.general(msg: "Invalid argument type: \(String(describing: arg))")
            }

            if firstArg {
                lastValue = b
                firstArg = false
            } else {
                result = body(lastValue, b)
            }
        }

        return .boolean(result)
    }

    func doSingleBooleanOperation(_ args: [LispType], environment: Environment, body:SingleBooleanOperationBody) throws -> LispType {
        let evaluated = try args.map { try parser.eval($0, environment: environment) }

        guard case let .boolean(b) = evaluated[0] else {
            throw LispError.general(msg: "Invalid argument type: \(String(describing: evaluated[0]))")
        }

        return .boolean(body(b))
    }
}
