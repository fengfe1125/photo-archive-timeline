import SwiftUI
import UIKit

/// Stable page identities prevent a completed swipe from being reapplied to a
/// shifted three-item window. Only the current page and its neighbors are kept.
struct MediaDetailPager<Page: View>: UIViewControllerRepresentable {
  let mediaIDs: [String]
  @Binding var currentID: String
  let content: (String, Bool) -> Page

  init(mediaIDs: [String], currentID: Binding<String>, @ViewBuilder content: @escaping (String, Bool) -> Page) {
    self.mediaIDs = mediaIDs
    _currentID = currentID
    self.content = content
  }

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  func makeUIViewController(context: Context) -> UIPageViewController {
    let controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
    controller.view.backgroundColor = .clear
    controller.view.accessibilityIdentifier = "media-detail-pager"
    controller.dataSource = context.coordinator
    controller.delegate = context.coordinator
    context.coordinator.update(self, controller: controller)
    return controller
  }

  func updateUIViewController(_ controller: UIPageViewController, context: Context) {
    context.coordinator.update(self, controller: controller)
  }

  static func dismantleUIViewController(_ controller: UIPageViewController, coordinator: Coordinator) {
    controller.delegate = nil
    controller.dataSource = nil
    coordinator.releasePages()
  }

  @MainActor final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    private var parent: MediaDetailPager
    private var ids: [String] = []
    private var indexByID: [String: Int] = [:]
    private var pages: [String: PageController] = [:]
    private var displayedID: String?
    private var transitioning = false

    init(parent: MediaDetailPager) { self.parent = parent }

    func update(_ parent: MediaDetailPager, controller: UIPageViewController) {
      self.parent = parent
      // Keep the data source and hosting roots unchanged while UIKit is settling
      // an interactive transition. New cursor contents are applied on completion.
      guard !transitioning else { return }
      updateIDs()
      guard indexByID[parent.currentID] != nil else {
        releasePages()
        displayedID = nil
        controller.setViewControllers(nil, direction: .forward, animated: false)
        return
      }
      if displayedID != parent.currentID || controller.viewControllers?.isEmpty != false {
        displayedID = parent.currentID
        controller.setViewControllers([page(for: parent.currentID)], direction: .forward, animated: false)
      }
      refreshAndTrimPages()
    }

    private func updateIDs() {
      guard ids != parent.mediaIDs else { return }
      ids = parent.mediaIDs
      indexByID = Dictionary(ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
    }

    private func page(for id: String) -> PageController {
      if let page = pages[id] { return page }
      let page = PageController(id: id, rootView: parent.content(id, id == displayedID))
      page.view.backgroundColor = .clear
      pages[id] = page
      return page
    }

    private func neighbor(of controller: UIViewController, offset: Int) -> UIViewController? {
      guard let page = controller as? PageController, let index = indexByID[page.mediaID] else { return nil }
      let neighbor = index + offset
      guard ids.indices.contains(neighbor) else { return nil }
      return self.page(for: ids[neighbor])
    }

    func pageViewController(_ controller: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
      neighbor(of: viewController, offset: -1)
    }

    func pageViewController(_ controller: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
      neighbor(of: viewController, offset: 1)
    }

    func pageViewController(_ controller: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
      transitioning = true
    }

    func pageViewController(_ controller: UIPageViewController, didFinishAnimating finished: Bool,
      previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
      transitioning = false
      if completed, let page = controller.viewControllers?.first as? PageController {
        displayedID = page.mediaID
        // Publish once, after UIKit has committed this stable page identity.
        parent.currentID = page.mediaID
      }
      updateIDs()
      refreshAndTrimPages()
    }

    private func refreshAndTrimPages() {
      guard let displayedID, let index = indexByID[displayedID] else { return }
      let retained = Set(ids[max(0, index - 1)...min(ids.count - 1, index + 1)])
      for (id, page) in pages {
        // Replacing the same hosting root preserves its SwiftUI state while
        // active=false cancels requests/playback as soon as the page leaves.
        page.rootView = parent.content(id, id == displayedID && retained.contains(id))
      }
      pages = pages.filter { retained.contains($0.key) }
    }

    func releasePages() {
      for (id, page) in pages { page.rootView = parent.content(id, false) }
      pages.removeAll()
    }
  }

  @MainActor final class PageController: UIHostingController<Page> {
    let mediaID: String
    init(id: String, rootView: Page) {
      mediaID = id
      super.init(rootView: rootView)
    }
    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is unavailable") }
  }
}
