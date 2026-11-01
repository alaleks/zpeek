Output examples/demo.gif

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

Type "/tables"
Enter
Sleep 1500ms

Type "orders"
Sleep 800ms
Enter
Sleep 2s

Right 3
Type "s"
Sleep 1s
Type "s"
Sleep 2s
Left 2
Type "f"
Sleep 3s

Type "q"
Sleep 500ms
Type "select item, total_usd from orders where total_usd >= 100;"
Enter
Sleep 4s

Hide
Ctrl+D
