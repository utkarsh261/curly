cask "nativecurlrunner" do
  version "0.1.3"
  sha256 "79eb52e46760ec0e0d5842a0bd84515c47846ef5bc6df3a451fd86ecd989bcea"

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
