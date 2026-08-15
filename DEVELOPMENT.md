# MenuTools development

## One-time setup

MenuTools needs a matching Swift compiler and macOS SDK. Full Xcode is the most reliable option; Command Line Tools also work when their versions match.

```bash
make doctor
```

The media converter additionally expects `ffmpeg` in `/opt/homebrew/bin`, `/usr/local/bin`, or `PATH`.

If Apple Command Line Tools contain a patch-level Swift/SDK mismatch, `scripts/build.sh` detects it and enables Swift's compatibility mode automatically. Installing full Xcode is still recommended for previews, debugging, and the most reliable SourceKit indexing.

## Daily workflow

```bash
make build      # debug bundle
make release    # optimized bundle
make run        # release build + launch from ./build
make install    # release build + copy to /Applications
make preview    # render dashboard/settings PNGs without opening the menu bar app
make lint       # verify Swift formatting
make format     # format Swift sources
```

VS Code tasks expose the same commands. Open the repository folder and install the recommended Swift extension for SourceKit-LSP navigation.

## macOS privacy permissions

The iMessage shortcut requires Accessibility, Input Monitoring, and permission to synthesize keyboard events. Grant them to the stable `/Applications/MenuTools.app` bundle from the Settings screen inside MenuTools.

The build script signs every local build with the stable designated requirement `com.frider.MenuTools`. Do not run the raw executable from `.build`; doing so creates a different TCC identity and macOS will treat it as another app.
