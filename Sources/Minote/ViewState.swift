import SwiftUI

/// SwiftUI's `State` property wrapper. In the macOS 27 SDK `@State` resolves to
/// a macro whose compiler plugin ships only with Xcode, so a Command Line Tools
/// build can't expand it. This alias names the property wrapper directly.
/// Once the project builds with Xcode, `@ViewState` can become `@State` again.
typealias ViewState = SwiftUI.State
