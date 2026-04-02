import SwiftUI

struct SampleItem: Identifiable {
    let id: Int
    let title: String
}

struct ContentView: View {
    let items: [SampleItem] = (0..<50).map {
        SampleItem(id: $0, title: "Item \($0)")
    }

    var body: some View {
        NavigationStack {
            VolumeScrollListView(items: items) { item, isHighlighted in
                HStack {
                    Text(item.title)
                        .fontWeight(isHighlighted ? .semibold : .regular)
                    Spacer()
                    if isHighlighted {
                        Image(systemName: "chevron.right")
                    }
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Copilot")
        }
    }
}

#Preview {
    ContentView()
}
