import SwiftUI

extension Notification.Name { static let furnitureLibraryDrop = Notification.Name("home.furnitureLibraryDrop") }

/// Direct pointer dragging avoids Catalyst's long-press-based SwiftUI drag initiation.
struct FurnitureDragTile: UIViewRepresentable {
    let title: String
    let image: UIImage?
    let payload: String
    let add: () -> Void
    func makeUIView(context:Context) -> FurnitureTileView { FurnitureTileView() }
    func updateUIView(_ view:FurnitureTileView,context:Context) {
        view.caption.text = title; view.picture.image = image; view.payload = payload; view.add = add; view.accessibilityLabel = "添加"+title
    }
}
final class FurnitureTileView: UIView {
    let picture = UIImageView(), caption = UILabel()
    var payload = ""
    var add: (() -> Void)?
    private var ghost: UIImageView?
    override init(frame:CGRect) {
        super.init(frame:frame); backgroundColor = AppTheme.surfaceUI; layer.cornerRadius = 10
        isAccessibilityElement = true; accessibilityTraits = .button
        picture.contentMode = .scaleAspectFit; caption.font = .systemFont(ofSize:12); caption.numberOfLines = 2; caption.textAlignment = .center
        addSubview(picture); addSubview(caption)
        let tap = UITapGestureRecognizer(target:self,action:#selector(activate))
        let pan = UIPanGestureRecognizer(target:self,action:#selector(drag(_:))); pan.maximumNumberOfTouches = 1
        tap.require(toFail:pan); addGestureRecognizer(tap); addGestureRecognizer(pan)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); picture.frame = CGRect(x:6,y:6,width:bounds.width-12,height:bounds.height-40); caption.frame = CGRect(x:4,y:bounds.height-34,width:bounds.width-8,height:30) }
    override func accessibilityActivate() -> Bool { add?(); return true }
    @objc private func activate() { add?() }
    @objc private func drag(_ gesture:UIPanGestureRecognizer) {
        guard let window else { return }
        let point = gesture.location(in:window)
        switch gesture.state {
        case .began:
            let image = UIImageView(image:picture.image); image.contentMode = .scaleAspectFit; image.frame.size = CGSize(width:90,height:90); image.alpha = 0.8; image.isUserInteractionEnabled = false; image.center = point; window.addSubview(image); ghost = image
        case .changed: ghost?.center = point
        case .ended:
            ghost?.removeFromSuperview(); ghost = nil
            NotificationCenter.default.post(name:.furnitureLibraryDrop,object:window,userInfo:["payload":payload,"point":NSValue(cgPoint:point)])
        case .cancelled,.failed: ghost?.removeFromSuperview(); ghost = nil
        default: break
        }
    }
}
