cask "sessiondock" do
  version "0.1.1"
  sha256 "f1b0725f9b6ee87b0466469ab2b66ef954245374a017b3956cd4d772538b66ff"

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
