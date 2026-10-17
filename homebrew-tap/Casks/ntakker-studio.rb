cask "ntakker-studio" do
  version "0.1.1"
  sha256 "3bc525e98644d189b69c638b98bc8ceb11e5ba894f2f4886962414dd567e5cdd"

  url "https://github.com/biks2013-tools/ntakker/releases/download/ntakker-studio-v#{version}/ntakker-studio-#{version}.zip"
  name "ntakker studio"
  desc "Explore ntakker recordings: transcripts, playback, cuts, Q&A and minutes"
  homepage "https://github.com/biks2013-tools/ntakker"

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
