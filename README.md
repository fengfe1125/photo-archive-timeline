# Photo Archive

[English](README.md) · [简体中文](README.zh-CN.md)

An offline-first photo archive for iPhone, with a web timeline for media you choose to import.

- **Organize:** Turn moments from your Photos library into editable stories. Your iPhone archive works offline.
- **Sync on your terms:** Story metadata sync and original-media upload use separate, opt-in controls; original uploads are off by default.
- **Web import:** Add photos and videos from folders you select.

iPhone metadata sync excludes original files, previews, PhotoKit local identifiers, local paths, and full EXIF. Separately enabled original-media uploads may include embedded EXIF.

## Get started

- iPhone app: [setup](ios/README.md) (iOS 18+)
- Web importer: configure your Supabase URL and publishable key in ios/Local.xcconfig, then run:

~~~sh
npm install
npm run cloud:import -- --dir /path/to/photos
~~~

The importer sends a one-time email code before upload. To build the static web client, run:

~~~sh
npm run cloud:build
~~~

See [Supabase setup](docs/ios-supabase-setup.md).

Built with SwiftUI, PhotoKit, SwiftData, TypeScript, and Supabase.
