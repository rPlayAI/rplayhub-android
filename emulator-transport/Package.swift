// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EmulatorTransport",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "EmulatorTransport", targets: ["EmulatorTransport"]),
        .executable(name: "emulator-probe", targets: ["emulator-probe"]),
        .executable(name: "emulator-bridge", targets: ["emulator-bridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "1.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
    ],
    targets: [
        .target(
            name: "EmulatorTransport",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .executableTarget(name: "emulator-probe", dependencies: ["EmulatorTransport"]),
        .executableTarget(name: "emulator-bridge", dependencies: [
            "EmulatorTransport",
            .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
        ]),
    ]
)
