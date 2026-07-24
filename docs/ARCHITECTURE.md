# Remora Architecture

This document gives a high-level view of how the three main modules fit together.

## Module Roles

- `RemoraCore`: SSH, SFTP, host models, credential handling, host key trust, and shared
  session abstractions.
- `RemoraTerminal`: SwiftTerm adapter layer plus app-facing terminal view integration.
- `RemoraApp`: SwiftUI application shell, workspace UI, settings, file manager, transfer
  flows, and runtime orchestration.

## High-Level Diagram

```mermaid
flowchart LR
    User["User"] --> App["RemoraApp\nSwiftUI workspace"]
    App --> Runtime["TerminalRuntime / ViewModels"]
    Runtime --> Core["RemoraCore\nSSH / SFTP / Security / Models"]
    Runtime --> Terminal["RemoraTerminal\nSwiftTerm Adapter / Terminal View"]
    Core --> Hub["RemoteSessionHub\nshared leases and lifecycle"]
    Hub --> SSH["LibSSH2Transport\nshell / exec / direct-tcpip"]
    Hub --> SFTP["RemoteFileSystem\nnative / administrator SFTP"]
    Core --> Local["LocalShellSession"]
    Terminal --> UI["TerminalView / Renderer"]
    SSH --> Host["Remote host or JumpServer target"]
    SFTP --> Host
    Local --> Shell["Local zsh PTY"]
    UI --> App
```

## Typical Data Flow

1. `RemoraApp` collects user intent from the SwiftUI workspace, settings, or file manager.
2. View models and `TerminalRuntime` translate that intent into session and transfer
   actions.
3. Remote terminal, command, file, metrics, Docker, and forwarding workflows acquire
   leases from `RemoteSessionHub` and share one authenticated native SSH session.
4. `RemoraCore` exposes typed shell, command, file-system, and forwarding capabilities;
   authentication challenges and host-key decisions are handled before a session becomes usable.
5. `RemoraTerminal` bridges shell channel data into SwiftTerm and exposes the terminal view back to the app UI.

## Boundary Rules

- `RemoraApp` owns user-facing workflow and presentation state.
- `RemoraTerminal` stays focused on terminal integration concerns and isolates SwiftTerm from the app layer.
- `RemoraCore` owns transport, persistence, security, and reusable domain logic.
- App-level features should prefer depending on `RemoraCore` and `RemoraTerminal` rather
  than re-implementing protocol or parser behavior in the UI layer.
