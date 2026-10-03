import AppKit
import QuartzCore
import IOSurface

// Overlay windows
//
// Compositing model: two STATIC, full-DISPLAY, click-through
// windows that are never moved or resized while tracking. Following the protected
// window only moves CALayers inside them (cheap, at display rate). Resizing real
// windows every frame only kept up ~40 fps during Stage Manager animations — that was
// the stagger. All implicit layer animations are disabled to stop flicker.

/// AppKit keeps a window on the display it's on: moving a full-display cover to another display got
/// pulled back (the cover stayed on the built-in screen when the window moved to an external one). The
/// covers go exactly where they're put.
final class OverlayWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

func makeOverlayWindow(shared: Bool) -> NSWindow {
    let w = OverlayWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                     styleMask: .borderless, backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    w.isOpaque = false
    w.backgroundColor = .clear
    w.hasShadow = false
    w.ignoresMouseEvents = true
    w.animationBehavior = .none
    w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
    w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + (shared ? 0 : 1))
    // backing is capturable (shows black in captures); mirror is excluded from captures.
    w.sharingType = shared ? .readOnly : .none
    return w
}

final class Overlay {
    let backing = makeOverlayWindow(shared: true)
    let mirror = makeOverlayWindow(shared: false)
    let backingShape = CALayer()
    let mirrorClip = CALayer()
    let mirrorLayer = CALayer()
    // Second cover, over Stage Manager's own preview of the window (a separate WindowManager window).
    let proxyShape = CALayer()
    private(set) var proxyFrame: NSRect?
    private(set) var frame = NSRect.zero        // protected window, Cocoa global coordinates
    private(set) var visible = false
    private(set) var hasContents = false
    private var screenFrame = NSRect.zero
    private var geometry: FrameGeometry?

    var radiusPoints: CGFloat = 0 { didSet { applyRadius() } }
    var naturalWidth: CGFloat = 0 { didSet { applyRadius() } }
    private(set) var mainHidden = false

    init() {
        let noAnimation: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(),
                                               "contents": NSNull(), "cornerRadius": NSNull(), "hidden": NSNull()]
        let backingView = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        backingView.wantsLayer = true
        backingShape.backgroundColor = NSColor.black.cgColor
        backingShape.actions = noAnimation
        backingView.layer?.addSublayer(backingShape)
        proxyShape.backgroundColor = NSColor.black.cgColor
        proxyShape.actions = noAnimation
        proxyShape.isHidden = true
        backingView.layer?.addSublayer(proxyShape)
        backing.contentView = backingView

