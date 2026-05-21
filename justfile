set shell := ["zsh", "-cu"]

project := "NativeCurlRunner.xcodeproj"
scheme := "NativeCurlRunner"
configuration := "Debug"
sdk := "macosx"
derived_data := "./.DerivedData"

# List available commands.
default:
    just --list

# Build the macOS app.
build:
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration {{configuration}} -sdk {{sdk}} -derivedDataPath {{derived_data}} build

# Run all unit and UI tests.
test:
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration {{configuration}} -sdk {{sdk}} -derivedDataPath {{derived_data}} test

# Run unit tests only.
test-unit:
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration {{configuration}} -sdk {{sdk}} -derivedDataPath {{derived_data}} test -skip-testing:NativeCurlRunnerUITests

# Run UI tests only.
test-ui:
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration {{configuration}} -sdk {{sdk}} -derivedDataPath {{derived_data}} test -only-testing:NativeCurlRunnerUITests

# Run a single XCTest selector.
test-one selector:
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration {{configuration}} -sdk {{sdk}} -derivedDataPath {{derived_data}} test -only-testing:{{selector}}

# Remove local Xcode build products.
clean:
    rm -rf {{derived_data}}
