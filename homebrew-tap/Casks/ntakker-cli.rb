cask "ntakker-cli" do
  version "0.2.0"
  sha256 "1dff4130d6604d459de0eb244d1483832dd7916cc1f6afccc64b481a2a90e64a"

  url "https://github.com/biks2013-tools/ntakker/releases/download/ntakker-cli-v#{version}/ntakker-cli-#{version}.zip"
  name "ntakker-cli"
  desc "Command-line recorder for system audio and microphone, with live transcription"
  homepage "https://github.com/biks2013-tools/ntakker"

  livecheck do
    url :url
    regex(/^ntakker-cli-v?(\d+(?:\.\d+)+)$/i)
    strategy :github_releases
  end

  depends_on macos: :tahoe

  binary "ntakker-cli"

  caveats <<~EOS
    Run: ntakker-cli start --output ~/Recordings/test.m4a   (Ctrl-C stops)
    macOS asks your terminal app for Microphone and Screen Recording access
    on the first recording. Settings (shared with ntakker and ntakker studio):
    ~/.tool-agents/ntakker/.env.
  EOS
end
