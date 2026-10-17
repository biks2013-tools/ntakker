cask "ntakker-studio" do
  version "0.2.0"
  sha256 "97dd077cea68b2ea4923dd9d8011675344fbf8bf89f1434ece6de8b369bdd2e8"

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
    ntakker studio opens the recordings ntakker saved. On first launch it uses
    ntakker's recording folder, or asks you to choose one.
    Ask, minutes and re-transcription use ntakker's settings in
    ~/.tool-agents/ntakker/.env (NTAKKER_ASK_PROVIDER and the provider's key).
  EOS
end
