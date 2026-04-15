import Foundation

enum CLI {
    static func parse(arguments: [String]) -> CommandLineOptions {
        var command: Command = .help
        var interval: TimeInterval = 5
        var depth = 8
        var verbose = false
        var databasePath: String?
        var promptForPermissions = false
        var openSettings = false

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "doctor":
                command = .doctor
            case "setup":
                command = .setup
            case "inspect":
                command = .inspect
            case "sync-once":
                command = .syncOnce
            case "watch":
                command = .watch
            case "--prompt":
                promptForPermissions = true
            case "--open-settings":
                openSettings = true
            case "--interval":
                if index + 1 < arguments.count, let value = Double(arguments[index + 1]) {
                    interval = value
                    index += 1
                }
            case "--depth":
                if index + 1 < arguments.count, let value = Int(arguments[index + 1]) {
                    depth = value
                    index += 1
                }
            case "--db":
                if index + 1 < arguments.count {
                    databasePath = arguments[index + 1]
                    index += 1
                }
            case "--verbose":
                verbose = true
            case "--help", "-h", "help":
                command = .help
            default:
                break
            }
            index += 1
        }

        return CommandLineOptions(
            command: command,
            interval: interval,
            depth: depth,
            verbose: verbose,
            databasePath: databasePath,
            promptForPermissions: promptForPermissions,
            openSettings: openSettings
        )
    }

    static func printHelp() {
        let help = """
        wechat-sync

        Commands:
          doctor                   Check WeChat presence and macOS accessibility permission.
          setup                    Prompt for permission and open Accessibility settings.
          inspect [--depth N]      Dump visible text nodes from the WeChat window.
          sync-once [--db PATH]    Read the visible transcript and persist it into SQLite.
          watch [--interval N]     Poll WeChat and continuously sync visible transcript.

        Options:
          --db PATH                Override the SQLite database path.
          --interval N             Poll interval in seconds for watch. Default: 5
          --depth N                Accessibility tree depth for inspect. Default: 8
          --prompt                 Ask macOS to show the Accessibility permission prompt.
          --open-settings          Open the Accessibility page in System Settings.
          --verbose                Print extra debug information.
        """
        print(help)
    }
}
