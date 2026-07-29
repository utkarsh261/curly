cask "curly" do
  version "0.1.19"
  sha256 "1c52428090875dc98b09f8f77f48a9952c873a4fa8fa3e88d2525b7b18cc1634"

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
