import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    // Transparent so the prompter's rounded corners / notch shape show the
    // desktop through them (Studio paints its own opaque background).
    flutterViewController.backgroundColor = .clear
    // The prompter is a floating window you hover without activating, so its
    // control bar must appear on hover even while another app is in front.
    flutterViewController.mouseTrackingMode = .always
    self.contentViewController = flutterViewController
    // macOS remembers the last frame. If the app was quit while the prompter
    // (a small borderless frame) was showing, Studio must not reopen that small.
    self.minSize = NSSize(width: 820, height: 620)
    var studioFrame = windowFrame
    if studioFrame.width < 820 || studioFrame.height < 620, let screen = NSScreen.main {
      let v = screen.visibleFrame
      let w = min(1100, v.width), h = min(760, v.height)
      studioFrame = NSRect(x: v.midX - w / 2, y: v.midY - h / 2, width: w, height: h)
    }
    self.setFrame(studioFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  // The prompter configuration is borderless; it must still take key events
  // (Esc to close) and be allowed to sit over the menu bar / notch.
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
