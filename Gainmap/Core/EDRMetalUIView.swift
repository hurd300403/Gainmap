//
//  EDRMetalUIView.swift
//  GainmapCore — the production UIKit twin of the Mac app's EDRMetalNSView (P5).
//
//  Renders an extended-range (linear, values >1) CIImage as true EDR via
//  CAMetalLayer + rgba16Float + wantsExtendedDynamicRangeContent — the same
//  reliable path the Mac uses. The render body is a verbatim port; only the
//  view-host plumbing differs (layerClass, layoutSubviews, displayScale).
//

#if canImport(UIKit)
import UIKit
import SwiftUI
import Metal
import CoreImage

public final class EDRMetalUIView: UIView {
    override public class var layerClass: AnyClass { CAMetalLayer.self }

    private let device = MTLCreateSystemDefaultDevice()
    private var queue: MTLCommandQueue?
    private var ciContext: CIContext?
    private let edrSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    public var ciImage: CIImage? { didSet { render() } }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        if let device {
            queue = device.makeCommandQueue()
            ciContext = CIContext(mtlDevice: device, options: [.workingColorSpace: edrSpace])
        }
        if let l = metalLayer {
            l.device = device
            l.pixelFormat = .rgba16Float
            l.framebufferOnly = false
            l.wantsExtendedDynamicRangeContent = true
            l.colorspace = edrSpace
            l.isOpaque = true
        }
    }
    required public init?(coder: NSCoder) { nil }

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    override public func layoutSubviews() {
        super.layoutSubviews()
        updateScale()
        render()
    }

    private func updateScale() {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        metalLayer?.contentsScale = scale
        metalLayer?.drawableSize = CGSize(width: max(1, bounds.width * scale),
                                          height: max(1, bounds.height * scale))
    }

    private func render() {
        guard let metalLayer, let ciContext, let queue, let ciImage,
              bounds.width > 1 else { return }
        let ds = metalLayer.drawableSize
        guard ds.width > 1, let drawable = metalLayer.nextDrawable(),
              let cb = queue.makeCommandBuffer() else { return }

        // Aspect-FIT the image into the drawable (show the whole frame in its
        // native aspect, never cropped), composited over black for the letterbox.
        let ext = ciImage.extent
        let scale = min(ds.width / ext.width, ds.height / ext.height)
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let sExt = scaled.extent
        let positioned = scaled.transformed(by: CGAffineTransform(
            translationX: (ds.width - sExt.width) / 2 - sExt.minX,
            y: (ds.height - sExt.height) / 2 - sExt.minY))
        let drawableRect = CGRect(origin: .zero, size: ds)
        let framed = positioned.composited(over: CIImage(color: .black).cropped(to: drawableRect))

        ciContext.render(framed, to: drawable.texture, commandBuffer: cb,
                         bounds: drawableRect, colorSpace: edrSpace)
        cb.present(drawable)
        cb.commit()
    }
}

public struct EDRMetalView: UIViewRepresentable {
    let image: CIImage?

    public init(image: CIImage?) { self.image = image }
    public func makeUIView(context: Context) -> EDRMetalUIView { EDRMetalUIView() }
    public func updateUIView(_ v: EDRMetalUIView, context: Context) { v.ciImage = image }
}

#endif
