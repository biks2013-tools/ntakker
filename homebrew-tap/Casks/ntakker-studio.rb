cask "ntakker-studio" do
  version "0.4.1"
  sha256 "affcf7e57c60522a955a9c88452c434cc29e8727dc46f8f4f116da9395ebc3bf"

  url "https://github.com/biks2013-tools/ntakker/releases/download/ntakker-studio-v#{version}/ntakker-studio-#{version}.zip"
  name "ntakker studio"
  desc "Explore ntakker recordings: transcripts, playback, cuts, Q&A and minutes"
  homepage "https://github.com/biks2013-tools/ntakker"

  livecheck do
    url :url
    regex(/^ntakker-studio-v?(\d+(?:\.\d+)+)$/i)
    strategy :github_releases
  end

  depends_on macos: :tahoe

  app "ntakker-studio.app"

  uninstall quit: "com.giorgosmarinos.ntakker-studio"

  zap trash: [
    "~/Library/Preferences/com.giorgosmarinos.ntakker-studio.plist",
    "~/Library/Saved Application State/com.giorgosmarinos.ntakker-studio.savedState",
  ]

  caveats <<~EOS
    ntakker studio opens the recordings ntakker saved (NTAKKER_RECORDINGS_DIR).
    It shares one settings file with ntakker and ntakker-cli:
    ~/.tool-agents/ntakker/.env (Ask provider, keys, echo filter).
  EOS
end
