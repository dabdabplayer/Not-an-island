# NotAnIslandKit

Build extensions for [Not an Island](../README.md): live activities that share the MacBook notch with Music and the other built-in features.

An extension provides SwiftUI views for the notch's presentations. Not an Island runs each extension in its own sandboxed process, draws its views inside the notch, and owns every animation.

## Licence

NotAnIslandKit is licensed under the **GPL-3.0**, like Not an Island. An extension that uses it is a GPL-covered work, so **every Not an Island extension must be open source under the GPL-3.0**.

## Presentations

| Presentation | Where it appears | View |
|---|---|---|
| Compact leading | Left of the camera, while your activity has the highest priority | `compactLeading` |
| Compact trailing | Right of the camera | `compactTrailing` |
| Minimal | A bubble beside the wings, while another activity has them | `minimal` |
| Expanded | Your section of the notch when the pointer hovers over it | `expanded` |
| Banner | Briefly below the camera, when you post one | `banner` |

Each view is drawn at the **fixed size** you declare in `NotchActivitySizes`. The notch never resizes your view while it animates, and it clips content that overflows. A presentation whose size is `nil` isn't shown.

Not an Island caps every size:

| Size | Maximum |
|---|---|
| `compactSideWidth` | 80 pt |
| `expanded` | 480 × 320 pt |
| `minimal` | the camera band's height (about 32 pt), at most 3 times as wide as it is tall |
| `banner` | 320 × 60 pt |
| Banner duration | 10 seconds |

People choose the order of activities in Not an Island's Settings. The highest active activity fills the wings and the next becomes the bubble. New extensions start at the bottom of the order.

## Create an extension

Requirements: Xcode 26 or later and macOS 15 or later.

1. **Create or open a macOS app.** An extension always ships inside an app. The app can be as small as a window explaining how to turn the extension on.
2. **Add an extension target.** Choose File ▸ New ▸ Target ▸ macOS ▸ **Generic Extension**. Leave the App Sandbox capability on; extensions must be sandboxed.
3. **Point it at Not an Island.** In the extension's `Info.plist`, set:

   ```xml
   <key>EXAppExtensionAttributes</key>
   <dict>
       <key>EXExtensionPointIdentifier</key>
       <string>app.arysha.NotAnIsland.activity</string>
   </dict>
   ```

4. **Add the package.** Choose File ▸ Add Package Dependencies, enter `https://github.com/dabdabplayer/Not-an-island`, and add the **NotAnIslandKit** library to the extension target.
5. **Replace the template's code** with a type that adopts `NotchActivityExtension`:

   ```swift
   import ExtensionFoundation
   import ExtensionKit
   import NotAnIslandKit
   import SwiftUI

   @main
   struct CoffeeExtension: NotchActivityExtension {
       let controller = NotchActivityController(
           isActive: true,
           sizes: NotchActivitySizes(
               compactSideWidth: 40,
               expanded: CGSize(width: 320, height: 64),
               minimal: CGSize(width: 24, height: 24)
           )
       )

       var compactLeading: some View { Image(systemName: "cup.and.saucer.fill") }
       var compactTrailing: some View { Text("2 left") }
       var minimal: some View { Image(systemName: "cup.and.saucer.fill") }
       var expanded: some View { Text("Two coffees to go").padding() }
   }
   ```

   Import `ExtensionFoundation` and `ExtensionKit` as well as `NotAnIslandKit`: the extension's entry point comes from them.

The complete, working example in [`Examples/Timer`](../Examples/Timer) is a countdown timer with presets, a ring-shaped bubble and a "Time's up" banner.

## The controller

`NotchActivityController` is shared by every presentation, because an extension runs as a single process. Views can read it from the environment:

```swift
@Environment(NotchActivityController.self) private var controller
```

- `isActive`: whether there is anything to show. An inactive activity takes no room in the notch.
- `sizes`: change these at any time; the notch animates to the new layout.
- `postBanner(for:)`: shows your `banner` view, at `sizes.banner`, for the given time. One banner shows at a time, and banners are dropped while the notch is expanded.
- `holdOpen(_:)`: keeps the notch expanded during an interaction that may carry the pointer outside it, such as dragging a slider. Release it when the interaction ends.
- `visiblePresentations`: which presentations may be on screen. Pause work the person can't see.
- `isConnected`: whether Not an Island is currently connected.

## Try it

1. Build and run your app once, so macOS registers its extension.
2. In Not an Island, right-click the notch, choose **Settings…**, open **Extensions**, and switch your extension on. Extensions from other apps are always off until a person turns them on.
3. To see what Not an Island makes of your extension, stream its log:

   ```sh
   /usr/bin/log stream --level debug --predicate 'subsystem == "app.arysha.NotAnIsland"'
   ```

If your extension crashes, its presentations disappear and Not an Island restarts it after 1, 5 and then 30 seconds. After repeated crashes it gives up and says so in Settings. An extension that ran for at least a minute starts afresh.

## Compatibility

Messages between Not an Island and extensions carry a protocol version. Additions keep the same major version. Not an Island ignores an extension built against a newer major version, and its Settings ask the person to update Not an Island.
