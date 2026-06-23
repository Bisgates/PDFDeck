// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PDFDeck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PDFDeck",
            path: "Sources/PDFDeck"
        )
    ]
)
