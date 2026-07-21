set shell := ["zsh", "-cu"]

project := "Curly.xcodeproj"
scheme := "Curly"
unit_scheme := "CurlyUnitTests"
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
    zsh CurlyTests/run_with_test_server.sh xcodebuild -project {{project}} -scheme {{scheme}} -configuration {{configuration}} -sdk {{sdk}} -derivedDataPath {{derived_data}} test

# Run unit tests only.
test-unit:
    zsh CurlyTests/run_with_test_server.sh xcodebuild -project {{project}} -scheme {{scheme}} -configuration {{configuration}} -sdk {{sdk}} -derivedDataPath {{derived_data}} test -skip-testing:CurlyUITests

# Run unit tests using a scheme that does not build the UI test target. Use this in CI.
test-unit-ci:
    zsh CurlyTests/run_with_test_server.sh xcodebuild -project {{project}} -scheme {{unit_scheme}} -configuration {{configuration}} -sdk {{sdk}} -derivedDataPath {{derived_data}} test

# Run UI tests only.
test-ui:
    zsh CurlyTests/run_with_test_server.sh xcodebuild -project {{project}} -scheme {{scheme}} -configuration {{configuration}} -sdk {{sdk}} -derivedDataPath {{derived_data}} test -only-testing:CurlyUITests

# Run the real post-response engine unit tests and its complete UI automation.
test-scripting:
    zsh CurlyTests/run_with_test_server.sh xcodebuild -project {{project}} -scheme {{scheme}} -configuration {{configuration}} -sdk {{sdk}} -derivedDataPath {{derived_data}} test -only-testing:CurlyTests/PostResponseScriptingTests -only-testing:CurlyTests/SessionCoordinatorTests/testInvalidPostResponseScriptBlocksHTTPRequest -only-testing:CurlyTests/SessionCoordinatorTests/testPostResponseScriptCommitsVariablesAfterHTTPResponse -only-testing:CurlyTests/SessionCoordinatorTests/testScriptFailureRollsBackWritesAndPreservesHTTPStatus -only-testing:CurlyTests/SessionCoordinatorTests/testTransportFailureDoesNotExecutePostResponseScript -only-testing:CurlyUITests/PostResponseScriptsUITests

# Verify the pinned QuickJS-NG source and license bytes.
verify-quickjs-vendor:
    cd CurlyQuickJS && shasum -a 256 -c SHA256SUMS

# Run a single XCTest selector.
test-one selector:
    zsh CurlyTests/run_with_test_server.sh xcodebuild -project {{project}} -scheme {{scheme}} -configuration {{configuration}} -sdk {{sdk}} -derivedDataPath {{derived_data}} test -only-testing:{{selector}}

# Start the test HTTP server on port 9999.
test-server:
    python3 CurlyTests/test_server.py

# Remove local Xcode build products.
clean:
    rm -rf {{derived_data}}

# Build a Release app for distribution testing.
build-release:
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration {{release_configuration}} -sdk {{sdk}} -derivedDataPath {{derived_data}} build

# Prepare a free (ad-hoc signed) distributable app bundle in dist/.
prepare-free-app: build-release
    mkdir -p {{release_dir}}
    rm -rf "{{release_dir}}/Curly.app"
    cp -R "{{derived_data}}/Build/Products/{{release_configuration}}/Curly.app" "{{release_dir}}/Curly.app"
    codesign --force --deep --sign - "{{release_dir}}/Curly.app"

# Create distributable zip from ad-hoc signed app.
package-zip-free: prepare-free-app
    rm -f "{{release_dir}}/Curly.zip"
    ditto -c -k --keepParent "{{release_dir}}/Curly.app" "{{release_dir}}/Curly.zip"

# Create distributable dmg from ad-hoc signed app.
package-dmg-free: prepare-free-app
    rm -f "{{release_dir}}/Curly.dmg"
    rm -rf "{{release_dir}}/dmg_stage"
    mkdir -p "{{release_dir}}/dmg_stage"
    cp -R "{{release_dir}}/Curly.app" "{{release_dir}}/dmg_stage/"
    create-dmg \
      --volname "Curly" \
      --window-pos 200 120 \
      --window-size 600 400 \
      --icon-size 100 \
      --icon "Curly.app" 160 160 \
      --app-drop-link 460 160 \
      --hdiutil-quiet \
      "{{release_dir}}/Curly.dmg" \
      "{{release_dir}}/dmg_stage/"
    rm -rf "{{release_dir}}/dmg_stage"

# Create styled drag-to-Applications dmg from ad-hoc signed app.
package-dmg-styled-free: package-dmg-free

# Validate code signature and Gatekeeper assessment for packaged app.
verify-package-free:
    codesign --verify --deep --strict --verbose=2 "{{release_dir}}/Curly.app"
    spctl --assess --type execute --verbose=4 "{{release_dir}}/Curly.app" || true
