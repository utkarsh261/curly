cask "nativecurlrunner" do
  version "0.1.0"
  sha256 "placeholder_sha256"

  url "https://github.com/utkarsh261/gurl/releases/download/v#{version}/NativeCurlRunner-v#{version}.dmg"
  name "NativeCurlRunner"
  desc "Native macOS GUI for importing and running cURL commands"
  homepage "https://github.com/utkarsh261/gurl"

  app "NativeCurlRunner.app"

  zap trash: [
    "~/Library/Application Support/NativeCurlRunner",
    "~/Library/Preferences/com.example.NativeCurlRunner.plist",
  ]
end
