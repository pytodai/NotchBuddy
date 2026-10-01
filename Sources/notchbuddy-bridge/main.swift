import Darwin
import NotchBuddyCore

// notchbuddy-bridge --source <claude|codex|kimi>   — agent hook: forwards the event to NotchBuddy.
// notchbuddy-bridge statusline                    — Claude Code statusLine: caches rate limits, prints one line.
// notchbuddy-bridge hooks <install|uninstall|status> [agent|all] — manage hook configs (interactive use).
//
// Whatever happens, the agent must not notice us: no stray stdout, exit 0 unless an adapter says otherwise.

BridgeIO.installSignalHandlers()

let exitCode: Int32
switch BridgeCommand.parse(Array(CommandLine.arguments.dropFirst())) {
case .hook(let source):
    exitCode = HookCommand.run(source: source)
case .statusLine:
    exitCode = StatusLineCommand.run()
case .hooks(let action, let sources):
    exitCode = HooksCommand.run(action, sources: sources)
case .usage(let message):
    BridgeIO.write(message + "\n", to: STDERR_FILENO)
    exitCode = 0
}
exit(exitCode)
