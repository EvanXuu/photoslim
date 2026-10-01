#if os(iOS) && PHOTOSLIM_UNIFIED_APP
#if SWIFT_PACKAGE
import PhotoSlimMediaCore
#endif
import SwiftUI
import UIKit

/// Native zooming updates the scrollable area, unlike a scaleEffect on a fit image.
/// The same scroll view survives comparisons, rotation, and display resizing.
struct PhotoSlimiOSZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> PhotoSlimZoomingScrollView {
        PhotoSlimZoomingScrollView()
    }

    func updateUIView(_ view: PhotoSlimZoomingScrollView, context: Context) {
        view.display(image)
    }
}

final class PhotoSlimZoomingScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var lastSize = CGSize.zero
    private var relativeZoom: CGFloat = 1

    init() {
        super.init(frame: .zero)
        delegate = self
        backgroundColor = .black
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        bouncesZoom = true
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = L10n("照片")
        imageView.accessibilityTraits = .image
        imageView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: L10n("放大"), target: self, selector: #selector(photoSlimZoomIn)),
            UIAccessibilityCustomAction(name: L10n("缩小"), target: self, selector: #selector(photoSlimZoomOut)),
            UIAccessibilityCustomAction(name: L10n("适合窗口"), target: self, selector: #selector(photoSlimFit))
        ]
        addSubview(imageView)
        let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func display(_ image: UIImage) {
        guard imageView.image !== image else { return }
        relativeZoom = minimumZoomScale > 0 ? zoomScale / minimumZoomScale : 1
        zoomScale = 1
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size
        lastSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = imageView.image, bounds.width > 0, bounds.height > 0,
              image.size.width > 0, image.size.height > 0 else { return }
        if lastSize != bounds.size {
            if lastSize != .zero, minimumZoomScale > 0 {
                relativeZoom = zoomScale / minimumZoomScale
            }
            let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
            minimumZoomScale = fit
            maximumZoomScale = max(1, fit * 8)
            zoomScale = min(maximumZoomScale, max(fit, fit * relativeZoom))
            lastSize = bounds.size
        }
        centerImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    private func centerImage() {
        let x = max(0, (bounds.width - imageView.frame.width) / 2)
        let y = max(0, (bounds.height - imageView.frame.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        imageView.accessibilityValue = "\(Int((zoomScale / max(minimumZoomScale, 0.001) * 100).rounded()))%"
    }

    @objc private func photoSlimZoomIn() -> Bool {
        setZoomScale(min(maximumZoomScale, zoomScale * 2), animated: !UIAccessibility.isReduceMotionEnabled)
        return true
    }

    @objc private func photoSlimZoomOut() -> Bool {
        setZoomScale(max(minimumZoomScale, zoomScale / 2), animated: !UIAccessibility.isReduceMotionEnabled)
        return true
    }

    @objc private func photoSlimFit() -> Bool {
        setZoomScale(minimumZoomScale, animated: !UIAccessibility.isReduceMotionEnabled)
        return true
    }

    @objc private func doubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale * 1.1 {
            setZoomScale(minimumZoomScale, animated: !UIAccessibility.isReduceMotionEnabled)
        } else {
            let targetZoom = min(maximumZoomScale, minimumZoomScale * 3)
            let point = gesture.location(in: imageView)
            let size = CGSize(width: bounds.width / targetZoom, height: bounds.height / targetZoom)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height),
                 animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }
}
#endif
