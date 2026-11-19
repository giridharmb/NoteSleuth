cask "notesleuth" do
  version "1.2.0"
  sha256 "0fb31a69bccb648024a7b2b7ca0d688c864d092b1b1ba40b922da6a79163e222"

  url "https://github.com/giridharmb/NoteSleuth/releases/download/v#{version}/NoteSleuth-#{version}.dmg"
  name "NoteSleuth"
  desc "Fast, private menu-bar search for Apple Notes"
  homepage "https://github.com/giridharmb/NoteSleuth"

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "NoteSleuth.app"

  zap trash: "~/Library/Preferences/io.github.giridharmb.NoteSleuth.plist"
end
