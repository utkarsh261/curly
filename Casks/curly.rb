cask "curly" do
  version "0.1.4"
  sha256 "037ee89857e3444b8a4026c51c4a2888ccf39e7d31d52d98891d91a22f51916d"

  url "https://github.com/utkarsh261/curly/releases/download/v#{version}/Curly-v#{version}.dmg"
  name "Curly"
  desc "Native macOS GUI for importing and running cURL commands"
  homepage "https://github.com/utkarsh261/curly"

  app "Curly.app"

  zap trash: [
    "~/Library/Application Support/Curly",
    "~/Library/Preferences/com.example.Curly.plist",
  ]
end
