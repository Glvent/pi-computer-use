import AppKit
import CoreMedia
import ScreenCaptureKit

/// Floating panel that can never take focus or activate the helper.
private final class PipPanel: NSPanel {
	override var canBecomeKey: Bool { false }
	override var canBecomeMain: Bool { false }
}

/// Glow colors from the Zenkai theme: `accent` (#6a9bcc) and the lighter `info` (#a3cdf2).
private let pipAccentColor = NSColor(srgbRed: 0x6a / 255, green: 0x9b / 255, blue: 0xcc / 255, alpha: 1)
private let pipHighlightColor = NSColor(srgbRed: 0xa3 / 255, green: 0xcd / 255, blue: 0xf2 / 255, alpha: 1)

/// Transparent margin around the card that holds the glow. `pipGlowIntensity` fades to 0
/// at this distance, so the window edge never clips the glow.
let pipGlowPadding: CGFloat = 48
/// Distance from the card to the visible screen edge at the default position. The panel's
/// transparent margin may extend past the visible frame.
let pipCardScreenInset: CGFloat = 20

private final class PipCardView: NSView {
	override var mouseDownCanMoveWindow: Bool { true }
	override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
	// The full-bounds PipResizeView (mouseDownCanMoveWindow == false) removes the whole
	// window from AppKit's background-drag region, so start the move explicitly.
	override func mouseDown(with event: NSEvent) {
		window?.performDrag(with: event)
	}
}

/// Transparent overlay that turns drags on the card's border into resizes. Everywhere else
/// it returns no hit, so drags fall through and move the panel.
final class PipResizeView: NSView {
	static let band: CGFloat = 8
	static let corner: CGFloat = 18
	var onBegin: (() -> Void)?
	var onDrag: ((PipResizeEdges, CGVector) -> Void)?
	var onEnd: (() -> Void)?
	private var dragEdges: PipResizeEdges = []
	private var dragStart: CGPoint = .zero

	override var mouseDownCanMoveWindow: Bool { false }
	override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

	private func edges(at point: CGPoint) -> PipResizeEdges {
		pipResizeEdges(at: point, card: bounds.insetBy(dx: pipGlowPadding, dy: pipGlowPadding), band: Self.band, corner: Self.corner)
	}

	override func hitTest(_ point: NSPoint) -> NSView? {
		guard let superview, !edges(at: convert(point, from: superview)).isEmpty else { return nil }
		return self
	}

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		for area in trackingAreas { removeTrackingArea(area) }
		addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
	}

	override func mouseMoved(with event: NSEvent) {
		guard dragEdges.isEmpty else { return }
		Self.cursor(for: edges(at: convert(event.locationInWindow, from: nil))).set()
	}

	override func mouseExited(with event: NSEvent) {
		if dragEdges.isEmpty { NSCursor.arrow.set() }
	}

	override func mouseDown(with event: NSEvent) {
		dragEdges = edges(at: convert(event.locationInWindow, from: nil))
		guard !dragEdges.isEmpty else { return }
		dragStart = NSEvent.mouseLocation
		onBegin?()
	}

	override func mouseDragged(with event: NSEvent) {
		guard !dragEdges.isEmpty else { return }
		let location = NSEvent.mouseLocation
		onDrag?(dragEdges, CGVector(dx: location.x - dragStart.x, dy: location.y - dragStart.y))
	}

	override func mouseUp(with event: NSEvent) {
		guard !dragEdges.isEmpty else { return }
		dragEdges = []
		onEnd?()
	}

	private static func cursor(for edges: PipResizeEdges) -> NSCursor {
		let horizontal = edges.contains(.left) || edges.contains(.right)
		let vertical = edges.contains(.top) || edges.contains(.bottom)
		if horizontal && vertical, #available(macOS 15.0, *) {
			let position: NSCursor.FrameResizePosition = edges.contains(.top)
				? (edges.contains(.left) ? .topLeft : .topRight)
				: (edges.contains(.left) ? .bottomLeft : .bottomRight)
			return NSCursor.frameResize(position: position, directions: .all)
		}
		if horizontal { return .resizeLeftRight }
		if vertical { return .resizeUpDown }
		return .arrow
	}
}

