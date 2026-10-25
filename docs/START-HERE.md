# Put StudioShelf on your iPad (free Apple ID)

You need: your Mac with Xcode, your iPad, and a USB-C cable.

1. **Download the project.** On github.com/ronyoder31-maker/studio-shelf, click the green **Code** button → **Download ZIP**, and unzip it. (Or in Terminal: `git clone https://github.com/ronyoder31-maker/studio-shelf.git`.)
2. **Open it.** Double-click `StudioShelf.xcodeproj`. Xcode fetches two open-source parts the first time (YouTubeKit and the LAME MP3 encoder); wait until the progress bar at the top finishes.
3. **Sign it with your Apple ID.** Click the blue StudioShelf project icon in the left column → target **StudioShelf** → **Signing & Capabilities**. Tick *Automatically manage signing*, pick your name under **Team** (Xcode › Settings › Accounts lets you add your Apple ID if it's not there). If Xcode says the bundle identifier is taken, change `com.ronyoder.studioshelf` to something unique, such as `com.ronyoder.studioshelf2`.
4. **Connect the iPad** with the cable and unlock it. Tap **Trust** if asked. On the iPad, turn on **Settings › Privacy & Security › Developer Mode** (it restarts once).
5. **Run.** At the top of Xcode, choose your iPad as the destination and press the ▶︎ button.
6. **Trust yourself as a developer** the first time: on the iPad, **Settings › General › VPN & Device Management** → your Apple ID → **Trust**. Then open StudioShelf.

With a free Apple ID the app stops opening after **7 days**. Plug in and press ▶︎ again to renew it; your files stay.

## Where your files are
Everything lives in **Files › On My iPad › StudioShelf**. That folder is on the iPad itself, so anything there plays with no internet.

## Moving movies from the Mac before a trip
- **AirDrop** the movie from Finder to the iPad and choose StudioShelf (or save to Files › On My iPad › StudioShelf), or
- plug in the iPad, open it in **Finder**, go to the **Files** tab, and drag movies onto **StudioShelf**.
Then check **Media** in the app: a movie listed there without a cloud icon is fully on the iPad.

## Saving YouTube audio as MP3
Open a YouTube video in **Browser** and tap **MP3**, or tap **Save Audio as MP3** in Downloads and paste a link. Keep the app open until it says *Saved*. The MP3 lands in **Downloads › Audio** and plays offline. The iPad does all of this itself; the Mac doesn't need to be on.
