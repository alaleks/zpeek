Output examples/demo.gif
Output examples/demo.mp4

Require sqlite3

Set Shell "bash"
Set FontSize 18
Set Width 1180
Set Height 680
Set Framerate 12
Set TypingSpeed 25ms
Set Theme "Catppuccin Mocha"

Hide
Type "mkdir -p .zig-cache/demo"
Enter
Type "sqlite3 .zig-cache/demo/zpeek-demo.db < examples/demo.sql"
Enter
Type "export ZPEEK_CONFIG=/dev/null XDG_STATE_HOME=$PWD/.zig-cache/demo/state"
Enter
Type "unset NO_COLOR"
Enter
Type "clear"
Enter

Type "./zig-out/bin/zpeek .zig-cache/demo/zpeek-demo.db"
Enter
Sleep 1s
Show

# 0–5s: connected SQLite session.
Set TypingSpeed 100ms
Sleep 5s

# 5–12s: choose orders from /tables.
Type "/tables"
Enter@100ms
Sleep 2s

Type "orders"
Enter@100ms
Sleep 3500ms

# 12–22s: customer_id -> related customer. Keep the FK preview visible.
Right@100ms
Sleep 1400ms
Type "f"
Sleep 8400ms

# 22–35s: SQL autocomplete, then results.
Type "q"
Sleep 400ms
Type "SELECT * FROM ord"
Sleep 2300ms
Tab@100ms
Type " WHERE total_usd >= 100;"
Enter@100ms
Sleep 6s

Hide
Ctrl+D
