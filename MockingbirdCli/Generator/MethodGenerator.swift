//
//  MethodGenerator.swift
//  MockingbirdCli
//
//  Created by Andrew Chang on 8/6/19.
//  Copyright © 2019 Bird Rides, Inc. All rights reserved.
//
// swiftlint:disable leading_whitespace

import Foundation

extension MethodParameter {
  var resolvedType: String {
    let capitalizedName = name.capitalizedFirst
    return "let matcher\(capitalizedName) = resolve(`\(name)`)"
  }
  
  func castedMatcherType(in context: MockableType) -> String {
    let capitalizedName = name.capitalizedFirst
    let typeName = matchableTypeName(in: context, unwrapOptional: true)
    let alreadyMatcher = "matcher\(capitalizedName) as? MockingbirdMatcher"
    let createMatcher = "MockingbirdMatcher(matcher\(capitalizedName) as AnyObject as? \(typeName))"
    return "(\(alreadyMatcher)) ?? \(createMatcher)"
  }
  
  func matchableTypeName(in context: MockableType, unwrapOptional: Bool = false) -> String {
    let typeName = context.specializeTypeName(self.typeName, unwrapOptional: unwrapOptional)
    guard isClosure else { return typeName }
    return typeName
      .replacingOccurrences(of: "@escaping", with: "")
      .replacingOccurrences(of: "@autoclosure", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
  
  var isClosure: Bool { // This could be slow, should cache
    return typeName.contains(" -> ")
  }
  
  var isEscapingClosure: Bool { // This could be slow, should cache
    return typeName.contains("@escaping")
  }
  
  var isAutoclosure: Bool { // This could be slow, should cache
    return typeName.contains("@autoclosure")
  }
}

extension Method {
  func createGenerator(in context: MockableType) -> MethodGenerator {
    return MethodGenerator(method: self, context: context)
  }
}

class MethodGenerator {
  let method: Method
  let context: MockableType
  init(method: Method, context: MockableType) {
    self.method = method
    self.context = context
  }
  
  func generate() -> String {
    return [generatedMock,
            generatedStub,
            generatedVerification]
      .filter({ !$0.isEmpty })
      .joined(separator: "\n\n")
  }
  
  lazy var generatedMock: String = {
    return """
      // MARK: Mockable `\(method.name)`
    
      public \(overridableModifiers)func \(regularFullName) \(returnTypeAttributes)-> \(specializedReturnTypeName) {
        let invocation = MockingbirdInvocation(selectorName: "\(fullSelectorName)",
                                               arguments: [\(mockArgumentMatchers)])
        \(contextPrefix)mockingContext.didInvoke(invocation)
    \(stubbedImplementationCall)
      }
    """
  }()
  
  lazy var generatedStub: String = {
    guard !method.isInitializer else { return "" }
    let returnTypeName = specializedReturnTypeName
    return """
      // MARK: Stubbable `\(method.name)`
    
      public \(regularModifiers)func \(fullNameForMatching) -> MockingbirdScopedStub<\(returnTypeName)> {
    \(matchableInvocation)
        if let stub = DispatchQueue.currentStub {
          \(contextPrefix)stubbingContext.swizzle(invocation, with: stub.implementation)
        }
        return MockingbirdScopedStub<\(returnTypeName)>()
      }
    """
  }()
  
  lazy var generatedVerification: String = {
    return """
      // MARK: Verifiable `\(method.name)`
    
      public \(regularModifiers)func \(fullNameForMatching) -> MockingbirdScopedMock {
    \(matchableInvocation)
        if let expectation = DispatchQueue.currentExpectation {
          expect(\(contextPrefix)mockingContext, handled: invocation, using: expectation)
        }
        return MockingbirdScopedMock()
      }
    """
  }()
  
  lazy var regularModifiers: String = { return modifiers(allowOverride: false) }()
  lazy var overridableModifiers: String = { return modifiers(allowOverride: true) }()
  func modifiers(allowOverride: Bool = true) -> String {
    let isRequired = method.attributes.contains(.required)
    let required = (isRequired ? "required " : "")
    let override = (context.kind == .class && !isRequired && allowOverride ? "override " : "")
    let `static` = (method.kind.typeScope == .static || method.kind.typeScope == .class ? "static " : "")
    return "\(required)\(override)\(`static`)"
  }
  
  lazy var genericConstraints: String = { // This might be slow, we should consider caching it.
    return method.genericTypes.map({ genericType -> String in
      guard !genericType.inheritedTypes.isEmpty else { return genericType.name }
      let inheritedTypes = Array(genericType.inheritedTypes).joined(separator: " & ")
      return "\(genericType.name): \(inheritedTypes)"
    }).joined(separator: ", ")
  }()
  
  lazy var shortName: String = {
    guard let shortName = method.name.substringComponents(separatedBy: "(").first else {
      return method.name
    }
    let genericConstraints = self.genericConstraints
    return genericConstraints.isEmpty ? "\(shortName)" : "\(shortName)<\(genericConstraints)>"
  }()
  
  lazy var regularFullName: String = { return fullName() }()
  lazy var fullNameForMatching: String = { return fullName(forMatching: true) }()
  func fullName(forMatching: Bool = false) -> String {
    let parameterNames = method.parameters.map({ parameter -> String in
      let typeName: String
      if forMatching {
        typeName = "@escaping @autoclosure () -> \(parameter.matchableTypeName(in: context))"
      } else {
        typeName = context.specializeTypeName(parameter.typeName)
      }
      let argumentLabel = parameter.argumentLabel ?? "_"
      if argumentLabel != parameter.name {
        return "\(argumentLabel) \(parameter.name): \(typeName)"
      } else {
        return "\(parameter.name): \(typeName)"
      }
    }).joined(separator: ", ")
    return "\(shortName)(\(parameterNames))"
  }
  
  lazy var fullSelectorName: String = {
    return "\(method.name) -> \(specializedReturnTypeName)"
  }()
  
  lazy var stubbedImplementationCall: String = {
    if method.returnTypeName == "Void" {
      return """
          guard let implementation = try? \(contextPrefix)stubbingContext.implementation(for: invocation) else { return }
          (\(tryInvocation)implementation(invocation)) as! Void
      """
    } else {
      let castedResult = !method.isInitializer ? " as! \(specializedReturnTypeName)" : ""
      return """
          \(!method.isInitializer ? "return " : "")(\(tryInvocation)(try! \(contextPrefix)stubbingContext.implementation(for: invocation))(invocation))\(castedResult)
      """
    }
  }()
  
  lazy var matchableInvocation: String = {
    guard !method.parameters.isEmpty else {
      return """
          let invocation = MockingbirdInvocation(selectorName: "\(fullSelectorName)",
                                                 arguments: [])
      """
    }
    
    return """
    \(resolvedArgumentMatchers)
        let invocation = MockingbirdInvocation(selectorName: "\(fullSelectorName)",
                                               arguments: arguments)
    """
  }()
  
  lazy var resolvedArgumentMatchers: String = {
    let resolved = method.parameters.map({ $0.resolvedType }).joined(separator: "\n    ")
    let arguments = method.parameters.map({ $0.castedMatcherType(in: context) }).joined(separator: ",\n      ")
    return """
        \(resolved)
        let arguments: [MockingbirdMatcher] = [
          \(arguments)
        ]
    """
  }()
  
  lazy var tryInvocation: String = {
    return "try\(method.attributes.contains(.throws) ? "" : "?") "
  }()
  
  lazy var returnTypeAttributes: String = {
    let `throws` = method.attributes.contains(.throws) ? "throws " : ""
    let `rethrows` = method.attributes.contains(.rethrows) ? "rethrows " : ""
    return "\(`throws`)\(`rethrows`)"
  }()
  
  lazy var mockArgumentMatchers: String = {
    return method.parameters.map({ parameter -> String in
      guard !parameter.isClosure || parameter.isEscapingClosure else {
        // Can't save the parameter in the invocation because it's non-escaping
        return "MockingbirdMatcher(nil)"
      }
      return "MockingbirdMatcher(`\(parameter.name)`)"
    }).joined(separator: ", ")
  }()
  
  lazy var contextPrefix: String = {
    return (method.kind.typeScope == .static || method.kind.typeScope == .class ? "staticMock." : "")
  }()
  
  lazy var specializedReturnTypeName: String = {
    return context.specializeTypeName(method.returnTypeName)
  }()
}