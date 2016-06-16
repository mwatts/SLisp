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


enum TokenType: Equatable {
    case lParen
    case rParen
    case atom(String)
    case number(Double)
    case lString(String)
}

func ==(a: TokenType, b: TokenType) -> Bool {
    switch (a, b) {
    case (.lParen, .lParen): return true
    case (.rParen, .rParen): return true
    case (.atom(let a), .atom(let b)) where a == b: return true
    case (.number(let a), .number(let b)) where a == b: return true
    case (.lString(let a), .lString(let b)) where a == b: return true
    default: return false
    }
}

protocol TokenMatcher {
    static func isMatch(_ stream:StringStream) -> Bool
    static func getToken(_ stream:StringStream) -> TokenType?
}

func characterIsInSet(_ c: Character, set: CharacterSet) -> Bool {
    var found = true
    for ch in String(c).utf16 {
        if !set.contains(UnicodeScalar(ch)) {
            found = false
        }
    }
    return found
}

func isWhitespace(_ c: Character) -> Bool {
    return characterIsInSet(c, set: CharacterSet.whitespacesAndNewlines)
}

class LParenTokenMatcher: TokenMatcher {
    
    static func isMatch(_ stream: StringStream) -> Bool {
        return stream.currentCharacter() == "("
    }
    
    static func getToken(_ stream: StringStream) -> TokenType? {
        if isMatch(stream) {
            stream.advanceCharacter()
            return TokenType.lParen
        }
        return nil
    }
}

class RParenTokenMatcher: TokenMatcher {
    
    static func isMatch(_ stream: StringStream) -> Bool {
        return stream.currentCharacter() == ")"
    }
    
    static func getToken(_ stream: StringStream) -> TokenType? {
        if isMatch(stream) {
            stream.advanceCharacter()
            return TokenType.rParen
        }
        return nil
    }
}

class AtomMatcher: TokenMatcher {
    static var matcherCharacterSet: NSMutableCharacterSet?
    static var matcherStartCharacterSet: NSMutableCharacterSet?

    static func isMatch(_ stream: StringStream) -> Bool {
        return characterIsInSet(stream.currentCharacter()!, set: startCharacterSet())
    }
    
    static func getToken(_ stream: StringStream) -> TokenType? {
        if isMatch(stream) {
            var tok = ""
            
            while characterIsInSet(stream.currentCharacter()!, set: characterSet()) {
                tok += String(stream.currentCharacter()!)
                stream.advanceCharacter()
                if stream.currentCharacter() == nil {
                    break
                }
            }
            
            return TokenType.atom(tok)
        }
        
        return nil
    }
    
    static func characterSet() -> CharacterSet {
        if matcherCharacterSet == nil {
            matcherCharacterSet = NSMutableCharacterSet.letters()
            matcherCharacterSet!.formUnion(with: CharacterSet.decimalDigits)
            matcherCharacterSet!.formUnion(with: CharacterSet.punctuation)
            matcherCharacterSet!.formUnion(with: NSMutableCharacterSet.symbols() as CharacterSet)
            matcherCharacterSet!.removeCharacters(in: "()")
        }
        return matcherCharacterSet! as CharacterSet
    }

    static func startCharacterSet() -> CharacterSet {
        if matcherStartCharacterSet == nil {
            matcherStartCharacterSet = NSMutableCharacterSet.letters()
            matcherStartCharacterSet!.formUnion(with: CharacterSet.decimalDigits)
            matcherStartCharacterSet!.formUnion(with: CharacterSet.punctuation)
            matcherStartCharacterSet!.formUnion(with: NSMutableCharacterSet.symbols() as CharacterSet)
            matcherStartCharacterSet!.removeCharacters(in: "()")
        }
        return matcherStartCharacterSet! as CharacterSet
    }
}

class StringMatcher: TokenMatcher {
    static var matcherCharacterSet: NSMutableCharacterSet?

    static func isMatch(_ stream: StringStream) -> Bool {
        return stream.currentCharacter() == "\""
    }
    
