//
//  CircleAnnotationWindow.swift
//  leanring-buddy
//
//  Circle-to-ask: while push-to-talk is recording, a transparent overlay on
//  the cursor's screen lets the user drag an ellipse around something they
//  want Clicky to look at. The bounding rect (in global screen points) is
//  cropped out of the screenshot and attached to the prompt as a labeled
//  "region the user circled" image.
//

import AppKit
import SwiftUI

/// AppKit view that captures a drag and draws the resulting ellipse.
private final class CircleDrawingView: NSView {
    /// Ellipse drawn in this view's coordinates (which are the window's
    /// coordinates = the screen's global AppKit coords offset by the window origin).
    var ellipseRect: NSRect? {
        didSet { needsDisplay = true }
    }

    var dragDidEnd: (() -> Void)?

    private var dragStartPoint: NSPoint? = nil

    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        dragStartPoint = convert(event.locationInWindow, from: nil)
        ellipseRect = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartPoint else { return }
        let dragCurrentPoint = convert(event.locationInWindow, from: nil)
        ellipseRect = NSRect(
            x: min(dragStartPoint.x, dragCurrentPoint.x),
            y: min(dragStartPoint.y, dragCurrentPoint.y),
            width: abs(dragCurrentPoint.x - dragStartPoint.x),
            height: abs(dragCurrentPoint.y - dragStartPoint.y)
        )
    }

    override func mouseUp(with event: NSEvent) {
        dragStartPoint = nil
        dragDidEnd?()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Transparent background — only the ellipse stroke is drawn
        NSColor.clear.setFill()
        dirtyRect.fill()

        guard let ellipseRect else { return }
        let ellipsePath = NSBezierPath(ovalIn: ellipseRect)
        ellipsePath.lineWidth = 3
        NSColor(DS.Colors.overlayCursorBlue).withAlphaComponent(0.9).setStroke()
        ellipsePath.stroke()
    }
}

/// Owns the annotation overlay for one push-to-talk session.
@MainActor
final class CircleAnnotationSession {

    /// The circled region in global AppKit screen coords (nil if the user
    /// never dragged, or dragged a sliver too small to crop).
    private(set) var circledRegionInGlobalPoints: CGRect? = nil

    private var annotationPanel: NSPanel?
    private var drawingView: CircleDrawingView?

    /// Shows a full-screen transparent overlay on the given screen that
    /// captures a drag.
    func begin(onScreen targetScreen: NSScreen) {
        end() // safety: never stack two overlays
        // Reset so a no-drag interaction can't inherit the previous one's circle
        circledRegionInGlobalPoints = nil

        let drawingView = CircleDrawingView(frame: NSRect(origin: .zero, size: targetScreen.frame.size))
        drawingView.autoresizingMask = [.width, .height]
        drawingView.dragDidEnd = { [weak self, weak drawingView] in
            guard let self, let drawingView else { return }
            self.recordCircledRegion(fromDrawingView: drawingView, onScreen: targetScreen)
        }

        let hostingView = NSView(frame: NSRect(origin: .zero, size: targetScreen.frame.size))
        hostingView.addSubview(drawingView)

        let annotationPanel = NSPanel(
            contentRect: targetScreen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        annotationPanel.level = .screenSaver
        annotationPanel.isOpaque = false
        annotationPanel.backgroundColor = .clear
        annotationPanel.hasShadow = false
        annotationPanel.isExcludedFromWindowsMenu = true
        annotationPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        annotationPanel.contentView = hostingView

        annotationPanel.orderFrontRegardless()

        self.annotationPanel = annotationPanel
        self.drawingView = drawingView
    }

    /// Hides the overlay. Called when the transcript finalizes or the
    /// interaction is cancelled.
    func end() {
        annotationPanel?.orderOut(nil)
        annotationPanel = nil
        drawingView = nil
    }

    private func recordCircledRegion(fromDrawingView drawingView: CircleDrawingView, onScreen targetScreen: NSScreen) {
        guard let ellipseRect = drawingView.ellipseRect,
              ellipseRect.width > 16, ellipseRect.height > 16 else {
            circledRegionInGlobalPoints = nil
            return
        }

        // Drawing view coords are window-local; the window fills the screen,
        // so add the screen origin to get global AppKit coords.
        circledRegionInGlobalPoints = NSRect(
            x: ellipseRect.origin.x + targetScreen.frame.origin.x,
            y: ellipseRect.origin.y + targetScreen.frame.origin.y,
            width: ellipseRect.width,
            height: ellipseRect.height
        ).integral
    }

    /// Crops the circled region out of the cursor screen's capture and returns
    /// a labeled image block for the API. Returns nil when nothing was circled.
    func circledRegionImageBlock(fromScreenCapture capture: CompanionScreenCapture) -> (data: Data, label: String)? {
        guard let circledRegion = circledRegionInGlobalPoints,
              let fullScreenshot = NSBitmapImageRep(data: capture.imageData)?.cgImage else {
            return nil
        }

        // Global points → local points on this display → screenshot pixels
        let localRegion = CGRect(
            x: circledRegion.origin.x - capture.displayFrame.origin.x,
            y: circledRegion.origin.y - capture.displayFrame.origin.y,
            width: circledRegion.width,
            height: circledRegion.height
        )

        let scaleX = CGFloat(capture.screenshotWidthInPixels) / CGFloat(capture.displayWidthInPoints)
        let scaleY = CGFloat(capture.screenshotHeightInPixels) / CGFloat(capture.displayHeightInPoints)

        // AppKit points are bottom-left origin; the screenshot is top-left origin
        let pixelRect = CGRect(
            x: localRegion.origin.x * scaleX,
            y: (CGFloat(capture.displayHeightInPoints) - localRegion.maxY) * scaleY,
            width: localRegion.width * scaleX,
            height: localRegion.height * scaleY
        ).integral

        let clampedPixelRect = pixelRect.intersection(CGRect(
            x: 0, y: 0,
            width: capture.screenshotWidthInPixels,
            height: capture.screenshotHeightInPixels
        ))
        guard !clampedPixelRect.isEmpty,
              let croppedImage = fullScreenshot.cropping(to: clampedPixelRect),
              let croppedData = NSBitmapImageRep(cgImage: croppedImage)
                  .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return nil
        }

        return (
            data: croppedData,
            label: "the region the user circled on their screen (pay close attention to this area)"
        )
    }
}
