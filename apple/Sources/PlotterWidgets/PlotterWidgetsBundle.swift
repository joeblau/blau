import WidgetKit
import SwiftUI

@main
struct PlotterWidgetsBundle: WidgetBundle {
    var body: some Widget {
        PlotterSnapshotWidget()
        PlotterLiveActivity()
    }
}
