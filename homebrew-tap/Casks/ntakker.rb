cask "ntakker" do
  version "0.3.3"
  sha256 "f565139b1e0070b6c36a4f5d812104694f1f71e5e43b1409fa27ee1d0de88531"

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
    Settings and provider keys are kept in ~/.tool-agents/ntakker/.env,
    shared with ntakker studio and ntakker-cli.
    Companion apps: brew install --cask biks2013-tools/ntakker/ntakker-studio
                    brew install --cask biks2013-tools/ntakker/ntakker-cli
  EOS
end
