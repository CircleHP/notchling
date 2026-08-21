//
//  What the panel can ask the app to do.
//
//  One value rather than a closure apiece. Each action used to be declared five times on the way down
//  — a stored property, an initialiser parameter, an assignment and a pass-through, in
//  `WidgetController`, `WidgetPresenter`, `WidgetRoot`, `WidgetView` and `ExpandedView` — and the cost
//  was never the typing. It was that every new action is five chances to wire the wrong one, in a
//  chain where the compiler cannot tell one `() -> Void` from another, and where getting it wrong
//  means a button that silently does some other button's job.
//
//  Deliberately not here: `onHover` and `onContentGeometry`. Those report *out* of the view tree
//  rather than asking the app for anything, and they belong to one presenter rather than being shared
//  by all of them.
//

import Foundation

struct WidgetActions {
    /// Bring the terminal that owns this session to the front.
    let focus: (Session) -> Void

    /// Quit and come straight back, from whichever copy is on disk now — which after an upgrade is not
    /// the one running. Both the header button and the upgrade notice use this.
    let restart: () -> Void

    /// Ask launchd to let go, after confirming. Not `terminate`: see `LaunchAgent`.
    let stop: () -> Void

    /// Open the settings window.
    let settings: () -> Void
}
