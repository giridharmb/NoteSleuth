cask "notesleuth" do
  version "1.3.0"
  sha256 "af4d93f57fcd3ad7064071f5d44c91cf1b27363ba2245ef8bff994d7c39819b5"

  url "https://github.com/giridharmb/NoteSleuth/releases/download/v#{version}/NoteSleuth-#{version}.dmg"
  name "NoteSleuth"
  desc "Fast, private menu-bar search for Apple Notes"
  homepage "https://github.com/giridharmb/NoteSleuth"

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "NoteSleuth.app"

  zap trash: "~/Library/Preferences/io.github.giridharmb.NoteSleuth.plist"
end
