cask "ai-keeper" do
  version "0.1.0"
  sha256 "27e809e0187f865569c2550e9511ab9fb8c557ee413d09c7bb10da3ec482eed7"

  url "https://github.com/chungquantin/ai-keeper/releases/download/v#{version}/AI-Keeper-#{version}.zip"
  name "AI Keeper"
  desc "Find and clean up what AI coding agents leave behind"
  homepage "https://chungquantin.github.io/ai-keeper/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "AI Keeper.app"
  # Puts the command-line tool and MCP server on your PATH as `aikeeper`.
  binary "#{appdir}/AI Keeper.app/Contents/MacOS/AIKeeper", target: "aikeeper"

  # Releases are not notarized yet, so clear the quarantine flag Homebrew sets on downloads.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-cr", "{{appdir}}/AI Keeper.app"]
  end

  zap trash: [
    "~/Library/Application Support/AIKeeper",
    "~/Library/Caches/chungquantin.ai-keeper",
    "~/Library/Preferences/chungquantin.ai-keeper.plist",
    # Left behind by builds before the bundle ID changed.
    "~/Library/Caches/co.architect.ai-keeper",
    "~/Library/Preferences/co.architect.ai-keeper.plist",
  ]
end
