cask "sessiondock" do
  version "0.1.0"
  sha256 "ca1752a62125515461e626e6027a0a7b86f156e2fe662381b3e94441cd767413"

  url "https://github.com/ridvanaltun/SessionDock/releases/download/v#{version}/SessionDock-#{version}.zip"
  name "SessionDock"
  desc "Browse, search and migrate AI coding sessions"
  homepage "https://github.com/ridvanaltun/SessionDock"

  depends_on macos: ">= :sonoma"

  app "SessionDock.app"

  uninstall quit: "dev.sessiondock.app"

  zap trash: [
    "~/Library/Application Support/SessionDock",
    "~/Library/Preferences/dev.sessiondock.app.plist",
    "~/Library/Saved Application State/dev.sessiondock.app.savedState",
  ]

  caveats <<~EOS
    SessionDock isn't notarized by Apple, so macOS blocks its first launch.
    Open System Settings > Privacy & Security and click "Open Anyway" for SessionDock
    (once), or run:
      xattr -dr com.apple.quarantine "#{appdir}/SessionDock.app"
  EOS
end
