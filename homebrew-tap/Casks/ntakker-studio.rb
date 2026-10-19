cask "ntakker-studio" do
  version "0.5.0"
  sha256 "4901c370038c43dab21e7fb26e31feb9df9e4420ae6a34cc1a71fe14d9748a79"

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
