cask "curly" do
  version "0.1.12"
  sha256 "aab3d26d247e0eab5860ea36b0019041b38fe7d56c1d94626a92846a5194dcf9"

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
