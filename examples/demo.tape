Output examples/demo.gif
Output examples/demo.mp4

Require sqlite3

Set Shell "bash"
Set FontSize 18
Set Width 1180
Set Height 680
Set Framerate 12
Set TypingSpeed 60ms
Set Theme "Catppuccin Mocha"

Hide
Type "mkdir -p .zig-cache/demo"
Enter
Type "sqlite3 .zig-cache/demo/dev.db < examples/demo.sql"
Enter
Type "sqlite3 .zig-cache/demo/prod.db < examples/demo.sql"
Enter
Type "export XDG_STATE_HOME=$PWD/.zig-cache/demo/state"
Enter
Type "unset NO_COLOR"
Enter
Type "clear"
Enter

Type "./zig-out/bin/zpeek --config examples/demo.toml"
Enter
Sleep 1s
Show

# Video 5–12s: browse orders from the dev connection.
Type "/tables"
Enter@100ms
Sleep 800ms
Type "orders"
Enter@100ms
Sleep 5200ms

# Video 12–22s: follow customer_id to the related customer.
Right@100ms
Sleep 900ms
Type "f"
Sleep 1500ms
Down@100ms
Sleep 1000ms
Enter@100ms
Sleep 1800ms
Escape@100ms
Sleep 4340ms

# Video 22–30s: SQL autocomplete and result.
Type "q"
Sleep 200ms
Type "q"
Sleep 100ms
Type "SELECT * FROM ord"
Sleep 500ms
Tab@100ms
Type " WHERE total_usd >= 100;"
Enter@100ms
Sleep 4420ms

# Video 30–36s: show both saved connections, switch to prod.
Type "/connect"
Enter@100ms
Sleep 1200ms
Down@100ms
Sleep 800ms
Enter@100ms
Sleep 3200ms

Hide
Ctrl+D