/// Renders the glow around a rounded card as a bitmap. Core Animation shadows have a
/// fixed Gaussian falloff that is either too tight or gets clipped by the window; a
/// bitmap gives a long, soft tail that is guaranteed to reach 0 inside the margin.
private func pipGlowImage(size: CGSize, cardRect: CGRect, cornerRadius: CGFloat, scale: CGFloat) -> CGImage? {
	let width = Int((size.width * scale).rounded())
	let height = Int((size.height * scale).rounded())
	guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
	let accent = (r: 0x6a / 255.0, g: 0x9b / 255.0, b: 0xcc / 255.0)
	let highlight = (r: 0xa3 / 255.0, g: 0xcd / 255.0, b: 0xf2 / 255.0)
	var pixels = [UInt8](repeating: 0, count: width * height * 4)
	for row in 0..<height {
		// Bitmap rows run top to bottom; view coordinates run bottom to top.
		let y = (Double(height - row) - 0.5) / scale
		for column in 0..<width {
			let x = (Double(column) + 0.5) / scale
			let distance = pipRoundedRectDistance(point: CGPoint(x: x, y: y), rect: cardRect, radius: cornerRadius)
			let alpha = pipGlowIntensity(distance: distance, padding: pipGlowPadding)
			guard alpha > 0 else { continue }
			// Light blue right at the edge, settling into the accent blue farther out.
			let mix = min(1, max(0, distance) / 10)
			let r = highlight.r + (accent.r - highlight.r) * mix
			let g = highlight.g + (accent.g - highlight.g) * mix
			let b = highlight.b + (accent.b - highlight.b) * mix
			let index = (row * width + column) * 4
			pixels[index] = UInt8((r * alpha * 255).rounded())
			pixels[index + 1] = UInt8((g * alpha * 255).rounded())
			pixels[index + 2] = UInt8((b * alpha * 255).rounded())
			pixels[index + 3] = UInt8((alpha * 255).rounded())
		}
	}
	// The data provider owns a copy of the bytes, so the image never points at freed memory.
	guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
	return CGImage(
		width: width,
		height: height,
		bitsPerComponent: 8,
		bitsPerPixel: 32,
		bytesPerRow: width * 4,
		space: colorSpace,
		bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
		provider: provider,
		decode: nil,
		shouldInterpolate: true,
		intent: .defaultIntent
	)
}

private final class PipContentView: NSView {
	let imageLayer = CALayer()
	private let cornerRadius: CGFloat = 12
	private let card = PipCardView()
	private let glow = CALayer()
	private var glowScale: CGFloat?
	let resizeView = PipResizeView()
	/// 1 pt rim stroked with a light-to-accent gradient, top to bottom.
	private let rim = CAGradientLayer()
	private let rimMask = CAShapeLayer()

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		wantsLayer = true
		layer?.masksToBounds = false

		// A nine-slice image: the glow is constant along each straight edge, so stretching the
		// center slice resizes it exactly without re-rendering.
		glow.contentsGravity = .resize
		layer?.addSublayer(glow)
		if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
			let pulse = CABasicAnimation(keyPath: "opacity")
			pulse.fromValue = 0.65
			pulse.toValue = 1
			pulse.duration = 1.8
			pulse.autoreverses = true
			pulse.repeatCount = .infinity
			pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
			glow.add(pulse, forKey: "pip-glow-pulse")
		}

		card.wantsLayer = true
		card.layer?.cornerRadius = cornerRadius
		card.layer?.cornerCurve = .continuous
		card.layer?.masksToBounds = true
		card.layer?.backgroundColor = NSColor.black.cgColor
		addSubview(card)

		imageLayer.contentsGravity = .resizeAspect
		imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
		card.layer?.addSublayer(imageLayer)

		rim.colors = [pipHighlightColor.cgColor, pipAccentColor.withAlphaComponent(0.9).cgColor]
		rim.startPoint = CGPoint(x: 0.5, y: 1)
		rim.endPoint = CGPoint(x: 0.5, y: 0)
		rimMask.fillColor = nil
		rimMask.strokeColor = NSColor.white.cgColor
		rimMask.lineWidth = 1
		rim.mask = rimMask
		layer?.addSublayer(rim)

		resizeView.autoresizingMask = [.width, .height]
		addSubview(resizeView)

		for sublayer in [glow, rim, rimMask] { sublayer.actions = ["bounds": NSNull(), "position": NSNull(), "path": NSNull(), "contents": NSNull(), "contentsCenter": NSNull()] }
		setAccessibilityElement(false)
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override var mouseDownCanMoveWindow: Bool { true }

	private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

	/// Standalone layers default to 1x; render the glow and rim at the display's scale.
	override func viewDidChangeBackingProperties() {
		super.viewDidChangeBackingProperties()
		for sublayer in [glow, rim, rimMask] { sublayer.contentsScale = scale }
		needsLayout = true
	}

	override func layout() {
		super.layout()
		let cardFrame = bounds.insetBy(dx: pipGlowPadding, dy: pipGlowPadding)
		card.frame = cardFrame
		imageLayer.frame = card.bounds
		glow.frame = bounds
		resizeView.frame = bounds
		if glowScale != scale {
			glowScale = scale
			let core = 2 * cornerRadius + 4
			let sliceCard = CGRect(x: pipGlowPadding, y: pipGlowPadding, width: core, height: core)
			let sliceSize = CGSize(width: core + 2 * pipGlowPadding, height: core + 2 * pipGlowPadding)
			glow.contents = pipGlowImage(size: sliceSize, cardRect: sliceCard, cornerRadius: cornerRadius, scale: scale)
			let inset = pipGlowPadding + cornerRadius + 1
			glow.contentsCenter = CGRect(x: inset / sliceSize.width, y: inset / sliceSize.height, width: 2 / sliceSize.width, height: 2 / sliceSize.height)
		}
		rim.frame = bounds
		rimMask.frame = bounds
		// Inset by half the line width so the whole stroke lands inside the card edge.
		rimMask.path = CGPath(roundedRect: cardFrame.insetBy(dx: 0.5, dy: 0.5), cornerWidth: cornerRadius - 0.5, cornerHeight: cornerRadius - 0.5, transform: nil)
	}
}

