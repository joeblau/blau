# blau

Three-app ecosystem + landing page.

## Apple Apps (Pilot macOS, Copilot iOS, Wingman watchOS)

```bash
cd apple
brew bundle
xcodegen generate
open blau.xcodeproj
```

## Web (blau.app)

```bash
cd workers/web
bun install
bun run dev
```
