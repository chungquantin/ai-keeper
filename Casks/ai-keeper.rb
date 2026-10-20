cask "ai-keeper" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/chungquantin/ai-keeper/releases/download/v#{version}/AI-Keeper-#{version}.zip"
  name "AI Keeper"
  desc "Find and clean up what AI coding agents leave on your Mac"
  homepage "https://chungquantin.github.io/ai-keeper/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "AI Keeper.app"
  # Puts the command-line tool and MCP server on your PATH as `aikeeper`.
  binary "#{appdir}/AI Keeper.app/Contents/MacOS/AIKeeper", target: "aikeeper"

  # Releases are not notarized yet, so clear the quarantine flag Homebrew sets on downloads.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{appdir}/AI Keeper.app"]
  end

  zap trash: [
    "~/Library/Application Support/AIKeeper",
    "~/Library/Caches/co.architect.ai-keeper",
    "~/Library/Preferences/co.architect.ai-keeper.plist",
  ]
end
