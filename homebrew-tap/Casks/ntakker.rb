cask "ntakker" do
  version "0.2.0"
  sha256 "62c11a4043a867a263679623e9f7566e7d40bf14da5fc88058a17cedfcbadf75"

  url "https://github.com/biks2013-tools/ntakker/releases/download/ntakker-v#{version}/ntakker-#{version}.zip"
  name "ntakker"
  desc "Menu-bar recorder for system audio and microphone, with live transcription"
  homepage "https://github.com/biks2013-tools/ntakker"

  livecheck do
    url :url
    regex(/^ntakker-v?(\d+(?:\.\d+)+)$/i)
    strategy :github_releases
  end

  depends_on macos: :tahoe

  app "ntakker.app"

  uninstall quit: "com.giorgosmarinos.ntakker"

  zap trash: [
    "~/Library/Preferences/com.giorgosmarinos.ntakker.plist",
  ]

  caveats <<~EOS
    ntakker lives in the menu bar (no Dock icon). On the first recording macOS
    asks for Microphone and Screen Recording (system audio); allow both.
    Settings and provider keys are kept in ~/.tool-agents/ntakker/.env.
    Companion apps: brew install --cask biks2013-tools/ntakker/ntakker-studio
                    brew install --cask biks2013-tools/ntakker/ntakker-cli
  EOS
end
