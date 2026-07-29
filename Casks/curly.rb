cask "curly" do
  version "0.1.20"
  sha256 "af6f0c288c58e6e6fc64ba929526253e314341123355f363e6d67f2953c71f3a"

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
