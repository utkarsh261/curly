cask "curly" do
  version "0.1.5"
  sha256 "e386ff1e58e579dccab9281161aa5df072b7e1058c6a9cb2b47b077e05e1be9e"

  url "https://github.com/utkarsh261/curly/releases/download/v#{version}/Curly-v#{version}.dmg"
  name "Curly"
  desc "Native macOS GUI for importing and running cURL commands"
  homepage "https://github.com/utkarsh261/curly"

  app "Curly.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{appdir}/Curly.app"],
                   must_succeed: false
  end

  zap trash: [
    "~/Library/Application Support/Curly",
    "~/Library/Preferences/com.example.Curly.plist",
  ]
end
