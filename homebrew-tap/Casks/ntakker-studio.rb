cask "ntakker-studio" do
  version "0.1.0"
  sha256 "2ea51385f52ef262d08410b0b1be5a966a45dc07888eb5f4a9ed7255174f548f"

  url "https://github.com/biks2013-tools/ntakker/releases/download/ntakker-studio-v#{version}/ntakker-studio-#{version}.zip"
  name "ntakker studio"
  desc "Explore ntakker recordings: transcripts, playback, cuts, Q&A and minutes"
  homepage "https://github.com/biks2013-tools/ntakker"

  depends_on macos: ">= :tahoe"

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
