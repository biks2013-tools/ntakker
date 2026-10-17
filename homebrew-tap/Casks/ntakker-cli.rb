cask "ntakker-cli" do
  version "0.1.1"
  sha256 "eef4b894d3d5f9d66597117644704ba3ef4a9342669d015793ddf851c6806309"

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
    on the first recording. Settings: ~/.tool-agents/ntakker-cli/.env.
  EOS
end