        let mirrorView = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        mirrorView.wantsLayer = true
        mirrorClip.masksToBounds = true
        mirrorClip.actions = noAnimation
        mirrorLayer.contentsGravity = .resize
        mirrorLayer.actions = noAnimation
        mirrorClip.addSublayer(mirrorLayer)
        mirrorView.layer?.addSublayer(mirrorClip)
        mirror.contentView = mirrorView
    }

    private func applyRadius() {
        let scale = naturalWidth > 0 && frame.width > 0 ? min(1, frame.width / naturalWidth) : 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        backingShape.cornerRadius = (radiusPoints * scale).rounded(.up)
        CATransaction.commit()
    }

    func place(_ f: NSRect) {
        guard f != frame else { return }
        frame = f
        let center = NSPoint(x: f.midX, y: f.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main ?? NSScreen.screens[0]
        if screen.frame != screenFrame {
            screenFrame = screen.frame
            backing.setFrame(screenFrame.insetBy(dx: -1, dy: -1), display: false)
            mirror.setFrame(screenFrame, display: false)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        backingShape.frame = f.offsetBy(dx: -screenFrame.minX + 1, dy: -screenFrame.minY + 1)
        mirrorClip.frame = f.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        layoutMirror()
        CATransaction.commit()
        applyRadius()
        if mainHoles { applyProxyHoles() }
    }

    private func layoutMirror() {
        layout(mirrorLayer, in: mirrorClip)
    }

    private func layout(_ image: CALayer, in clip: CALayer) {
        let bounds = clip.bounds
        guard let g = geometry, bounds.width > 0, bounds.height > 0 else { return }
        let content = g.pixelRect
        // Full-scale frames are drawn pixel-for-pixel from the top-left — never stretched. A frame always lags
        // the window by a frame or two, so while you resize it's a little smaller or bigger than the window;
        // stretching it to fit resampled every pixel (blurry, very visible on 1× displays). Like a real window
        // redrawing: a frame-long sliver in the window's edge colour (setFill) or a cut-off edge instead.
        // Only frames that really are another size scale to fit: ScreenCaptureKit shrank them (contentScale),
        // they're cropped (Stage Manager offset frames), or they're far off (> 12 %, Stage Manager grow/shrink).
        let scale = g.scaleFactor > 0 ? g.scaleFactor : 1
        let w = content.width / scale, h = content.height / scale
        let oneToOne = g.crop == nil && g.contentScale >= 0.99 &&
                       abs(w - bounds.width) <= bounds.width * 0.12 && abs(h - bounds.height) <= bounds.height * 0.12
        let sx = oneToOne ? 1 / scale : bounds.width / content.width
        let sy = oneToOne ? 1 / scale : bounds.height / content.height
        let width = CGFloat(g.bufferWidth) * sx, height = CGFloat(g.bufferHeight) * sy
        let x = -content.minX * sx
        let y = bounds.height - height + content.minY * sy
        CATransaction.begin(); CATransaction.setDisableActions(true)
        image.frame = CGRect(x: x, y: y, width: width, height: height)
        CATransaction.commit()
    }

    /// Width in points of the image the copy is showing (0 before the first frame).
    var shownContentWidth: CGFloat {
        guard hasContents, let g = geometry else { return 0 }
        return g.pixelRect.width / max(1, g.scaleFactor)
    }

    /// Hide only the main cover (the window itself isn't on screen) while a preview cover stays.
    func setMainHidden(_ hidden: Bool) {
        guard hidden != mainHidden else { return }
        mainHidden = hidden
        applyVisibility()
    }

    /// false: the main cover shows plain black locally too (the window is a Stage Manager thumbnail or a
    /// Mission Control tile). Captures are black either way; this only decides what the user sees.
    private(set) var copyVisible = true
    func setCopyVisible(_ visible: Bool) {
        guard visible != copyVisible else { return }
        copyVisible = visible
        applyVisibility()
    }

    private func applyVisibility() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        backingShape.isHidden = mainHidden
        mirrorClip.isHidden = mainHidden || !copyVisible
        CATransaction.commit()
    }

    /// Cover Stage Manager's preview of the window (nil hides): black for captures, the live copy scaled
    /// into it locally. On the overlay's display (the strip always is).
    /// Parts of the thumbnail cover that windows above the thumbnail hide anyway (Cocoa global rects, corner
    /// radius). The cover floats above everything; without these holes it showed on top of those windows.
    struct Hole: Equatable { let rect: NSRect; let radius: CGFloat }
    private(set) var proxyHoles: [Hole] = []
    /// The main cover gets the same holes while it's showing the window as a strip thumbnail (macOS reports
    /// the window itself at the thumbnail, so its cover sits right there too, black locally).
    private(set) var mainHoles = false
    private let proxyMask = CAShapeLayer(), backingHoleMask = CAShapeLayer(), mirrorHoleMask = CAShapeLayer()

    func setProxyHoles(_ holes: [Hole], includingMainCover main: Bool) {
        guard holes != proxyHoles || main != mainHoles else { return }
        proxyHoles = holes
        mainHoles = main
        applyProxyHoles()
    }

    /// A mask for a layer covering `box` (Cocoa global): everything but the holes.
    private func holeMask(_ mask: CAShapeLayer, box: NSRect) -> CAShapeLayer {
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: box.size))
        for h in proxyHoles where h.rect.intersects(box) {
            let r = h.rect.offsetBy(dx: -box.minX, dy: -box.minY)
            let c = min(h.radius, r.width / 2, r.height / 2)
            path.addRoundedRect(in: r, cornerWidth: c, cornerHeight: c)
        }
        mask.frame = CGRect(origin: .zero, size: box.size)
        mask.fillRule = .evenOdd
        mask.fillColor = NSColor.black.cgColor
        mask.path = path
        mask.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        return mask
    }

    private func applyProxyHoles() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if let f = proxyFrame, !proxyHoles.isEmpty { proxyShape.mask = holeMask(proxyMask, box: f) } else { proxyShape.mask = nil }
        if mainHoles, !proxyHoles.isEmpty, proxyHoles.contains(where: { $0.rect.intersects(frame) }) {
            backingShape.mask = holeMask(backingHoleMask, box: frame)
            mirrorClip.mask = holeMask(mirrorHoleMask, box: frame)
        } else {
            backingShape.mask = nil; mirrorClip.mask = nil
        }
    }

    func placeProxy(_ f: NSRect?) {
        guard f != proxyFrame else { return }
        proxyFrame = f
        defer { applyProxyHoles() }   // holes are relative to the cover
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let f {
            proxyShape.frame = f.offsetBy(dx: -screenFrame.minX + 1, dy: -screenFrame.minY + 1)
            let r = naturalWidth > 0 ? (radiusPoints * min(1, f.width / naturalWidth)).rounded(.up) : 0
            proxyShape.cornerRadius = r
            // Preview cover is solid BLACK on screen and in captures (thumbnail — no live copy).
            proxyShape.isHidden = false
        } else {
            proxyShape.isHidden = true
        }
        CATransaction.commit()
    }


    var keepOnTop = true { didSet { applyLevels() } }
    /// Raise the cover ABOVE system UI (the Stage Manager strip and Mission Control both
    /// composite above normal floating windows, so a floating cover is captured *under* the
    /// preview). Toggled on only while a preview proxy is active; back to floating otherwise.
    var aboveSystemUI = false { didSet { if aboveSystemUI != oldValue { applyLevels() } } }
    private func applyLevels() {
        // aboveSystemUI = 101 (kCGPopUpMenuWindowLevel, above the Stage Manager strip / Mission Control);
        // else floating (keep on top) or normal.
        let base = aboveSystemUI ? NSWindow.Level.popUpMenu.rawValue
                                 : (keepOnTop ? NSWindow.Level.floating.rawValue : NSWindow.Level.normal.rawValue)
        backing.level = NSWindow.Level(rawValue: base)
        mirror.level = NSWindow.Level(rawValue: base + (keepOnTop || aboveSystemUI ? 1 : 0))
    }

    func show(above target: CGWindowID) {
        guard !visible else { return }
        visible = true
        lastOrderedAt = Date()
        if keepOnTop {
            backing.orderFrontRegardless()   // backing first: never a moment with mirror but no backing
            mirror.orderFrontRegardless()
        } else {
            orderDirectlyAbove(target)
        }
    }

    /// Last time the covers were ordered; the window list can lag behind that by a moment.
    private(set) var lastOrderedAt = Date.distantPast

    func orderDirectlyAbove(_ target: CGWindowID, force: Bool = false) {
        lastOrderedAt = Date()
        if force { mirror.orderOut(nil); backing.orderOut(nil) }
        backing.order(.above, relativeTo: Int(target))
        mirror.order(.above, relativeTo: backing.windowNumber)
    }

    /// (inOrder, exposed): exposed means the protected window is above the backing, so a capture now would show it.
    /// detail: the windows nearest above the target that count, for the log when the order doesn't hold.
    func stackState(above target: CGWindowID, targetPID: pid_t) -> (inOrder: Bool, exposed: Bool, detail: String) {
        guard let list = windowList([.optionOnScreenAboveWindow], relativeTo: target) else { return (true, false, "") }
        // Not "something covering the window": Stage Manager's own preview window for the app (WindowManager),
        // which macOS keeps directly above the app's window, and the app's own other windows (child / helper
        // windows that macOS keeps attached above it).
        let counted = list.filter { $0.owner != "WindowManager" && $0.pid != targetPID }
        let ids = counted.map { Int($0.id) }
        let n = ids.count
        let inOrder = n >= 2 && ids[n - 1] == backing.windowNumber && ids[n - 2] == mirror.windowNumber
        let detail = counted.suffix(4).reversed().map { w -> String in
            let num = Int(w.id)
            let who = num == backing.windowNumber ? "cover" : num == mirror.windowNumber ? "copy" : w.owner
            return "\(num):\(who)/L\(w.layer)"
        }.joined(separator: " < ")
        return (inOrder, !ids.contains(backing.windowNumber), detail)
    }

    func hide() {
        guard visible else { return }
        visible = false
        mirror.orderOut(nil)
        backing.orderOut(nil)
    }

    func setFrameContents(_ surface: IOSurface, geometry g: FrameGeometry) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mirrorLayer.contents = surface
        CATransaction.commit()
        hasContents = true
        if g != geometry { geometry = g; layoutMirror() }
    }

    func setFill(_ color: CGColor) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mirrorClip.backgroundColor = color
        mirrorClip.cornerRadius = backingShape.cornerRadius
        CATransaction.commit()
    }

    func close() { hide(); mirror.close(); backing.close() }
}