/// View-only picture-in-picture of the window the agent last observed, shown while an agent
/// run with `pip_view` is active and the target isn't the frontmost app. It streams the
/// window through ScreenCaptureKit, so it shows windows behind others or on another Space;
/// minimized windows can't be captured and keep their last frame. The panel never takes
/// focus and is excluded from screen capture; the user can drag it, and it keeps that corner.
/// Dragging the card's border resizes it with the target's aspect ratio; later targets fit
/// the same size.
final class PipViewController: NSObject, SCStreamOutput, SCStreamDelegate {
	private static let maxSize = CGSize(width: 360, height: 270)
	// Enough to follow typing and navigation without costing much CPU.
	private static let frameInterval = CMTime(value: 1, timescale: 8)
	// Keeps the stream across back-to-back runs instead of restarting it.
	private static let hideDelay: TimeInterval = 1.5

	private let stateLock = NSLock()
	private var activeClients = Set<UUID>()
	private var targetWindowId: CGWindowID = 0

	// Main thread only.
	private var panel: PipPanel?
	private var content: PipContentView?
	private var stream: SCStream?
	private var streamWindowId: CGWindowID = 0
	private var streamPid: pid_t?
	private var hasFrame = false
	private var generation = 0
	private var anchor: CGPoint?
	/// Bounding box for the card; starts at `maxSize` and follows the user's last resize.
	private var cardMaxSize = PipViewController.maxSize
	private var streamWindowSize: CGSize = .zero
	private var resizeStartCard: CGRect?
	private static let minCardWidth: CGFloat = 160
	private var movingProgrammatically = false
	private var hideWork: DispatchWorkItem?
	private let frameQueue = DispatchQueue(label: "pi-computer-use.pip-view")

	override init() {
		super.init()
		NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(frontmostChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
	}

	deinit {
		NSWorkspace.shared.notificationCenter.removeObserver(self)
		NotificationCenter.default.removeObserver(self)
	}

	func setActive(_ active: Bool, for clientID: UUID) {
		stateLock.lock()
		if active {
			activeClients.insert(clientID)
		} else {
			activeClients.remove(clientID)
		}
		stateLock.unlock()
		DispatchQueue.main.async { [weak self] in self?.sync() }
	}

	func disconnect(_ clientID: UUID) {
		setActive(false, for: clientID)
	}

	/// Called for every observation; the PIP follows the most recently observed window.
	func setTarget(windowId: CGWindowID) {
		guard windowId > 0 else { return }
		stateLock.lock()
		let changed = targetWindowId != windowId
		targetWindowId = windowId
		stateLock.unlock()
		if changed { DispatchQueue.main.async { [weak self] in self?.sync() } }
	}

	var isActive: Bool {
		stateLock.lock()
		defer { stateLock.unlock() }
		return !activeClients.isEmpty
	}

	private func state() -> (active: Bool, windowId: CGWindowID) {
		stateLock.lock()
		defer { stateLock.unlock() }
		return (!activeClients.isEmpty, targetWindowId)
	}

	private func sync() {
		let (active, windowId) = state()
		guard active, windowId > 0 else {
			scheduleTearDown()
			return
		}
		hideWork?.cancel()
		hideWork = nil
		if windowId != streamWindowId {
			startStream(windowId: windowId)
		} else {
			updateVisibility()
		}
	}

	private func scheduleTearDown() {
		// streamWindowId is set while a stream is still being set up, before `stream` exists.
		guard hideWork == nil, streamWindowId != 0 || stream != nil || panel?.isVisible == true else { return }
		let work = DispatchWorkItem { [weak self] in self?.tearDown() }
		hideWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDelay, execute: work)
		updateVisibility()
	}

