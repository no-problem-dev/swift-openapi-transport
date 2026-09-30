# OpenAPIHTTPTransport

[English](./README.md) | 日本語

[swift-openapi-generator](https://github.com/apple/swift-openapi-generator) が作るクライアントを [swift-http-transport](https://github.com/no-problem-dev/swift-http-transport) の上で動かす。Bearer トークンを付け、サーバーが 401 を返したら1回だけ取り直して送り直す。

![Swift 6.2+](https://img.shields.io/badge/Swift-6.2+-orange.svg)
![Platforms](https://img.shields.io/badge/Platforms-iOS%2017%20%7C%20macOS%2014%20%7C%20tvOS%2017%20%7C%20watchOS%2010%20%7C%20visionOS%201-blue.svg)
![License](https://img.shields.io/badge/License-MIT-green.svg)

## 特徴

- **swift-http-transport で動く `ClientTransport`**: `HTTPTransportClientTransport` はどの `HTTPTransport` でも送れる。`RetryingTransport` で包めば待ち時間の伸ばし方と `Retry-After` が効き、テストでは `MockTransport` を渡せる
- **送り直してよいかを操作ごとに決める**: `isIdempotent` は `operationId` とメソッドを受け取り、その答えを `RetryingTransport` が送り直す前に見る。既定は RFC 9110 の規則なので、POST は明示しない限り送り直さない
- **401 には強制の更新で1回だけ応える**: `BearerTokenMiddleware` は `forceRefresh: false` でトークンを取り、401 が返ったら `forceRefresh: true` で取り直して送り直す。2回目の 401 はそのまま返す。取り直したトークンが拒まれたものと同じなら送り直さない
- **同時に失敗した要求は更新を1回にまとめる**: 同じトークンで拒まれた要求は1回の更新を待ち合わせる。更新が終わった後で 401 を知った要求も、その結果を使う
- **2回読めない本文は送り直さない**: 要求の本文が `.single` なら、空の本文で送り直さず 401 を返す
- **トークンはクロージャで受ける**: `@Sendable (_ forceRefresh: Bool) async throws -> String`。準拠する protocol が無いので、どの認証ライブラリも1行でつなげる
- **依存の最低版が低い**: swift-openapi-runtime 1.0.0・swift-http-types 1.0.0・swift-http-transport 2.0.0 から。生成器と swift-openapi-urlsession には依存しない

## 使い方

```swift
import HTTPTransport          // クライアントを組み立てるファイルでだけ
import OpenAPIHTTPTransport

let client = Client(
    serverURL: try Servers.Server1.url(),
    transport: HTTPTransportClientTransport(
        RetryingTransport(base: URLSessionTransport(), policy: ExponentialBackoff()),
        isIdempotent: { operationID, method in
            // 行の押しはサーバーが stamp で重複を除くので、送り直しても安全
            operationID == "pushRows" || HTTPTransportClientTransport.defaultIdempotency(operationID, method)
        }
    ),
    middlewares: [
        LoggingMiddleware(),
        // 最後に置く。上の middleware は最終の応答だけを見る
        BearerTokenMiddleware { forceRefresh in
            guard let token = try await auth.token(forceRefresh: forceRefresh) else {
                throw NotSignedIn()   // 資格情報なしで送らず、送る前に失敗させる
            }
            return token
        },
    ]
)
```

生成コードが使う swift-http-types と swift-http-transport は、どちらも `HTTPRequest`・`HTTPResponse` を持つ。このパッケージは swift-http-transport を再公開しないので、`HTTPTransport` はクライアントを組み立てるファイルでだけ import する。ほかのファイルでは `HTTPRequest` は swift-http-types のものを指したままになる。

SSE のような長く続く本文は生成クライアントを通さない。ここでは本文をまとめて読む。流れは `HTTPStreamingTransport` で直接読む。

## ドキュメント

API リファレンスは [GitHub Pages](https://no-problem-dev.github.io/swift-openapi-transport/documentation/openapihttptransport/) にある。

## インストール

`Package.swift` に追加する:

```swift
dependencies: [
    .package(url: "https://github.com/no-problem-dev/swift-openapi-transport.git", .upToNextMinor(from: "0.1.0"))
]
```

ターゲットに追加する:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "OpenAPIHTTPTransport", package: "swift-openapi-transport")
    ]
)
```

## ライセンス

MIT License - 詳細は [LICENSE](LICENSE) を参照。
