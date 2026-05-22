set shell := ["zsh", "-cu"]

project := "NativeCurlRunner.xcodeproj"
scheme := "NativeCurlRunner"
unit_scheme := "NativeCurlRunnerUnitTests"
configuration := "Debug"
release_configuration := "Release"
sdk := "macosx"
derived_data := "./.DerivedData"
release_dir := "./dist"

# List available commands.
default:
    just --list

# Build the macOS app.
build:
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration {{configuration}} -sdk {{sdk}} -derivedDataPath {{derived_data}} build

# Run all unit and UI tests.
test:
    zsh NativeCurlRunnerTests/run_with_test_server.sh xcodebuild -project {{project}} -scheme {{scheme}} -configuration {{configuration}} -sdk {{sdk}} -derivedDataPath {{derived_data}} test

# Run unit tests only.
test-unit:
    zsh NativeCurlRunnerTests/run_with_test_server.sh xcodebuild -project {{project}} -scheme {{scheme}} -configuration {{configuration}} -sdk {{sdk}} -derivedDataPath {{derived_data}} test -skip-testing:NativeCurlRunnerUITests

# Run unit tests using a scheme that does not build the UI test target. Use this in CI.
test-unit-ci:
    zsh NativeCurlRunnerTests/run_with_test_server.sh xcodebuild -project {{project}} -scheme {{unit_scheme}} -configuration {{configuration}} -sdk {{sdk}} -derivedDataPath {{derived_data}} test

# Run UI tests only.
test-ui:
    zsh NativeCurlRunnerTests/run_with_test_server.sh xcodebuild -project {{project}} -scheme {{scheme}} -configuration {{configuration}} -sdk {{sdk}} -derivedDataPath {{derived_data}} test -only-testing:NativeCurlRunnerUITests

# Run a single XCTest selector.
test-one selector:
    zsh NativeCurlRunnerTests/run_with_test_server.sh xcodebuild -project {{project}} -scheme {{scheme}} -configuration {{configuration}} -sdk {{sdk}} -derivedDataPath {{derived_data}} test -only-testing:{{selector}}

# Start the test HTTP server on port 9999.
test-server:
    python3 NativeCurlRunnerTests/test_server.py

# Remove local Xcode build products.
clean:
    rm -rf {{derived_data}}

# Build a Release app for distribution testing.
build-release:
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration {{release_configuration}} -sdk {{sdk}} -derivedDataPath {{derived_data}} build

# Prepare a free (ad-hoc signed) distributable app bundle in dist/.
prepare-free-app: build-release
    mkdir -p {{release_dir}}
    rm -rf "{{release_dir}}/NativeCurlRunner.app"
    cp -R "{{derived_data}}/Build/Products/{{release_configuration}}/NativeCurlRunner.app" "{{release_dir}}/NativeCurlRunner.app"
    codesign --force --deep --sign - "{{release_dir}}/NativeCurlRunner.app"

# Create distributable zip from ad-hoc signed app.
package-zip-free: prepare-free-app
    rm -f "{{release_dir}}/NativeCurlRunner.zip"
    ditto -c -k --keepParent "{{release_dir}}/NativeCurlRunner.app" "{{release_dir}}/NativeCurlRunner.zip"

# Create distributable dmg from ad-hoc signed app.
package-dmg-free: prepare-free-app
    rm -f "{{release_dir}}/NativeCurlRunner.dmg"
    hdiutil create -volname "NativeCurlRunner" -srcfolder "{{release_dir}}/NativeCurlRunner.app" -ov -format UDZO "{{release_dir}}/NativeCurlRunner.dmg"

# Create styled drag-to-Applications dmg from ad-hoc signed app.
package-dmg-styled-free: prepare-free-app
    rm -f "{{release_dir}}/NativeCurlRunner.dmg"
    zsh ./scripts/create_styled_dmg.sh "{{release_dir}}/NativeCurlRunner.app" "{{release_dir}}/NativeCurlRunner.dmg" "NativeCurlRunner"

# Validate code signature and Gatekeeper assessment for packaged app.
verify-package-free:
    codesign --verify --deep --strict --verbose=2 "{{release_dir}}/NativeCurlRunner.app"
    spctl --assess --type execute --verbose=4 "{{release_dir}}/NativeCurlRunner.app" || true