	private func tearDown() {
		hideWork = nil
		// A run that started after this was scheduled may not have run its own sync yet.
		stateLock.lock()
		let idle = activeClients.isEmpty
		// A later run starts from its own first observation, not the previous run's window.
		if idle { targetWindowId = 0 }
		stateLock.unlock()
		guard idle else {
			sync()
			return
		}
		generation += 1
		stopStream()
		panel?.orderOut(nil)
	}

	@objc private func frontmostChanged() {
		updateVisibility()
	}

	private func updateVisibility() {
		guard let panel else { return }
		let show = hasFrame && pipShouldShow(
			runActive: isActive || hideWork != nil,
			targetPid: streamPid,
			frontmostPid: NSWorkspace.shared.frontmostApplication?.processIdentifier
		)
		if show {
			if !panel.isVisible { panel.orderFrontRegardless() }
		} else if panel.isVisible {
			panel.orderOut(nil)
		}
	}

	private func stopStream() {
		stream?.stopCapture(completionHandler: nil)
		stream = nil
		streamWindowId = 0
		streamPid = nil
		hasFrame = false
		content?.imageLayer.contents = nil
	}

	private func startStream(windowId: CGWindowID) {
		generation += 1
		let token = generation
		stopStream()
		streamWindowId = windowId
		Task { [weak self] in
			do {
				let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
				let window = shareable.windows.first { $0.windowID == windowId }
				DispatchQueue.main.async { self?.attach(window, token: token) }
			} catch {
				DispatchQueue.main.async { self?.attach(nil, token: token) }
			}
		}
	}

	private func attach(_ window: SCWindow?, token: Int) {
		guard token == generation else { return }
		guard let window else {
			streamWindowId = 0
			updateVisibility()
			return
		}
		let (panel, _) = ensurePanel()
		streamWindowSize = window.frame.size
		let anchor = self.anchor ?? defaultAnchor()
		// The anchor is the padded frame's corner, which may hang past the display; pick the
		// display from the card's own bottom-right corner instead.
		let cardCorner = CGPoint(x: anchor.x - pipGlowPadding, y: anchor.y + pipGlowPadding)
		let screen = NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(cardCorner) } ?? NSScreen.main ?? NSScreen.screens.first
		let maxSize = screen.map { pipCardMaxSize(saved: cardMaxSize, visibleSize: $0.visibleFrame.size) } ?? cardMaxSize
		let size = pipPanelSize(windowSize: window.frame.size, maxSize: maxSize)
		if let screen {
			movingProgrammatically = true
			let paddedSize = CGSize(width: size.width + 2 * pipGlowPadding, height: size.height + 2 * pipGlowPadding)
			// The transparent glow margin may hang past the visible frame; the card stays inside it.
			let outset = pipGlowPadding - pipCardScreenInset
			panel.setFrame(pipPanelFrame(size: paddedSize, anchor: anchor, visibleFrame: screen.visibleFrame.insetBy(dx: -outset, dy: -outset)), display: true)
			movingProgrammatically = false
		}
		streamPid = window.owningApplication?.processID

