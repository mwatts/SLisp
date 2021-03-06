/*
 
 MIT License
 
 Copyright (c) 2017 Andy Best
 
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

public class Environment {
    public var namespace: Namespace
    var localBindings: [String: LispType]
    weak var parent: Environment?
    
    public init(ns: Namespace) {
        namespace = ns
        localBindings = [String: LispType]()
    }
    
    func bindLocal(name: LispType, value: LispType) throws -> LispType {
        guard case let .symbol(bindingName) = name else {
            throw LispError.runtime(msg: "Values can only be bound to symbols. Got \(String(describing: name))")
        }
        
        localBindings[bindingName] = value
        
        return .symbol("bindingName")
    }
    
    func createChild() -> Environment {
        let env = Environment(ns: namespace)
        env.parent = self
        return env
    }
}

public class Parser {
    var namespaces                     = [String: Namespace]()
    let coreImports:          [String] = ["core"]
    
    let slisp_home_var = "SLISP_HOME"
    
    var cwdStack: [String]  // Holds the current working directory
    
    public init?() throws {
        cwdStack = [String]()
        
        let core = Core(parser: self)
        /* Core builtins */
        let coreBuiltins = [core]
        
        try coreBuiltins.forEach {
            let ns = createOrGetNamespace($0.namespaceName())
            let env = Environment(ns: ns)
            try $0.initBuiltins(environment: env).forEach { (arg) in
                
                let (name, builtinDef) = arg
                _ = try bindGlobal(name: .symbol(name),
                                   value: .function(.native(body: builtinDef.body),
                                                    docstring: builtinDef.docstring,
                                                    isMacro: false,
                                                    namespace: ns),
                                   toNamespace: ns)
            }
        }
        
        /* Other builtins */
        let builtins = [MathBuiltins(parser: self),
                        StringBuiltins(parser: self)]
        
        try builtins.forEach {
            let ns = createOrGetNamespace($0.namespaceName())
            try $0.initBuiltins(environment: Environment(ns: ns)).forEach { (arg) in
                
                let (name, builtinDef) = arg
                _ = try bindGlobal(name: .symbol(name),
                                   value: .function(.native(body: builtinDef.body),
                                                    docstring: builtinDef.docstring,
                                                    isMacro: false,
                                                    namespace: ns),
                                   toNamespace: ns)
            }
        }
        
        // Load SLisp standard library
        
        // Look for stdlib under $SLISP_HOME if it exists, else look in CWD
        if let slisp_home = ProcessInfo.processInfo.environment[slisp_home_var] {
            pushCWD(workingDir: "\(slisp_home)/stdlib")
        } else {
            pushCWD(workingDir: "./stdlib")
        }
        
        _ = evalFile(path: "stdlib.sl", environment: Environment(ns: createOrGetNamespace("core")))
        try popCWD()
    }
    
    func eval_form(_ form: LispType, environment: Environment) throws -> LispType {
        if try is_macro(form, environment: environment) { return form }
        switch form {
        case .symbol(let symbol):
            switch symbol {
            case "true":
                return .boolean(true)
            case "false":
                return .boolean(false)
            case "nil":
                return .nil
            default:
                return try getValue(symbol, withEnvironment: environment)
            }
        case .list(let list):
            return .list(try list.map {
                return try self.eval($0, environment: environment)
                })
        default:
            return form
        }
    }
    
    public func eval(_ form: LispType, environment e: Environment) throws -> LispType {
        var envs = [e]
        var tco: Bool   = false
        var mutableForm = form
        var env_push = 0
        
        while true {
            switch mutableForm {
            case .list(let list):
                if list.count == 0 {
                    return form
             }
            default:
                return try eval_form(mutableForm, environment: envs.last!)
            }
            
            do {
            mutableForm = try macroExpand(mutableForm, environment: envs.last!)
                
            switch mutableForm {
            case .list(let list):
                let args = Array(list.dropFirst())
                
                // Handle special forms
                switch list[0] {
                // MARK: def
                case .symbol("def"):
                    return try parseDef(args: args, environment: envs.last!)
                    
                // MARK: let
                case .symbol("let"):
                    env_push += 1
                    envs.append(envs.last!.createChild())
                    mutableForm = try parseLet(args: args, environment: envs.last!)
                    
                // MARK: set!
                case .symbol("set!"):
                    if args.count != 2 {
                        throw LispError.runtime(msg: "'set!' requires 2 arguments")
                    }
                    
                    guard case let .symbol(name) = args[0] else {
                        throw LispError.runtime(msg: "'set!' requires the variable name to be a symbol")
                    }
                    
                    _ = try setValue(name: name,
                                     value: self.eval(args[1], environment: envs.last!),
                                     withEnvironment: envs.last!)
                    return .nil
                    
                // MARK: apply
                case .symbol("apply"):
                    if args.count != 2 {
                        throw LispError.runtime(msg: "'apply' requires 2 arguments")
                    }
                    
                    guard case .function(_) = try eval(args[0], environment: envs.last!) else {
                        throw LispError.runtime(msg: "'apply' requires the first argument to be a function")
                    }
                    
                    guard case let .list(applyArgs) = try eval(args[1], environment: envs.last!) else {
                        throw LispError.runtime(msg: "'apply' requires the second argument to be a list")
                    }
                    
                    mutableForm = .list([args[0]] + applyArgs)
                    
                // MARK: quote
                case .symbol("quote"):
                    if args.count != 1 {
                        throw LispError.general(msg: "'quote' expects 1 argument, got \(args.count).")
                    }
                    
                    return args[0]
                    
                // MARK: quasiquote
                case .symbol("quasiquote"):
                    if args.count != 1 {
                        throw LispError.general(msg: "'quasiquote' expects 1 argument, got \(args.count).")
                    }
                    mutableForm = try quasiquote(args[0])
                    
                // MARK: do
                case .symbol("do"):
                    if args.count < 1 {
                        return .nil
                    }
                    
                    for (index, doForm) in args.enumerated() {
                        if index == args.count - 1 {
                            mutableForm = doForm
                            break
                        }
                        
                        _ = try eval(doForm, environment: envs.last!)
                    }
                    
                    // TCO
                    mutableForm = args[args.count - 1]
                    
                // MARK: function
                case .symbol("function"):
                    return try parseFunction(args: args, environment: envs.last!)
                    
                // MARK: if
                case .symbol("if"):
                    if args.count < 2 {
                        throw LispError.runtime(msg: "'if' expects 2 or 3 arguments.")
                    }
                    
                    guard case let .boolean(condition) = try eval(args[0], environment: envs.last!) else {
                        throw LispError.general(msg: "'if' expects the first argument to be a boolean condition")
                    }
                    
                    if condition {
                        mutableForm = args[1]
                    } else if args.count > 2 {
                        mutableForm = args[2]
                    } else {
                        return .nil
                    }
                    
                // MARK: while
                case .symbol("while"):
                    if args.count < 2 {
                        throw LispError.runtime(msg: "'while' requires a condition and a body")
                    }
                    
                    func getCondition() throws -> Bool {
                        if case let .boolean(b) = try eval(args[0], environment: envs.last!) {
                            return b
                        }
                        throw LispError.runtime(msg: "'while' expects the first argument to be a boolean.")
                    }
                    
                    var rv: LispType = .nil
                    var condition = try getCondition()
                    while condition {
                        let body = Array(args.dropFirst())
                        
                        for form in body {
                            rv = try eval(form, environment: envs.last!)
                        }
                        
                        condition = try getCondition()
                    }
                    
                    // TCO
                    mutableForm = rv
                    
                // MARK: defmacro
                case .symbol("defmacro"):
                    if args.count != 2 {
                        throw LispError.runtime(msg: "'defmacro' requires 2 arguments")
                    }
                    
                    guard case let .function(body, docstring: docstring, _, namespace: ns) = try eval(list[2], environment: envs.last!) else {
                        throw LispError.runtime(msg: "'defmacro' requires the 2nd argument to be a function")
                    }
                    
                    return try bindGlobal(name: list[1],
                                          value: .function(body, docstring: docstring, isMacro: true, namespace: ns), toNamespace: envs.last!.namespace)
                    
                // MARK: macroexpand
                case .symbol("macroexpand"):
                    if args.count != 1 {
                        throw LispError.runtime(msg: "'macroexpand' expects one argument")
                    }
                    return try macroExpand(args[0], environment: envs.last!)
                    
                // MARK: try
                case .symbol("try"):
                    return try parseTry(args: args, env: envs.last!)
                    
                default:
                    switch try eval_form(mutableForm, environment: envs.last!) {
                    case .list(let lst):
                        switch lst[0] {
                            
                        // MARK: Eval Function
                        case .function(let body, _, isMacro: _, namespace: let ns):
                            switch body {
                            case .native(body:let nativeBody):
                                let rv = try nativeBody(Array(lst.dropFirst()), self, envs.last!)
                                return rv
                            case .lisp(argnames:let argnames, body:let lispBody):
                                let funcArgs = Array(lst.dropFirst())
                                if funcArgs.count != argnames.count && argnames.index(of: "&") == nil {
                                    throw LispError.general(msg: "Invalid number of args: \(funcArgs.count). Expected \(argnames.count).")
                                }
                                
                                let newEnv = envs.last!.createChild()
                                newEnv.namespace = ns
                                envs.append(newEnv)
                                env_push += 1
                                
                                var bindList = false
                                for i in 0..<argnames.count {
                                    if argnames[i] == "&" {
                                        bindList = true
                                        if i != argnames.count - 2 {
                                            throw LispError.runtime(msg: "Functions require the '&' to be the second to last argument")
                                        }
                                    } else {
                                        if bindList {
                                            // Bind the rest of the arguments as a list
                                            _ = try envs.last!.bindLocal(name: .symbol(argnames[i]), value: .list(Array(funcArgs[(i-1)...])))
                                        } else {
                                            _ = try envs.last!.bindLocal(name: .symbol(argnames[i]), value: funcArgs[i])
                                        }
                                    }
                                }
                                
                                for val in lispBody.dropLast() {
                                    _ = try eval(val, environment: envs.last!)
                                }
                                
                                mutableForm = lispBody.last!
                            }
                        default:
                            throw LispError.runtime(msg: "\(String(describing: list[0])) is not a function.")
                        }
                    default:
                        throw LispError.runtime(msg: "Cannot evaluate form.")
                    }
                }
                
            default:
                throw LispError.runtime(msg: "Cannot evaluate form.")
            }
                
            } catch let LispError.runtime(msg:message) {
                throw LispError.runtimeForm(msg: message, form: mutableForm)
            } catch let LispError.general(msg:message) {
                throw LispError.runtimeForm(msg: message, form: mutableForm)
            } catch {
                throw error
            }
        } // while
    }
    
    func parseDef(args: [LispType], environment: Environment) throws -> LispType {
        if args.count != 2 {
            throw LispError.runtime(msg: "'def' requires 2 arguments")
        }
        
        return try bindGlobal(name: args[0],
                              value: try eval(args[1], environment: environment),
                              toNamespace: environment.namespace)
    }
    
    func parseLet(args: [LispType], environment: Environment) throws -> LispType {
        if args.count < 2 {
            throw LispError.runtime(msg: "'let' requires at least 2 arguments")
        }
        
        guard case let .list(bindings) = args[0] else {
            throw LispError.general(msg: "'let' requires the first argument to be a list of bindings")
        }
        
        if bindings.count % 2 != 0 {
            throw LispError.general(msg: "'let' requires an even number of items in the binding list")
        }
        
        try stride(from: 0, to: bindings.count, by: 2).forEach {
            _ = try environment.bindLocal(name: bindings[$0],
                                          value: self.eval(bindings[$0 + 1],
                                                           environment: environment))
        }
        
        let body: [LispType] = Array(args.dropFirst())
        
        for (index, form) in body.enumerated() {
            if index == body.count - 1 {
                break
            }
            
            _ = try eval(form, environment: environment)
        }
        
        // TCO
        return body[body.count - 1]
    }
    
    func parseFunction(args: [LispType], environment: Environment) throws -> LispType {
        if args.count < 2 {
            throw LispError.general(msg: "'function' expects a body")
        }
        
        let argList: [LispType]
        var docString: String?
        
        var fArgs = args
        
        // See if the first argument is a String. If it is, then it is a docstring.
        if case let .string(ds) = args[0] {
            docString = ds
            fArgs = Array(args.dropFirst())
        } else if case let .symbol(argSymb) = args[0] {
            if case let .string(ds) = try getValue(argSymb, withEnvironment: environment) {
                docString = ds
                fArgs = Array(args.dropFirst())
            }
        } else if case .list(_) = args[0] {
            do {
                if case let .string(ds) = try eval(args[0], environment: environment) {
                    docString = ds
                    fArgs = Array(args.dropFirst())
                }
            } catch {
                // Don't do anything, since this doesn't return a string.
            }
        }
        
        if case let .symbol(argSymb) = fArgs[0] {
            guard case let .list(argListFromSym) = try getValue(argSymb, withEnvironment: environment) else {
                throw LispError.general(msg: "function arguments must be a list")
            }
            argList = argListFromSym
        } else {
            guard case let .list(argListFromList) = fArgs[0] else {
                throw LispError.general(msg: "function arguments must be a list")
            }
            argList = argListFromList
        }
        
        let argNames: [String] = try argList.map {
            guard case let .symbol(argName) = $0 else {
                throw LispError.general(msg: "function arguments must be symbols")
            }
            return argName
        }
        
        if (argNames.filter { $0 == "&" }).count > 1 {
            throw LispError.runtime(msg: "Function arguments must only include one '&'")
        }
        
        let andIdx = argNames.index(of: "&")
        if andIdx != nil && andIdx != argNames.endIndex.advanced(by: -2) {
            throw LispError.runtime(msg: "Functions require the '&' to be the second to last argument")
        }
        
        let body = FunctionBody.lisp(argnames: argNames, body: Array(fArgs.dropFirst(1)))
        return LispType.function(body, docstring: docString, isMacro: false, namespace: environment.namespace)
    }
    
    func parseTry(args: [LispType], env: Environment) throws -> LispType {
        if args.count < 2 {
            throw LispError.runtime(msg: "'try' needs at least 2 arguments")
        }
        
        var tryBody: [LispType]?
        var catchBinding: String?
        var catchBody: [LispType]?
        
        var finallyBody: [LispType]? = nil
        
        if args.count == 2 {
            if let catchResult = try getCatch(catchForm: args.last!) {
                catchBinding = catchResult.0
                catchBody = catchResult.1
            }
            
            tryBody = Array(args.dropLast())
        } else {
            // Try to get the symbols for the last 2 forms
            
            let last2Args = args.dropFirst(args.count - 2)
            let symbols: [String?] =  last2Args.map {
                guard case let .list(lst) = $0, lst.count > 0, case let .symbol(sym) = lst.first! else {
                    return nil
                }
                
                return sym
            }
            
            if symbols[1] == "catch" {
                if let catchResult = try getCatch(catchForm: args.last!) {
                    catchBinding = catchResult.0
                    catchBody = catchResult.1
                }
                
                tryBody = Array(args.dropLast())
            } else if symbols[0] == "catch" && symbols[1] == "finally" {
                if let catchResult = try getCatch(catchForm: args.dropLast().last!) {
                    catchBinding = catchResult.0
                    catchBody = catchResult.1
                }
                
                // Try to get the 'finally' form
                guard case let .list(finallyList) = args.last! else {
                    throw LispError.runtime(msg: "'try': invalid 'finally' clause")
                }
                
                finallyBody = Array(finallyList.dropFirst())
                if finallyBody!.count < 1 {
                    throw LispError.runtime(msg: "'finally': must have body")
                }
                
                tryBody = Array(args.dropLast(2))
            } else {
                throw LispError.runtime(msg: "'try' expects catch and/or finally")
            }
        }
        
        var returnForm: LispType?
        
        do {
            for (index, doForm) in tryBody!.enumerated() {
                let form = try eval(doForm, environment: env)
                
                if index == tryBody!.count - 1 {
                    returnForm = form
                }
            }
        } catch LispError.lispError(errorKey: let errorKey, userInfo: let userInfo){
            if catchBinding != nil {
                _ = try env.bindLocal(name: .symbol(catchBinding!),
                                     value: .error(errorKey: errorKey,
                                                   userInfo: userInfo == nil ? nil : [userInfo!]))
            }
            
            // Eval catch body
            if catchBody != nil {
                for (index, catchForm) in catchBody!.enumerated() {
                    let form = try eval(catchForm, environment: env)
                    
                    if index == catchBody!.count - 1 {
                        returnForm = form
                    }
                }
            }
        } catch {
            // If it's not a native error, rethrow it.
            throw error
        }
        
        if finallyBody != nil {
            for finallyForm in finallyBody! {
                let _ = try eval(finallyForm, environment: env)
            }
        }
        
        return returnForm ?? .nil
    }
    
    func quasiquote(_ form: LispType) throws -> LispType {
        // If the argument isn't a list, just return the argument with a regular quote
        guard case let .list(args) = form, args.count > 0 else {
            return .list([.symbol("quote")] + [form])
        }
        
        if case .symbol("unquote") = args[0] {
            if args.count != 2 {
                throw LispError.runtime(msg: "'unquote' requires one argument")
            }
            return args[1]
        }
        
        if case let .list(list) = args[0], list.count > 0 {
            if case .symbol("splice-unquote") = list[0] {
                if list.count != 2 {
                    throw LispError.runtime(msg: "'splice-unquote' requires one argument")
                }
                return .list([.symbol("concat"), list[1], try quasiquote(.list(Array(args.dropFirst())))])
            }
        }
        
        return .list([.symbol("cons"), try quasiquote(args[0]), try quasiquote(.list(Array(args.dropFirst())))])
        
    }
    
    func is_macro(_ form: LispType, environment: Environment) throws -> Bool {
        switch form {
        case .list(let list) where list.count > 0:
            let arg = list.first!
            
            switch arg {
            case .symbol(let symbol):
                do {
                    let val = try getValue(symbol, withEnvironment: environment)
                    if case let .function(_, _, isMacro: isMacro, _) = val {
                        return isMacro
                    }
                    return false
                } catch {
                    return false
                }
            default:
                return false
            }
        default:
            return false
        }
    }
    
    func macroExpand(_ form: LispType, environment e: Environment) throws -> LispType {
        var mutableForm = form
        var envs = [e]
        
        while try is_macro(mutableForm, environment: envs.last!) {
            if case let .list(list) = mutableForm, list.count > 0, case let .symbol(sym) = list.first! {
                let f = try getValue(sym, withEnvironment: envs.last!)
                if case let .function(body, docstring: _, isMacro: _, namespace: ns) = f {
                    if case let .lisp(argList, lispBody) = body {
                        let funcArgs = Array(list.dropFirst())
                        if funcArgs.count != argList.count && argList.index(of: "&") == nil {
                            throw LispError.general(msg: "Invalid number of args: \(funcArgs.count). Expected \(argList.count).")
                        }
                        
                        let newEnv = envs.last!.createChild()
                        newEnv.namespace = ns
                        envs.append(newEnv)
                        
                        var bindList = false
                        for i in 0..<argList.count {
                            if argList[i] == "&" {
                                bindList = true
                                if i != argList.count - 2 {
                                    throw LispError.runtime(msg: "Macros require the '&' to be the second to last argument")
                                }
                            } else {
                                if bindList {
                                    // Bind the rest of the arguments as a list
                                    _ = try envs.last!.bindLocal(name: .symbol(argList[i]), value: .list(Array(funcArgs[(i - 1)...])))
                                } else {
                                    _ = try envs.last!.bindLocal(name: .symbol(argList[i]), value: funcArgs[i])
                                }
                            }
                        }
                        
                        for val in lispBody {
                            mutableForm = try eval(val, environment: envs.last!)
                        }
                    } else {
                        throw LispError.runtime(msg: "Builtin cannot be a macro!")
                    }
                } else {
                    throw LispError.runtime(msg: "'macroexpand' expects the first arg to be a function")
                }
            }
        }
        
        return mutableForm
    }
    
    func getCatch(catchForm: LispType) throws -> (String, [LispType])? {
        guard case let .list(catchList) = catchForm, catchList.count >= 1 else {
            throw LispError.runtime(msg: "'try': missing catch")
        }
        
        guard case let .symbol(catchForm) = catchList[0], catchForm == "catch" else {
            throw LispError.runtime(msg: "'try' expected catch")
        }
        
        if catchList.count > 1 {
            guard let pSym = catchList.dropFirst().first, case let .symbol(binding) = pSym else {
                throw LispError.runtime(msg: "'catch' expects the first argument to be a symbol")
            }
            
            let catchBody = catchList.dropFirst(2)
            
            if catchBody.count < 1 {
                throw LispError.runtime(msg: "'catch' expects a body")
            }
            
            return (binding, Array(catchBody))
        }
        
        return nil
    }
    
    func pushCWD(workingDir: String) {
        cwdStack.append(FileManager.default.currentDirectoryPath)
        FileManager.default.changeCurrentDirectoryPath(workingDir)
    }
    
    func popCWD() throws {
        guard let cwd = cwdStack.popLast() else {
            throw LispError.general(msg: "Unable to pop cwd- stack is empty!")
        }
        FileManager.default.changeCurrentDirectoryPath(cwd)
    }
}