    static func getToken(_ stream: StringStream) -> TokenType? {
        if isMatch(stream) {
            stream.advanceCharacter()
            
            var tok = ""
            
            while stream.currentCharacter() != nil && !isMatch(stream) {
                tok += String(stream.currentCharacter()!)
                stream.advanceCharacter()
            }
            
            stream.advanceCharacter()
            
            return TokenType.lString(tok)
        }
        
        return nil
    }
    
    static func characterSet() -> CharacterSet {
        if matcherCharacterSet == nil {
            matcherCharacterSet = NSMutableCharacterSet.letters()
            matcherCharacterSet!.formUnion(with: CharacterSet.decimalDigits)

            let allowedSymbols = NSMutableCharacterSet.symbols()
            allowedSymbols.formIntersection(with:CharacterSet(charactersIn: "\""))

            matcherCharacterSet!.formUnion(with: allowedSymbols as CharacterSet)
        }
        return matcherCharacterSet! as CharacterSet
    }
}

class NumberMatcher: TokenMatcher {
    static var matcherCharacterSet: NSMutableCharacterSet?

    static func isMatch(_ stream: StringStream) -> Bool {
        let matches = characterIsInSet(stream.currentCharacter()!, set: CharacterSet(charactersIn: "0123456789"))
        return matches
    }
    
    static func getToken(_ stream: StringStream) -> TokenType? {
        if isMatch(stream) {
            var tok = ""
            
            while stream.currentCharacter() != nil &&
                characterIsInSet(stream.currentCharacter()!, set: characterSet()) {
                tok += String(stream.currentCharacter()!)
                stream.advanceCharacter()
            }
            
            return TokenType.number(Double(tok)!)
        }
        
        return nil
    }

    
    static func characterSet() -> CharacterSet {
        if matcherCharacterSet == nil {
            matcherCharacterSet = NSMutableCharacterSet(charactersIn: "0123456789.")
        }
        return matcherCharacterSet! as CharacterSet
    }
}

// Token matchers in order
let tokenClasses: [TokenMatcher.Type] = [
        LParenTokenMatcher.self,
        RParenTokenMatcher.self,
        NumberMatcher.self,
        StringMatcher.self,
        AtomMatcher.self,
]

class StringStream {
    var str: String
    var position = 0

    init(source: String) {
        str = source
        position = 0
    }

    func advanceCharacter() {
        position += 1
    }

    func currentCharacter() -> Character? {
        if position < str.characters.count {
            let idx = str.index(str.startIndex, offsetBy: position)
            return str.characters[idx]
        }

        return nil
    }

    func nextCharacter() -> Character? {
        if position + 1 < str.characters.count {
            let idx = str.index(str.startIndex, offsetBy: position + 1)
            return str.characters[idx]
        }

        return nil
    }

    func characterAtPosition(_ pos: Int) -> Character? {
        if pos < str.characters.count {
            let idx = str.index(str.startIndex, offsetBy: pos)
            return str.characters[idx]
        }

        return nil
    }

    func eatWhitespace() {
        var pos = position
        while pos < str.characters.count {
            if isWhitespace(characterAtPosition(pos)!) {
                pos += 1
            } else {
                position = pos
                return
            }
        }
        position = pos
    }

    func rewind() {
        position = 0
    }
}

class Tokenizer {
    let stream: StringStream
    var currentTokenMatcher: TokenMatcher.Type? = nil
    var currentTokenString: String

    init(source: String) {
        self.stream = StringStream(source: source)
        self.currentTokenString = ""
    }

    func tokenizeInput() -> [TokenType] {
        var tokens = [TokenType]()
        
        while let t = getNextToken() {
            tokens.append(t)
        }
        
        return tokens
    }
    
    func getNextToken() -> TokenType? {
        if stream.position >= stream.str.characters.count {
            return nil
        }
        
        for matcher in tokenClasses {
            if matcher.isMatch(stream) {
                return matcher.getToken(stream)
            }
        }
        
        stream.eatWhitespace()
        
        if stream.position >= stream.str.characters.count {
            return nil
        }
        
        return getNextToken()
    }

}
