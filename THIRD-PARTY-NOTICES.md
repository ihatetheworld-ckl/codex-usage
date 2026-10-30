# Third-party components

Codex Usage source and the original CU logo are provided under Apache-2.0.

- The Windows portable build includes the Microsoft .NET runtime and Windows Desktop runtime. .NET is licensed under MIT; its distribution also includes third-party components. See [dotnet/runtime license](https://github.com/dotnet/runtime/blob/main/LICENSE.TXT) and [third-party notices](https://github.com/dotnet/runtime/blob/main/THIRD-PARTY-NOTICES.TXT).
- The macOS application links to operating-system frameworks supplied by Apple and includes the Swift runtime where required by the operating system.
- Codex CLI is a separately installed prerequisite. It is not redistributed in these application archives.

The build workflow preserves the runtime license and third-party notice files supplied by the .NET publish output and adds this file, LICENSE, and NOTICE to each distribution.