		let config = Self.streamConfiguration(cardSize: size, scale: screen?.backingScaleFactor ?? 2)
		let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: self)
		do {
			try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
		} catch {
			streamWindowId = 0
			return
		}
		self.stream = stream
		stream.startCapture { [weak self] error in
			guard error != nil else { return }
			DispatchQueue.main.async { self?.streamEnded(stream) }
		}
	}

	private static func streamConfiguration(cardSize: CGSize, scale: CGFloat) -> SCStreamConfiguration {
		let config = SCStreamConfiguration()
		config.width = max(1, Int((cardSize.width * scale).rounded()))
		config.height = max(1, Int((cardSize.height * scale).rounded()))
		config.minimumFrameInterval = frameInterval
		config.pixelFormat = kCVPixelFormatType_32BGRA
		config.queueDepth = 3
		config.showsCursor = false
		config.ignoreShadowsSingleWindow = true
		return config
	}

	private func beginResize() {
		guard let panel else { return }
		resizeStartCard = panel.frame.insetBy(dx: pipGlowPadding, dy: pipGlowPadding)
	}

	/// Resizes with the card's aspect ratio, never past the target window's own size (the
	/// stream can't add detail) or most of the screen.
	private func resize(edges: PipResizeEdges, delta: CGVector) {
		guard let panel, let start = resizeStartCard else { return }
		let visible = (panel.screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
		let windowLimit = streamWindowSize.width > 0 && streamWindowSize.height > 0 ? streamWindowSize : visible
		let limit = pipCardMaxSize(saved: windowLimit, visibleSize: visible)
		let card = pipResizedCardFrame(start: start, delta: delta, edges: edges, minWidth: Self.minCardWidth, maxSize: limit)
		movingProgrammatically = true
		panel.setFrame(card.insetBy(dx: -pipGlowPadding, dy: -pipGlowPadding), display: true)
		movingProgrammatically = false
	}

	private func endResize() {
		resizeStartCard = nil
		guard let panel else { return }
		let card = panel.frame.insetBy(dx: pipGlowPadding, dy: pipGlowPadding)
		cardMaxSize = card.size
		anchor = CGPoint(x: panel.frame.maxX, y: panel.frame.minY)
		// Match the stream's resolution to the new size so frames stay sharp.
		stream?.updateConfiguration(Self.streamConfiguration(cardSize: card.size, scale: panel.backingScaleFactor)) { _ in }
	}

	private func defaultAnchor() -> CGPoint {
		let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
		let outset = pipGlowPadding - pipCardScreenInset
		return CGPoint(x: visible.maxX + outset, y: visible.minY - outset)
	}

	private func ensurePanel() -> (PipPanel, PipContentView) {
		if let panel, let content { return (panel, content) }
		let panel = PipPanel(
			contentRect: CGRect(origin: .zero, size: CGSize(width: Self.maxSize.width + 2 * pipGlowPadding, height: Self.maxSize.height + 2 * pipGlowPadding)),
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		panel.isOpaque = false
		panel.backgroundColor = .clear
		// The accent glow replaces the system shadow.
		panel.hasShadow = false
		panel.level = .floating
		panel.hidesOnDeactivate = false
		panel.becomesKeyOnlyIfNeeded = true
		panel.isMovableByWindowBackground = true
		panel.isReleasedWhenClosed = false
		// Keeps the PIP out of the agent's own captures and out of its accessibility roots.
		panel.sharingType = .none
		panel.setAccessibilityElement(false)
		panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
		let content = PipContentView(frame: CGRect(origin: .zero, size: panel.frame.size))
		content.autoresizingMask = [.width, .height]
		content.resizeView.onBegin = { [weak self] in self?.beginResize() }
		content.resizeView.onDrag = { [weak self] edges, delta in self?.resize(edges: edges, delta: delta) }
		content.resizeView.onEnd = { [weak self] in self?.endResize() }
		panel.contentView = content
		NotificationCenter.default.addObserver(self, selector: #selector(panelMoved), name: NSWindow.didMoveNotification, object: panel)
		self.panel = panel
		self.content = content
		return (panel, content)
	}

	@objc private func panelMoved() {
		guard !movingProgrammatically, let frame = panel?.frame else { return }
		anchor = CGPoint(x: frame.maxX, y: frame.minY)
	}

	private func streamEnded(_ ended: SCStream) {
		guard ended === stream else { return }
		stream = nil
		streamWindowId = 0
		streamPid = nil
		hasFrame = false
		updateVisibility()
	}

	func stream(_ stream: SCStream, didStopWithError error: Error) {
		DispatchQueue.main.async { [weak self] in self?.streamEnded(stream) }
	}

	func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
		guard type == .screen,
			sampleBuffer.isValid,
			let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
			let rawStatus = attachments.first?[.status] as? Int,
			SCFrameStatus(rawValue: rawStatus) == .complete,
			let pixelBuffer = sampleBuffer.imageBuffer,
			let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
		else { return }
		DispatchQueue.main.async { [weak self] in
			guard let self, stream === self.stream, let content = self.content else { return }
			content.imageLayer.contents = surface
			if !self.hasFrame {
				self.hasFrame = true
				self.updateVisibility()
			}
		}
	}
}
