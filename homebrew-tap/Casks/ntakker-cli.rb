cask "ntakker-cli" do
  version "0.1.0"
  sha256 "186c7d7a475d068d8f86b48e89bc229a0da4e21e43793d6d616bec766df65b53"

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
